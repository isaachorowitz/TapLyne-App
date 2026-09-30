const stage = document.querySelector('#stage');
const screen = document.querySelector('#screen');
const pointer = document.querySelector('#pointer');
const ripple = document.querySelector('#ripple');
const ocr = document.querySelector('#ocr');
const scan = document.querySelector('#scan');
const promptEl = document.querySelector('#prompt');
const reply = document.querySelector('#reply');
const note = document.querySelector('#ctl-note');
const pauseBtn = document.querySelector('#ctl-pause');
const takeBtn = document.querySelector('#ctl-take');
const steps = [...document.querySelectorAll('.step')];
const screens = Object.fromEntries([...document.querySelectorAll('[data-screen]')].map(el => [el.dataset.screen, el]));
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const PROMPT = 'Open Settings and show me General.';

let generation = 0;
let visible = true;

class Cancelled extends Error {}

function sleep(ms, gen) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const tick = () => {
      if (gen !== generation) return reject(new Cancelled());
      if (!visible) return setTimeout(tick, 200);
      if (performance.now() - started >= ms) return resolve();
      setTimeout(tick, Math.min(60, ms));
    };
    tick();
  });
}

function show(name) {
  for (const [key, el] of Object.entries(screens)) {
    el.classList.toggle('is-active', key === name);
  }
}

function setStep(n, state, result) {
  const step = steps[n - 1];
  step.dataset.state = state;
  if (result) step.querySelector('.step-res').textContent = result;
}

function rectIn(el) {
  const s = screen.getBoundingClientRect();
  const r = el.getBoundingClientRect();
  return { x: r.left - s.left, y: r.top - s.top, w: r.width, h: r.height, sw: s.width, sh: s.height };
}

function box(el, match) {
  const r = rectIn(el);
  const b = document.createElement('span');
  b.className = 'ocr-box' + (match ? ' is-match' : '');
  const pad = r.sw * 0.012;
  Object.assign(b.style, {
    left: `${((r.x - pad) / r.sw) * 100}%`, top: `${((r.y - pad) / r.sh) * 100}%`,
    width: `${((r.w + pad * 2) / r.sw) * 100}%`, height: `${((r.h + pad * 2) / r.sh) * 100}%`
  });
  ocr.append(b);
  return b;
}

function clearBoxes() {
  for (const b of ocr.children) b.classList.add('is-out');
  setTimeout(() => { for (const b of [...ocr.querySelectorAll('.is-out')]) b.remove(); }, 480);
}

function aimAt(el) {
  const r = rectIn(el);
  const x = ((r.x + r.w / 2) / r.sw) * 100;
  const y = ((r.y + r.h / 2) / r.sh) * 100;
  pointer.style.left = `${x}%`;
  pointer.style.top = `${y}%`;
  return { x, y };
}

async function tap(el, at, gen) {
  pointer.classList.add('is-down');
  ripple.style.left = `${at.x}%`;
  ripple.style.top = `${at.y}%`;
  ripple.classList.remove('is-on');
  void ripple.offsetWidth;
  ripple.classList.add('is-on');
  el.classList.add('is-pressed');
  await sleep(160, gen);
  pointer.classList.remove('is-down');
  await sleep(120, gen);
  el.classList.remove('is-pressed');
}

const frameId = () => 'f_' + Math.random().toString(16).slice(2, 6);

function reset() {
  ocr.replaceChildren();
  pointer.classList.remove('is-on', 'is-down');
  pointer.style.left = '50%';
  pointer.style.top = '62%';
  for (const step of steps) step.dataset.state = 'pending';
  reply.dataset.show = 'false';
  stage.dataset.flow = 'idle';
  show('home');
  promptEl.textContent = '';
}

async function tapLabel(n, target, expectEl, nextScreen, gen) {
  const expect = expectEl.dataset.label;
  setStep(n, 'run');
  stage.dataset.flow = 'bt';
  pointer.classList.add('is-on');
  await sleep(250, gen);
  const at = aimAt(target);
  await sleep(1000, gen);
  await tap(target, at, gen);
  show(nextScreen);
  stage.dataset.flow = 'usb';
  await sleep(700, gen);
  const b = box(expectEl, true);
  await sleep(650, gen);
  setStep(n, 'ok', `verified · “${expect}” on screen`);
  await sleep(500, gen);
  b.classList.add('is-out');
  stage.dataset.flow = 'idle';
}

