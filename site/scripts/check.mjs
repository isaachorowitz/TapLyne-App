import { readFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../public/', import.meta.url));
const pages = { '/': 'index.html', '/docs/': 'docs/index.html' };
const read = file => readFile(path.join(root, file), 'utf8');
const idsOf = html => [...html.matchAll(/\bid="([^"]+)"/g)].map(x => x[1]);
const htmlByPath = {};
for (const [route, file] of Object.entries(pages)) htmlByPath[route] = await read(file);

for (const [route, html] of Object.entries(htmlByPath)) {
  assert(html.includes('<html lang="en">'), `${route}: missing lang`);
  assert.equal((html.match(/<h1\b/g) || []).length, 1, `${route}: needs exactly one h1`);
  const ids = idsOf(html);
  assert.equal(new Set(ids).size, ids.length, `${route}: duplicate HTML IDs`);
  assert(!/<script>|\son[a-z]+="/.test(html), `${route}: inline script or handler breaks the CSP`);
  assert(!html.includes('taplyne-mac'), `${route}: old repository name`);
  for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const ref = match[1];
    if (ref.startsWith('#') && ref.length > 1) assert(ids.includes(ref.slice(1)), `${route}: missing anchor ${ref}`);
    if (!ref.startsWith('/')) continue;
    const [target, hash] = ref.split('#');
    if (pages[target]) {
      if (hash) assert(idsOf(htmlByPath[target]).includes(hash), `${route}: missing anchor ${ref}`);
      continue;
    }
    await access(path.join(root, target.slice(1)));
  }
}

const html = htmlByPath['/'];
assert.equal((html.match(/releases\/download\/v0\.3\.0\/Taplyne\.dmg/g) || []).length, 1);
const repository = 'https://github.com/isaachorowitz/TapLyne-App';
assert(html.includes(`href="${repository}"`), 'Missing canonical GitHub link');
assert(html.includes(`href="${repository}/blob/main/docs/GETTING-STARTED.md"`), 'Missing setup guide');
assert(html.includes(`href="${repository}/releases/download/v0.3.0/Taplyne.dmg"`), 'Download must use the public repository');
assert(html.includes('Version 0.3.0.'), 'Missing current release version');
assert(!/arrive[^<]*next download|unplug it and walk away|never submits forms|never presses Submit/i.test(html), 'Outdated availability or safety claim');
assert(html.includes('href="/docs/"'), 'Missing link to the setup guide page');
assert(html.includes('Illustrated demo'));
assert(html.includes('class="scr scr-list is-active"'), 'No static end state for reduced motion or no JavaScript');
const css = await read('style.css');
for (const match of css.matchAll(/url\(['"]?(\/[^)'"\s]+)['"]?\)/g)) await access(path.join(root, match[1].slice(1)));
assert(css.includes('prefers-reduced-motion'));
await access(path.join(root, 'fonts/DM-Sans-OFL.txt'));
await access(path.join(root, 'setup.md'));
console.log('PASS: pages, asset paths, cross-page anchors, fonts, single heading, download link and reduced-motion styling');
