// Requests go through the main process, which may set the headers NVIDIA's services expect
// (a page may not set Origin or User-Agent itself).

export class ApiError extends Error {
  constructor(message, code = 0) { super(message); this.code = code; }
}

/** Sends a request and returns { status, ok, text, json }. Throws ApiError(code 0) when the network fails. */
export async function send(url, { method = 'GET', headers = {}, body = null } = {}) {
  let r;
  try {
    r = await window.kumori.http({ url, method, headers, body });
  } catch (e) {
    throw new ApiError("Can't reach GeForce NOW. Check your connection.");
  }
  if (r.error) throw new ApiError("Can't reach GeForce NOW. Check your connection.");
  let json = null;
  try { json = JSON.parse(r.text); } catch { /* not JSON */ }
  return { status: r.status, ok: r.status >= 200 && r.status < 300, text: r.text, json };
}

export const uuid = () => crypto.randomUUID();
