// GeForce NOW input packets. Each event is a small binary record. From input protocol
// version 3 on, records are wrapped with a microsecond timestamp and a framing byte.

export const X = {
  UP: 0x0001, DOWN: 0x0002, LEFT: 0x0004, RIGHT: 0x0008, START: 0x0010, BACK: 0x0020, LS: 0x0040, RS: 0x0080,
  LB: 0x0100, RB: 0x0200, GUIDE: 0x0400, A: 0x1000, B: 0x2000, X: 0x4000, Y: 0x8000,
};
export const MOD = { SHIFT: 1, CTRL: 2, ALT: 4, META: 8, CAPS: 16, NUM: 32 };

const nowUs = () => BigInt(Math.round(performance.now() * 1000));
const clamp16 = (v) => Math.max(-32768, Math.min(32767, Math.round(v)));

export class InputEncoder {
  /** Set from the server's handshake on the input channel. */
  version = 2;
  #seq = [1, 1, 1, 1];

  /** Keeps the input path alive. Sent bare, never wrapped. */
  heartbeat() {
    const d = new DataView(new ArrayBuffer(4));
    d.setUint32(0, 2, true);
    return d.buffer;
  }

  /** `vk` is a Windows virtual-key code, `scan` the key's USB HID usage. */
  key(down, vk, scan, modifiers) {
    const d = new DataView(new ArrayBuffer(18));
    d.setUint32(0, down ? 3 : 4, true);
    d.setUint16(4, vk);
    d.setUint16(6, modifiers);
    d.setUint16(8, scan);
    d.setBigUint64(10, nowUs());
    return this.#single(d.buffer);
  }

  mouseMove(dx, dy) {
    const d = new DataView(new ArrayBuffer(22));
    d.setUint32(0, 7, true);
    d.setInt16(4, clamp16(dx));
    d.setInt16(6, clamp16(dy));
    d.setBigUint64(14, nowUs());
    return this.#sized(d.buffer);
  }

  /** A position on the stream picture, as fractions of 65535 across and down. */
  mouseAbsolute(x, y) {
    const d = new DataView(new ArrayBuffer(26));
    d.setUint32(0, 5, true);
    d.setUint16(4, Math.max(0, Math.min(65535, Math.round(x))));
    d.setUint16(6, Math.max(0, Math.min(65535, Math.round(y))));
    d.setUint16(10, 65535);
    d.setUint16(12, 65535);
    d.setBigUint64(18, nowUs());
    return this.#sized(d.buffer);
  }

  /** `button`: 1 left, 2 middle, 3 right, 4 back, 5 forward. */
  mouseButton(down, button) {
    const d = new DataView(new ArrayBuffer(18));
    d.setUint32(0, down ? 8 : 9, true);
    d.setUint8(4, button);
    d.setBigUint64(10, nowUs());
    return this.#single(d.buffer);
  }

  /** One wheel notch is 120, positive away from the user. */
  wheel(delta) {
    const d = new DataView(new ArrayBuffer(22));
    d.setUint32(0, 10, true);
    d.setInt16(6, clamp16(delta));
    d.setBigUint64(14, nowUs());
    return this.#single(d.buffer);
  }

  /** One XInput-style report. Sticks are -32768..32767 with up positive, triggers 0..255. */
  gamepad(slot, connected, buttons, lt, rt, lx, ly, rx, ry, partiallyReliable) {
    const d = new DataView(new ArrayBuffer(38));
    d.setUint32(0, 12, true);
    d.setUint16(4, 26, true);
    d.setUint16(6, slot & 3, true);
    d.setUint16(8, connected, true);
    d.setUint16(10, 20, true);
    d.setUint16(12, buttons, true);
    d.setUint16(14, (lt & 0xff) | ((rt & 0xff) << 8), true);
    d.setInt16(16, lx, true);
    d.setInt16(18, ly, true);
    d.setInt16(20, rx, true);
    d.setInt16(22, ry, true);
    d.setUint16(26, 85, true);
    d.setBigUint64(30, nowUs(), true);
    if (this.version <= 2) return d.buffer;
    if (!partiallyReliable) return this.#sized(d.buffer);
    const s = slot & 3;
    const seq = this.#seq[s];
    this.#seq[s] = (seq + 1) & 0xffff;
    const w = new DataView(new ArrayBuffer(16 + 38));
    w.setUint8(0, 0x23);
    w.setBigUint64(1, nowUs());
    w.setUint8(9, 0x26);
    w.setUint8(10, s);
    w.setUint16(11, seq);
    w.setUint8(13, 0x21);
    w.setUint16(14, 38);
    new Uint8Array(w.buffer).set(new Uint8Array(d.buffer), 16);
    return w.buffer;
  }

  /** A lone event: [0x23][timestamp][0x22][record]. */
  #single(payload) {
    if (this.version <= 2) return payload;
    const w = new DataView(new ArrayBuffer(10 + payload.byteLength));
    w.setUint8(0, 0x23);
    w.setBigUint64(1, nowUs());
    w.setUint8(9, 0x22);
    new Uint8Array(w.buffer).set(new Uint8Array(payload), 10);
    return w.buffer;
  }

  /** A sized event: [0x23][timestamp][0x21][length][record]. */
  #sized(payload) {
    if (this.version <= 2) return payload;
    const w = new DataView(new ArrayBuffer(12 + payload.byteLength));
    w.setUint8(0, 0x23);
    w.setBigUint64(1, nowUs());
    w.setUint8(9, 0x21);
    w.setUint16(10, payload.byteLength);
    new Uint8Array(w.buffer).set(new Uint8Array(payload), 12);
    return w.buffer;
  }
}

