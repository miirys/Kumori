// One stream: the WebRTC connection to the rig, its video and sound, and everything typed,
// clicked or pressed going back the other way.
import * as Sdp from './sdp.js';
import { Signaling, newPeerName } from './signaling.js';
import { InputEncoder, handshakeVersion, keyFor, modifiers, padReport, X } from './input.js';
import { parseCursor, CursorState } from './cursor.js';

const ARROW = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='20' height='28'%3E%3Cpath d='M1 1v21l5.5-5 3.6 8.6 3.2-1.4-3.6-8.4H17z' fill='%23fff' stroke='%23000' stroke-width='1.4'/%3E%3C/svg%3E\")";

export class Stream {
  #pc = null;
  #signaling = null;
  #input = null;
  #partial = null;
  #control = null;
  #cursorChannel = null;
  #encoder = new InputEncoder();
  #cursor = new CursorState();
  #timers = [];
  #off = [];
  #closed = false;
  #connected = false;
  #inputReady = false;
  #remoteSet = false;
  #pending = [];
  #pendingAnswer = null;
  #signIns = 0;
  #offerSeen = false;
  #media = new MediaStream();
  #keys = new Map();
  #buttons = new Set();
  #pads = new Map();
  #locked = false;
  #ourUnlock = false;
  #local = { x: 0, y: 0 };
  #wheel = 0;
  #last = null;
  #menuHold = 0;
  codec = null;
  /** True while the game should get the keyboard and mouse (false with the menu open). */
  active = true;

  /**
   * `o`: session, config { width, height, fps, maxKbps, codec, cursorMode, volume },
   * video (element), surface (element around it), pointer (element for the drawn cursor),
   * and callbacks onProgress(text), onConnected(), onStats(s), onClosed(reason, error),
   * onMenu(), onNeedClick(bool), onTimeWarning(secondsLeft).
   */
  constructor(o) {
    Object.assign(this, o);
    this.peerName = o.peerName ?? newPeerName();
  }

  // ---------- Connection ----------

