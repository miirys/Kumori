// The screens: sign-in, library, settings, the launch card and the stream with its menu.
// One set of elements serves both layouts. The mouse works everywhere; the keyboard's
// arrows and a controller move a focus ring over the same buttons.
import { state, subscribe, boot, set, refresh, loadCatalog, searchGames, signIn, signOut, RESOLUTIONS, RATES, BITRATES } from './state.js';
import { Player } from './player.js';

const $ = (id) => document.getElementById(id);
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'focus') el.dataset.focus = '';
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid);
  return el;
}
const fill = (el, ...kids) => { el.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false)); return el; };

const view = { tab: 'library', query: '', results: null, searching: false, detail: null, variant: null, menu: false, needClick: false, challenge: null, signInError: null };
let version = '';

const player = new Player({
  video: $('video'), surface: $('stream'), pointer: $('pointer'),
  onChange: () => renderPlay(),
  onStats: () => renderStats(),
  onMenu: () => toggleMenu(),
  onFullscreen: () => toggleFullscreen(),
  onNeedClick: (need) => { view.needClick = need; renderHint(); },
});
window.__takePointer = () => player.stream?.takePointer();

// ---------- Small pieces ----------

let toastTimer = 0;
function toast(text) {
  $('toast').textContent = text;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4000);
}

const button = (text, onclick, cls = '') => h('button', { class: `btn ${cls}`, focus: true, onclick }, text);

/** A setting that steps through a short list: click the arrows, or press left and right. */
function stepper(label, options, index, onChange, hint = null) {
  const i = Math.max(0, index);
  const step = (d) => onChange((i + d + options.length) % options.length);
  const row = h('button', { class: 'row', focus: true, onclick: () => step(1) },
    h('span', { class: 'label' }, label, hint && h('small', {}, hint)),
    h('span', { class: 'stepper' },
      h('i', { onclick: (e) => { e.stopPropagation(); step(-1); } }, '‹'), h('b', {}, options[i]), h('i', { onclick: (e) => { e.stopPropagation(); step(1); } }, '›')));
  row.step = step;
  return row;
}
const toggle = (label, on, onChange, hint) => stepper(label, ['Off', 'On'], on ? 1 : 0, (i) => onChange(i === 1), hint);
const choice = (label, key, pairs, hint) => stepper(label, pairs.map((p) => p[1]), pairs.findIndex((p) => p[0] === state.settings[key]),
  (i) => set(key, pairs[i][0]), typeof hint === 'function' ? hint(state.settings[key]) : hint);

function tile(game) {
  const art = game.boxArt ?? game.banner;
  return h('button', { class: `tile${art ? '' : ' bare'}`, focus: true, title: game.title, onclick: () => openDetail(game) },
    art && h('img', { src: art, loading: 'lazy', alt: '', onerror: (e) => { e.target.remove(); } }), h('span', {}, game.title));
}
const grid = (games) => h('div', { class: 'grid' }, games.map(tile));

// ---------- Pages ----------

const TABS = [['library', 'Library'], ['all', 'All games'], ['settings', 'Settings']];

function selectTab(tab) {
  view.tab = tab;
  view.query = '';
  view.results = null;
  $('search').value = '';
  if (tab === 'all') loadCatalog();
  render();
  $('content').scrollTop = 0;
}

function gameFor(session) {
  return [...state.library, ...(state.catalog ?? [])].find((g) => g.variants.some((v) => v.id === session.appId)) ?? null;
}

function sessionsBlock() {
  if (!state.sessions.length) return null;
  return h('div', { class: 'sessions' }, state.sessions.map((s) => {
    const g = gameFor(s);
    return h('div', { class: 'session' },
      h('div', {}, h('b', {}, g?.title ?? 'A game is running'), h('small', {}, [s.resolution, s.fps && `${s.fps} fps`, 'still running on the rig'].filter(Boolean).join(' · '))),
      button('Resume', () => player.resume(s, g), 'primary'), button('End', async () => { await player.endActive(s); toast('Session ended.'); }));
  }));
}