async function run(gen) {
  reset();
  await sleep(700, gen);
  promptEl.classList.add('typing');
  for (let i = 1; i <= PROMPT.length; i++) {
    promptEl.textContent = PROMPT.slice(0, i);
    await sleep(34, gen);
  }
  promptEl.classList.remove('typing');
  await sleep(450, gen);

  setStep(1, 'run');
  await sleep(650, gen);
  setStep(1, 'ok', 'iPhone · online · unlocked');
  await sleep(350, gen);

  setStep(2, 'run');
  stage.dataset.flow = 'usb';
  scan.classList.remove('is-on');
  void scan.offsetWidth;
  scan.classList.add('is-on');
  const labels = [...screens.home.querySelectorAll('.app-lb, .widget-date')];
  for (const [i, el] of labels.entries()) {
    box(el, el.parentElement.dataset.label === 'Settings');
    await sleep(55 + (i % 3) * 10, gen);
  }
  await sleep(600, gen);
  setStep(2, 'ok', `frame ${frameId()} · ${labels.length} labels`);
  await sleep(500, gen);
  clearBoxes();
  stage.dataset.flow = 'idle';
  await sleep(300, gen);

  await tapLabel(3, document.querySelector('#t-settings'), document.querySelector('#t-general'), 'settings', gen);
  await sleep(350, gen);
  await tapLabel(4, document.querySelector('#t-general'), document.querySelector('#t-about'), 'general', gen);

  pointer.classList.remove('is-on');
  reply.dataset.show = 'true';
  await sleep(4200, gen);
}

async function loop() {
  const gen = ++generation;
  stage.dataset.mode = 'running';
  note.textContent = 'You can stop it any time.';
  pauseBtn.textContent = 'Pause';
  pauseBtn.setAttribute('aria-pressed', 'false');
  takeBtn.setAttribute('aria-pressed', 'false');
  try {
    while (gen === generation) await run(gen);
  } catch (error) {
    if (!(error instanceof Cancelled)) throw error;
  }
}

function halt(message, pressed) {
  generation++;
  stage.dataset.mode = 'paused';
  stage.dataset.flow = 'idle';
  pointer.classList.remove('is-down');
  for (const step of steps) if (step.dataset.state === 'run') step.dataset.state = 'pending';
  note.textContent = message;
  pauseBtn.textContent = 'Resume';
  pauseBtn.setAttribute('aria-pressed', String(pressed === pauseBtn));
  takeBtn.setAttribute('aria-pressed', String(pressed === takeBtn));
}

pauseBtn.addEventListener('click', () => {
  if (stage.dataset.mode === 'paused') loop();
  else halt('Paused. Queued input was cancelled.', pauseBtn);
});
takeBtn.addEventListener('click', () => {
  if (stage.dataset.mode === 'paused' && takeBtn.getAttribute('aria-pressed') === 'true') return loop();
  halt('You have the phone. The agent waits for you.', takeBtn);
  pointer.classList.remove('is-on');
});

document.addEventListener('visibilitychange', () => { visible = !document.hidden; });
new IntersectionObserver(([entry]) => { visible = entry.isIntersecting && !document.hidden; }).observe(stage);

// Parallax: the phone tilts slightly toward the cursor.
const frame = document.querySelector('.phone-frame');
const fine = matchMedia('(pointer: fine)');
let raf = 0;
window.addEventListener('pointermove', event => {
  if (reduced.matches || !fine.matches || raf) return;
  raf = requestAnimationFrame(() => {
    raf = 0;
    const nx = event.clientX / innerWidth - 0.5;
    const ny = event.clientY / innerHeight - 0.5;
    frame.style.setProperty('--ry', `${-9 + nx * 8}deg`);
    frame.style.setProperty('--rx', `${3 - ny * 5}deg`);
  });
}, { passive: true });

if (!reduced.matches) loop();
