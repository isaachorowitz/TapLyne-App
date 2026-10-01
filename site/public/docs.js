// Copy buttons for code blocks, and the agent prompt points at whichever host serves this page.
const prompt = document.querySelector('#agent-prompt');
if (prompt && location.protocol === 'https:') {
  prompt.textContent = prompt.textContent.replace(/https:\/\/[^/\s]+\/setup\.md/, `${location.origin}/setup.md`);
}

for (const button of document.querySelectorAll('.copy')) {
  button.addEventListener('click', async () => {
    const text = button.parentElement.querySelector('code').textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(button.parentElement.querySelector('code'));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      button.textContent = 'Press ⌘C';
    }
    setTimeout(() => { button.textContent = 'Copy'; }, 1600);
  });
}

const links = [...document.querySelectorAll('.docs-toc a')];
const targets = links.map(a => document.getElementById(a.getAttribute('href').slice(1)));
if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const i = targets.indexOf(entry.target);
      links.forEach((a, j) => a.toggleAttribute('aria-current', i === j));
    }
  }, { rootMargin: '-15% 0px -75% 0px' });
  targets.forEach(t => t && io.observe(t));
}
