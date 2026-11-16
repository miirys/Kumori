import test from 'node:test';
import assert from 'node:assert/strict';
import * as Sdp from '../app/js/sdp.js';
import { InputEncoder, handshakeVersion, keyFor, padReport, X } from '../app/js/input.js';
import { parseCursor, CursorState } from '../app/js/cursor.js';
import { dlssJson, createBody, parseSession, message } from '../app/js/cloudmatch.js';

const OFFER = [
  'v=0', 'c=IN IP4 0.0.0.0', 'a=ice-ufrag:abcd', 'a=ice-pwd:pw', 'a=fingerprint:sha-256 AA:BB',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111', 'a=rtpmap:111 opus/48000/2', 'a=fmtp:111 minptime=10;useinbandfec=1',
  'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99', 'a=rtpmap:96 H264/90000', 'a=rtpmap:97 rtx/90000', 'a=fmtp:97 apt=96',
  'a=rtpmap:98 AV1/90000', 'a=rtpmap:99 rtx/90000', 'a=fmtp:99 apt=98', 'a=rtcp-fb:98 nack',
  'a=candidate:1 1 udp 2130706431 0.0.0.0 49005 typ host',
  'm=application 9 UDP/DTLS/SCTP webrtc-datachannel', 'a=ri.partialReliableThresholdMs:250',
].join('\r\n');

test('sdp: server address, codecs and credentials', () => {
  assert.equal(Sdp.publicIp('80-250-97-40.cloudmatchbeta.nvidiagrid.net'), '80.250.97.40');
  const fixed = Sdp.fixServerIp(OFFER, '80-250-97-40.x.net');
  assert.ok(fixed.includes('c=IN IP4 80.250.97.40'));
  assert.ok(fixed.includes('2130706431 80.250.97.40 49005'));
  assert.deepEqual([...Sdp.offeredCodecs(OFFER)].sort(), ['AV1', 'H264', 'RTX']);
  assert.equal(Sdp.partialReliableThreshold(OFFER), 250);
  assert.deepEqual(Sdp.credentials(OFFER), { ufrag: 'abcd', pwd: 'pw', fingerprint: 'AA:BB' });
  const kept = Sdp.keepCodec(OFFER, 'AV1');
  assert.ok(kept.includes('m=video 9 UDP/TLS/RTP/SAVPF 98 99'));
  assert.ok(!kept.includes('H264'));
  assert.equal(Sdp.negotiatedCodec(kept), 'AV1');
  const munged = Sdp.mungeAnswer(OFFER, 50000);
  assert.ok(munged.includes('m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99\r\nb=AS:50000'));
  assert.ok(munged.includes('useinbandfec=1;stereo=1'));
});

test('sdp: nvst description carries the stream settings', () => {
  const s = Sdp.nvst({ width: 2560, height: 1440, viewportWidth: 2560, viewportHeight: 1440, fps: 120, maxKbps: 50000,
    codec: 'AV1', bitDepth: 8, partialReliableMs: 250, ice: { ufrag: 'u', pwd: 'p', fingerprint: 'f' } });
  for (const l of ['a=general.iceUserNameFragment:u', 'a=video.maxFPS:120', 'a=vqos.bw.maximumBitrateKbps:50000',
    'a=vqos.bw.minimumBitrateKbps:20000', 'a=video.initialBitrateKbps:35000', 'a=packetPacing.numGroups:3',
    'a=video.minQp:25', 'a=ri.partialReliableThresholdMs:250']) assert.ok(s.includes(l + '\n'), l);
});

