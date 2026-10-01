# Taplyne encrypted-frame relay

This standalone Node service carries opaque client-encrypted WebSocket frames between one Mac host and one companion device. It keeps only SHA-256 token hashes and live sockets in memory. Restarting it drops all rooms and requires the host to create a new room. It does not persist or replay messages.

## Wire contract

- `GET /health` returns `{"status":"ok"}`.
- `wss://<domain>/v1/rooms/<room>/host` uses `Authorization: Bearer <host-token>` and `X-Taplyne-Device-Token-SHA256: <sha256-of-device-token>`. A room ID and each raw token are independently generated 32 random bytes encoded as 64 lowercase hex characters. On initial creation, include `X-Taplyne-Enrollment: <enrollment-token>` when configured. Reconnecting the host must present the same host token and device-token hash.
- `wss://<domain>/v1/rooms/<room>/device` uses `Authorization: Bearer <device-token>`. The device may join only a room already created by its host.
- The relay sends each peer JSON **text** notifications `{"type":"peer","connected":true|false}` on connection and counterpart changes. An authenticated role replacement sends the surviving opposite peer `false` then `true` in order so it resets the old encrypted session before a new handshake. The clients use these only to decide when to begin their own encrypted handshake. All client-to-relay messages must be **binary** encrypted frames; a client text message closes with code 1003. The relay does not interpret binary bytes.
- When a peer is absent or its outgoing queue would exceed 16 MiB, the sender closes with 1013. Nothing is queued for a missing peer. An authenticated role reconnect replaces its prior socket (4001 when capacity permits a graceful close, otherwise an immediate termination); the prior socket cannot forward more data. A frame exceeding 8 MiB closes with 1009.

Rooms expire after 24 hours even if active. An empty room is retained for up to 30 minutes for reconnect, within that 24-hour bound. The process also enforces ping/pong liveness, bounded per-IP upgrade and room creation rates, 10,000 rooms, and 20,000 sockets. A room is only in this process's memory, so production needs one relay instance unless a future protocol adds explicit room affinity.

## Local checks

```sh
npm ci
npm run check
npm test
```

`npm`'s official registry reported `ws` 8.22.0 on 2026-10-01; the dependency and lockfile pin that release. For local testing, `npm start` binds `127.0.0.1:8787`. A development process can create rooms without an enrollment token. Any request with a browser `Origin` is denied by default. Set `TAPLYNE_ALLOWED_ORIGINS` to a comma-separated list of exact HTTPS origins only if a specific browser client is intended. Native clients omit Origin.

## TLS deployment

Set `TAPLYNE_DOMAIN` to a DNS name pointed at the host and set a high-entropy `TAPLYNE_ENROLLMENT_TOKEN` in the deployment environment. Then run `docker compose up --build -d` on the server. This command is a deployment action; run it only when authorized. Caddy obtains TLS certificates and is the only public service. Its private network forwards WebSockets to the relay and sets the client IP header for rate limits. Keep port 8787 unpublished. The Caddy data volume holds its certificates. Back up that volume according to the host's normal certificate recovery policy; no relay room data needs a backup.

Outside this compose setup, bind to loopback behind a TLS reverse proxy. Public binding requires `TAPLYNE_PROXY_MODE=1`, and the upstream network must be reachable only by the trusted proxy, which must overwrite `X-Taplyne-Client-IP` with the actual client address. Production startup requires an enrollment token unless `TAPLYNE_ALLOW_ANONYMOUS_ENROLLMENT=1` explicitly enables open room creation. Enrollment limits room creation; each room's two random bearer tokens authorize subsequent connections. Rotate enrollment tokens at deployment boundaries. Existing rooms live only until this process stops or their expiry.