/** The input protocol version from the server's first message on the input channel, or null. */
export function handshakeVersion(bytes) {
  if (bytes.length < 2) return null;
  const first = bytes[0] | (bytes[1] << 8);
  if (first === 526) return bytes.length >= 4 ? bytes[2] | (bytes[3] << 8) : 2;
  return bytes[0] === 0x0e ? first : null;
}

// Physical keys (KeyboardEvent.code) to a Windows virtual-key code and the key's USB HID
// usage. Layout-independent, like a keyboard plugged into the rig.
const KEYS = {};
const put = (code, vk, hid) => { KEYS[code] = { vk, scan: hid }; };
for (let i = 0; i < 26; i++) put(`Key${String.fromCharCode(65 + i)}`, 0x41 + i, 0x04 + i);
put('Digit0', 0x30, 0x27);
for (let i = 1; i <= 9; i++) put(`Digit${i}`, 0x30 + i, 0x1d + i);
for (let i = 0; i < 12; i++) put(`F${i + 1}`, 0x70 + i, 0x3a + i);
for (let i = 13; i <= 24; i++) put(`F${i}`, 0x7c + i - 13, 0x68 + i - 13);
put('Numpad0', 0x60, 0x62);
for (let i = 1; i <= 9; i++) put(`Numpad${i}`, 0x60 + i, 0x58 + i);
for (const [code, vk, hid] of [
  ['Enter', 0x0d, 0x28], ['Escape', 0x1b, 0x29], ['Backspace', 0x08, 0x2a], ['Tab', 0x09, 0x2b], ['Space', 0x20, 0x2c],
  ['Minus', 0xbd, 0x2d], ['Equal', 0xbb, 0x2e], ['BracketLeft', 0xdb, 0x2f], ['BracketRight', 0xdd, 0x30],
  ['Backslash', 0xdc, 0x31], ['Semicolon', 0xba, 0x33], ['Quote', 0xde, 0x34], ['Backquote', 0xc0, 0x35],
  ['Comma', 0xbc, 0x36], ['Period', 0xbe, 0x37], ['Slash', 0xbf, 0x38], ['CapsLock', 0x14, 0x39],
  ['PrintScreen', 0x2c, 0x46], ['ScrollLock', 0x91, 0x47], ['Pause', 0x13, 0x48], ['Insert', 0x2d, 0x49],
  ['Home', 0x24, 0x4a], ['PageUp', 0x21, 0x4b], ['Delete', 0x2e, 0x4c], ['End', 0x23, 0x4d], ['PageDown', 0x22, 0x4e],
  ['ArrowRight', 0x27, 0x4f], ['ArrowLeft', 0x25, 0x50], ['ArrowDown', 0x28, 0x51], ['ArrowUp', 0x26, 0x52],
  ['NumLock', 0x90, 0x53], ['NumpadDivide', 0x6f, 0x54], ['NumpadMultiply', 0x6a, 0x55], ['NumpadSubtract', 0x6d, 0x56],
  ['NumpadAdd', 0x6b, 0x57], ['NumpadEnter', 0x0d, 0x58], ['NumpadDecimal', 0x6e, 0x63], ['IntlBackslash', 0xe2, 0x64],
  ['ContextMenu', 0x5d, 0x65], ['ControlLeft', 0xa2, 0xe0], ['ShiftLeft', 0xa0, 0xe1], ['AltLeft', 0xa4, 0xe2],
  ['MetaLeft', 0x5b, 0xe3], ['ControlRight', 0xa3, 0xe4], ['ShiftRight', 0xa1, 0xe5], ['AltRight', 0xa5, 0xe6],
  ['MetaRight', 0x5c, 0xe7],
]) put(code, vk, hid);

export const keyFor = (code) => KEYS[code] ?? null;

/** Modifier bits for a keyboard or mouse event. */
export function modifiers(e) {
  return (e.shiftKey ? MOD.SHIFT : 0) | (e.ctrlKey ? MOD.CTRL : 0) | (e.altKey ? MOD.ALT : 0) | (e.metaKey ? MOD.META : 0) |
    (e.getModifierState?.('CapsLock') ? MOD.CAPS : 0) | (e.getModifierState?.('NumLock') ? MOD.NUM : 0);
}

const STANDARD = [X.A, X.B, X.X, X.Y, X.LB, X.RB, 0, 0, X.BACK, X.START, X.LS, X.RS, X.UP, X.DOWN, X.LEFT, X.RIGHT, X.GUIDE];

/** A browser gamepad in the standard layout as an XInput report. */
export function padReport(pad, deadzone = 0.08) {
  let buttons = 0;
  pad.buttons.forEach((b, i) => { if (b.pressed && STANDARD[i]) buttons |= STANDARD[i]; });
  const axis = (v) => {
    const a = Math.abs(v) < deadzone ? 0 : v;
    return Math.round(32767.5 * (a + 1)) - 32768;
  };
  const trigger = (i) => Math.round((pad.buttons[i]?.value ?? 0) * 255);
  const ax = pad.axes;
  return {
    buttons, lt: trigger(6), rt: trigger(7),
    lx: axis(ax[0] ?? 0), ly: axis(-(ax[1] ?? 0)), rx: axis(ax[2] ?? 0), ry: axis(-(ax[3] ?? 0)),
  };
}