test('input: packets match the wire layout', () => {
  const e = new InputEncoder();
  const k = new DataView(e.key(true, 0x41, 0x04, 1));
  assert.equal(k.byteLength, 18);
  assert.equal(k.getUint32(0, true), 3);
  assert.equal(k.getUint16(4), 0x41);
  assert.equal(k.getUint16(6), 1);
  assert.equal(k.getUint16(8), 0x04);
  const m = new DataView(e.mouseMove(-5, 70000));
  assert.equal(m.getUint32(0, true), 7);
  assert.equal(m.getInt16(4), -5);
  assert.equal(m.getInt16(6), 32767);
  const a = new DataView(e.mouseAbsolute(32768, 70000));
  assert.equal(a.byteLength, 26);
  assert.equal(a.getUint32(0, true), 5);
  assert.equal(a.getUint16(4), 32768);
  assert.equal(a.getUint16(6), 65535);
  assert.equal(a.getUint16(10), 65535);
  assert.equal(a.getUint16(12), 65535);
  const b = new DataView(e.mouseButton(false, 3));
  assert.equal(b.getUint32(0, true), 9);
  assert.equal(b.getUint8(4), 3);
  assert.equal(new DataView(e.wheel(-120)).getInt16(6), -120);
  const g = new DataView(e.gamepad(1, 3, X.A | X.UP, 255, 0, 100, -100, 0, 0, true));
  assert.equal(g.byteLength, 38);
  assert.equal(g.getUint16(12, true), X.A | X.UP);
  assert.equal(g.getUint16(14, true), 255);
  assert.equal(g.getInt16(18, true), -100);
});

test('input: version 3 wraps records', () => {
  const e = new InputEncoder();
  e.version = 3;
  const k = new DataView(e.key(true, 0x41, 0x04, 0));
  assert.equal(k.byteLength, 28);
  assert.equal(k.getUint8(0), 0x23);
  assert.equal(k.getUint8(9), 0x22);
  const m = new DataView(e.mouseAbsolute(1, 2));
  assert.equal(m.getUint8(9), 0x21);
  assert.equal(m.getUint16(10), 26);
  const g = new DataView(e.gamepad(2, 4, 0, 0, 0, 0, 0, 0, 0, true));
  assert.equal(g.byteLength, 54);
  assert.equal(g.getUint8(9), 0x26);
  assert.equal(g.getUint8(10), 2);
  assert.equal(g.getUint16(11), 1);
  assert.equal(new DataView(e.gamepad(2, 4, 0, 0, 0, 0, 0, 0, 0, true)).getUint16(11), 2);
  assert.equal(e.heartbeat().byteLength, 4);
});

test('input: handshake, keys and pads', () => {
  assert.equal(handshakeVersion(new Uint8Array([0x0e, 0x02, 3, 0])), 3);
  assert.equal(handshakeVersion(new Uint8Array([0x0e, 0x00])), 14);
  assert.equal(handshakeVersion(new Uint8Array([1, 2, 3])), null);
  assert.deepEqual(keyFor('KeyW'), { vk: 0x57, scan: 0x1a });
  assert.deepEqual(keyFor('Digit1'), { vk: 0x31, scan: 0x1e });
  assert.deepEqual(keyFor('Escape'), { vk: 0x1b, scan: 0x29 });
  assert.equal(keyFor('Nope'), null);
  const pad = { buttons: Array.from({ length: 17 }, (_, i) => ({ pressed: i === 0 || i === 12, value: i === 7 ? 0.5 : 0 })), axes: [1, 1, 0.01, -1] };
  assert.deepEqual(padReport(pad), { buttons: X.A | X.UP, lt: 0, rt: 128, lx: 32767, ly: -32768, rx: 0, ry: 32767 });
});

const cursorBytes = (kind, id, hx, hy, mime, image, tail = []) =>
  new Uint8Array([kind, id, hx, hy, mime.length, ...Buffer.from(mime), image.length & 255, image.length >> 8, ...Buffer.from(image), ...tail]);