  start(reconnect = false) {
    const s = this.session;
    if (!s.signalingUrl) return this.#fail("The rig didn't say where to connect.");
    this.onProgress?.('Connecting to the rig');
    const servers = s.ice.length ? s.ice.map((i) => ({ urls: i.urls, username: i.username, credential: i.credential })) : [
      { urls: 'stun:s1.stun.gamestream.nvidia.com:19308' }, { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
    ];
    const pc = new RTCPeerConnection({ iceServers: servers, bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
    this.#pc = pc;
    pc.onicecandidate = (e) => { if (e.candidate?.candidate) this.#signaling?.sendCandidate(e.candidate); };
    pc.onconnectionstatechange = () => {
      if (this.#closed) return;
      if (pc.connectionState === 'connected' && !this.#connected) {
        this.#connected = true;
        this.onConnected?.();
      } else if (pc.connectionState === 'failed') this.#fail('The connection to the rig was lost.');
    };
    pc.ontrack = (e) => {
      this.#media.addTrack(e.track);
      // Show frames as they arrive instead of smoothing them out.
      try { e.receiver.jitterBufferTarget = 0; } catch { /* older engines */ }
      try { e.receiver.playoutDelayHint = 0; } catch { /* non-standard */ }
      if (this.video.srcObject !== this.#media) this.video.srcObject = this.#media;
      this.video.play().catch(() => {});
    };
    pc.ondatachannel = (e) => {
      if (e.channel.label !== 'control_channel') return;
      this.#control = e.channel;
      e.channel.onmessage = (m) => this.#controlMessage(m.data);
    };
    this.video.volume = this.config.volume ?? 1;
    this.#signIn(reconnect);
    this.#listen();
  }

  #signIn(reconnect) {
    const attempt = ++this.#signIns;
    this.#signaling?.close();
    const retry = (why) => {
      if (this.#closed || attempt !== this.#signIns) return;
      if (attempt >= 4) return this.#fail("The rig didn't answer. Try again in a moment.");
      console.warn('signing in again:', why);
      this.#signIn(true);
    };
    this.#signaling = new Signaling({
      url: this.session.signalingUrl, sessionId: this.session.id, resolution: `${this.config.width}x${this.config.height}`,
      reconnect, peerName: this.peerName,
      events: {
        onOpen: () => {
          if (this.#pendingAnswer) { this.#signaling.sendAnswer(...this.#pendingAnswer); this.#pendingAnswer = null; }
        },
        onOffer: (sdp) => { if (!this.#offerSeen) { this.#offerSeen = true; this.#negotiate(sdp); } },
        onCandidate: (c) => {
          const cand = { candidate: c.candidate, sdpMid: c.sdpMid ?? String(c.sdpMLineIndex), sdpMLineIndex: c.sdpMLineIndex };
          if (this.#remoteSet) this.#pc.addIceCandidate(cand).catch(() => {}); else this.#pending.push(cand);
        },
        onClosed: (reason) => {
          if (attempt !== this.#signIns || this.#closed || this.#inputReady) return;
          // Before the answer is out the socket is still needed. After it, media carries on alone.
          if (!this.#remoteSet || this.#pendingAnswer) retry(reason);
        },
      },
    });
    this.#signaling.connect();
    this.#after(12000, () => { if (!this.#offerSeen) retry('no offer after 12 s'); });
  }

  #pickCodec(offer) {
    const offered = Sdp.offeredCodecs(offer);
    const can = new Set((RTCRtpReceiver.getCapabilities('video')?.codecs ?? []).map((c) => {
      const n = c.mimeType.split('/')[1].toUpperCase();
      return n === 'HEVC' ? 'H265' : n;
    }));
    const wanted = (this.config.codec ?? 'AUTO').toUpperCase();
    if (wanted !== 'AUTO' && offered.has(wanted) && can.has(wanted)) return wanted;
    // HEVC only shows up here when the GPU decodes it. AV1 and H.264 always decode, in
    // software if need be, and H.264 is the lighter of the two then.
    return ['H265', 'H264', 'AV1'].find((c) => offered.has(c) && can.has(c)) ?? 'H264';
  }

  async #negotiate(offerSdp) {
    const pc = this.#pc;
    const s = this.session;
    try {
      this.onProgress?.('Negotiating the stream');
      const serverIp = s.media?.ip ?? s.serverIp ?? '';
      let offer = serverIp ? Sdp.fixServerIp(offerSdp, serverIp) : offerSdp;
      const serverUfrag = Sdp.value(offer, 'a=ice-ufrag:') ?? '';
      const threshold = Sdp.partialReliableThreshold(offer) ?? 300;
      const chosen = this.#pickCodec(offer);
      offer = Sdp.keepCodec(offer, chosen);

      // Input channels, before the answer, so they ride the offer's data section.
      this.#input = pc.createDataChannel('input_channel_v1', { ordered: true });
      this.#input.binaryType = 'arraybuffer';
      this.#input.onmessage = (m) => this.#handshake(new Uint8Array(m.data));
      this.#partial = pc.createDataChannel('input_channel_partially_reliable', { ordered: false, maxPacketLifeTime: threshold });
      this.#partial.binaryType = 'arraybuffer';
      // Opening this channel is how the rig learns to send the game's cursor instead of
      // leaving us to guess. "Streamed" mode leaves it out and takes the cursor in the video.
      if (this.config.cursorMode !== 'streamed') {
        this.#cursorChannel = pc.createDataChannel('cursor_channel', { ordered: true });
        this.#cursorChannel.binaryType = 'arraybuffer';
        this.#cursorChannel.onmessage = (m) => this.#cursorMessage(new Uint8Array(m.data));
      }

      await pc.setRemoteDescription({ type: 'offer', sdp: offer });
      this.#remoteSet = true;
      // Receive only: the rig's microphone line would otherwise ask for a microphone.
      for (const t of pc.getTransceivers()) { try { t.direction = 'recvonly'; } catch { /* stopped */ } }
      for (const c of this.#pending.splice(0)) pc.addIceCandidate(c).catch(() => {});

      const answer = await pc.createAnswer();
      const munged = Sdp.mungeAnswer(answer.sdp, this.config.maxKbps);
      try {
        await pc.setLocalDescription({ type: 'answer', sdp: munged });
      } catch {
        await pc.setLocalDescription(answer);
      }
      await new Promise((resolve) => {
        if (pc.iceGatheringState === 'complete') return resolve();
        const t = setTimeout(resolve, 3000);
        pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); resolve(); } });
      });
      if (this.#closed) return;
      const final = Sdp.mungeAnswer(pc.localDescription?.sdp ?? munged, this.config.maxKbps);
      this.codec = Sdp.negotiatedCodec(final) ?? chosen;
      const nvst = Sdp.nvst({
        width: this.config.width, height: this.config.height, viewportWidth: this.config.width, viewportHeight: this.config.height,
        fps: this.config.fps, maxKbps: this.config.maxKbps, codec: this.codec, bitDepth: 8, partialReliableMs: threshold,
        ice: Sdp.credentials(final),
      });
      if (this.#signaling?.open) this.#signaling.sendAnswer(final, nvst); else this.#pendingAnswer = [final, nvst];

      // The rig runs ICE-lite and may not send candidates. Tell ICE where it is.
      if (s.media) {
        const ip = Sdp.publicIp(s.media.ip) ?? s.media.ip;
        const ufrag = serverUfrag ? ` generation 0 ufrag ${serverUfrag}` : '';
        const add = (candidate) => pc.addIceCandidate({ candidate, sdpMid: '0', sdpMLineIndex: 0 }).catch(() => {});
        add(`candidate:1 1 udp 2130706431 ${ip} ${s.media.port} typ host${ufrag}`);
        add(`candidate:2 1 tcp 1518149375 ${ip} ${s.media.port} typ host tcptype passive${ufrag}`);
      }
      this.onProgress?.('Starting the video');
      this.#every(1000, () => this.#pollStats());
      this.#after(25000, () => { if (!this.#connected) this.#fail("The video didn't start. The rig may be unreachable from this network."); });
    } catch (e) {
      console.error('negotiation failed', e);
      this.#fail(`The stream couldn't be negotiated: ${e?.message ?? 'unknown error'}`);
    }
  }

  /** The server opens input with its protocol version. From then on we may send. */
  #handshake(bytes) {
    if (this.#inputReady) return;
    const v = handshakeVersion(bytes);
    if (v == null) return;
    this.#encoder.version = v;
    this.#inputReady = true;
    this.#every(2000, () => this.#send(this.#encoder.heartbeat()));
    this.#every(8, () => this.#pollPads());
    this.#syncMouse();
  }

  #controlMessage(data) {
    try {
      const text = typeof data === 'string' ? data : new TextDecoder().decode(data);
      const t = JSON.parse(text).timerNotification;
      if (t && t.secondsLeft >= 0) this.onTimeWarning?.(t.secondsLeft);
    } catch { /* not for us */ }
  }

  async #pollStats() {
    if (this.#closed || !this.#pc) return;
    const report = await this.#pc.getStats().catch(() => null);
    if (!report) return;
    const s = { codec: this.codec, cursor: this.cursorInfo() };
    let codecId = null;
    for (const r of report.values()) {
      if (r.type === 'inbound-rtp' && r.kind === 'video') {
        const now = { t: r.timestamp, bytes: r.bytesReceived, decoded: r.framesDecoded, decodeTime: r.totalDecodeTime };
        const p = this.#last;
        if (p && now.t > p.t) {
          s.kbps = Math.round(((now.bytes - p.bytes) * 8) / (now.t - p.t));
          const frames = now.decoded - p.decoded;
          s.decodeMs = frames > 0 ? ((now.decodeTime - p.decodeTime) / frames) * 1000 : null;
        }
        this.#last = now;
        Object.assign(s, { fps: r.framesPerSecond ?? 0, width: r.frameWidth, height: r.frameHeight, lost: r.packetsLost, dropped: r.framesDropped,
          jitterMs: r.jitter != null ? r.jitter * 1000 : null, decoder: r.decoderImplementation, hardware: r.powerEfficientDecoder });
        codecId = r.codecId;
      } else if (r.type === 'candidate-pair' && r.nominated && r.currentRoundTripTime != null) {
        s.rttMs = r.currentRoundTripTime * 1000;
      }
    }
    const c = codecId && report.get(codecId);
    if (c?.mimeType) s.codec = c.mimeType.split('/')[1].toUpperCase().replace('HEVC', 'H265');
    this.onStats?.(s);
  }

  requestKeyframe(reason) {
    const msg = { type: 'request_keyframe', reason, backlogFrames: 0, attempt: 1 };
    if (this.#control?.readyState === 'open') this.#control.send(JSON.stringify(msg)); else this.#signaling?.requestKeyframe(reason);
  }

  setVolume(v) { this.config.volume = v; this.video.volume = v; }

  #after(ms, fn) { this.#timers.push(setTimeout(() => { if (!this.#closed) fn(); }, ms)); }
  #every(ms, fn) { this.#timers.push(setInterval(() => { if (!this.#closed) fn(); }, ms)); }

  #fail(reason) {
    if (this.#closed) return;
    this.stop();
    this.onClosed?.(reason, true);
  }

  stop() {
    if (this.#closed) return;
    this.releaseAll();
    this.#closed = true;
    this.#timers.forEach((t) => { clearTimeout(t); clearInterval(t); });
    this.#off.forEach((f) => f());
    if (document.pointerLockElement) document.exitPointerLock();
    this.#signaling?.close();
    for (const ch of [this.#input, this.#partial, this.#cursorChannel]) { try { ch?.close(); } catch { /* closed */ } }
    try { this.#pc?.close(); } catch { /* closed */ }
    this.video.srcObject = null;
    this.video.style.cursor = '';
    this.pointer.hidden = true;
  }

  // ---------- Sending ----------

  #send(buf) {
    if (!this.#closed && this.#input?.readyState === 'open') this.#input.send(buf);
  }

  // ---------- Cursor and mouse ----------

  #cursorMessage(bytes) {
    const was = this.#cursor.relative;
    if (!this.#cursor.apply(parseCursor(bytes))) return;
    const p = this.#cursor.position;
    if (p) {
      // The game brought its cursor back at this spot. The drawn cursor starts there.
      const r = this.#rect();
      this.#local = { x: (p.x / 65535) * r.width, y: (p.y / 65535) * r.height };
    }
    if (was !== this.#cursor.relative) console.info('cursor:', this.#cursor.relative ? 'hidden by the game, raw movement' : 'visible, positions');
    this.#syncMouse();
  }

  /** What the cursor is doing, for the stats panel. */
  cursorInfo() {
    if (this.config.cursorMode === 'streamed') return 'in the video';
    if (!this.#cursor.seen) return 'waiting for the rig';
    if (this.#cursor.relative) return 'hidden by the game';
    return this.#cursor.shape.keyword ? `local, ${this.#cursor.shape.keyword}` : 'local, game image';
  }

  /** Where the picture sits inside the video element, in CSS pixels. */
  #rect() {
    const v = this.video;
    const box = v.getBoundingClientRect();
    const vw = v.videoWidth || this.config.width;
    const vh = v.videoHeight || this.config.height;
    const scale = Math.min(box.width / vw, box.height / vh) || 1;
    const width = vw * scale;
    const height = vh * scale;
    return { left: box.left + (box.width - width) / 2, top: box.top + (box.height - height) / 2, width, height,
      // The game's desktop is the size that was asked for, whatever the video is scaled to on the way.
      zoom: this.config.width / width || 1 };
  }

  /** Whether the mouse should be held by the app, sending raw movement or driving a drawn cursor. */
  #wantLock() {
    if (!this.active || !this.#inputReady) return false;
    const mode = this.config.cursorMode;
    return mode === 'captured' || mode === 'streamed' || this.#cursor.relative;
  }

  /** Brings the pointer lock, the system cursor and the drawn cursor in line with the game. */
  #syncMouse() {
    if (this.#closed) return;
    const want = this.#wantLock();
    if (want && !this.#locked) this.#lock();
    else if (!want && this.#locked) { this.#ourUnlock = true; document.exitPointerLock(); }
    const mode = this.config.cursorMode;
    const visible = this.active && !this.#cursor.relative;
    const r = this.#rect();
    this.video.style.cursor = !this.active ? 'default' : mode === 'system' && visible ? this.#cursor.css(r.zoom) : 'none';
    const draw = mode === 'captured' && visible && this.#locked;
    this.pointer.hidden = !draw;
    if (draw) {
      const s = this.#cursor.shape;
      const f = s.keyword ? 1 : Math.max(0.25, r.zoom * (s.scale || 1));
      this.pointer.style.backgroundImage = s.keyword ? ARROW : `url(${s.url})`;
      this.pointer.style.transform = `translate(${r.left + this.#local.x - (s.keyword ? 1 : s.hotX / f)}px, ${r.top + this.#local.y - (s.keyword ? 1 : s.hotY / f)}px) scale(${1 / f})`;
    }
  }

  async #lock() {
    try {
      // The app holds the pointer through the main process, so it does not depend on a click.
      await window.kumori.lockPointer();
    } catch { /* falls through to the hint */ }
    if (!this.#locked) this.onNeedClick?.(true);
  }

  /** Called by the page when the main process asks for the pointer with a user gesture. */
  async takePointer() {
    if (this.#closed || !this.#wantLock() || this.#locked) return;
    try {
      await this.video.requestPointerLock({ unadjustedMovement: true });
    } catch (e) {
      if (e?.name === 'NotSupportedError') await this.video.requestPointerLock().catch(() => {});
    }
  }

  #position(e) {
    const r = this.#rect();
    return [((e.clientX - r.left) / r.width) * 65535, ((e.clientY - r.top) / r.height) * 65535];
  }

  #move(e) {
    if (!this.active || !this.#inputReady) return;
    if (!this.#locked) {
      if (this.config.cursorMode === 'system' && !this.#cursor.relative) this.#send(this.#encoder.mouseAbsolute(...this.#position(e)));
      return;
    }
    let dx = 0;
    let dy = 0;
    const list = e.getCoalescedEvents?.() ?? [];
    for (const c of list.length ? list : [e]) { dx += c.movementX; dy += c.movementY; }
    if (!dx && !dy) return;
    if (this.#cursor.relative || this.config.cursorMode === 'streamed') return this.#send(this.#encoder.mouseMove(dx, dy));
    // Captured with a visible cursor: move the drawn cursor now and tell the game where it is.
    const r = this.#rect();
    this.#local.x = Math.max(0, Math.min(r.width, this.#local.x + dx));
    this.#local.y = Math.max(0, Math.min(r.height, this.#local.y + dy));
    this.#send(this.#encoder.mouseAbsolute((this.#local.x / r.width) * 65535, (this.#local.y / r.height) * 65535));
    this.#syncMouse();
  }

  #button(e, down) {
    if (!this.active || !this.#inputReady) return;
    e.preventDefault();
    if (down && this.#wantLock() && !this.#locked) return this.takePointer();
    const b = [1, 2, 3, 4, 5][e.button];
    if (!b) return;
    if (down) {
      if (!this.#locked) {
        this.#send(this.#encoder.mouseAbsolute(...this.#position(e)));
        try { this.video.setPointerCapture(e.pointerId); } catch { /* not a pointer event */ }
      }
      this.#buttons.add(b);
    } else if (!this.#buttons.delete(b)) return;
    this.#send(this.#encoder.mouseButton(down, b));
  }

  // ---------- Keyboard ----------

  #key(e, down) {
    if (this.#closed) return;
    if (down && !e.repeat && ((e.ctrlKey && !e.altKey && !e.shiftKey && e.code === 'KeyG') || (e.ctrlKey && e.shiftKey && e.code === 'KeyQ'))) {
      e.preventDefault();
      return this.onMenu?.();
    }
    if (e.code === 'F11') {
      e.preventDefault();
      if (down && !e.repeat) this.onFullscreen?.();
      return;
    }
    if (!this.active || !this.#inputReady) return;
    const k = keyFor(e.code);
    if (!k) return;
    e.preventDefault();
    if (down) this.#keys.set(e.code, k); else if (!this.#keys.delete(e.code)) return;
    this.#send(this.#encoder.key(down, k.vk, k.scan, modifiers(e)));
  }

  /** Taps a key the browser kept for itself, such as Escape leaving the pointer lock. */
  tap(code) {
    const k = keyFor(code);
    if (!k || !this.#inputReady) return;
    this.#send(this.#encoder.key(true, k.vk, k.scan, 0));
    setTimeout(() => this.#send(this.#encoder.key(false, k.vk, k.scan, 0)), 30);
  }

  /** Lets go of everything held, so nothing stays stuck when the game loses the keyboard. */
  releaseAll() {
    if (!this.#inputReady) return;
    for (const k of this.#keys.values()) this.#send(this.#encoder.key(false, k.vk, k.scan, 0));
    this.#keys.clear();
    for (const b of this.#buttons) this.#send(this.#encoder.mouseButton(false, b));
    this.#buttons.clear();
  }

  setActive(on) {
    if (this.active === on) return;
    if (!on) this.releaseAll();
    this.active = on;
    this.#syncMouse();
  }

  setCursorMode(mode) {
    // Switching to or from "streamed" needs the cursor channel, which is set up at connect.
    this.config.cursorMode = mode;
    this.#syncMouse();
  }

  // ---------- Controllers ----------

  #pollPads() {
    const pads = [...navigator.getGamepads()].filter((p) => p && p.connected && p.index < 4);
    let mask = 0;
    for (const p of pads) mask |= 1 << p.index;
    const seen = new Set();
    for (const p of pads) {
      seen.add(p.index);
      const r = padReport(p);
      // The Guide button, or Back and Start held together, opens the menu and stays here.
      const combo = (r.buttons & X.GUIDE) || ((r.buttons & X.BACK) && (r.buttons & X.START));
      if (combo) {
        if (!this.#menuHold) this.#menuHold = performance.now();
        else if (this.#menuHold > 0 && performance.now() - this.#menuHold > ((r.buttons & X.GUIDE) ? 0 : 700)) { this.#menuHold = -1; this.onMenu?.(); }
      } else if (p.index === pads[0].index) this.#menuHold = 0;
      if (!this.active) continue;
      r.buttons &= ~X.GUIDE;
      const key = `${mask}|${r.buttons}|${r.lt}|${r.rt}|${r.lx}|${r.ly}|${r.rx}|${r.ry}`;
      if (this.#pads.get(p.index) === key) continue;
      this.#pads.set(p.index, key);
      this.#sendPad(p.index, mask, r);
    }
    // A pad that went away is reported once more, at rest and no longer in the mask.
    for (const index of [...this.#pads.keys()]) {
      if (seen.has(index)) continue;
      this.#pads.delete(index);
      this.#sendPad(index, mask, { buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0 });
    }
  }

  #sendPad(slot, mask, r) {
    const args = [slot, mask, r.buttons, r.lt, r.rt, r.lx, r.ly, r.rx, r.ry];
    // Controller reports go on the partially reliable channel: a late report is useless.
    if (this.#partial?.readyState === 'open') this.#partial.send(this.#encoder.gamepad(...args, true));
    else this.#send(this.#encoder.gamepad(...args, false));
  }

  // ---------- Listeners ----------

  #listen() {
    const on = (target, type, fn, opts) => {
      target.addEventListener(type, fn, opts);
      this.#off.push(() => target.removeEventListener(type, fn, opts));
    };
    const v = this.video;
    const raw = 'onpointerrawupdate' in v;
    // Raw updates arrive as the mouse reports them, not once per drawn frame.
    on(v, raw ? 'pointerrawupdate' : 'pointermove', (e) => this.#move(e));
    on(v, 'pointerdown', (e) => this.#button(e, true));
    on(v, 'pointerup', (e) => this.#button(e, false));
    on(v, 'contextmenu', (e) => e.preventDefault());
    on(v, 'wheel', (e) => {
      if (!this.active || !this.#inputReady) return;
      e.preventDefault();
      // One notch is 100 px here and 120 to Windows, with the sign flipped.
      this.#wheel += -e.deltaY * (e.deltaMode === 1 ? 40 : 1.2);
      const whole = Math.trunc(this.#wheel);
      if (whole) { this.#wheel -= whole; this.#send(this.#encoder.wheel(whole)); }
    }, { passive: false });
    on(window, 'keydown', (e) => this.#key(e, true), true);
    on(window, 'keyup', (e) => this.#key(e, false), true);
    on(window, 'blur', () => this.releaseAll());
    on(window, 'resize', () => this.#syncMouse());
    on(document, 'pointerlockchange', () => {
      const locked = document.pointerLockElement === v;
      const was = this.#locked;
      this.#locked = locked;
      if (locked) this.onNeedClick?.(false);
      if (was && !locked && !this.#ourUnlock && this.#wantLock() && document.hasFocus()) {
        // Escape took the pointer back before the game saw the key. Pass the key on and
        // take the pointer again, as GeForce NOW's own client does.
        this.tap('Escape');
        setTimeout(() => this.#syncMouse(), 60);
      }
      this.#ourUnlock = false;
      this.#syncMouse();
    });
    on(document, 'pointerlockerror', () => this.onNeedClick?.(true));
  }
}
