// The WebSocket that sets up the stream: the rig sends its offer and network candidates, we
// send our answer and ours. Messages between the two peers ride inside `peer_msg` envelopes,
// and anything with an `ackid` is acknowledged.

export const newPeerName = () => 'peer-' + crypto.randomUUID().replaceAll('-', '').slice(0, 12);

export class Signaling {
  #ws = null;
  #selfId = 0;
  #rigId = 1;
  #ack = 0;
  #beat = 0;
  #closed = false;
  open = false;

  /** `events`: onOpen(), onOffer(sdp), onCandidate({candidate, sdpMid, sdpMLineIndex}), onClosed(reason). */
  constructor({ url, sessionId, resolution, reconnect, peerName, events }) {
    Object.assign(this, { url, sessionId, resolution, reconnect, peerName, events });
  }

  /** The sign-in address: .../nvst/sign_in?peer_id=...&version=3.0&peer_role=1&pairing_id=<session>. */
  #signInUrl() {
    const path = this.url.split('#')[0].split('?')[0].replace(/^[a-z]+:\/\//, '').replace(/^\/+|\/+$/g, '');
    const base = path.endsWith('/sign_in') ? path : `${path}/sign_in`;
    const q = encodeURIComponent;
    return `wss://${base}?peer_id=${q(this.peerName)}&version=3.0&peer_role=1&pairing_id=${q(this.sessionId)}${this.reconnect ? '&reconnect=1' : ''}`;
  }

  connect() {
    const ws = new WebSocket(this.#signInUrl(), `x-nv-sessionid.${this.sessionId}`);
    this.#ws = ws;
    ws.onopen = () => {
      if (this.#closed) return;
      // Signalling version 3: we sign in as the client of this session's pairing, and the rig
      // only sends its offer once it has our peer information.
      this.#send({ ackid: ++this.#ack, peer_info: {
        browser: 'Chrome', browserVersion: '131.0.0.0', connected: true, id: this.#selfId, name: this.peerName, peer_role: 1,
        resolution: this.resolution, signalingVersion: '3.0', version: 3,
      } });
      this.#beat = setInterval(() => this.#send({ hb: 1 }), 5000);
      this.open = true;
      this.events.onOpen?.();
    };
    ws.onmessage = (e) => { try { this.#handle(String(e.data)); } catch (err) { console.error('signaling', err); } };
    ws.onclose = (e) => this.#finish(e.reason || `closed (${e.code})`);
    ws.onerror = () => this.#finish('connection failed');
  }

  #handle(text) {
    let j;
    try { j = JSON.parse(text); } catch { return; }
    const info = j.peer_info;
    // The server answers our sign-in with our registration, which carries the id it gave us.
    if (info && info.name === this.peerName && info.id != null) this.#selfId = info.id;
    if (j.ackid != null && !(info && info.id === this.#selfId)) this.#send({ ack: j.ackid });
    if (j.error) console.warn('signaling error', j.error);
    if (j.hb != null) return this.#send({ hb: 1 });
    const env = j.peer_msg;
    if (!env) return;
    if (env.from != null) this.#rigId = env.from;
    let p;
    try { p = JSON.parse(env.msg); } catch { return; }
    if (p.type === 'offer' && p.sdp) this.events.onOffer?.(p.sdp);
    else if (p.candidate) this.events.onCandidate?.({ candidate: p.candidate, sdpMid: p.sdpMid ?? null, sdpMLineIndex: p.sdpMLineIndex ?? 0 });
  }

  #peer(msg) {
    this.#send({ peer_msg: { from: this.#selfId, to: this.#rigId, msg: JSON.stringify(msg) }, ackid: ++this.#ack });
  }
  sendAnswer(sdp, nvstSdp) { this.#peer({ type: 'answer', sdp, nvstSdp }); }
  sendCandidate(c) { this.#peer({ candidate: c.candidate, sdpMid: c.sdpMid ?? null, sdpMLineIndex: c.sdpMLineIndex ?? 0 }); }
  requestKeyframe(reason) { this.#peer({ type: 'request_keyframe', reason, backlogFrames: 0, attempt: 1 }); }

  #send(j) {
    if (!this.#closed && this.#ws?.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify(j));
  }

  #finish(reason) {
    if (this.#closed) return;
    this.#closed = true;
    this.open = false;
    clearInterval(this.#beat);
    this.events.onClosed?.(reason);
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.open = false;
    clearInterval(this.#beat);
    try { this.#ws?.close(1000, 'bye'); } catch { /* already closed */ }
  }
}
