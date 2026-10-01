import { createHash, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { WebSocket, WebSocketServer } from 'ws';

const HEX = /^[a-f0-9]{64}$/;
const ROOM_PATH = /^\/v1\/rooms\/([a-f0-9]{64})\/(host|device)$/;
const MAX_FRAME = 8 * 1024 * 1024;
const BACKPRESSURE = 16 * 1024 * 1024;
const WINDOW_MS = 60_000;
const MAX_AGE_MS = 24 * 60 * 60_000;
const RETENTION_MS = 30 * 60_000;

function sha256(value) {
  return createHash('sha256').update(value).digest();
}

function equalHash(a, b) {
  return timingSafeEqual(a, b);
}

function singleHeader(request, name) {
  const matches = request.rawHeaders.filter((_, i) => i % 2 === 0 && request.rawHeaders[i].toLowerCase() === name);
  if (matches.length !== 1) return null;
  const value = request.headers[name];
  return typeof value === 'string' ? value : null;
}

function refuse(socket, code) {
  if (!socket.destroyed) socket.end(`HTTP/1.1 ${code} ${code === 429 ? 'Too Many Requests' : 'Rejected'}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

function peerStatus(socket, connected) {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'peer', connected }), { binary: false }, () => {});
  }
}

export function createRelayServer(options = {}) {
  const config = {
    host: options.host ?? '127.0.0.1',
    port: options.port ?? 8787,
    proxyMode: options.proxyMode ?? false,
    production: options.production ?? false,
    enrollmentToken: options.enrollmentToken ?? '',
    allowAnonymousEnrollment: options.allowAnonymousEnrollment ?? false,
    allowedOrigins: options.allowedOrigins ?? [],
    maxRooms: options.maxRooms ?? 10_000,
    maxConnections: options.maxConnections ?? 20_000,
    maxRateIPs: options.maxRateIPs ?? 20_000,
    upgradesPerMinute: options.upgradesPerMinute ?? 120,
    creationsPerMinute: options.creationsPerMinute ?? 12,
    pingIntervalMs: options.pingIntervalMs ?? 30_000,
    pongTimeoutMs: options.pongTimeoutMs ?? 90_000,
    maxAgeMs: options.maxAgeMs ?? MAX_AGE_MS,
    retentionMs: options.retentionMs ?? RETENTION_MS,
  };
  if (!['127.0.0.1', '::1', 'localhost'].includes(config.host) && !config.proxyMode) {
    throw new Error('Public bind requires TAPLYNE_PROXY_MODE=1 and a TLS reverse proxy');
  }
  if (config.production && !config.enrollmentToken && !config.allowAnonymousEnrollment) {
    throw new Error('Production requires TAPLYNE_ENROLLMENT_TOKEN or explicit anonymous enrollment opt-in');
  }
  if (config.enrollmentToken && config.enrollmentToken.length < 32) {
    throw new Error('TAPLYNE_ENROLLMENT_TOKEN must have at least 32 characters');
  }
  if (!Array.isArray(config.allowedOrigins) || config.allowedOrigins.some(origin => {
    try {
      const parsed = new URL(origin);
      return !['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin;
    } catch { return true; }
  })) throw new Error('Allowed origins must be exact http(s) origins');
  for (const name of ['maxRooms', 'maxConnections', 'maxRateIPs', 'upgradesPerMinute',
    'creationsPerMinute', 'pingIntervalMs', 'pongTimeoutMs', 'maxAgeMs', 'retentionMs']) {
    if (!Number.isSafeInteger(config[name]) || config[name] < 1) throw new Error(`Invalid ${name}`);
  }
  if (!Number.isSafeInteger(config.port) || config.port < 0 || config.port > 65535) throw new Error('Invalid port');

  const rooms = new Map();
  const rates = new Map();
  const sockets = new Set();
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME, perMessageDeflate: false, clientTracking: false });
  const server = createServer((request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end('{"status":"ok"}');
    } else {
      response.writeHead(404, { 'content-length': '0' });
      response.end();
    }
  });

  function expired(room, now) {
    return now - room.created >= config.maxAgeMs ||
      (room.emptySince !== null && now - room.emptySince >= config.retentionMs);
  }

  function removeRoom(id, room) {
    if (rooms.get(id) !== room) return;
    rooms.delete(id);
    for (const role of ['host', 'device']) room[role]?.close(1001, 'Room expired');
  }

  function rate(ip, field, limit, now) {
    let record = rates.get(ip);
    if (!record) {
      if (rates.size >= config.maxRateIPs) return false;
      record = { start: now, upgrades: 0, creations: 0 };
      rates.set(ip, record);
    }
    if (now - record.start >= WINDOW_MS) {
      record.start = now;
      record.upgrades = 0;
      record.creations = 0;
    }
    record[field] += 1;
    return record[field] <= limit;
  }

  server.on('upgrade', (request, socket, head) => {
    const now = Date.now();
    const proxied = config.proxyMode ? singleHeader(request, 'x-taplyne-client-ip') : null;
    const ip = proxied && isIP(proxied) ? proxied : request.socket.remoteAddress ?? 'unknown';
    if (!rate(ip, 'upgrades', config.upgradesPerMinute, now)) return refuse(socket, 429);
    const match = ROOM_PATH.exec(request.url ?? '');
    if (!match || request.method !== 'GET') return refuse(socket, 404);
    const [, id, role] = match;
    const origin = request.headers.origin;
    if (origin !== undefined && (typeof origin !== 'string' || !config.allowedOrigins.includes(origin))) return refuse(socket, 403);
    const authorization = singleHeader(request, 'authorization');
    const bearer = authorization && /^Bearer ([a-f0-9]{64})$/.exec(authorization);
    if (!bearer) return refuse(socket, 401);
    let room = rooms.get(id);
    if (room && expired(room, now)) {
      removeRoom(id, room);
      room = undefined;
    }
    if (!room && role !== 'host') return refuse(socket, 401);
    if (!room && rooms.size >= config.maxRooms) return refuse(socket, 503);
    if (sockets.size >= config.maxConnections && !room?.[role]) return refuse(socket, 503);
    let created = false;
    if (role === 'host') {
      const deviceHash = singleHeader(request, 'x-taplyne-device-token-sha256');
      if (!deviceHash || !HEX.test(deviceHash)) return refuse(socket, 401);
      if (room) {
        if (!equalHash(room.hostHash, sha256(bearer[1])) || !equalHash(room.deviceHash, Buffer.from(deviceHash, 'hex'))) return refuse(socket, 401);
      } else {
        if (config.enrollmentToken) {
          const enrollment = singleHeader(request, 'x-taplyne-enrollment');
          if (!enrollment || !equalHash(sha256(enrollment), sha256(config.enrollmentToken))) return refuse(socket, 401);
        }
        if (!rate(ip, 'creations', config.creationsPerMinute, now)) return refuse(socket, 429);
        room = { hostHash: sha256(bearer[1]), deviceHash: Buffer.from(deviceHash, 'hex'),
          created: now, emptySince: now, host: null, device: null };
        created = true;
      }
    } else if (!equalHash(room.deviceHash, sha256(bearer[1]))) return refuse(socket, 401);

    wss.handleUpgrade(request, socket, head, ws => {
      if (created) rooms.set(id, room);
      const old = room[role];
      room[role] = ws;
      room.emptySince = null;
      if (old) {
        const atCapacity = sockets.size >= config.maxConnections;
        if (atCapacity) {
          sockets.delete(old);
          old.terminate();
        } else old.close(4001, 'Replaced');
      }
      sockets.add(ws);
      const opposite = role === 'host' ? 'device' : 'host';
      if (old) peerStatus(room[opposite], false);
      peerStatus(ws, !!room[opposite] && room[opposite].readyState === WebSocket.OPEN);
      peerStatus(room[opposite], true);
      ws.lastPong = Date.now();
      ws.on('pong', () => { ws.lastPong = Date.now(); });
      ws.on('message', (frame, binary) => {
        if (room[role] !== ws || rooms.get(id) !== room || ws.readyState !== WebSocket.OPEN) return;
        if (!binary) return ws.close(1003, 'Binary frames required');
        const peer = room[opposite];
        if (!peer || peer.readyState !== WebSocket.OPEN || peer.bufferedAmount + frame.length > BACKPRESSURE) {
          return ws.close(1013, 'Peer unavailable');
        }
        peer.send(frame, { binary: true, compress: false }, error => {
          if (error && room[role] === ws) ws.close(1013, 'Peer unavailable');
        });
      });
      ws.on('close', () => {
        sockets.delete(ws);
        if (room[role] !== ws) return;
        room[role] = null;
        if (!room.host && !room.device) room.emptySince = Date.now();
        peerStatus(room[opposite], false);
      });
      ws.on('error', () => {});
    });
  });

  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [id, room] of rooms) if (expired(room, now)) removeRoom(id, room);
    for (const [ip, record] of rates) if (now - record.start >= WINDOW_MS) rates.delete(ip);
    for (const ws of sockets) {
      if (now - ws.lastPong >= config.pongTimeoutMs) ws.terminate();
      else if (ws.readyState === WebSocket.OPEN) ws.ping();
    }
  }, config.pingIntervalMs);
  sweep.unref();

  return {
    server,
    async listen() {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(config.port, config.host, () => { server.off('error', reject); resolve(); });
      });
      return server.address();
    },
    async close() {
      clearInterval(sweep);
      for (const ws of sockets) ws.terminate();
      await new Promise(resolve => server.close(resolve));
      wss.close();
    },
  };
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const app = createRelayServer({
    host: process.env.TAPLYNE_HOST ?? '127.0.0.1',
    port: Number(process.env.TAPLYNE_PORT ?? 8787),
    proxyMode: process.env.TAPLYNE_PROXY_MODE === '1',
    production: process.env.NODE_ENV === 'production',
    enrollmentToken: process.env.TAPLYNE_ENROLLMENT_TOKEN ?? '',
    allowAnonymousEnrollment: process.env.TAPLYNE_ALLOW_ANONYMOUS_ENROLLMENT === '1',
    allowedOrigins: (process.env.TAPLYNE_ALLOWED_ORIGINS ?? '').split(',').filter(Boolean),
  });
  app.listen().then(address => {
    process.stdout.write(`Taplyne relay listening on ${address.address}:${address.port}\n`);
  }).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
    app.close().then(() => { process.exitCode = 0; });
  });
}
