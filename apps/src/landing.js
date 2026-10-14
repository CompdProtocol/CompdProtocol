(() => {
  const root = document.documentElement;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const state = { stage: 0, scroll: 0, scrollStage: 0 };
  const stages = [...document.querySelectorAll('[data-stage]')];

  // Stage follows the section nearest the viewport centre. Works without GSAP.
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { state.stage = Number(entry.target.dataset.stage); root.dataset.stage = state.stage; }
    }, { rootMargin: '-45% 0px -45% 0px' });
    stages.forEach((section) => observer.observe(section));
  }

  const ready = () => root.classList.add('ready');
  if (reduced) { root.classList.add('no-scene'); ready(); return; }

  // Text is visible by default. GSAP only adds motion once it has loaded.
  if (window.gsap && window.ScrollTrigger) {
    gsap.registerPlugin(ScrollTrigger);
    // Headings rise word by word from a mask (shared helper from compd-page.js).
    document.querySelectorAll('.home-title, .chapter-copy h2').forEach((heading) => window.compdSplitWords(heading));
    const hero = gsap.timeline();
    ready();
    hero.from('.home-title .word > span', { yPercent: 110, duration: 1.1, ease: 'power4.out', stagger: 0.07 })
      .from('.home-label, .home-lead, .home-hero .cta-row', { y: 20, opacity: 0, duration: 0.8, ease: 'power3.out', stagger: 0.1 }, '-=0.6');
    gsap.to('.home-copy', { yPercent: -35, opacity: 0, ease: 'none', scrollTrigger: { trigger: '.home-hero', start: 'top top', end: 'bottom top', scrub: true } });
    document.querySelectorAll('.chapter').forEach((chapter) => {
      const copy = chapter.querySelector('.chapter-copy');
      const tl = gsap.timeline({ scrollTrigger: { trigger: chapter, start: 'top 65%', toggleActions: 'play none none reverse' } });
      tl.from(copy.querySelectorAll('.word > span'), { yPercent: 110, duration: 0.9, ease: 'power4.out', stagger: 0.05 })
        .from(copy.querySelectorAll('small, p, .chapter-link'), { y: 18, opacity: 0, duration: 0.7, ease: 'power3.out', stagger: 0.08 }, '-=0.5');
      // Layered parallax: giant numeral drifts against the scroll, copy drifts with it.
      const numeral = chapter.querySelector('.chapter-num');
      if (numeral) gsap.fromTo(numeral, { yPercent: 40 }, { yPercent: -40, ease: 'none', scrollTrigger: { trigger: chapter, start: 'top bottom', end: 'bottom top', scrub: true } });
      if (!chapter.classList.contains('chapter-end')) gsap.fromTo(copy, { y: 60 }, { y: -60, ease: 'none', scrollTrigger: { trigger: chapter, start: 'top bottom', end: 'bottom top', scrub: true } });
      ScrollTrigger.create({ trigger: chapter, start: 'top bottom', end: 'bottom top', onUpdate: (self) => { if (chapter.dataset.stage == state.stage) state.scrollStage = Math.sin(self.progress * Math.PI); } });
    });
    const rail = document.querySelector('.progress-rail i');
    if (rail) gsap.to(rail, { scaleY: 1, ease: 'none', scrollTrigger: { start: 0, end: 'max', scrub: true } });
    ScrollTrigger.create({ start: 0, end: 'max', onUpdate: (self) => { state.scroll = self.progress; } });
  } else ready();

  // Three.js loads after first paint so text and CTA never wait on it.
  const boot = () => import('./compd-scene.js').then((mod) => {
    const canvas = document.getElementById('scene');
    root.classList.add(canvas && mod.startScene(canvas, state) ? 'scene-on' : 'no-scene');
  }).catch(() => root.classList.add('no-scene'));
  const idle = window.requestIdleCallback || ((fn) => setTimeout(fn, 200));
  if (document.readyState === 'complete') idle(boot);
  else addEventListener('load', () => idle(boot), { once: true });
})();