function libraryPage() {
  if (state.loading && !state.library.length) return h('div', { class: 'empty' }, h('div', { class: 'spinner' }), 'Loading your games');
  if (state.error && !state.library.length) return h('div', { class: 'empty' }, h('p', {}, state.error), button('Try again', refresh, 'primary'));
  const recent = state.library.filter((g) => g.lastPlayed).slice(0, 8);
  return [
    sessionsBlock(),
    recent.length > 0 && [h('h2', {}, 'Continue playing'), grid(recent)],
    h('h2', {}, `Your library${state.library.length ? ` · ${state.library.length}` : ''}`),
    state.library.length ? grid(state.library) : h('div', { class: 'empty' }, 'No games yet. Connect your stores in GeForce NOW, or pick something from All games.'),
  ];
}

function allPage() {
  if (!state.catalog) return h('div', { class: 'empty' }, h('div', { class: 'spinner' }), 'Loading the catalogue');
  return [h('h2', {}, `Everything on GeForce NOW · ${state.catalog.length}`), grid(state.catalog)];
}

function searchPage() {
  if (view.searching && !view.results) return h('div', { class: 'empty' }, h('div', { class: 'spinner' }), 'Searching');
  const r = view.results ?? [];
  return [h('h2', {}, `Results for "${view.query}"`), r.length ? grid(r) : h('div', { class: 'empty' }, 'Nothing found.')];
}

const CURSOR_HINTS = {
  system: "Your own mouse pointer, in the game's shape. It moves at once and can leave the window.",
  captured: "Held inside the game and drawn here in the game's shape. Open the menu to get the mouse back.",
  streamed: 'The cursor is part of the video, so it trails the mouse by the stream delay. Use this if the others misbehave.',
};

function settingsPage() {
  const s = state.settings;
  const sizes = RESOLUTIONS.map(([w, hh]) => [`${w}x${hh}`, `${w} × ${hh}`]);
  const regions = [['', 'Automatic'], ...state.regions.map((r) => [r.name, r.pingMs != null ? `${r.name} · ${r.pingMs} ms` : r.name])];
  const [, hh] = s.resolution.split('x').map(Number);
  return h('div', { class: 'settings' },
    h('h2', {}, 'Stream'),
    choice('Resolution', 'resolution', sizes, hh > 1440 ? 'Above 1440p depends on your membership and the rig. If it is refused the stream starts at 1440p.' : null),
    choice('Frame rate', 'fps', RATES.map((r) => [r, `${r} fps`])),
    choice('Bitrate', 'bitrate', BITRATES.map((b) => [b, `${b} Mbps`]), 'The most the stream may use. It adapts below this.'),
    choice('Video codec', 'codec', [['AUTO', 'Automatic'], ['H265', 'HEVC'], ['AV1', 'AV1'], ['H264', 'H.264']], 'Automatic takes HEVC when your GPU decodes it, and H.264 otherwise.'),
    choice('Server location', 'region', regions),
    toggle('Low latency mode', s.lowLatency, (v) => set('lowLatency', v), 'Asks for NVIDIA Reflex at 120 fps and above.'),
    toggle('Start games in fullscreen', s.fullscreen, (v) => set('fullscreen', v), 'Fullscreen also sends Escape, Alt+Tab and the Windows key to the game. F11 switches.'),
    h('h2', {}, 'Mouse'),
    choice('Cursor', 'cursorMode', [['system', 'System cursor'], ['captured', 'Captured'], ['streamed', 'In the video']], (v) => CURSOR_HINTS[v]),
    h('h2', {}, 'DLSS'),
    choice('Model', 'dlssModel', [[0, "Game's choice"], [1, 'Recommended'], [12, 'Preset K'], [13, 'Preset L'], [14, 'Preset M']], 'Applies from the next game you start, in games with DLSS turned on.'),
    choice('Quality', 'dlssQuality', [[0, "Game's choice"], [5, 'DLAA'], [3, 'Quality'], [2, 'Balanced'], [1, 'Performance'], [4, 'Ultra Performance']]),
    choice('Ray Reconstruction model', 'dlssRays', [[0, "Game's choice"], [1, 'Recommended']], 'Needs Performance or Ultimate.'),
    choice('Frame generation', 'dlssFrames', [[0, "Game's choice"], [1, 'Recommended model'], [2, 'Dynamic, up to 3x'], [3, 'Dynamic, up to 4x']], 'Dynamic needs an Ultimate RTX 5080 rig.'),
    h('h2', {}, 'Interface'),
    choice('Layout', 'layout', [['desktop', 'Mouse and keyboard'], ['pad', 'Gamepad']], 'Gamepad is the big-tile layout from the TV apps. The mouse keeps working in it.'),
    toggle('Show stats while playing', s.stats, (v) => set('stats', v)),
    h('h2', {}, 'Account'),
    h('div', { class: 'row' }, h('span', { class: 'label' }, state.profile?.name ?? '', h('small', {}, state.profile?.email ?? '')), button('Sign out', signOut)),
    h('div', { class: 'row' }, h('span', { class: 'label' }, 'Kumori', h('small', {}, `Version ${version}. Not affiliated with NVIDIA.`)), button('GitHub', () => window.kumori.open('https://github.com/miirys/Kumori'), 'quiet')),
  );
}

