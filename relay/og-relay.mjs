// Minimal relay skeleton — implements the RUNBOOK minimum requirements only:
// loopback bind, Bearer read from a file (never argv), no upstream LLM wired.
//   RELAY_PORT=8787 RELAY_KEY_FILE=/lab/etc/relay.key node og-relay.mjs
import http from 'node:http';
import fs from 'node:fs';

const PORT = Number(process.env.RELAY_PORT || 8787);
const HOST = '127.0.0.1';
const KEY_FILE = process.env.RELAY_KEY_FILE || '/lab/etc/relay.key';
const TOKEN = fs.existsSync(KEY_FILE) ? fs.readFileSync(KEY_FILE, 'utf8').trim() : '';

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: true, upstream: false }));
  }
  if (!TOKEN) {
    res.writeHead(503, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'no_key' }));
  }
  if ((req.headers.authorization || '') !== `Bearer ${TOKEN}`) {
    res.writeHead(401, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: false, error: 'unauthorized' }));
  }
  res.writeHead(501, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ ok: false, error: 'no_upstream_configured' }));
});

server.listen(PORT, HOST, () => console.log(`relay listening ${HOST}:${PORT}`));
