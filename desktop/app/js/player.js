// Starting, resuming and ending a game: the session service on one side, the stream on the other.
import { Cloudmatch, SessionError } from './cloudmatch.js';
import { Stream } from './stream.js';
import { newPeerName } from './signaling.js';
import { state, token, streamingBase, dlss, refreshSessions } from './state.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class Player {
  phase = { kind: 'idle' };
  stream = null;
  session = null;
  game = null;
  notice = null;
  stats = {};
  #cm = null;
  #run = 0;
  #request = null;
  #retries = 0;
  #startedAt = 0;

  /** `ui`: video, surface, pointer elements, and onChange(), onMenu(), onFullscreen(), onNeedClick(bool). */
  constructor(ui) { this.ui = ui; }

  #set(phase) { this.phase = phase; this.ui.onChange(); }
  get busy() { return this.phase.kind !== 'idle' && this.phase.kind !== 'error'; }
  get elapsedMs() { return this.#startedAt ? Date.now() - this.#startedAt : 0; }

  #ask(appId, title, linked, route, width, height) {
    const s = state.settings;
    return { appId, title, accountLinked: linked, route, width, height, fps: s.fps, lowLatency: s.lowLatency, dlss: dlss() };
  }

  /** Starts `game`, or picks up its session if one is already running for the account. */
  play(game, variant) {
    const v = variant ?? game.variants.find((x) => x.selected) ?? game.variants.find((x) => x.owned) ?? game.variants[0];
    if (!v) return this.#set({ kind: 'error', text: "This game can't be launched from here yet." });
    const running = state.sessions.find((a) => game.variants.some((x) => x.id === a.appId));
    if (running) return this.resume(running, game);
    const [w, h] = state.settings.resolution.split('x').map(Number);
    this.#begin(game, async (cm, alive) => {
      const base = streamingBase();
      // The browser client's list of sizes stops at 1440p. For more, ask as the PC app
      // does, still over WebRTC, and step down if the service says no.
      const tries = h > 1440 || w > 2560 ? [['DESKTOP', w, h], ['WEB', 2560, 1440]] : [['WEB', w, h]];
      let last = null;
      for (const [route, tw, th] of tries) {
        this.#request = this.#ask(v.id, game.title, v.owned, route, tw, th);
        try {
          const s = await this.#seat(cm, await cm.create(base, this.#request), alive, true);
          if (th !== h) this.notice = `This membership or rig didn't give ${h}p, so the stream is ${th}p.`;
          return s;
        } catch (e) {
          last = e;
          if (!(e instanceof SessionError) || !e.stepDown || !alive()) throw e;
        }
      }
      throw last;
    }, true);
  }

  /** Picks up a session listed for the account. */
  resume(active, game = null) {
    const [w, h] = state.settings.resolution.split('x').map(Number);
    const small = h > 1440 || w > 2560;
    this.#begin(game, (cm, alive) => {
      this.#request = this.#ask(active.appId, game?.title ?? null, true, 'WEB', small ? 2560 : w, small ? 1440 : h);
      return cm.claim(active, this.#request, alive);
    });
  }

  async #seat(cm, first, alive, fresh) {
    let s = first;
    let misses = 0;
    this.session = s;
    while (!s.ready) {
      if (!alive()) { if (fresh) cm.stop(s); throw new SessionError('Cancelled.'); }
      if (!(s.status >= 1 && s.status <= 3)) throw new SessionError('The session ended before it was ready.');
      if (s.adsRequired) {
        // A place in the queue that was asked for just now is given back, or it would block every other launch.
        if (fresh) await cm.stop(s);
        throw new SessionError("Your membership shows ads in the queue, which this app can't play. A paid membership skips them.");
      }
      const q = s.queuePosition;
      const step = s.setupStep;
      this.#set(q > 0 ? { kind: 'queued', position: q } : { kind: 'starting', text: step == null || step > 3 ? (step > 3 ? 'Launching the game' : 'Preparing your rig') : step <= 1 ? 'Finding a rig' : 'Preparing your rig' });
      await sleep(q > 10 ? 4000 : 1500);
      try {
        s = await cm.poll(s);
      } catch (e) {
        if ((e instanceof SessionError && e.statusCode !== 0) || ++misses > 20) throw e;
      }
      this.session = s;
    }
    return s;
  }

  #begin(game, obtain, fresh = false) {
    this.#stopStream();
    const run = ++this.#run;
    const alive = () => run === this.#run;
    this.game = game;
    this.notice = null;
    this.stats = {};
    this.#retries = 0;
    this.#cm = new Cloudmatch(() => token());
    this.#set({ kind: 'starting', text: 'Requesting a rig' });
    (async () => {
      try {
        const s = await obtain(this.#cm, alive);
        // Cancelled while the rig was being asked for: give it back, or it blocks the next launch.
        if (!alive()) { if (fresh) this.#cm.stop(s); return; }
        this.session = s;
        this.#connect(run, false);
      } catch (e) {
        if (!alive()) return;
        console.error(e);
        this.session = null;
        this.#set({ kind: 'error', text: e.message || 'Something went wrong.' });
        refreshSessions();
      }
    })();
  }

  #connect(run, reconnect) {
    const s = this.session;
    const r = this.#request;
    const set = state.settings;
    this.peerName ??= newPeerName();
    if (!reconnect) this.peerName = newPeerName();
    const stream = new Stream({
      session: s, peerName: this.peerName,
      config: { width: s.width ?? r.width, height: s.height ?? r.height, fps: r.fps, maxKbps: set.bitrate * 1000, codec: set.codec, cursorMode: set.cursorMode, volume: set.volume },
      video: this.ui.video, surface: this.ui.surface, pointer: this.ui.pointer,
      onProgress: (text) => { if (run === this.#run && this.phase.kind !== 'streaming') this.#set({ kind: 'starting', text }); },
      onConnected: () => {
        if (run !== this.#run) return;
        this.#startedAt ||= Date.now();
        this.#retries = 0;
        this.#set({ kind: 'streaming' });
      },
      onStats: (st) => { this.stats = st; this.ui.onStats?.(st); },
      onMenu: () => this.ui.onMenu(),
      onFullscreen: () => this.ui.onFullscreen(),
      onNeedClick: (need) => this.ui.onNeedClick(need),
      onTimeWarning: (left) => { this.notice = left > 90 ? `About ${Math.round(left / 60)} minutes of this session are left.` : `The session ends in ${left} seconds.`; this.ui.onChange(); },
      onClosed: (reason) => { if (run === this.#run) this.#lost(run, reason); },
    });
    this.stream = stream;
    stream.start(reconnect);
  }

  /** The stream dropped. The game is still running on the rig, so go back for it a few times. */
  async #lost(run, reason) {
    this.stream = null;
    if (this.#retries >= 3 || !this.session) {
      this.#startedAt = 0;
      this.#set({ kind: 'error', text: reason });
      return refreshSessions();
    }
    this.#retries++;
    this.#set({ kind: 'starting', text: 'Reconnecting' });
    await sleep(1000 * this.#retries);
    if (run !== this.#run) return;
    try {
      const s = this.session;
      this.session = await this.#cm.claim({ sessionId: s.id, appId: this.#request.appId, streamingBase: s.controlBase, serverHost: s.controlBase.replace(/^https:\/\//, '') },
        this.#request, () => run === this.#run);
      if (run === this.#run) this.#connect(run, true);
    } catch (e) {
      if (run !== this.#run) return;
      this.#startedAt = 0;
      this.#set({ kind: 'error', text: e.message || reason });
      refreshSessions();
    }
  }

  #stopStream() {
    this.stream?.stop();
    this.stream = null;
  }

  /** Stops watching. `end` also shuts the game down on the rig; otherwise it keeps running for a while. */
  async leave(end) {
    this.#run++;
    this.#stopStream();
    const s = this.session;
    this.session = null;
    this.#startedAt = 0;
    this.#set({ kind: 'idle' });
    if (s && end) await this.#cm?.stop(s);
    await refreshSessions();
  }

  dismiss() { if (this.phase.kind === 'error') this.#set({ kind: 'idle' }); }

  async endActive(active) {
    await new Cloudmatch(() => token()).stopActive(active);
    await refreshSessions();
  }
}
