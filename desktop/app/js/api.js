// NVIDIA's sign-in, membership and catalogue services.
import { send, ApiError } from './http.js';
import { parseActive } from './cloudmatch.js';

const SERVICE_URLS = 'https://pcs.geforcenow.com/v1/serviceUrls';
const DEVICE_AUTHORIZE = 'https://login.nvidia.com/device/authorize';
const TOKEN = 'https://login.nvidia.com/token';
const CLIENT_TOKEN = 'https://login.nvidia.com/client_token';
const GRAPHQL = 'https://games.geforce.com/graphql';
const DEFAULT_STREAMING = 'https://prod.cloudmatchbeta.nvidiagrid.net/';
const AUTH_CLIENT_ID = 'q61ddeJrVt7O90Nl-P-N7I36yctih4Ml6FyXLrb6j-U';
/** The client id GeForce NOW's browser sign-in uses. Some accounts only renew under it. */
const BROWSER_CLIENT_ID = 'ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ';
const LCARS_CLIENT_ID = 'ec7e38d4-03af-4b58-b131-cfb0495903ab';
const CLIENT_VERSION = '2.0.87.131';
const BROWSER_UA = 'Mozilla/5.0 (X11; Linux x86_64; Steam Deck) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
const GFN_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/7b92719716 GFN-PC/2.0.87.131';
const BIFROST_UA = 'GFN-PC/30.0 (Linux) BifrostClientSDK/4.9 (38495286)';
const APP_UA = 'GFN-PC/22.0 (Android 14) PGC/3.8 (6.36.38319306) okhttp/4.12.0';
const APP_ORIGIN = 'https://nvfile';

const form = (o) => new URLSearchParams(o).toString();
const FORM = { 'Content-Type': 'application/x-www-form-urlencoded' };

async function call(url, opts) {
  const r = await send(url, opts);
  if (r.status === 401 || r.status === 403) throw new ApiError('Your sign-in has expired.', r.status);
  if (!r.ok) throw new ApiError(`The server answered ${r.status}.`, r.status);
  if (!r.json) throw new ApiError('The server sent an unreadable answer.');
  return r.json;
}

function jwtPayload(token) {
  try {
    const b = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b), (c) => c.charCodeAt(0))));
  } catch { return null; }
}
/** When a signed token says it expires, or null when it doesn't say. */
export const jwtExpiryMs = (token) => { const e = jwtPayload(token)?.exp; return e > 0 ? e * 1000 : null; };

/** The token GeForce NOW's services take: the ID token while it is valid, else the access token. */
export const serviceToken = (t) => (t.id && (jwtExpiryMs(t.id) ?? Infinity) > Date.now() + 30000 ? t.id : t.access);
/** When the tokens stop working. */
export const staleAt = (t) => Math.min(t.expiresAt, (t.id && jwtExpiryMs(t.id)) || Infinity);

export function tierName(raw) {
  const u = String(raw).toUpperCase();
  if (u === 'FREE') return 'Free';
  if (u === 'PRIORITY' || u === 'PERFORMANCE') return 'Performance';
  if (u === 'ULTIMATE') return 'Ultimate';
  return u.charAt(0) + u.slice(1).toLowerCase();
}

export function profileFromJwt(token) {
  const j = jwtPayload(token);
  if (!j?.sub) return null;
  return { userId: j.sub, name: j.preferred_username || j.email?.split('@')[0] || 'Player', email: j.email || null, tier: j.gfn_tier ? tierName(j.gfn_tier) : null };
}

export async function defaultProvider() {
  const info = (await call(SERVICE_URLS, { headers: { Accept: 'application/json', 'User-Agent': GFN_UA } })).gfnServiceInfo ?? {};
  let fallback = null;
  for (const e of info.gfnServiceEndpoints ?? []) {
    if (!e?.idpId) continue;
    const url = e.streamingServiceUrl || DEFAULT_STREAMING;
    const p = { idpId: e.idpId, streamingUrl: url.endsWith('/') ? url : `${url}/` };
    fallback ??= p;
    if (e.loginProvider === info.defaultProvider || e.loginProviderCode === info.defaultProvider) return p;
  }
  return fallback ?? { idpId: 'PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg', streamingUrl: DEFAULT_STREAMING };
}

const BROWSER_HEADERS = {
  Accept: 'application/json, text/plain, */*', Origin: 'https://play.geforcenow.com', Referer: 'https://play.geforcenow.com/', 'User-Agent': BROWSER_UA,
};