function render() {
  const signedIn = !!state.tokens;
  document.body.classList.toggle('pad', state.settings.layout === 'pad');
  $('app').hidden = !state.ready || !signedIn;
  $('signin').hidden = !state.ready || signedIn;
  if (!state.ready) return;
  if (!signedIn) return renderSignIn();
  fill($('tabs'), TABS.map(([id, label]) => h('button', { class: `tab${view.tab === id && !view.query ? ' on' : ''}`, focus: true, onclick: () => selectTab(id) }, label)));
  fill($('account'), h('b', {}, state.profile?.name ?? ''), state.membership?.tier ?? state.profile?.tier ?? '');
  const m = state.membership;
  $('member').textContent = m && !m.unlimited && m.hoursLeft != null ? `${m.hoursLeft.toFixed(1)} h of playtime left` : '';
  const page = view.query ? searchPage() : view.tab === 'settings' ? settingsPage() : view.tab === 'all' ? allPage() : libraryPage();
  // Rebuilding the page must not lose the place: keep the scroll and the focused row.
  const active = document.activeElement;
  const index = active && $('content').contains(active) ? [...$('content').querySelectorAll('[data-focus]')].indexOf(active) : -1;
  const top = $('content').scrollTop;
  fill($('content'), page);
  $('content').scrollTop = top;
  if (index >= 0) $('content').querySelectorAll('[data-focus]')[index]?.focus({ preventScroll: true });
  fill($('hints'), ...[['A', 'Select'], ['B', 'Back'], ['Y', 'Search'], ['LB RB', 'Switch page']].map(([k, t]) => h('span', {}, h('b', {}, k), t)));
}

// ---------- Sign-in ----------

let signInRun = 0;
function renderSignIn() {
  const c = view.challenge;
  fill($('signin'), h('div', { class: 'card' },
    h('h1', {}, 'Sign in to GeForce NOW'),
    view.signInError ? h('p', {}, view.signInError) : h('p', {}, 'Open the sign-in page in your browser and enter this code. Kumori never sees your password.'),
    c ? h('div', { class: 'code' }, c.userCode) : h('div', { class: 'spinner' }),
    h('div', { class: 'actions' },
      c && button('Open sign-in page', () => window.kumori.open(c.verificationUriComplete), 'primary'),
      c && button('Copy code', () => { navigator.clipboard.writeText(c.userCode); toast('Code copied.'); }),
      view.signInError && button('Try again', startSignIn, 'primary'))));
  if (!c && !view.signInError && !signInRun) startSignIn();
}
async function startSignIn() {
  const run = ++signInRun;
  view.signInError = null;
  view.challenge = null;
  renderSignIn();
  try {
    await signIn((c) => { view.challenge = c; if (!state.tokens) renderSignIn(); focusFirst(); }, () => run === signInRun && !state.tokens);
  } catch (e) {
    view.signInError = e.message;
    view.challenge = null;
    if (!state.tokens) renderSignIn();
  }
  if (run === signInRun) signInRun = 0;
}

// ---------- Game card ----------

