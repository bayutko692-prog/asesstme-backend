#!/usr/bin/env node
/**
 * ASESSTME — 24/7 backend relay.
 * Owner: @dvc | Builder: promode
 *
 * Runs on GitHub Actions (free, public repo = unlimited minutes).
 * Publishes its public URL into relay-lease.json so the Android app can
 * find it without any hard-coded host.
 *
 *   GET  /health        -> liveness + key pool size
 *   POST /chat          -> Groq chat completion (client key OR pool key)
 *   GET  /models        -> Groq model list
 *   POST /transcribe    -> Groq whisper transcription
 *
 * Key failover: the client's Authorization header is used first. If Groq
 * rejects it (401/403) the relay retries with the keys in the pool, so a
 * dead client key does not kill the backend.
 */
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.PORT || '8080', 10);
const GROQ = 'https://api.groq.com/openai/v1';
const LEASE_FILE = process.env.LEASE_FILE || path.join(__dirname, '..', 'relay-lease.json');
const MY_URL_FILE = process.env.MY_URL_FILE || path.join(__dirname, '..', 'relay_url.txt');
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
const GITHUB_REPO = process.env.GITHUB_REPO || '';   // owner/repo
const REFRESH_MS = 90 * 1000;

const POOL = (process.env.GROQ_KEY_POOL || '')
  .split(',').map(s => s.trim()).filter(Boolean);

let myUrl = '';
try { myUrl = fs.readFileSync(MY_URL_FILE, 'utf8').trim(); } catch (e) {}

/* ------------------------------------------------------------------ */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function json(res, code, obj) {
  const b = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': b.length,
    'Access-Control-Allow-Origin': '*'
  });
  res.end(b);
}

function groqRequest(method, urlPath, key, bodyBuf, contentType) {
  return new Promise((resolve, reject) => {
    const opts = {
      hostname: 'api.groq.com',
      path: urlPath,
      method: method,
      headers: {
        'Authorization': 'Bearer ' + key,
        'Accept': 'application/json'
      }
    };
    if (bodyBuf) {
      opts.headers['Content-Type'] = contentType || 'application/json';
      opts.headers['Content-Length'] = bodyBuf.length;
    }
    const r = https.request(opts, (resp) => {
      const chunks = [];
      resp.on('data', c => chunks.push(c));
      resp.on('end', () => resolve({
        code: resp.statusCode,
        body: Buffer.concat(chunks).toString('utf8')
      }));
    });
    r.on('error', reject);
    r.setTimeout(60000, () => { r.destroy(new Error('groq timeout')); });
    if (bodyBuf) r.write(bodyBuf);
    r.end();
  });
}

/** try the client key first, then every pool key */
async function groqWithFailover(method, urlPath, clientKey, bodyBuf, contentType) {
  const tries = [];
  if (clientKey) tries.push(clientKey);
  for (const k of POOL) if (k !== clientKey) tries.push(k);
  if (!tries.length) return { code: 401, body: JSON.stringify({ error: { message: 'no key available' } }) };

  let last = null;
  for (const k of tries) {
    try {
      const r = await groqRequest(method, urlPath, k, bodyBuf, contentType);
      if (r.code === 200) return r;
      if (r.code === 401 || r.code === 403) { last = r; continue; }  // key dead -> next
      return r;
    } catch (e) {
      last = { code: 502, body: JSON.stringify({ error: { message: String(e.message || e) } }) };
    }
  }
  return last || { code: 502, body: JSON.stringify({ error: { message: 'relay failed' } }) };
}

/* ------------------------------------------------------------------ */
const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const u = new URL(req.url, 'http://localhost');
  const p = u.pathname.replace(/\/+$/, '') || '/';

  try {
    if (p === '/health') {
      return json(res, 200, {
        ok: true, service: 'asesstme-relay', uptime: Math.round(process.uptime()),
        url: myUrl, pool: POOL.length, time: Date.now()
      });
    }

    if (p === '/chat' && req.method === 'POST') {
      const body = await readBody(req);
      const clientKey = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '').trim();
      const r = await groqWithFailover('POST', '/openai/v1/chat/completions', clientKey, body, 'application/json');
      res.writeHead(r.code, { 'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*' });
      return res.end(r.body);
    }

    if (p === '/models') {
      const clientKey = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '').trim();
      const r = await groqWithFailover('GET', '/openai/v1/models', clientKey, null, null);
      res.writeHead(r.code, { 'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*' });
      return res.end(r.body);
    }

    if (p === '/transcribe' && req.method === 'POST') {
      const body = await readBody(req);
      const clientKey = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '').trim();
      const r = await groqWithFailover('POST', '/openai/v1/audio/transcriptions', clientKey, body,
        req.headers['content-type'] || 'multipart/form-data');
      res.writeHead(r.code, { 'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*' });
      return res.end(r.body);
    }

    return json(res, 404, { error: { message: 'not found: ' + p } });
  } catch (e) {
    return json(res, 500, { error: { message: String(e && e.message ? e.message : e) } });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('[relay] listening on ' + PORT + ' url=' + (myUrl || '(pending)'));
});

/* ------------------------------------------------------------------ */
/*  lease publisher — keeps relay-lease.json fresh so the app knows    */
/*  where the live backend is                                         */
/* ------------------------------------------------------------------ */
async function publishLease() {
  if (!GITHUB_TOKEN || !GITHUB_REPO || !myUrl) return;
  const lease = {
    url: myUrl,
    ts: Math.floor(Date.now() / 1000),
    expires: Math.floor(Date.now() / 1000) + 300,
    host: 'github-actions',
    service: 'asesstme-relay'
  };
  const content = Buffer.from(JSON.stringify(lease, null, 2)).toString('base64');
  const api = 'https://api.github.com/repos/' + GITHUB_REPO + '/contents/relay-lease.json';

  // read the current sha (if any)
  let sha = null;
  await new Promise((resolve) => {
    https.get(api, { headers: { 'Authorization': 'Bearer ' + GITHUB_TOKEN,
      'User-Agent': 'asesstme-relay', 'Accept': 'application/vnd.github+json' } }, (r) => {
      const c = []; r.on('data', d => c.push(d));
      r.on('end', () => {
        try { const j = JSON.parse(Buffer.concat(c).toString('utf8')); sha = j.sha || null; } catch (e) {}
        resolve();
      });
    }).on('error', () => resolve());
  });

  const payload = JSON.stringify({ message: 'chore: refresh relay lease', content, branch: 'main', sha: sha || undefined });
  await new Promise((resolve) => {
    const req = https.request(api, {
      method: 'PUT',
      headers: { 'Authorization': 'Bearer ' + GITHUB_TOKEN, 'User-Agent': 'asesstme-relay',
        'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
    }, (r) => { r.resume(); r.on('end', resolve); });
    req.on('error', () => resolve());
    req.write(payload);
    req.end();
  });
  console.log('[relay] lease published: ' + myUrl);
}

setInterval(() => {
  // the tunnel may hand us a new url, keep it fresh
  try {
    const u = fs.readFileSync(MY_URL_FILE, 'utf8').trim();
    if (u && u !== myUrl) myUrl = u;
  } catch (e) {}
}, 15000);

setInterval(publishLease, REFRESH_MS);
setTimeout(publishLease, 4000);

process.on('SIGTERM', () => { try { publishLease(); } catch (e) {} process.exit(0); });
process.on('SIGINT', () => { try { publishLease(); } catch (e) {} process.exit(0); });
