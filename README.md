# ASESSTME — 24/7 Backend Relay

**Owner:** @dvc | **Builder:** promode

Free, always-on backend for the **AsesstMe** Android voice assistant.
Runs on **GitHub Actions** (public repo = unlimited free minutes) and
exposes itself through a **free SSH reverse tunnel** — no Cloudflare, no
ngrok, no paid service.

```
Android app ──https──▶ SSH tunnel (localhost.run / serveo / bore)
                          │
                          ▼
                    relay.js  (Node, :8080)
                          │
                          ▼
                    api.groq.com/openai/v1
```

## Endpoints

| Method | Path           | Purpose                                     |
|:--|:--|:--|
| GET  | `/health`      | liveness, uptime, key-pool size             |
| POST | `/chat`        | Groq chat completion (OpenAI-compatible)    |
| GET  | `/models`      | Groq model list                             |
| POST | `/transcribe`  | Groq whisper transcription (multipart)      |

## How the app finds the backend

The relay publishes its live public URL into **`relay-lease.json`** in this
repo (via the GitHub contents API, every 90 s). The Android app reads:

```
https://raw.githubusercontent.com/bayutko692-prog/asesstme-backend/main/relay-lease.json
```

No hard-coded host. When the tunnel restarts, the app simply picks up the
new URL. A `?t=<timestamp>` query is appended by the app to defeat
`raw.githubusercontent.com` caching.

## Key failover

`relay.js` sends the client's `Authorization` header first. If Groq rejects
it (401/403) the relay retries with the keys in `GROQ_KEY_POOL`
(repo secret). A dead client key therefore does not kill the backend.

## The watchdog

`.github/workflows/relay.yml` runs every 5 minutes. It reads the lease
file; if the recorded URL still answers `/health` the job does nothing
(the previous instance keeps serving). If the backend is dead it opens a
fresh tunnel, starts the relay and republishes the lease.

## Secrets

| Secret            | Meaning                                   |
|:--|:--|
| `GROQ_KEY_POOL`   | comma-separated Groq keys used for failover |

`GITHUB_TOKEN` is provided automatically by Actions and needs the
`contents: write` permission (already declared in the workflow).
