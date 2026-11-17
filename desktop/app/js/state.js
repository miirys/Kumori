// What the app knows: the sign-in, the saved choices, and the account's games.
import * as api from './api.js';
import { ApiError, uuid } from './http.js';

export const RESOLUTIONS = [[1280, 720], [1920, 1080], [2560, 1080], [2560, 1440], [3440, 1440], [3840, 2160]];
export const RATES = [30, 60, 120, 240];
export const BITRATES = [10, 15, 20, 30, 40, 50, 60, 75, 90, 100];

/** The largest listed 16:9 size the screen can show without scaling down. */
function nativeSize() {
  const h = Math.round(screen.height * devicePixelRatio);
  const fit = RESOLUTIONS.filter(([w, hh]) => hh <= h && Math.abs(w / hh - 16 / 9) < 0.01).pop() ?? RESOLUTIONS[1];
  return `${fit[0]}x${fit[1]}`;
}

const DEFAULTS = () => ({
  resolution: nativeSize(), fps: 60, codec: 'AUTO', bitrate: 50, region: '', cursorMode: 'system', layout: 'desktop', fullscreen: true,
  stats: false, lowLatency: true, volume: 1, dlssModel: 0, dlssQuality: 0, dlssRays: 0, dlssFrames: 0,
});

export const state = {
  ready: false, deviceId: '', tokens: null, profile: null, settings: DEFAULTS(), provider: null, vpcId: null, regions: [], membership: null,
  library: [], catalog: null, sessions: [], loading: false, error: null,
};

const listeners = new Set();
export const subscribe = (fn) => { listeners.add(fn); return () => listeners.delete(fn); };
export const changed = () => listeners.forEach((fn) => fn());

async function persist() {
  await window.kumori.save({ deviceId: state.deviceId, tokens: state.tokens, settings: state.settings });
}

export function set(key, value) {
  state.settings[key] = value;
  persist();
  changed();
}

export async function boot() {
  const saved = await window.kumori.load();
  state.deviceId = saved.deviceId || uuid();
  state.tokens = saved.tokens ?? null;
  state.settings = { ...DEFAULTS(), ...(saved.settings ?? {}) };
  state.profile = state.tokens ? api.profileFromJwt(state.tokens.id ?? state.tokens.access) : null;
  state.ready = true;
  changed();
  if (state.tokens) refresh();
}

let renewing = null;
/**
 * The token for GeForce NOW's services, renewed when it is close to running out. Throws a 401
 * only when the sign-in is really over. A network failure never signs anyone out.
 */
export async function token(force = false) {
  if (!state.tokens) throw new ApiError('Sign in to continue.', 401);
  if (!force && api.staleAt(state.tokens) - Date.now() > 5 * 60000) return api.serviceToken(state.tokens);
  renewing ??= (async () => {
    try {
      let t = await api.renew(state.tokens, state.profile?.userId);
      try { t = await api.withClientToken(t); } catch { /* keep the old client token */ }
      state.tokens = t;
      state.profile = api.profileFromJwt(t.id ?? t.access) ?? state.profile;
      await persist();
    } finally { renewing = null; }
  })();
  try {
    await renewing;
  } catch (e) {
    // Refused: the sign-in is over. Anything else: carry on with what we have while it lasts.
    if (e.code === 400 || e.code === 401 || e.code === 403) { await signOut(); throw new ApiError('Your sign-in has expired.', 401); }
    if (api.staleAt(state.tokens) < Date.now()) throw e;
  }
  return api.serviceToken(state.tokens);
}

/** The streaming service to ask for sessions: the chosen location, or the account's default. */
export const streamingBase = () => state.regions.find((r) => r.name === state.settings.region)?.url ?? state.provider?.streamingUrl;

export async function refresh() {
  state.loading = true;
  state.error = null;
  changed();
  try {
    state.provider ??= await api.defaultProvider();
    const t = await token();
    const info = await api.serverInfo(state.provider.streamingUrl, t);
    state.vpcId = info.vpcId;
    if (!state.vpcId) throw new ApiError('The server did not say which region you are in.');
    const [lib, member, sessions] = await Promise.allSettled([
      api.library(t, state.vpcId), api.membership(t, state.profile.userId, state.vpcId), api.activeSessions(state.provider.streamingUrl, t, state.deviceId),
    ]);
    if (lib.status === 'rejected') throw lib.reason;
    state.library = lib.value;
    state.membership = member.status === 'fulfilled' ? member.value : null;
    state.sessions = sessions.status === 'fulfilled' ? sessions.value : [];
    state.regions = info.regions;
    Promise.all(info.regions.map(async (r) => { r.pingMs = await window.kumori.ping(r.url); })).then(() => {
      state.regions = [...info.regions].sort((a, b) => (a.pingMs ?? 1e9) - (b.pingMs ?? 1e9) || a.name.localeCompare(b.name));
      changed();
    });
  } catch (e) {
    state.error = e.message;
  }
  state.loading = false;
  changed();
}

export async function loadCatalog() {
  if (state.catalog || !state.vpcId) return;
  try { state.catalog = await api.catalog(await token(), state.vpcId); } catch (e) { state.error = e.message; state.catalog = []; }
  changed();
}

export async function refreshSessions() {
  if (!state.provider || !state.tokens) return;
  try { state.sessions = await api.activeSessions(state.provider.streamingUrl, await token(), state.deviceId); changed(); } catch { /* keep the old list */ }
}

export const searchGames = async (q) => api.search(await token(), state.vpcId, q);

/** Runs a device sign-in. `show(challenge)` displays the code. Resolves when signed in. */
export async function signIn(show, alive) {
  state.provider ??= await api.defaultProvider();
  let c = await api.startDeviceLogin(state.provider, state.deviceId);
  show(c);
  let wait = c.intervalSeconds;
  while (alive()) {
    await new Promise((r) => setTimeout(r, wait * 1000));
    if (!alive()) return;
    if (Date.now() > c.expiresAt) { c = await api.startDeviceLogin(state.provider, state.deviceId); show(c); continue; }
    let r;
    try { r = await api.pollDeviceLogin(c); } catch (e) { if (e.code) throw e; continue; }
    if (r === 'pending') continue;
    if (r === 'slow') { wait += 5; continue; }
    if (r === 'expired') { c = await api.startDeviceLogin(state.provider, state.deviceId); show(c); continue; }
    if (r === 'denied') throw new ApiError('The sign-in was turned down.');
    try { r = await api.withClientToken(r); } catch { /* stays signed in for a day at least */ }
    state.tokens = r;
    state.profile = api.profileFromJwt(r.id ?? r.access);
    await persist();
    changed();
    refresh();
    return;
  }
}

export async function signOut() {
  Object.assign(state, { tokens: null, profile: null, library: [], catalog: null, sessions: [], membership: null, vpcId: null });
  await persist();
  changed();
}

/** The DLSS settings as the session service takes them. A quality mode needs a model, so it gets the recommended one. */
export function dlss() {
  const s = state.settings;
  const frames = [[0, 0], [1, 0], [1, 3], [1, 4]][s.dlssFrames] ?? [0, 0];
  return { srModel: s.dlssModel === 0 && s.dlssQuality !== 0 ? 1 : s.dlssModel, srMode: s.dlssQuality, rrModel: s.dlssRays, fgModel: frames[0], fgMultiplier: frames[1] };
}
