// Shared motion for content pages: word-by-word heading rise, section fade-in,
// and an optional intro particle scene (body[data-scene] names the Chapter layout).
(() => {
  const root = document.documentElement;
  const ready = () => root.classList.add('ready');

  // Wraps each word of a heading in a mask so it can rise into view. Screen readers get the original text.
  window.compdSplitWords = (heading) => {
    heading.setAttribute('aria-label', heading.textContent.replace(/\s+/g, ' ').trim());
    const walk = (node) => [...node.childNodes].forEach((child) => {
      if (child.nodeType === 3) {
        const frag = document.createDocumentFragment();
        child.textContent.split(/(\s+)/).forEach((part) => {
          if (!part.trim()) { frag.append(part); return; }
          const mask = document.createElement('span'); mask.className = 'word'; mask.setAttribute('aria-hidden', 'true');
          const inner = document.createElement('span'); inner.textContent = part; mask.append(inner); frag.append(mask);
        });
        child.replaceWith(frag);
      } else walk(child);
    });
    walk(heading);
    return heading.querySelectorAll('.word > span');
  };

  const intro = document.querySelector('.page-intro');
  if (!intro) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduced || !window.gsap || !window.ScrollTrigger) { ready(); if (reduced) root.classList.add('no-scene'); return; }

  gsap.registerPlugin(ScrollTrigger);
  const words = window.compdSplitWords(intro.querySelector('h1'));
  ready();
  gsap.timeline()
    .from(words, { yPercent: 110, duration: 1, ease: 'power4.out', stagger: 0.06 })
    .from(intro.querySelectorAll('.eyebrow, .page-intro-copy > p:not(.eyebrow), .intro-aside'), { y: 18, opacity: 0, duration: 0.7, ease: 'power3.out', stagger: 0.08 }, '-=0.6');
  document.querySelectorAll('main section:not(.page-intro)').forEach((section) => {
    gsap.from(section, { y: 32, opacity: 0, duration: 0.8, ease: 'power3.out', scrollTrigger: { trigger: section, start: 'top 85%', once: true } });
  });

  const layout = document.body.dataset.scene;
  const canvas = document.getElementById('scene');
  if (!layout || !canvas) return;
  // Particles fade out as the intro scrolls away, so cards and tables stay clean.
  const state = { stage: 0, visible: 1, scroll: 0.5 };
  ScrollTrigger.create({ trigger: intro, start: 'top top', end: 'bottom top', onUpdate: (self) => { state.visible = 1 - self.progress; } });
  const boot = () => import('./compd-scene.js').then((mod) => {
    state.stage = mod.layoutIds[layout] ?? 0;
    root.classList.add(mod.startScene(canvas, state, { placement: 'intro' }) ? 'scene-on' : 'no-scene');
  }).catch(() => root.classList.add('no-scene'));
  const idle = window.requestIdleCallback || ((fn) => setTimeout(fn, 200));
  if (document.readyState === 'complete') idle(boot);
  else addEventListener('load', () => idle(boot), { once: true });
})();
