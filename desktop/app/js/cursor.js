// The game's mouse cursor, drawn on this computer.
//
// GeForce NOW's rig does not have to paint the cursor into the video. On `cursor_channel`
// it tells the client which cursor the game is showing: one of Windows' standard shapes by
// number, or the game's own image with its hotspot. Shape 0 means the game has hidden the
// cursor and wants raw mouse movement (mouse-look). The layout below is the one GeForce
// NOW's own browser client reads.

/** Windows' standard cursors in the rig's numbering, as CSS cursors. 0 is "hidden". */
export const SYSTEM = ['none', 'default', 'text', 'wait', 'crosshair', 'progress', 'nwse-resize', 'nesw-resize',
  'ew-resize', 'ns-resize', 'move', 'pointer', 'help'];

/**
 * Reads one cursor message:
 * [kind][id][hotspot x][hotspot y][mime length][mime][image length, 16-bit LE][image, base64 text]
 * then, optionally, the cursor's position (two 16-bit fractions of 65535) and its scale x100.
 * Kind 0 names a standard cursor by id. Kind 1 is an image, sent once and named by id after.
 */
export function parseCursor(bytes) {
  if (bytes.length < 7 || bytes[0] > 1) return null;
  let at = 5;
  const u16 = () => { const v = bytes[at] | (bytes[at + 1] << 8); at += 2; return v; };
  const text = (n) => { const s = new TextDecoder().decode(bytes.subarray(at, at + n)); at += n; return s; };
  const mimeLength = bytes[4];
  if (at + mimeLength + 2 > bytes.length) return null;
  const mime = text(mimeLength);
  const imageLength = u16();
  if (at + imageLength > bytes.length) return null;
  const image = text(imageLength);
  const m = { image: bytes[0] === 1, id: bytes[1], hotX: bytes[2], hotY: bytes[3], mime, data: image, x: null, y: null, scale: 1 };
  if (at + 4 <= bytes.length) { m.x = u16(); m.y = u16(); }
  if (at + 2 <= bytes.length) m.scale = u16() / 100 || 1;
  return m;
}

/**
 * Follows the cursor messages and says what the mouse should be doing: `relative` (the game
 * hid the cursor, send raw movement) or not (show `css` and send positions).
 */
export class CursorState {
  #images = new Map();
  /** True once the rig has sent any cursor message, so we know it supports this. */
  seen = false;
  relative = false;
  /** What to show: { keyword } or { url, hotX, hotY, scale }. */
  shape = { keyword: 'default' };
  /** Where the rig says the cursor is when it reappears, as fractions of 65535, or null. */
  position = null;

  /** Returns true when the message changed anything. */
  apply(m) {
    if (!m) return false;
    let shape;
    if (m.image) {
      if (m.data) this.#images.set(m.id, { url: `data:${m.mime || 'image/png'};base64,${m.data}`, hotX: m.hotX, hotY: m.hotY, scale: m.scale });
      shape = this.#images.get(m.id);
      if (!shape) return false;
    } else {
      if (m.id >= SYSTEM.length) return false;
      shape = { keyword: SYSTEM[m.id] };
    }
    this.seen = true;
    const wasRelative = this.relative;
    this.relative = shape.keyword === 'none';
    this.position = !this.relative && wasRelative && m.x != null ? { x: m.x, y: m.y } : null;
    if (!this.relative) this.shape = shape;
    return true;
  }

  /**
   * The CSS `cursor` value. `zoom` is stream pixels per screen pixel, so a cursor drawn for
   * a 1440p stream is not oversized in a smaller window.
   */
  css(zoom = 1) {
    const s = this.shape;
    if (s.keyword) return s.keyword;
    const f = Math.max(0.25, Math.min(4, zoom * (s.scale || 1)));
    const x = Math.round(s.hotX / f);
    const y = Math.round(s.hotY / f);
    return Math.abs(f - 1) < 0.02 ? `url(${s.url}) ${x} ${y}, default` : `image-set(url(${s.url}) ${f.toFixed(2)}x) ${x} ${y}, default`;
  }
}
