import { readFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../public/', import.meta.url));
const html = await readFile(path.join(root, 'index.html'), 'utf8');
assert(html.includes('<html lang="en">'));
assert.equal((html.match(/<h1\b/g) || []).length, 1);
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(x => x[1]);
assert.equal(new Set(ids).size, ids.length, 'Duplicate HTML IDs');
for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
  const ref = match[1];
  if (ref.startsWith('#') && ref.length > 1) assert(ids.includes(ref.slice(1)), `Missing anchor ${ref}`);
  if (ref.startsWith('/')) await access(path.join(root, ref.slice(1)));
}
assert.equal((html.match(/releases\/latest\/download\/Taplyne\.dmg/g) || []).length, 3);
const css = await readFile(path.join(root, 'style.css'), 'utf8');
for (const match of css.matchAll(/url\(['"]?(\/[^)'"\s]+)['"]?\)/g)) await access(path.join(root, match[1].slice(1)));
assert(css.includes('prefers-reduced-motion'));
assert(html.includes('Illustrated demo'));
await access(path.join(root, 'fonts/DM-Sans-OFL.txt'));
await access(path.join(root, 'fonts/Instrument-Serif-OFL.txt'));
console.log('PASS: asset paths, fonts, anchors, single heading, download links and reduced-motion styling');