function openDetail(game) {
  view.detail = game;
  view.variant = game.variants.find((v) => v.selected) ?? game.variants.find((v) => v.owned) ?? game.variants[0] ?? null;
  renderDetail();
  focusFirst();
}
function closeDetail() { view.detail = null; renderDetail(); }
function renderDetail() {
  const g = view.detail;
  $('detail').hidden = !g;
  if (!g) return;
  const running = state.sessions.find((a) => g.variants.some((v) => v.id === a.appId));
  fill($('detail'), h('div', { class: 'card' },
    h('div', { class: 'hero', style: g.hero ?? g.banner ? `background-image:url("${(g.hero ?? g.banner).replace(/"/g, '%22')}")` : null }),
    h('div', { class: 'info' },
      h('h1', {}, g.title),
      h('div', { class: 'meta' }, [g.publisher, ...g.genres.slice(0, 3)].filter(Boolean).join(' · ')),
      g.description && h('p', {}, g.description),
      g.variants.length > 1 && h('div', { class: 'stores' }, g.variants.map((v) =>
        h('button', { class: `chip${v === view.variant ? ' on' : ''}`, focus: true, onclick: () => { view.variant = v; renderDetail(); } }, v.store + (v.owned ? '' : ' (not owned)')))),
      h('div', { class: 'actions' },
        button(running ? 'Resume' : `Play${g.variants.length === 1 && view.variant ? ` on ${view.variant.store}` : ''}`, () => { closeDetail(); player.play(g, view.variant); }, 'primary'),
        button('Close', closeDetail, 'quiet')))));
}
$('detail').addEventListener('click', (e) => { if (e.target === $('detail')) closeDetail(); });

// ---------- Launching and playing ----------

function renderPlay() {
  const p = player.phase;
  const streaming = p.kind === 'streaming';
  const wasStreaming = !$('stream').hidden;
  $('stream').hidden = !streaming;
  $('launch').hidden = p.kind === 'idle' || streaming;
  if (p.kind === 'starting' || p.kind === 'queued') {
    fill($('launch'), h('div', { class: 'card' }, h('div', { class: 'spinner' }),
      h('h1', {}, player.game?.title ?? 'Resuming your game'),
      h('p', {}, p.kind === 'queued' ? `In the queue, position ${p.position}` : p.text),
      h('div', { class: 'actions' }, button('Cancel', () => player.leave(true)))));
  } else if (p.kind === 'error') {
    fill($('launch'), h('div', { class: 'card' }, h('h1', {}, "That didn't work"), h('p', {}, p.text),
      h('div', { class: 'actions' }, button('OK', () => player.dismiss(), 'primary'))));
    focusFirst();
  }
  if (streaming && !wasStreaming) {
    view.menu = false;
    if (state.settings.fullscreen && !document.fullscreenElement) toggleFullscreen();
    flashHint('Ctrl+G opens the menu');
  }
  if (!streaming && wasStreaming) {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    view.menu = false;
    render();
  }
  if (player.notice) { toast(player.notice); player.notice = null; }
  $('stats').hidden = !state.settings.stats || !streaming;
  renderMenu();
  renderHint();
}

function renderStats() {
  if ($('stats').hidden) return;
  const s = player.stats;
  const n = (v, d = 0) => (v == null ? '-' : v.toFixed(d));
  $('stats').textContent = [
    `${s.width ?? '-'}×${s.height ?? '-'}  ${n(s.fps)} fps  ${s.codec ?? ''}${s.hardware === false ? ' (software)' : ''}`,
    `${n((s.kbps ?? 0) / 1000, 1)} Mbps  ping ${n(s.rttMs)} ms  decode ${n(s.decodeMs, 1)} ms`,
    `lost ${s.lost ?? 0}  dropped ${s.dropped ?? 0}  jitter ${n(s.jitterMs, 1)} ms`,
    `cursor: ${s.cursor ?? '-'}`,
  ].join('\n');
}

let hintTimer = 0;
let hintText = null;
function flashHint(text) {
  hintText = text;
  renderHint();
  clearTimeout(hintTimer);
  hintTimer = setTimeout(() => { hintText = null; renderHint(); }, 5000);
}
function renderHint() {
  const text = view.menu ? null : view.needClick ? 'Click to give the mouse to the game' : hintText;
  $('hint').hidden = !text;
  $('hint').textContent = text ?? '';
}

function toggleMenu() {
  if (player.phase.kind !== 'streaming') return;
  view.menu = !view.menu;
  player.stream?.setActive(!view.menu);
  renderMenu();
  renderHint();
  if (view.menu) focusFirst();
}

