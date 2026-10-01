import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { test } from 'node:test';
import { WebSocket } from 'ws';
import { createRelayServer } from '../src/server.mjs';

const room = 'a'.repeat(64);
const secondRoom = 'b'.repeat(64);
const hostToken = '1'.repeat(64);
const deviceToken = '2'.repeat(64);
const otherToken = '3'.repeat(64);
const deviceHash = createHash('sha256').update(deviceToken).digest('hex');
const hash = value => createHash('sha256').update(value).digest('hex');

async function fixture(t, options = {}) {
  const app = createRelayServer({ port: 0, ...options });
  const address = await app.listen();
  t.after(() => app.close());
  return `ws://127.0.0.1:${address.port}`;
}

function path(id, role) { return `/v1/rooms/${id}/${role}`; }
function headers(token, extras = {}) { return { Authorization: `Bearer ${token}`, ...extras }; }
function hostHeaders(token = hostToken, extra = {}) {
  return headers(token, { 'X-Taplyne-Device-Token-SHA256': deviceHash, ...extra });
}

async function connect(base, roomPath, authHeaders) {
  const socket = new WebSocket(base + roomPath, { headers: authHeaders, perMessageDeflate: false });
  const messages = [];
  const waiters = [];
  socket.on('message', (data, binary) => {
    const message = { data, binary };
    if (waiters.length) waiters.shift()(message);
    else messages.push(message);
  });
  await once(socket, 'open');
  return {
    socket,
    read() {
      if (messages.length) return Promise.resolve(messages.shift());
      return Promise.race([
        new Promise(resolve => waiters.push(resolve)),
        new Promise((_, reject) => setTimeout(() => reject(new Error('No message')), 1000)),
      ]);
    },
  };
}

async function rejected(base, roomPath, authHeaders, expected) {
  const ws = new WebSocket(base + roomPath, { headers: authHeaders });
  const status = await new Promise((resolve, reject) => {
    ws.on('unexpected-response', (_, response) => { response.resume(); resolve(response.statusCode); });
    ws.on('open', () => reject(new Error('Unexpected upgrade')));
    ws.on('error', error => reject(error));
  });
  assert.equal(status, expected);
  ws.terminate();
}

async function closeCode(socket) {
  return new Promise(resolve => socket.once('close', code => resolve(code)));
}

async function status(peer, connected) {
  const message = await peer.read();
  assert.equal(message.binary, false);
  assert.deepEqual(JSON.parse(message.data.toString()), { type: 'peer', connected });
}

test('authenticates each role and forwards only opaque binary frames', async t => {
  const base = await fixture(t);
  await rejected(base, path(room, 'device'), headers(deviceToken), 401);
  await rejected(base, path(room, 'host'), hostHeaders(otherToken, { Origin: 'https://evil.example' }), 403);
  const host = await connect(base, path(room, 'host'), hostHeaders());
  await status(host, false);
  await rejected(base, path(room, 'device'), headers(otherToken), 401);
  await rejected(base, path(room, 'host'), hostHeaders(otherToken), 401);
  await rejected(base, path(room, 'host'), headers(deviceToken, { 'X-Taplyne-Device-Token-SHA256': deviceHash }), 401);
  await rejected(base, path(room, 'host'), hostHeaders(hostToken, { 'X-Taplyne-Device-Token-SHA256': hash(otherToken) }), 401);
  const device = await connect(base, path(room, 'device'), headers(deviceToken));
  await status(device, true);
  await status(host, true);
  const encrypted = Buffer.from([0, 255, 1, 33, 0]);
  host.socket.send(encrypted);
  assert.deepEqual((await device.read()).data, encrypted);
  device.socket.send(encrypted);
  assert.deepEqual((await host.read()).data, encrypted);
  device.socket.send('plaintext');
  assert.equal(await closeCode(device.socket), 1003);
  await status(host, false);
  host.socket.send(encrypted);
  assert.equal(await closeCode(host.socket), 1013);
});

test('rejects oversized frames and fences replaced sockets', async t => {
  const base = await fixture(t);
  const first = await connect(base, path(room, 'host'), hostHeaders());
  await status(first, false);
  const device = await connect(base, path(room, 'device'), headers(deviceToken));
  await status(device, true);
  await status(first, true);
  const oldClose = closeCode(first.socket);
  const replacement = await connect(base, path(room, 'host'), hostHeaders());
  await status(replacement, true);
  await status(device, false);
  await status(device, true);
  assert.equal(await oldClose, 4001);
  if (first.socket.readyState === WebSocket.OPEN) first.socket.send(Buffer.from('stale'));
  replacement.socket.send(Buffer.from('fresh'));
  assert.deepEqual((await device.read()).data, Buffer.from('fresh'));
  const oldDeviceClose = closeCode(device.socket);
  const newDevice = await connect(base, path(room, 'device'), headers(deviceToken));
  await status(newDevice, true);
  await status(replacement, false);
  await status(replacement, true);
  assert.equal(await oldDeviceClose, 4001);
  replacement.socket.send(Buffer.alloc(8 * 1024 * 1024 + 1));
  assert.equal(await closeCode(replacement.socket), 1009);
  await status(newDevice, false);
});