export async function startDeviceLogin(provider, deviceId) {
  const j = await call(DEVICE_AUTHORIZE, {
    method: 'POST',
    headers: { ...BROWSER_HEADERS, ...FORM, 'x-device-id': deviceId, 'nv-client-id': AUTH_CLIENT_ID, 'nv-client-streamer': 'WEBRTC',
      'nv-client-type': 'BROWSER', 'nv-client-platform-name': 'browser', 'nv-browser-type': 'CHROME', 'nv-device-os': 'STEAMOS',
      'nv-device-type': 'CONSOLE', 'nv-device-model': 'STEAMDECK', 'nv-device-make': 'VALVE' },
    body: form({ client_id: AUTH_CLIENT_ID, scope: 'openid consent email tk_client age', device_id: deviceId, display_name: 'Kumori', idp_id: provider.idpId }),
  });
  const life = Math.max(60, Math.min(3600, j.expires_in ?? 600));
  return {
    deviceCode: j.device_code, userCode: j.user_code, verificationUri: j.verification_uri,
    verificationUriComplete: j.verification_uri_complete || j.verification_uri,
    intervalSeconds: Math.max(1, Math.min(60, j.interval ?? 5)), expiresAt: Date.now() + life * 1000,
  };
}

const tokensFrom = (j, old = {}) => ({
  access: j.access_token, refresh: j.refresh_token || old.refresh || null,
  id: j.id_token || (old.id && (jwtExpiryMs(old.id) ?? Infinity) > Date.now() + 60000 ? old.id : null),
  expiresAt: Date.now() + (j.expires_in ?? 86400) * 1000, client: j.client_token || old.client || null,
});

/** One poll of a device sign-in: 'pending', 'slow', 'expired', 'denied' or the tokens. */
export async function pollDeviceLogin(challenge) {
  const r = await send(TOKEN, {
    method: 'POST', headers: { ...BROWSER_HEADERS, ...FORM },
    body: form({ grant_type: 'urn:ietf:params:oauth:grant-type:device_code', device_code: challenge.deviceCode, client_id: AUTH_CLIENT_ID }),
  });
  if (r.ok && r.json?.access_token) return tokensFrom(r.json);
  const known = { authorization_pending: 'pending', slow_down: 'slow', expired_token: 'expired', access_denied: 'denied' }[r.json?.error];
  if (known) return known;
  throw new ApiError(`Sign-in failed (${r.status}).`, r.status);
}

const APP_HEADERS = { Origin: APP_ORIGIN, Accept: 'application/json, text/plain, */*', 'User-Agent': APP_UA };

/** Fetches the long-lived client token, which keeps the app signed in for months. */
export async function withClientToken(t) {
  const j = await call(CLIENT_TOKEN, { headers: { ...APP_HEADERS, Authorization: `Bearer ${t.access}` } });
  if (!j.client_token) throw new ApiError('The sign-in service sent no client token.');
  return { ...t, client: j.client_token };
}

/** Renews a sign-in with the client token, then the refresh token, under each client id it may belong to. */
export async function renew(t, userId) {
  let last = null;
  const grants = [];
  for (const id of [AUTH_CLIENT_ID, BROWSER_CLIENT_ID]) {
    if (t.client && userId) grants.push({ grant_type: 'urn:ietf:params:oauth:grant-type:client_token', client_token: t.client, client_id: id, sub: userId });
  }
  for (const id of [AUTH_CLIENT_ID, BROWSER_CLIENT_ID]) {
    if (t.refresh) grants.push({ grant_type: 'refresh_token', refresh_token: t.refresh, client_id: id });
  }
  for (const g of grants) {
    try {
      return tokensFrom(await call(TOKEN, { method: 'POST', headers: { ...APP_HEADERS, ...FORM }, body: form(g) }), t);
    } catch (e) {
      last = e;
      if (!e.code) throw e; // the network failed, so nothing was refused
    }
  }
  throw last ?? new ApiError('Your sign-in has expired.', 401);
}

const lcars = (token, extra = {}) => ({
  Accept: 'application/json, text/plain, */*', Authorization: `GFNJWT ${token}`, 'nv-client-id': LCARS_CLIENT_ID, 'nv-client-type': 'NATIVE',
  'nv-client-version': CLIENT_VERSION, 'nv-client-streamer': 'NVIDIA-CLASSIC', 'nv-device-os': 'LINUX', 'nv-device-type': 'DESKTOP',
  'nv-device-make': 'GENERIC', 'nv-device-model': 'PC', 'x-nv-client-identity': 'GFN-PC', 'User-Agent': GFN_UA, ...extra,
});

