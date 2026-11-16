// The GeForce NOW session service: start a game on a cloud rig, follow it through the queue,
// pick up one started elsewhere, and end it.
import { send, uuid } from './http.js';

export class SessionError extends Error {
  constructor(message, statusCode = 0, http = 0, description = null) {
    super(message);
    this.statusCode = statusCode;
    this.http = http;
    this.description = description;
  }
  /** A refusal of this stream shape, not of the account, so a simpler one is worth asking for. */
  get stepDown() {
    return [2, 3, 4, 5, 8, 18, 68].includes(this.statusCode) || this.http >= 500 || /INTERNAL/i.test(this.description ?? '');
  }
}

const BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
const VERSION = '2.0.88.129';
const str = (o, k) => (o && o[k] != null ? String(o[k]) : '');
const first = (v) => (typeof v === 'string' ? v : Array.isArray(v) ? v[0] : null) || null;
export const isZoneHost = (h) => h.includes('cloudmatchbeta.nvidiagrid.net') || h.includes('cloudmatch.nvidiagrid.net');
export const hostOf = (url) => url.replace(/^https?:\/\//, '').split('/')[0];
function hostOfUrl(url) {
  const m = /^(?:rtsps?|wss|https):\/\/([^/:]+)/.exec(url);
  return m ? m[1] : null;
}

/** DLSS settings the rig forces on a game, with the numbers the official client sends. Zero leaves a setting to the game. */
export function dlssJson(d = {}) {
  const srModel = d.srModel ?? 0;
  const mode = srModel === 0 ? 0 : d.srMode ?? 0;
  const fgModel = d.fgModel ?? 0;
  const dynamic = fgModel !== 0 && d.fgMultiplier >= 3 && d.fgMultiplier <= 6;
  const o = { srMode: mode, srModel, srScale: { 1: 50, 2: 58, 3: 67, 4: 33 }[mode] ?? 100, rrModel: d.rrModel ?? 0, fgMode: dynamic ? 1 : 0, fgModel };
  if (dynamic) o.fgMultiplier = d.fgMultiplier;
  return o;
}

const monitor = (r) => ({
  monitorId: 0, positionX: 0, positionY: 0, widthInPixels: r.width, heightInPixels: r.height, framesPerSecond: r.fps, sdrHdrMode: 0,
  displayData: { desiredContentMaxLuminance: 0, desiredContentMinLuminance: 0, desiredContentMaxFrameAverageLuminance: 0 }, dpi: 100,
});

const features = (r) => ({
  reflex: !!r.lowLatency && r.fps >= 120, bitDepth: 0, cloudGsync: false, enabledL4S: false, mouseMovementFlags: 0, trueHdr: false,
  supportedHidDevices: 0, profile: 0, fallbackToLogicalResolution: false, hidDevices: null, chromaFormat: 0, prefilterMode: 0,
  prefilterSharpness: 0, prefilterNoiseReduction: 0, hudStreamingMode: 0, sdrColorSpace: 2, hdrColorSpace: 0,
});

const meta = (r) => [
  ['SubSessionId', uuid()], ['wssignaling', '1'], ['GSStreamerType', 'WebRTC'], ['networkType', 'Unknown'], ['ClientImeSupport', '0'],
  ['clientPhysicalResolution', JSON.stringify({ horizontalPixels: r.width, verticalPixels: r.height })], ['surroundAudioInfo', '2'],
].map(([key, value]) => ({ key, value }));

// The stream is always asked for over WebRTC. DESKTOP only borrows the PC app's list of sizes.
const common = (r) => ({
  availableSupportedControllers: [], networkTestSessionId: null, parentSessionId: null, clientIdentification: 'GFN-PC',
  clientVersion: '30.0', streamerVersion: 1, sdkVersion: '1.0', enhancedStreamMode: 1, secureRTSPSupported: false,
  clientPlatformName: r.route === 'DESKTOP' ? 'windows' : 'browser', clientRequestMonitorSettings: [monitor(r)], useOps: true,
  audioMode: 2, metaData: meta(r), sdrHdrMode: 0, clientDisplayHdrCapabilities: null, surroundAudioInfo: 0, remoteControllersBitmap: 0,
  clientTimezoneOffset: -new Date().getTimezoneOffset() * 60000, appLaunchMode: 1, partnerCustomData: '',
  enablePersistingInGameSettings: r.route === 'DESKTOP', userAge: 26,
});

export function createBody(r, deviceId) {
  return { sessionRequestData: {
    ...common(r), appId: Number(r.appId), internalTitle: r.title ?? null, deviceHashId: deviceId, accountLinked: r.accountLinked !== false,
    // Only a new session carries the DLSS settings. Picking one up keeps what it was started with.
    requestedStreamingFeatures: { ...features(r), dlssOverrides: dlssJson(r.dlss) },
  } };
}

/** Taking over a session asks for this device's stream shape. */
export function claimBody(appId, r) {
  return { action: 2, data: 'RESUME', metaData: [], sessionRequestData: {
    ...common(r), appId: Number(appId) || 0, internalTitle: null, deviceHashId: uuid(), accountLinked: true, requestedStreamingFeatures: features(r),
  } };
}

function signalingUrl(path, ip) {
  if (/^rtsps?:\/\//.test(path)) return `wss://${hostOfUrl(path) ?? `${ip}:443`}/nvst/`;
  if (path.startsWith('wss://')) return path;
  if (path.startsWith('https://')) return path.replace('https://', 'wss://');
  if (path.startsWith('/')) return `wss://${ip}:443${path}`;
  return `wss://${ip}:443/nvst/`;
}

function portOf(c) {
  if (c.port > 0) return c.port;
  const m = /:(\d+)(?:\/|$)/.exec(str(c, 'resourcePath').replace(/^[a-z]+:\/\//, ''));
  return m ? Number(m[1]) : 0;
}

function media(list, serverIp) {
  const from = (c, fallback) => {
    const ip = first(c.ip) ?? hostOfUrl(str(c, 'resourcePath')) ?? fallback;
    const port = portOf(c);
    return ip && port > 0 ? { ip, port } : null;
  };
  for (const usage of [2, 17]) {
    const c = list.find((x) => Number(x.usage) === usage);
    const e = c && from(c, null);
    if (e) return e;
  }
  for (const c of list.filter((x) => Number(x.usage) === 14).sort((a, b) => (b.port ?? 0) - (a.port ?? 0))) {
    const e = from(c, serverIp);
    if (e) return e;
  }
  return null;
}

export function parseSession(j, base) {
  const s = j?.session;
  if (!s) throw new SessionError("The session service didn't describe the session.");
  const list = (s.connectionInfo ?? []).filter(Boolean);
  const usage = (c) => Number(c.usage);
  const signal = list.find((c) => /^(wss|https):\/\//.test(str(c, 'resourcePath')) && [14, 16].includes(usage(c))) ??
    list.find((c) => usage(c) === 14) ?? list.find((c) => usage(c) === 16);
  const serverIp = (signal && (first(signal.ip) ?? hostOfUrl(str(signal, 'resourcePath')))) ?? first(s.sessionControlInfo?.ip);
  const mon = s.monitorSettings?.[0] ?? s.sessionRequestData?.clientRequestMonitorSettings?.[0];
  const pos = (o) => (o?.queuePosition > 0 ? o.queuePosition : null);
  const status = Number(s.status) || 0;
  return {
    id: str(s, 'sessionId'), status, ready: status === 2 || status === 3,
    queuePosition: pos(s) ?? pos(s.seatSetupInfo) ?? pos(s.sessionProgress) ?? pos(s.progressInfo),
    setupStep: s.seatSetupInfo?.seatSetupStep ?? null, controlBase: base, serverIp,
    signalingUrl: serverIp ? signalingUrl(str(signal, 'resourcePath'), serverIp) : null,
    media: media(list, serverIp),
    ice: (s.iceServerConfiguration?.iceServers ?? []).map((o) => ({
      urls: [].concat(o?.urls ?? []).filter(Boolean), username: o?.username || undefined, credential: o?.credential || undefined,
    })).filter((o) => o.urls.length),
    gpu: s.gpuType && s.gpuType !== 'null' ? s.gpuType : null,
    width: mon?.widthInPixels || null, height: mon?.heightInPixels || null, fps: mon?.framesPerSecond || null,
    adsRequired: !!(s.sessionAdsRequired || s.isAdsRequired),
  };
}

/** A session listed for the account, possibly started on another device. */
export function parseActive(j, base) {
  const id = str(j, 'sessionId');
  const status = Number(j.status);
  if (!id || !(status >= 1 && status <= 6)) return null;
  const req = j.sessionRequestData ?? {};
  const mon = j.monitorSettings?.[0] ?? req.clientRequestMonitorSettings?.[0];
  const signal = (j.connectionInfo ?? []).find((c) => Number(c?.usage) === 14);
  return {
    sessionId: id, appId: String(req.appId ?? ''), status, streamingBase: base,
    serverHost: first(signal?.ip) ?? first(j.sessionControlInfo?.ip),
    resolution: mon?.widthInPixels && mon?.heightInPixels ? `${mon.widthInPixels}×${mon.heightInPixels}` : null,
    fps: mon?.framesPerSecond || null,
  };
}

/** Plain-language reasons for the session service's status codes. */
export function message(code, description, http, unified = null) {
  const table = [
    [[2], 'GeForce NOW refused the request.'],
    [[7, 11, 50], 'Another game is already running on your account. Resume it or end it first.'],
    [[10], 'Too many requests in a row. Wait a moment and try again.'],
    [[13], "You've used all the playtime your membership includes for now."],
    [[14, 15, 16, 17, 37, 38], 'Your sign-in has expired. Sign in again to continue.'],
    [[18, 68], "Your membership doesn't include this game or setting."],
    [[19, 20, 42], "This game isn't available to stream right now."],
    [[23], "Accept GeForce NOW's terms on another device first, then try again."],
    [[24, 56], 'GeForce NOW is under maintenance. Try again a little later.'],
    [[25, 48], "GeForce NOW isn't available right now. Try again a little later."],
    [[26, 27, 28], 'Steam needs you to sign in again. Launch the game once on another device to fix it.'],
    [[29], "Your Steam profile is private, so your games can't be checked."],
    [[30, 31, 32, 33, 45, 52, 53, 63], "GeForce NOW isn't available in your region."],
    [[34], "This session can't be resumed right now."],
    [[35], 'Verify your email address with NVIDIA first.'],
    [[41], 'This game is being updated. Try again in a few minutes.'],
    [[46], 'The session was taken over by another device.'],
    [[49], 'The session expired.'],
    [[51, 58, 59, 60], 'All rigs nearby are busy. Try again in a moment.'],
    [[54, 55], 'Your region is temporarily paused for new sessions.'],
    [[62], 'The queue is full right now. Try again a little later.'],
    [[69], 'You left the queue.'],
  ];
  const hit = table.find(([codes]) => codes.includes(code));
  if (hit) return hit[1];
  if (http === 401 || http === 403) return 'Your sign-in has expired. Sign in again to continue.';
  // Keep the raw code visible: it's what NVIDIA support and forums go by.
  const tail = description?.split('_').pop();
  const ref = (unified && unified !== '0' ? unified : null) ?? (tail && /^[A-Za-z0-9]{6,}$/.test(tail) ? tail : null) ??
    (code > 0 ? `status ${code}` : http > 0 ? `HTTP ${http}` : null);
  return "GeForce NOW couldn't start the game." + (ref ? ` Error ${ref}.` : '');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class Cloudmatch {
  #token;
  // One identity per session, as the official clients do.
  #clientId = uuid();
  #deviceId = uuid();
  /** How this session was asked for. Follow-up calls must look like the same client. */
  #route = 'WEB';

  constructor(token) { this.#token = token; }

  #headers(t, origin) {
    const web = this.#route === 'WEB';
    const h = {
      'User-Agent': BROWSER_UA, Authorization: `GFNJWT ${t}`, 'Content-Type': 'application/json', 'nv-browser-type': 'CHROME',
      'nv-client-id': this.#clientId, 'nv-client-streamer': web ? 'WEBRTC' : 'NVIDIA-CLASSIC', 'nv-client-type': web ? 'BROWSER' : 'NATIVE',
      'nv-client-version': VERSION, 'nv-device-make': 'UNKNOWN', 'nv-device-model': 'UNKNOWN', 'nv-device-os': 'WINDOWS',
      'nv-device-type': 'DESKTOP', 'x-device-id': this.#deviceId,
    };
    if (origin) Object.assign(h, { Origin: 'https://play.geforcenow.com', Referer: 'https://play.geforcenow.com/' });
    return h;
  }

  async #call(url, { method = 'GET', body = null, origin = false } = {}) {
    let r;
    try {
      r = await send(url, { method, headers: this.#headers(await this.#token(), origin), body: body ? JSON.stringify(body) : null });
    } catch (e) {
      throw new SessionError(e.message);
    }
    const status = r.json?.requestStatus;
    const code = Number(status?.statusCode) || 0;
    if (!r.ok || (status && code !== 1)) {
      const desc = status?.statusDescription && status.statusDescription !== 'null' ? String(status.statusDescription) : null;
      const u = status?.unifiedErrorCode;
      const unified = typeof u === 'number' ? (u >>> 0).toString(16).toUpperCase() : u != null ? String(u) : null;
      console.warn(`session ${method} ${url} -> HTTP ${r.status}, status ${code}, ${desc}, unified ${unified}`);
      throw new SessionError(message(code, desc, r.status, unified), code, r.status, desc);
    }
    if (!r.json) throw new SessionError('The session service sent an unreadable answer.', 0, r.status);
    return r.json;
  }

  #get = async (base, id) => parseSession(await this.#call(`${base}/v2/session/${id}`), base);

  async create(streamingBase, r) {
    if (!/^\d+$/.test(r.appId)) throw new SessionError("This game can't be launched from here yet.");
    this.#route = r.route;
    const base = streamingBase.replace(/\/+$/, '');
    const url = `${base}/v2/session?keyboardLayout=${r.keyboard ?? 'en-US'}&languageCode=${r.language ?? 'en_US'}`;
    return parseSession(await this.#call(url, { method: 'POST', body: createBody(r, this.#deviceId), origin: true }), base);
  }

  /** Follows a session. Once a seat is ready we talk to that rig directly, not the load balancer. */
  async poll(s) {
    const next = await this.#get(s.controlBase, s.id);
    if (next.ready && isZoneHost(hostOf(s.controlBase)) && next.serverIp && !isZoneHost(next.serverIp)) {
      const base = `https://${next.serverIp}`;
      try { return await this.#get(base, s.id); } catch { return { ...next, controlBase: base }; }
    }
    return next;
  }

  /** Takes over a session running on another device (or left running here) and waits for its seat. */
  async claim(active, r, alive = () => true) {
    this.#route = r.route;
    let host = active.serverHost ?? hostOf(active.streamingBase);
    // The listing names the region's load balancer. Ask it for the rig itself first.
    if (isZoneHost(host)) {
      try { host = (await this.#get(`https://${host}`, active.sessionId)).serverIp ?? host; } catch { /* keep the balancer */ }
    }
    const base = `https://${host}`;
    let current = null;
    try { current = await this.#get(base, active.sessionId); } catch { /* ask anyway */ }
    // A session still being set up can't be resumed, only followed.
    if (current?.status !== 1) {
      const url = `${base}/v2/session/${active.sessionId}?keyboardLayout=${r.keyboard ?? 'en-US'}&languageCode=${r.language ?? 'en_US'}`;
      await this.#call(url, { method: 'PUT', body: claimBody(active.appId, r), origin: true });
    }
    for (let attempt = 0; attempt < 90 && alive(); attempt++) {
      if (attempt > 0) await sleep(1000);
      let s = null;
      try {
        s = await this.#get(base, active.sessionId);
      } catch (e) {
        // The service answered and said no: the session is gone, so stop waiting for it.
        if (e.http === 404 || e.statusCode !== 0) throw e;
      }
      if (s?.ready) return s;
      if (s && !(s.status >= 1 && s.status <= 3)) throw new SessionError('The session has ended.');
    }
    throw new SessionError("The session didn't come back. It may have ended on the other device.");
  }

  async stop(s) {
    try { await this.#call(`${s.controlBase}/v2/session/${s.id}`, { method: 'DELETE' }); } catch { /* already gone */ }
  }

  async stopActive(active) {
    const host = active.serverHost ?? hostOf(active.streamingBase);
    try { await this.#call(`https://${host}/v2/session/${active.sessionId}`, { method: 'DELETE' }); } catch { /* already gone */ }
  }
}
