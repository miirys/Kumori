// Runs the real app against a stand-in rig: NVIDIA's services are faked in the main process,
// the signalling socket is intercepted, and the "rig" is a second WebRTC peer inside the
// window that sends video, the input handshake and cursor messages like GeForce NOW does.
//
//   xvfb-run -a node test/e2e.cjs      
const { _electron } = require('playwright-core');
const assert = require('node:assert/strict');
const path = require('node:path');

const jwt = () => {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b({ alg: 'none' })}.${b({ sub: 'u1', exp: Math.floor(Date.now() / 1000) + 86400, preferred_username: 'Tester', email: 't@example.com', gfn_tier: 'ULTIMATE' })}.x`;
};

(async () => {
  // KUMORI_BIN runs the packaged app instead of the source tree.
  const packaged = process.env.KUMORI_BIN;
  const app = await _electron.launch({ executablePath: packaged || require(path.join(__dirname, '..', 'node_modules', 'electron')), args: packaged ? ['--no-sandbox'] : [path.join(__dirname, '..'), '--no-sandbox'], env: { ...process.env } });
  const token = jwt();
  await app.evaluate(({ ipcMain }, token) => {
    const game = (id, title) => ({ id: `g${id}`, title, publisherName: 'Studio', genres: ['ACTION'], images: {},
      variants: [{ id: String(1000 + id), appStore: 'STEAM', gfn: { library: { status: 'IN_LIBRARY', selected: true, lastPlayedDate: '2026-11-01T10:00:00Z' } } }] });
    let polls = 0;
    const session = (status) => ({ requestStatus: { statusCode: 1 }, session: { sessionId: 'sess-1', status, gpuType: 'RTX 5080',
      seatSetupInfo: { queuePosition: 0, seatSetupStep: 2 },
      connectionInfo: [{ usage: 14, ip: '127-0-0-1.rig.nvidiagrid.net', port: 443, resourcePath: '/nvst/' }, { usage: 2, ip: '127-0-0-1.rig.nvidiagrid.net', port: 9 }],
      monitorSettings: [{ widthInPixels: 1280, heightInPixels: 720, framesPerSecond: 60 }] } });
    globalThis.requests = [];
    const answer = ({ url, method, body }) => {
      globalThis.requests.push({ url, method, body });
      if (url.includes('serviceUrls')) return { gfnServiceInfo: { defaultProvider: 'NVIDIA', gfnServiceEndpoints: [{ idpId: 'idp', loginProvider: 'NVIDIA', streamingServiceUrl: 'https://prod.cloudmatchbeta.nvidiagrid.net/' }] } };
      if (url.includes('serverInfo')) return { requestStatus: { serverId: 'NP-TEST' }, metaData: [{ key: 'EU West', value: 'https://eu.cloudmatchbeta.nvidiagrid.net' }] };
      if (url.includes('graphql')) return { data: { apps: { pageInfo: { hasNextPage: false }, items: [game(1, 'Alpha Quest'), game(2, 'Beta Racer'), game(3, 'Gamma Tactics')] } } };
      if (url.includes('subscriptions')) return { membershipTier: 'ULTIMATE', subType: 'UNLIMITED', features: { resolutions: [] } };
      if (url.endsWith('/v2/session') && method === 'GET') return { requestStatus: { statusCode: 1 }, sessions: [] };
      if (url.includes('/v2/session') && method === 'POST') return session(1);
      if (url.includes('/v2/session/') && method === 'GET') return session(++polls >= 1 ? 2 : 1);
      if (url.includes('/v2/session/') && method === 'DELETE') return { requestStatus: { statusCode: 1 } };
      return null;
    };
    ipcMain.removeHandler('http');
    ipcMain.handle('http', (_e, req) => { const j = answer(req); return j ? { status: 200, text: JSON.stringify(j) } : { status: 404, text: '{}' }; });
    ipcMain.removeHandler('store:get');
    ipcMain.handle('store:get', () => ({ deviceId: 'dev-1', tokens: { access: token, id: token, client: 'c', refresh: null, expiresAt: Date.now() + 86400000 },
      settings: { fullscreen: false, stats: true, resolution: '1280x720', codec: process.env.CODEC || 'AUTO' } }));
    ipcMain.removeHandler('store:set');
    ipcMain.handle('store:set', () => {});
    ipcMain.removeHandler('ping');
    ipcMain.handle('ping', () => 12);
  }, token);

  const page = await app.firstWindow();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });

  // The signalling socket: every message from the app goes to the stand-in rig and back.
  await page.exposeFunction('__fromRig', (text) => socket?.send(text));
  let socket = null;
  let signInUrl = null;
  await page.routeWebSocket(/sign_in/, (ws) => {
    socket = ws;
    signInUrl = ws.url();
    ws.onMessage((m) => page.evaluate((t) => window.__rig.onClient(t), String(m)).catch(() => {}));
  });
  await page.reload();
  await page.evaluate(() => {
    const rig = window.__rig = { packets: [], cursor: null, answer: null, pc: null, channels: [] };
    const send = (msg) => window.__fromRig(JSON.stringify({ peer_msg: { from: 1, to: 0, msg: JSON.stringify(msg) }, ackid: Date.now() % 100000 }));
    rig.onClient = async (text) => {
      const j = JSON.parse(text);
      if (j.peer_info) return rig.start();
      const m = j.peer_msg && JSON.parse(j.peer_msg.msg);
      if (!m) return;
      if (m.type === 'answer') { rig.answer = m; await rig.pc.setRemoteDescription({ type: 'answer', sdp: m.sdp }); } else if (m.candidate) rig.pc.addIceCandidate(m).catch(() => {});
    };
    rig.start = async () => {
      const pc = rig.pc = new RTCPeerConnection();
      const canvas = Object.assign(document.createElement('canvas'), { width: 1280, height: 720 });
      const ctx = canvas.getContext('2d');
      let n = 0;
      setInterval(() => { ctx.fillStyle = `hsl(${n++ % 360} 60% 40%)`; ctx.fillRect(0, 0, 1280, 720); }, 16);
      for (const t of canvas.captureStream(60).getTracks()) pc.addTrack(t);
      pc.createDataChannel('control_channel');
      pc.onicecandidate = (e) => { if (e.candidate) send(e.candidate.toJSON()); };
      pc.ondatachannel = ({ channel }) => {
        channel.binaryType = 'arraybuffer';
        rig.channels.push(channel.label);
        if (channel.label === 'cursor_channel') rig.cursor = channel;
        if (channel.label.startsWith('input_channel')) {
          channel.onmessage = (e) => rig.packets.push([...new Uint8Array(e.data)]);
          // The rig opens input by announcing protocol version 3.
          if (channel.label === 'input_channel_v1') { const hello = () => channel.send(new Uint8Array([0x0e, 0x02, 3, 0])); if (channel.readyState === 'open') hello(); else channel.onopen = hello; }
        }
      };
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      send({ type: 'offer', sdp: offer.sdp });
    };
    // A cursor message as the rig sends it: kind, id, hotspot, mime, image, position, scale.
    rig.sendCursor = (kind, id, hx, hy, mime, image, tail = []) => {
      const enc = new TextEncoder();
      const m = enc.encode(mime);
      const i = enc.encode(image);
      rig.cursor.send(new Uint8Array([kind, id, hx, hy, m.length, ...m, i.length & 255, i.length >> 8, ...i, ...tail]));
    };
    // The record type of each input packet received, with its fields.
    rig.decoded = () => rig.packets.map((p) => {
      const d = new DataView(new Uint8Array(p).buffer);
      if (p.length === 4) return { type: 'heartbeat' };
      if (p[0] !== 0x23) return { type: 'raw' };
      const at = p[9] === 0x21 ? 12 : p[9] === 0x22 ? 10 : 16;
      const type = d.getUint32(at, true);
      if (type === 5) return { type: 'abs', x: d.getUint16(at + 4), y: d.getUint16(at + 6) };
      if (type === 7) return { type: 'rel', dx: d.getInt16(at + 4), dy: d.getInt16(at + 6) };
      if (type === 3 || type === 4) return { type: type === 3 ? 'keydown' : 'keyup', vk: d.getUint16(at + 4), scan: d.getUint16(at + 8) };
      if (type === 8 || type === 9) return { type: type === 8 ? 'mousedown' : 'mouseup', button: p[at + 4] };
      if (type === 10) return { type: 'wheel', delta: d.getInt16(at + 6) };
      return { type: `other${type}` };
    });
  });

  const step = (name) => console.log('ok -', name);
  // Library, from the faked catalogue.
  await page.waitForSelector('.tile');
  assert.equal(await page.locator('#account b').textContent(), 'Tester');
  assert.ok((await page.locator('.tile').count()) >= 3);
  assert.ok(!(await page.locator('#content').textContent()).includes('[object'));
  await page.waitForSelector('h2:has-text("Continue playing")');
  step('signed in and library shown');

  // Keyboard navigation and the gamepad layout.
  await page.keyboard.press('ArrowDown');
  assert.ok(await page.evaluate(() => document.activeElement.classList.contains('tile')));
  const firstTitle = await page.evaluate(() => document.activeElement.title);
  await page.keyboard.press('ArrowRight');
  assert.notEqual(await page.evaluate(() => document.activeElement.title), firstTitle);
  step('arrow keys move between tiles');
  await page.click('text=Settings');
  await page.locator('.row', { hasText: 'Layout' }).locator('i').last().click();
  assert.ok(await page.evaluate(() => document.body.classList.contains('pad')));
  await page.locator('.row', { hasText: 'Layout' }).focus();
  await page.keyboard.press('ArrowLeft');
  assert.ok(!(await page.evaluate(() => document.body.classList.contains('pad'))));
  step('settings steppers and layout switch');
  await page.screenshot({ path: process.env.SHOTS ? `${process.env.SHOTS}/settings.png` : undefined }).catch(() => {});
  await page.click('text=Library');
  await page.fill('#search', 'beta');
  await page.waitForSelector('h2:has-text("Results")');
  await page.fill('#search', '');
  step('search');
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/library.png` });

  // Start a game.
  await page.locator('.tile', { hasText: 'Alpha Quest' }).first().click();
  await page.click('#detail .btn.primary');
  await page.waitForFunction(() => !document.getElementById('stream').hidden, null, { timeout: 30000 });
  await page.waitForFunction(() => document.getElementById('video').videoWidth > 0, null, { timeout: 15000 });
  const created = await app.evaluate(() => JSON.parse(globalThis.requests.find((r) => r.method === 'POST' && r.url.includes('/v2/session')).body));
  assert.equal(created.sessionRequestData.appId, 1001);
  assert.equal(created.sessionRequestData.clientRequestMonitorSettings[0].widthInPixels, 1280);
  assert.ok(signInUrl.includes('pairing_id=sess-1') && signInUrl.includes('peer_role=1'));
  const rig = await page.evaluate(() => ({ channels: window.__rig.channels, nvst: window.__rig.answer.nvstSdp }));
  assert.deepEqual(rig.channels.sort(), ['cursor_channel', 'input_channel_partially_reliable', 'input_channel_v1']);
  assert.ok(rig.nvst.includes('a=video.maxFPS:60') && rig.nvst.includes('a=general.iceUserNameFragment:'));
  step(`stream connected, video decoding (${await page.evaluate(() => document.getElementById('video').videoWidth)}px wide)`);

  const video = page.locator('#video');
  const box = await video.boundingBox();
  const cursorCss = () => page.evaluate(() => document.getElementById('video').style.cursor);
  const decoded = () => page.evaluate(() => window.__rig.decoded().filter((p) => p.type !== 'heartbeat'));
  const clear = () => page.evaluate(() => { window.__rig.packets.length = 0; });
  await page.waitForFunction(() => window.__rig.packets.length > 0, null, { timeout: 10000 });
  await page.waitForTimeout(300);

  // Keyboard.
  await clear();
  await page.keyboard.press('KeyW');
  await page.waitForTimeout(150);
  assert.deepEqual((await decoded()).filter((p) => p.type.startsWith('key')), [{ type: 'keydown', vk: 0x57, scan: 0x1a }, { type: 'keyup', vk: 0x57, scan: 0x1a }]);
  step('keys reach the rig');

  // A visible cursor: the system pointer takes the game's shape and positions are sent.
  await page.evaluate(() => window.__rig.sendCursor(0, 2, 0, 0, '', ''));
  await page.waitForFunction(() => document.getElementById('video').style.cursor === 'text');
  step('standard cursor shape shown locally (text)');
  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  await page.evaluate((png) => window.__rig.sendCursor(1, 9, 5, 7, 'image/png', png), png);
  await page.waitForFunction(() => document.getElementById('video').style.cursor.includes('data:image/png'));
  const css = await cursorCss();
  assert.match(css, /url\("?data:image\/png;base64,iVBOR[^)]*\)( [\d.]+x\))? \d+ \d+, default/);
  step(`game cursor image with hotspot shown locally: ${css.replace(/base64,[^")]+/, 'base64,...')}`);
  await clear();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 4);
  await page.waitForTimeout(150);
  const abs = (await decoded()).filter((p) => p.type === 'abs').pop();
  // The picture is letterboxed inside the window, so the expected position is worked out from it.
  const picH = Math.min(box.height, (box.width * 9) / 16);
  const wantY = ((box.height / 4 - (box.height - picH) / 2) / picH) * 65535;
  assert.ok(abs && Math.abs(abs.x - 32768) < 400 && Math.abs(abs.y - wantY) < 400, JSON.stringify([abs, wantY]));
  step(`pointer position sent as a position (${abs.x}, ${abs.y} of 65535)`);
  await clear();
  await page.mouse.down();
  await page.mouse.up();
  await page.mouse.wheel(0, 100);
  await page.waitForTimeout(150);
  const clicks = (await decoded()).map((p) => p.type);
  assert.ok(clicks.includes('mousedown') && clicks.includes('mouseup') && clicks.includes('wheel'), clicks.join());
  assert.equal(await page.evaluate(() => document.pointerLockElement), null);
  step('click and wheel sent, pointer not captured while the cursor is visible');

  // The game hides its cursor (mouse-look): the pointer is captured and raw movement is sent.
  await page.evaluate(() => window.__rig.sendCursor(0, 0, 0, 0, '', ''));
  let locked = await page.waitForFunction(() => document.pointerLockElement === document.getElementById('video'), null, { timeout: 3000 }).then(() => true, () => false);
  if (!locked) { await video.click(); locked = await page.evaluate(() => document.pointerLockElement === document.getElementById('video')); }
  assert.ok(locked, 'pointer lock');
  assert.equal(await cursorCss(), 'none');
  await clear();
  await page.mouse.move(box.x + box.width / 2 + 40, box.y + box.height / 4 + 10);
  await page.waitForTimeout(150);
  const rel = (await decoded()).filter((p) => p.type === 'rel');
  assert.ok(rel.length > 0, 'relative movement');
  assert.ok(!(await decoded()).some((p) => p.type === 'abs'));
  step(`cursor hidden by the game: pointer captured, raw movement sent (${rel.length} packets)`);

  // The cursor comes back (a menu opens): the pointer is released with the cached game image.
  await page.evaluate(() => window.__rig.sendCursor(1, 9, 0, 0, '', '', [0x00, 0x80, 0x00, 0x80]));
  await page.waitForFunction(() => document.pointerLockElement === null);
  assert.match(await cursorCss(), /data:image\/png/);
  step('cursor shown again: pointer released, cached game image restored');

  // Captured mode: the pointer stays held and the cursor is drawn by the app.
  await page.keyboard.press('Control+KeyG');
  await page.waitForSelector('#menu:not([hidden])');
  // Opening the menu lets go of held keys, and those releases can still be on their way.
  await page.waitForTimeout(200);
  await clear();
  await page.keyboard.press('KeyA');
  await page.waitForTimeout(150);
  assert.deepEqual((await decoded()).filter((p) => p.type !== 'keyup'), []);
  step('menu open: the game gets no input');
  await page.locator('#menu .row', { hasText: 'Cursor' }).locator('i').last().click();
  await page.locator('#menu .row', { hasText: 'Back to the game' }).click();
  await page.waitForFunction(() => document.pointerLockElement === document.getElementById('video'), null, { timeout: 3000 }).catch(() => video.click());
  await page.waitForFunction(() => !document.getElementById('pointer').hidden, null, { timeout: 3000 });
  await clear();
  const before = await page.evaluate(() => document.getElementById('pointer').style.transform);
  await page.mouse.move(box.x + box.width / 2 + 90, box.y + box.height / 4 + 60);
  await page.waitForTimeout(150);
  assert.notEqual(await page.evaluate(() => document.getElementById('pointer').style.transform), before);
  assert.ok((await decoded()).some((p) => p.type === 'abs'));
  step('captured mode: cursor drawn by the app, moved locally, positions sent');

  await page.waitForFunction(() => /cursor: local, game image/.test(document.getElementById('stats').textContent), null, { timeout: 4000 });
  const stats = await page.locator('#stats').textContent();
  step(`stats: ${stats.split('\n').join(' | ')}`);
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/stream.png` });

  // End the session.
  await page.keyboard.press('Control+KeyG');
  await page.locator('#menu .row', { hasText: 'End the session' }).click();
  await page.waitForFunction(() => document.getElementById('stream').hidden);
  assert.ok(await app.evaluate(() => globalThis.requests.some((r) => r.method === 'DELETE' && r.url.includes('/v2/session/sess-1'))));
  step('session ended on the rig');
  assert.deepEqual(errors, []);
  await app.close();
  console.log('all passed');
})().catch((e) => { console.error('FAILED:', e.message.split('\n').slice(0, 6).join('\n')); process.exit(1); });