/** What the membership allows: its tier, stream modes and playtime left. */
export async function membership(token, userId, vpcId) {
  const q = form({ serviceName: 'gfn_pc', languageCode: 'en_US', vpcId: vpcId || 'NP-AMS-08', userId });
  const j = await call(`https://mes.geforcenow.com/v4/subscriptions?${q}`, { headers: lcars(token, { 'nv-device-os': 'WINDOWS' }) });
  const all = (j.features?.resolutions ?? []).filter((r) => r?.widthInPixels > 0 && r?.heightInPixels > 0 && r?.framesPerSecond > 0);
  const entitled = all.filter((r) => r.isEntitled !== false);
  const minutes = Number(j.remainingTimeInMinutes);
  return {
    tier: j.membershipTier ? tierName(j.membershipTier) : null,
    modes: (entitled.length ? entitled : all).map((r) => ({ width: r.widthInPixels, height: r.heightInPixels, fps: r.framesPerSecond })),
    hoursLeft: Number.isFinite(minutes) ? minutes / 60 : null, unlimited: j.subType === 'UNLIMITED',
  };
}

/** The streaming region the account is served from, and every server location it lists. */
export async function serverInfo(streamingBase, token) {
  const j = await call(`${streamingBase}v2/serverInfo`, { headers: lcars(token) });
  const regions = [];
  for (const e of j.metaData ?? []) {
    const key = e?.key ?? '';
    const value = e?.value ?? '';
    if (!value.startsWith('https://') || !key || key.startsWith('gfn-')) continue;
    const url = value.endsWith('/') ? value : `${value}/`;
    if (!regions.some((r) => r.url === url)) regions.push({ name: key, url, pingMs: null });
  }
  return { vpcId: j.requestStatus?.serverId || null, regions };
}

const APP_FIELDS = `
  id title developerName publisherName genres __EXTRA__
  library { favorited }
  images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS }
  variants { id appStore storeUrl gfn { status library { status selected lastPlayedDate } } }`;
const APPS_QUERY = (search) => `query Apps($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!,${search ? ' $searchString: String!,' : ''} $filters: AppFilterFields!) {
  apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor,${search ? ' searchQuery: $searchString,' : ''} filters: $filters) {
    numberReturned pageInfo { hasNextPage endCursor totalCount }
    items { ${APP_FIELDS} }
  }
}`;

async function graphql(token, query, variables) {
  const j = await call(GRAPHQL, {
    method: 'POST', body: JSON.stringify({ query, variables }),
    headers: lcars(token, { 'Content-Type': 'application/json', Origin: 'https://play.geforcenow.com', Referer: 'https://play.geforcenow.com/', 'nv-browser-type': 'CHROME' }),
  });
  if (!j.data) throw new ApiError(j.errors?.[0]?.message || 'GeForce NOW sent an empty answer.');
  return j.data;
}

// The description field isn't part of every catalogue version. The first query finds out.
let describe = null;
async function appsQuery(token, search, vars) {
  if (describe !== false) {
    try {
      const d = await graphql(token, APPS_QUERY(search).replace('__EXTRA__', 'shortDescription'), vars);
      describe = true;
      return d;
    } catch (e) {
      if (describe === true || (e.code !== 0 && e.code !== 400)) throw e;
      describe = false;
    }
  }
  return graphql(token, APPS_QUERY(search).replace('__EXTRA__', ''), vars);
}

const STORES = {
  STEAM: 'Steam', EPIC: 'Epic Games Store', EPIC_GAMES_STORE: 'Epic Games Store', EGS: 'Epic Games Store', UPLAY: 'Ubisoft Connect',
  UBISOFT: 'Ubisoft Connect', UBISOFT_CONNECT: 'Ubisoft Connect', ORIGIN: 'EA app', EA_APP: 'EA app', EA: 'EA app', BATTLENET: 'Battle.net',
  BATTLE_NET: 'Battle.net', XBOX: 'Xbox', MICROSOFT: 'Xbox', MICROSOFT_STORE: 'Microsoft Store', GOG: 'GOG', HOYOPLAY: 'HoYoPlay',
  HOYOVERSE: 'HoYoPlay', ROCKSTAR: 'Rockstar Games Launcher', WARGAMING: 'Wargaming Game Center', GAIJIN: 'Gaijin', BETHESDA: 'Bethesda.net',
  NEXON: 'Nexon', GAMEPASS: 'PC Game Pass', PC_GAME_PASS: 'PC Game Pass', RIOT: 'Riot Client', GFN: 'GeForce NOW', FREE: 'Free to play',
};
export function storeName(code, publisher) {
  const c = String(code ?? '').trim().toUpperCase();
  if (STORES[c]) return STORES[c];
  if (!c || ['NONE', 'UNKNOWN', 'OTHER'].includes(c)) return publisher ? `${publisher} launcher` : 'Own launcher';
  return c.toLowerCase().split(/[_ ]/).map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
}