function renderMenu() {
  $('menu').hidden = !view.menu;
  if (!view.menu) return;
  const s = state.settings;
  const st = player.stats;
  const mins = Math.floor(player.elapsedMs / 60000);
  const index = [...$('menu').querySelectorAll('[data-focus]')].indexOf(document.activeElement);
  const modes = [['system', 'System cursor'], ['captured', 'Captured'], ['streamed', 'In the video']];
  fill($('menu'), h('div', { class: 'card' },
    h('h1', {}, player.game?.title ?? 'Playing'),
    h('p', {}, [`${st.width ?? '-'}×${st.height ?? '-'}`, st.fps != null && `${Math.round(st.fps)} fps`, st.codec, `${mins} min`].filter(Boolean).join(' · ')),
    h('button', { class: 'row', focus: true, onclick: toggleMenu }, h('span', { class: 'label' }, 'Back to the game'), h('span', { class: 'value' }, 'Ctrl+G')),
    h('button', { class: 'row', focus: true, onclick: toggleFullscreen }, h('span', { class: 'label' }, document.fullscreenElement ? 'Leave fullscreen' : 'Fullscreen'), h('span', { class: 'value' }, 'F11')),
    stepper('Volume', Array.from({ length: 11 }, (_, i) => `${i * 10}%`), Math.round(s.volume * 10), (i) => { set('volume', i / 10); player.stream?.setVolume(i / 10); renderMenu(); }),
    stepper('Cursor', modes.map((m) => m[1]), modes.findIndex((m) => m[0] === s.cursorMode), (i) => {
      const was = s.cursorMode;
      set('cursorMode', modes[i][0]);
      player.stream?.setCursorMode(modes[i][0]);
      if ((was === 'streamed') !== (modes[i][0] === 'streamed')) toast('This takes effect the next time the stream connects.');
      renderMenu();
    }),
    toggle('Stats', s.stats, (v) => { set('stats', v); $('stats').hidden = !v; renderStats(); renderMenu(); }),
    h('button', { class: 'row', focus: true, onclick: () => player.leave(false) }, h('span', { class: 'label' }, 'Leave, keep the game running', h('small', {}, 'Come back to it from the library within a few minutes.'))),
    h('button', { class: 'row', focus: true, onclick: () => player.leave(true) }, h('span', { class: 'label' }, 'End the session'))));
  if (index >= 0) $('menu').querySelectorAll('[data-focus]')[index]?.focus();
}

async function toggleFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch { /* the window manager said no */ }
}
document.addEventListener('fullscreenchange', () => {
  // In fullscreen the keys the system or browser would take (Escape, Alt+Tab, the Windows
  // key) go to the game instead. Holding Escape still leaves fullscreen.
  if (document.fullscreenElement) navigator.keyboard?.lock?.().catch(() => {}); else navigator.keyboard?.unlock?.();
  if (view.menu) renderMenu();
});

// ---------- Getting around without a mouse ----------

const playing = () => player.phase.kind === 'streaming' && !view.menu;
const scope = () => [$('menu'), $('launch'), $('detail'), $('signin'), $('app')].find((el) => !el.hidden) ?? document.body;
const focusables = () => [...scope().querySelectorAll('[data-focus]')].filter((el) => el.offsetParent !== null);
function focusFirst() { requestAnimationFrame(() => focusables().find((el) => el.id !== 'search')?.focus()); }

/** Moves the focus to the nearest button in a direction, by where things are on screen. */
function move(dx, dy) {
  const all = focusables();
  const from = document.activeElement;
  if (!all.includes(from)) return (all.find((el) => el.classList.contains('tile')) ?? all.find((el) => el.id !== 'search') ?? all[0])?.focus();
  const a = from.getBoundingClientRect();
  const ax = a.left + a.width / 2;
  const ay = a.top + a.height / 2;
  let best = null;
  let bestScore = Infinity;
  for (const el of all) {
    if (el === from) continue;
    const b = el.getBoundingClientRect();
    const along = dx ? (b.left + b.width / 2 - ax) * dx : (b.top + b.height / 2 - ay) * dy;
    if (along < 6) continue;
    // Being off to the side costs more than being further away, so rows and columns hold.
    const across = dx ? Math.max(0, Math.max(b.top - a.bottom, a.top - b.bottom)) + Math.abs(b.top + b.height / 2 - ay) * 0.3
      : Math.max(0, Math.max(b.left - a.right, a.left - b.right)) + Math.abs(b.left + b.width / 2 - ax) * 0.3;
    const score = along + across * 3;
    if (score < bestScore) { bestScore = score; best = el; }
  }
  if (best) { best.focus({ preventScroll: true }); best.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }
}

