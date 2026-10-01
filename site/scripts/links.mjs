// Fetches every external link on the site and in setup.md. Run with network access: npm run links
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../public/', import.meta.url));
const files = ['index.html', 'docs/index.html', 'setup.md'];
const urls = new Set();
for (const file of files) {
  const text = await readFile(path.join(root, file), 'utf8');
  for (const m of text.matchAll(/https:\/\/[^\s"'<>)`]+[^\s"'<>).,:;`]/g)) urls.add(m[0].replace(/&amp;/g, '&'));
}
const skip = u => /example\.com|127\.0\.0\.1|zippy-host\.workers\.dev\/setup\.md/.test(u);
let failed = 0;
for (const url of [...urls].filter(u => !skip(u)).sort()) {
  let status;
  try {
    const res = await fetch(url, { method: 'GET', redirect: 'follow', headers: { 'user-agent': 'taplyne-link-check' } });
    status = res.status;
    if (res.redirected) status += ` -> ${res.url}`;
  } catch (e) { status = e.cause?.code || e.message; }
  const ok = /^2\d\d/.test(String(status));
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${status}  ${url}`);
}
process.exit(failed ? 1 : 0);