test('enrollment, room cap, rate cap, and restart lose room state', async t => {
  const base = await fixture(t, {
    enrollmentToken: 'e'.repeat(64), maxRooms: 1,
    upgradesPerMinute: 8, creationsPerMinute: 1,
  });
  await rejected(base, path(room, 'host'), hostHeaders(), 401);
  const enrolled = hostHeaders(hostToken, { 'X-Taplyne-Enrollment': 'e'.repeat(64) });
  const host = await connect(base, path(room, 'host'), enrolled);
  await status(host, false);
  await rejected(base, path(secondRoom, 'host'), enrolled, 503);
  const device = await connect(base, path(room, 'device'), headers(deviceToken));
  await status(device, true);
  await status(host, true);
  const app2 = createRelayServer({ port: 0 });
  const address2 = await app2.listen();
  t.after(() => app2.close());
  await rejected(`ws://127.0.0.1:${address2.port}`, path(room, 'device'), headers(deviceToken), 401);
});

test('rate, connection, and lifetime bounds are enforced', async t => {
  const base = await fixture(t, {
    upgradesPerMinute: 2, creationsPerMinute: 1, maxConnections: 1,
  });
  const host = await connect(base, path(room, 'host'), hostHeaders());
  await status(host, false);
  await rejected(base, path(room, 'device'), headers(deviceToken), 503);
  await rejected(base, path(room, 'device'), headers(deviceToken), 429);
  const shortBase = await fixture(t, { maxAgeMs: 25, pingIntervalMs: 10, pongTimeoutMs: 1000 });
  const shortHost = await connect(shortBase, path(room, 'host'), hostHeaders());
  await status(shortHost, false);
  assert.equal(await closeCode(shortHost.socket), 1001);
  await rejected(shortBase, path(room, 'device'), headers(deviceToken), 401);
});

test('empty room retention and room creation rate are bounded', async t => {
  const base = await fixture(t, { retentionMs: 25, pingIntervalMs: 10, creationsPerMinute: 1 });
  const host = await connect(base, path(room, 'host'), hostHeaders());
  await status(host, false);
  const closed = closeCode(host.socket);
  host.socket.close();
  await closed;
  await new Promise(resolve => setTimeout(resolve, 50));
  await rejected(base, path(room, 'device'), headers(deviceToken), 401);
  await rejected(base, path(secondRoom, 'host'), hostHeaders(), 429);
});

test('allows only configured browser Origin and does not allocate on failed authentication', async t => {
  const base = await fixture(t, { maxRooms: 1, allowedOrigins: ['https://app.example'] });
  await rejected(base, path(room, 'host'), hostHeaders(hostToken, { Origin: 'https://other.example' }), 403);
  await rejected(base, path(room, 'host'), headers(hostToken), 401);
  const host = await connect(base, path(secondRoom, 'host'), hostHeaders(hostToken, { Origin: 'https://app.example' }));
  await status(host, false);
});

test('replacement remains available at the global connection limit', async t => {
  const base = await fixture(t, { maxConnections: 1 });
  const original = await connect(base, path(room, 'host'), hostHeaders());
  await status(original, false);
  const oldClosed = closeCode(original.socket);
  const replacement = await connect(base, path(room, 'host'), hostHeaders());
  await status(replacement, false);
  assert.equal(await oldClosed, 1006);
  await rejected(base, path(room, 'device'), headers(deviceToken), 503);
});

test('shutdown drops live peers and a new process has no room', async t => {
  const app = createRelayServer({ port: 0 });
  const address = await app.listen();
  const base = `ws://127.0.0.1:${address.port}`;
  const host = await connect(base, path(room, 'host'), hostHeaders());
  await status(host, false);
  const device = await connect(base, path(room, 'device'), headers(deviceToken));
  await status(device, true);
  await status(host, true);
  const hostClosed = closeCode(host.socket);
  const deviceClosed = closeCode(device.socket);
  await app.close();
  assert.equal(await hostClosed, 1006);
  assert.equal(await deviceClosed, 1006);
  const nextBase = await fixture(t);
  await rejected(nextBase, path(room, 'device'), headers(deviceToken), 401);
});

test('startup rejects insecure public bind and unconfigured production enrollment', () => {
  assert.throws(() => createRelayServer({ host: '0.0.0.0' }), /Public bind/);
  assert.throws(() => createRelayServer({ production: true }), /enrollment/);
  assert.throws(() => createRelayServer({ allowedOrigins: ['*'] }), /origins/);
});