function image(images, width, keys, format = 'jpg') {
  for (const k of keys) {
    const v = images[k];
    const url = (typeof v === 'string' ? v : Array.isArray(v) ? v[0] : null)?.trim();
    // NVIDIA's image CDN resizes on request.
    if (url && url !== 'null') return url.includes('img.nvidiagrid.net') ? `${url};f=${format};w=${width}` : url;
  }
  return null;
}

const plainText = (s) => s.replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();

export function parseGame(j) {
  if (!j?.id || !j?.title) return null;
  const images = j.images ?? {};
  const publisher = j.publisherName || j.developerName || null;
  const variants = (j.variants ?? []).filter(Boolean).map((v) => {
    const lib = v.gfn?.library;
    return {
      id: String(v.id ?? ''), store: storeName(v.appStore, publisher), lastPlayed: Date.parse(lib?.lastPlayedDate ?? '') || 0,
      selected: lib?.selected === true, owned: ['MANUAL', 'PLATFORM_SYNC', 'IN_LIBRARY'].includes(lib?.status),
    };
  });
  const text = [j.shortDescription, j.description].find((t) => typeof t === 'string' && t.trim() && t !== 'null');
  return {
    id: String(j.id), title: j.title, publisher,
    genres: (j.genres ?? []).filter(Boolean).map((g) => String(g).toLowerCase().split(/[_ ]/).map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')),
    hero: image(images, 1920, ['MARQUEE_HERO_IMAGE', 'HERO_IMAGE', 'KEY_ART', 'FEATURE_IMAGE', 'SCREENSHOTS']),
    boxArt: image(images, 480, ['GAME_BOX_ART', 'KEY_IMAGE']),
    banner: image(images, 640, ['TV_BANNER', 'KEY_ART', 'HERO_IMAGE', 'FEATURE_IMAGE']),
    variants, owned: variants.some((v) => v.owned), lastPlayed: Math.max(0, ...variants.map((v) => v.lastPlayed)),
    description: text ? plainText(text) : null,
  };
}

async function apps(token, vpcId, { filters = {}, sort, pages, count = 100, search = null }) {
  const games = new Map();
  let cursor = '';
  for (let i = 0; i < pages; i++) {
    const vars = { vpcId, locale: 'en_US', sortString: sort, fetchCount: count, cursor, filters };
    if (search != null) vars.searchString = search;
    const a = (await appsQuery(token, search != null, vars)).apps;
    if (!a) throw new ApiError('GeForce NOW sent an empty answer.');
    for (const it of a.items ?? []) { const g = parseGame(it); if (g && !games.has(g.id)) games.set(g.id, g); }
    cursor = a.pageInfo?.hasNextPage ? a.pageInfo.endCursor ?? '' : '';
    if (!cursor) break;
  }
  return [...games.values()];
}

export const library = (token, vpcId) => apps(token, vpcId, {
  filters: { variants: { gfn: { library: { status: { notEquals: 'NOT_OWNED' } } } } },
  sort: 'variants.gfn.library.lastPlayedDate:DESC,computedValues.libraryAddedDate:DESC,sortName:ASC', pages: 12,
});
/** Every game GeForce NOW streams in this region, A to Z. */
export const catalog = (token, vpcId) => apps(token, vpcId, { sort: 'sortName:ASC', pages: 40, count: 50 });
export const search = (token, vpcId, query) => apps(token, vpcId, { sort: 'itemMetadata.relevance:DESC,sortName:ASC', pages: 1, count: 60, search: query });

/** Sessions running for this account on any device, so they can be picked up here. */
export async function activeSessions(streamingBase, token, deviceId) {
  const j = await call(`${streamingBase}v2/session`, { headers: {
    'User-Agent': BIFROST_UA, Authorization: `GFNJWT ${token}`, 'Content-Type': 'text/plain', 'nv-client-id': LCARS_CLIENT_ID,
    'nv-client-streamer': 'NVIDIA-CLASSIC', 'nv-client-type': 'NATIVE', 'nv-client-version': CLIENT_VERSION, 'nv-device-os': 'LINUX',
    'nv-device-type': 'DESKTOP', 'nv-device-make': 'UNKNOWN', 'nv-device-model': 'UNKNOWN', 'x-device-id': deviceId, 'x-nv-client-identity': BIFROST_UA,
  } });
  return (j.sessions ?? []).map((s) => s && parseActive(s, streamingBase)).filter(Boolean);
}
