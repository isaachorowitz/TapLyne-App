import { createRelayServer } from '../src/server.mjs';
import { spawn } from 'node:child_process';
const server = createRelayServer({ port: 0 });
const address = await server.listen();
let child;
try {
  child = spawn(process.argv[2], [], { stdio: 'inherit', env: { ...process.env, TAPLYNE_RELAY_TEST_URL: `ws://127.0.0.1:${address.port}` } });
  const timer = setTimeout(() => child.kill('SIGTERM'), 45000);
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  clearTimeout(timer);
  if (code !== 0) process.exitCode = 1;
} finally { if (child && child.exitCode === null) child.kill('SIGTERM'); await server.close(); }