test('cursor: standard shapes, hidden cursor and game images', () => {
  const c = new CursorState();
  assert.equal(c.relative, false);
  assert.ok(c.apply(parseCursor(cursorBytes(0, 2, 0, 0, '', ''))));
  assert.equal(c.css(), 'text');
  assert.ok(c.seen);
  // The game hides the cursor: raw movement, and the last shape is kept for when it returns.
  c.apply(parseCursor(cursorBytes(0, 0, 0, 0, '', '')));
  assert.equal(c.relative, true);
  // A game image with a hotspot, then the position it reappears at.
  const img = parseCursor(cursorBytes(1, 7, 4, 9, 'image/png', 'QUJD', [0x00, 0x80, 0xff, 0xff, 200, 0]));
  assert.deepEqual({ id: img.id, hotX: img.hotX, hotY: img.hotY, mime: img.mime, data: img.data, x: img.x, y: img.y, scale: img.scale },
    { id: 7, hotX: 4, hotY: 9, mime: 'image/png', data: 'QUJD', x: 32768, y: 65535, scale: 2 });
  c.apply(img);
  assert.equal(c.relative, false);
  assert.deepEqual(c.position, { x: 32768, y: 65535 });
  assert.equal(c.css(0.5), 'url(data:image/png;base64,QUJD) 4 9, default');
  assert.equal(c.css(1), 'image-set(url(data:image/png;base64,QUJD) 2.00x) 2 5, default');
  // Named again by id only: the cached image is reused.
  c.apply(parseCursor(cursorBytes(0, 1, 0, 0, '', '')));
  assert.equal(c.css(), 'default');
  c.apply(parseCursor(cursorBytes(1, 7, 0, 0, '', '')));
  assert.ok(c.css(0.5).startsWith('url(data:image/png;base64,QUJD)'));
  // An image id never sent, a standard id out of range and a short message change nothing.
  assert.equal(c.apply(parseCursor(cursorBytes(1, 99, 0, 0, '', ''))), false);
  assert.equal(c.apply(parseCursor(cursorBytes(0, 40, 0, 0, '', ''))), false);
  assert.equal(parseCursor(new Uint8Array([1, 2, 3])), null);
  assert.equal(parseCursor(new Uint8Array([1, 1, 0, 0, 0, 50, 0, 65])), null);
});

test('cloudmatch: request body, DLSS and session parsing', () => {
  assert.deepEqual(dlssJson({ srModel: 0, srMode: 3, rrModel: 0, fgModel: 0, fgMultiplier: 0 }),
    { srMode: 0, srModel: 0, srScale: 100, rrModel: 0, fgMode: 0, fgModel: 0 });
  assert.deepEqual(dlssJson({ srModel: 12, srMode: 2, rrModel: 1, fgModel: 1, fgMultiplier: 4 }),
    { srMode: 2, srModel: 12, srScale: 58, rrModel: 1, fgMode: 1, fgModel: 1, fgMultiplier: 4 });
  const body = createBody({ appId: '123', width: 2560, height: 1440, fps: 120, route: 'WEB', title: 'Game', accountLinked: true, lowLatency: true }, 'dev');
  const d = body.sessionRequestData;
  assert.equal(d.appId, 123);
  assert.equal(d.clientPlatformName, 'browser');
  assert.equal(d.clientRequestMonitorSettings[0].framesPerSecond, 120);
  assert.equal(d.requestedStreamingFeatures.reflex, true);
  assert.equal(d.requestedStreamingFeatures.dlssOverrides.srModel, 0);
  assert.ok(d.metaData.some((m) => m.key === 'GSStreamerType' && m.value === 'WebRTC'));
  const s = parseSession({ session: { sessionId: 'abc', status: 2, gpuType: 'RTX', seatSetupInfo: { queuePosition: 0, seatSetupStep: 2 },
    connectionInfo: [{ usage: 14, ip: '80-1-2-3.x.net', port: 443, resourcePath: '/nvst/' }, { usage: 2, ip: '80-1-2-3.x.net', port: 49005 }],
    iceServerConfiguration: { iceServers: [{ urls: 'stun:a:1' }, { urls: ['turn:b:2'], username: 'u', credential: 'c' }] },
    monitorSettings: [{ widthInPixels: 2560, heightInPixels: 1440, framesPerSecond: 120 }] } }, 'https://base');
  assert.equal(s.id, 'abc');
  assert.equal(s.ready, true);
  assert.equal(s.signalingUrl, 'wss://80-1-2-3.x.net:443/nvst/');
  assert.deepEqual(s.media, { ip: '80-1-2-3.x.net', port: 49005 });
  assert.equal(s.ice.length, 2);
  assert.equal(s.height, 1440);
  assert.match(message(13, null, 200), /playtime/);
  assert.match(message(0, 'X_ABCDEF12', 500), /Error ABCDEF12/);
});