function back() {
  if (view.menu) return toggleMenu();
  if (player.phase.kind === 'error') return player.dismiss();
  if (view.detail) return closeDetail();
  if (view.query) { $('search').value = ''; return runSearch(''); }
  if (document.activeElement === $('search')) $('search').blur();
}

function arrow(dx, dy) {
  const el = document.activeElement;
  if (dx && el?.step) return el.step(dx);
  move(dx, dy);
}

window.addEventListener('keydown', (e) => {
  if (playing()) return;
  const inSearch = document.activeElement === $('search');
  const dir = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
  if (dir && !(inSearch && dir[0])) { e.preventDefault(); return arrow(...dir); }
  if (e.key === 'Escape') { e.preventDefault(); return back(); }
  if (e.key === 'F11') { e.preventDefault(); return toggleFullscreen(); }
  if (!inSearch && !$('app').hidden && scope() === $('app') && (e.key === '/' || (e.ctrlKey && e.key.toLowerCase() === 'f'))) { e.preventDefault(); $('search').focus(); $('search').select(); }
});

// A controller drives the same focus ring. While a game has the controller this stays out of the way.
const held = new Map();
function padPressed(pad, i, now) {
  const down = i < 100 ? pad.buttons[i]?.pressed : ({ 100: pad.axes[0] < -0.6, 101: pad.axes[0] > 0.6, 102: pad.axes[1] < -0.6, 103: pad.axes[1] > 0.6 })[i];
  const key = `${pad.index}:${i}`;
  if (!down) { held.delete(key); return false; }
  const hh = held.get(key);
  if (!hh) { held.set(key, { at: now, next: now + 420 }); return true; }
  // Directions repeat while held. Buttons do not.
  if ((i >= 12 && i <= 15) || i >= 100) { if (now >= hh.next) { hh.next = now + 110; return true; } }
  return false;
}
setInterval(() => {
  if (playing() || !document.hasFocus()) return held.clear();
  const now = performance.now();
  for (const pad of navigator.getGamepads()) {
    if (!pad?.connected) continue;
    const p = (i) => padPressed(pad, i, now);
    if (p(12) || p(102)) arrow(0, -1);
    if (p(13) || p(103)) arrow(0, 1);
    if (p(14) || p(100)) arrow(-1, 0);
    if (p(15) || p(101)) arrow(1, 0);
    if (p(0)) { const el = document.activeElement; if (el && el !== document.body) el.click(); else move(0, 1); }
    if (p(1)) back();
    if (scope() !== $('app')) continue;
    if (p(3)) { $('search').focus(); $('search').select(); }
    const t = TABS.findIndex(([id]) => id === view.tab);
    if (p(4)) selectTab(TABS[(t + TABS.length - 1) % TABS.length][0]);
    if (p(5)) selectTab(TABS[(t + 1) % TABS.length][0]);
    if (p(9)) selectTab('settings');
  }
}, 16);

// ---------- Search ----------

let searchTimer = 0;
let searchRun = 0;
function runSearch(q) {
  view.query = q.trim();
  view.results = null;
  clearTimeout(searchTimer);
  const run = ++searchRun;
  if (!view.query) { view.searching = false; return render(); }
  view.searching = true;
  render();
  searchTimer = setTimeout(async () => {
    let r = [];
    try { r = await searchGames(view.query); } catch (e) { toast(e.message); }
    if (run !== searchRun) return;
    view.results = r;
    view.searching = false;
    render();
  }, 300);
}
$('search').addEventListener('input', (e) => runSearch(e.target.value));
$('search').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); move(0, 1); } });

// ---------- Start ----------

subscribe(render);
window.kumori.version().then((v) => { version = v; });
boot().catch((e) => { console.error(e); toast('Kumori could not start: ' + e.message); });
// Sessions started elsewhere show up without a restart.
setInterval(() => { if (state.tokens && player.phase.kind === 'idle' && document.hasFocus()) import('./state.js').then((m) => m.refreshSessions()); }, 30000);
