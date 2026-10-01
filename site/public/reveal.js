// Sticky bar shadow and scroll-in reveal for the long page sections.
const bar = document.querySelector('.bar');
const onScroll = () => bar.classList.toggle('is-stuck', scrollY > 8);
addEventListener('scroll', onScroll, { passive: true });
onScroll();

if (!matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
  const targets = document.querySelectorAll('.sec-head, .big-statement, .analogy-item, .card, .g, .split-copy, .split-art, .pv, .uses, .faq, .callout, .setup-list li');
  const io = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-in');
      setTimeout(() => { entry.target.style.transitionDelay = ''; }, 1200);
      io.unobserve(entry.target);
    }
  }, { rootMargin: '0px 0px -8% 0px' });
  targets.forEach((el, i) => {
    el.dataset.reveal = '';
    el.style.transitionDelay = `${(i % 4) * 70}ms`;
    io.observe(el);
  });
  document.documentElement.classList.add('reveal-on');
}
