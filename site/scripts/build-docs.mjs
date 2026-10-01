// Builds public/docs/index.html from public/setup.md so the agent-readable guide
// and the human page never drift. Handles the Markdown subset the guide uses.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../public/', import.meta.url));
const SITE = 'https://taplyne.zippy-host.workers.dev';

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const slug = s => s.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function inline(text) {
  const codes = [];
  let s = text.replace(/`([^`]+)`/g, (_, c) => `\u0000${codes.push(c) - 1}\u0000`);
  s = esc(s)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(https:\/\/[^\s)<]+[^\s).,:;<])/g, url => `<a href="${url}">${url.replace(/^https:\/\//, '')}</a>`)
    .replace(/(^|\s)(\/docs\/)/g, '$1<a href="/docs/">$2</a>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[i])}</code>`);
}

function render(md) {
  const lines = md.split('\n');
  const out = [];
  const toc = [];
  let title = '';
  let list = null;
  let para = [];
  const flushPara = () => { if (para.length) out.push(`<p>${inline(para.join(' '))}</p>`); para = []; };
  const flushList = () => { if (list) out.push(`</${list}>`); list = null; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('```')) {
      flushPara(); flushList();
      const lang = line.slice(3).trim();
      const body = [];
      while (!lines[++i].startsWith('```')) body.push(lines[i]);
      out.push(`<div class="code"><button type="button" class="copy" aria-label="Copy command">Copy</button><pre><code${lang ? ` data-lang="${lang}"` : ''}>${esc(body.join('\n'))}</code></pre></div>`);
      continue;
    }
    const h = /^(#{1,3}) (.*)$/.exec(line);
    if (h) {
      flushPara(); flushList();
      const level = h[1].length;
      if (level === 1) { title = h[2]; continue; }
      const id = slug(h[2]);
      if (level === 2) toc.push({ id, text: h[2] });
      out.push(`<h${level} id="${id}"><a class="anchor" href="#${id}" aria-hidden="true" tabindex="-1">#</a>${inline(h[2])}</h${level}>`);
      continue;
    }
    const li = /^(- |\d+\. )(.*)$/.exec(line);
    if (li) {
      flushPara();
      const kind = li[1] === '- ' ? 'ul' : 'ol';
      if (list !== kind) { flushList(); out.push(`<${kind}>`); list = kind; }
      out.push(`<li>${inline(li[2])}</li>`);
      continue;
    }
    if (!line.trim()) { flushPara(); flushList(); continue; }
    if (line.startsWith('Human-readable version:')) continue;
    if (list) { flushList(); }
    para.push(line.trim());
  }
  flushPara(); flushList();
  return { title, toc, body: out.join('\n') };
}

const md = await readFile(path.join(root, 'setup.md'), 'utf8');
const { title, toc, body } = render(md);
const prompt = `Set up TapLyne on this Mac so you can control my iPhone. Read ${SITE}/setup.md and follow it step by step. Run the commands yourself, tell me when a step needs my hands, and check each step before moving on.`;

const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#05070d">
  <meta name="color-scheme" content="dark">
  <title>Setup guide · TapLyne</title>
  <meta name="description" content="Step-by-step TapLyne setup for people and AI agents: USB and Bluetooth, connecting agents over MCP or REST, voice, remote mode with an encrypted relay, and the companion app.">
  <link rel="alternate" type="text/markdown" href="/setup.md" title="Setup guide (Markdown)">
  <link rel="icon" type="image/png" href="/favicon.png">
  <link rel="preload" href="/fonts/dm-sans.woff2" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="/style.css">
  <link rel="stylesheet" href="/docs.css">
  <script src="/docs.js" defer></script>
</head>
<body class="docs-body">
  <a class="skip-link" href="#doc">Skip to content</a>
  <div class="page docs-page">
    <header class="bar">
      <a class="brand" href="/" aria-label="TapLyne home"><img src="/logo.png" width="28" height="28" alt="">TapLyne</a>
      <nav class="bar-nav" aria-label="Main">
        <a class="bar-link" href="/">Home</a>
        <a class="bar-link" href="/setup.md">Markdown</a>
        <a class="bar-gh" href="https://github.com/isaachorowitz/TapLyne-App" aria-label="TapLyne on GitHub"><span>GitHub</span></a>
      </nav>
    </header>
    <div class="docs-layout">
      <aside class="docs-toc" aria-label="On this page">
        <p class="toc-title">On this page</p>
        <ol>${toc.map(t => `<li><a href="#${t.id}">${esc(t.text)}</a></li>`).join('')}</ol>
      </aside>
      <main id="doc" class="doc">
        <h1>${esc(title)}</h1>
        <section class="agent-box" aria-labelledby="agent-box-h">
          <h2 id="agent-box-h" class="agent-box-h">Let your AI do the setup</h2>
          <p>Paste this into Claude Code, Codex, Cursor or any agent that can run commands on your Mac. It reads the guide and does the work. You only tap the phone when it asks.</p>
          <div class="code"><button type="button" class="copy" aria-label="Copy prompt">Copy</button><pre><code id="agent-prompt">${esc(prompt)}</code></pre></div>
          <p class="fine">Agents can read the plain version at <a href="/setup.md">/setup.md</a>.</p>
        </section>
${body}
      </main>
    </div>
    <footer class="foot">
      <a class="brand" href="/"><img src="/logo.png" width="22" height="22" alt="">TapLyne</a>
      <nav class="foot-nav" aria-label="Footer"><a href="/">Home</a><a href="https://github.com/isaachorowitz/TapLyne-App">GitHub</a><a href="https://github.com/isaachorowitz/TapLyne-App/releases">Releases</a><a href="https://github.com/isaachorowitz/TapLyne-App/blob/main/SECURITY.md">Security</a></nav>
      <p class="fine">AGPL‑3.0. Independent project, not affiliated with Apple.</p>
    </footer>
  </div>
</body>
</html>
`;

await mkdir(path.join(root, 'docs'), { recursive: true });
const target = path.join(root, 'docs/index.html');
if (process.argv.includes('--check')) {
  const current = await readFile(target, 'utf8').catch(() => '');
  if (current !== html) { console.error('docs/index.html is stale: run npm run docs'); process.exit(1); }
} else {
  await writeFile(target, html);
  console.log('Wrote public/docs/index.html');
}
