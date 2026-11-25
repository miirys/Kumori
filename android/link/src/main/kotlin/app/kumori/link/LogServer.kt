package app.kumori.link

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder

/**
 * A small web page with the log and a Copy button, at http://<this box>:47821 on any
 * device on the same network, and at http://localhost:47821 on the box itself.
 */
class LogServer(private val state: () -> String, private val header: () -> String) {
    companion object { const val PORT = 47821 }

    private var server: ServerSocket? = null

    fun start() {
        Thread({
            try {
                val s = ServerSocket(PORT)
                server = s
                LogBook.add("web", "log page on port $PORT")
                while (!s.isClosed) {
                    val c = try { s.accept() } catch (e: Exception) { break }
                    Thread({ serve(c) }, "web").apply { isDaemon = true; start() }
                }
            } catch (e: Exception) {
                LogBook.add("web", "log page failed to start: ${e.message}")
            }
        }, "web-accept").apply { isDaemon = true; start() }
    }

    fun stop() { runCatching { server?.close() } }

    private fun serve(c: Socket) {
        c.use { runCatching {
            c.soTimeout = 5000
            val r = BufferedReader(InputStreamReader(c.getInputStream()))
            val line = r.readLine() ?: return
            while (true) { val h = r.readLine() ?: break; if (h.isEmpty()) break }
            val parts = line.split(" ")
            val method = parts.getOrNull(0) ?: "GET"
            val target = parts.getOrNull(1) ?: "/"
            val path = target.substringBefore('?')
            val query = target.substringAfter('?', "").split('&').filter { it.contains('=') }
                .associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
            when (path) {
                "/" -> reply(c, "text/html; charset=utf-8", PAGE)
                "/log.txt" -> reply(c, "text/plain; charset=utf-8", header() + "\n\n" + LogBook.text() + "\n", download = query["download"] != null)
                "/tail" -> {
                    val (total, lines) = LogBook.since(query["from"]?.toLongOrNull() ?: 0)
                    reply(c, "text/plain; charset=utf-8", "$total\n" + lines.joinToString("\n"))
                }
                "/state.json" -> reply(c, "application/json", state())
                "/clear" -> if (method == "POST") { LogBook.clear(); reply(c, "text/plain", "ok") } else reply(c, "text/plain", "POST only", 405)
                else -> reply(c, "text/plain", "not found", 404)
            }
        } }
    }

    private fun reply(c: Socket, type: String, body: String, code: Int = 200, download: Boolean = false) {
        val bytes = body.toByteArray()
        val status = when (code) { 200 -> "OK"; 404 -> "Not Found"; else -> "Method Not Allowed" }
        val head = buildString {
            append("HTTP/1.1 $code $status\r\n")
            append("Content-Type: $type\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            append("Cache-Control: no-store\r\n")
            append("Access-Control-Allow-Origin: *\r\n")
            if (download) append("Content-Disposition: attachment; filename=\"kumori-link-log.txt\"\r\n")
            append("Connection: close\r\n\r\n")
        }
        val o = c.getOutputStream()
        o.write(head.toByteArray())
        o.write(bytes)
        o.flush()
    }
}

private val PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kumori Link log</title>
<style>
:root{color-scheme:dark;--bg:#0b0a0d;--panel:#16131a;--line:#2a2530;--text:#ece8f0;--dim:#9a93a3;--accent:#f27ba6}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px;display:flex;flex-wrap:wrap;gap:8px;align-items:center;z-index:1}
h1{font-size:16px;margin:0 12px 0 0;font-weight:600}
button,a.btn{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:7px 12px;font:inherit;cursor:pointer;text-decoration:none}
button.primary{background:var(--accent);border-color:var(--accent);color:#16111b;font-weight:600}
label{color:var(--dim);display:flex;gap:6px;align-items:center}
#msg{color:var(--accent);margin-left:4px}
main{padding:12px 16px;display:grid;gap:12px}
section{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 12px;overflow:auto}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:0 0 6px;font-weight:600}
pre{margin:0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all}
#log{max-height:65vh;overflow:auto}
</style></head><body>
<header>
<h1>Kumori Link</h1>
<button class="primary" id="copy">Copy log</button>
<a class="btn" href="/log.txt?download=1">Download</a>
<button id="clear">Clear</button>
<label><input type="checkbox" id="follow" checked> Live</label>
<span id="msg"></span>
</header>
<main>
<section><h2>Now</h2><pre id="state">…</pre></section>
<section><h2>Log</h2><pre id="log"></pre></section>
</main>
<textarea id="buf" style="position:fixed;left:-9999px;top:0" readonly></textarea>
<script>
let from=0;const log=document.getElementById('log'),msg=document.getElementById('msg');
function say(t){msg.textContent=t;setTimeout(()=>{if(msg.textContent===t)msg.textContent=''},2500)}
async function tail(){
  if(!document.getElementById('follow').checked)return;
  try{const t=await (await fetch('/tail?from='+from)).text();const i=t.indexOf('\n');const n=+t.slice(0,i);const body=i<0?'':t.slice(i+1);
    if(n<from){log.textContent='';}
    if(body){const atEnd=log.scrollTop+log.clientHeight>=log.scrollHeight-20;log.textContent+=(log.textContent?'\n':'')+body;
      if(log.textContent.length>800000)log.textContent=log.textContent.slice(-600000);if(atEnd)log.scrollTop=log.scrollHeight}
    from=n}catch(e){}
}
async function state(){try{document.getElementById('state').textContent=JSON.stringify(await (await fetch('/state.json')).json(),null,2)}catch(e){}}
document.getElementById('copy').onclick=async()=>{
  const text=await (await fetch('/log.txt')).text();
  // The page is plain http on the local network, where the clipboard API is often blocked.
  try{if(navigator.clipboard&&window.isSecureContext){await navigator.clipboard.writeText(text);say('Copied');return}}catch(e){}
  const b=document.getElementById('buf');b.value=text;b.focus();b.select();b.setSelectionRange(0,text.length);
  say(document.execCommand('copy')?'Copied':'Copy blocked. Use Download.')
};
document.getElementById('clear').onclick=async()=>{await fetch('/clear',{method:'POST'});from=0;log.textContent='';say('Cleared')};
tail();state();setInterval(tail,700);setInterval(state,500);
</script></body></html>
"""
