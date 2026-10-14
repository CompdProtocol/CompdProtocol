(() => {
  const toggles = [...document.querySelectorAll('.menu-toggle[aria-controls]')];

  function close(toggle, restoreFocus = false) {
    const menu = document.getElementById(toggle.getAttribute('aria-controls'));
    if (!menu) return;
    menu.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', 'Open navigation menu');
    if (restoreFocus) toggle.focus({ preventScroll: true });
  }

  for (const toggle of toggles) {
    const menu = document.getElementById(toggle.getAttribute('aria-controls'));
    if (!menu) continue;
    toggle.addEventListener('click', () => {
      const opening = toggle.getAttribute('aria-expanded') !== 'true';
      menu.hidden = !opening;
      toggle.setAttribute('aria-expanded', String(opening));
      toggle.setAttribute('aria-label', opening ? 'Close navigation menu' : 'Open navigation menu');
      if (opening) menu.querySelector('a')?.focus({ preventScroll: true });
    });
    menu.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => close(toggle)));
    document.addEventListener('pointerdown', (event) => {
      if (!menu.hidden && !menu.contains(event.target) && !toggle.contains(event.target)) close(toggle);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !menu.hidden) close(toggle, true);
    });
  }

  const tocLinks = [...document.querySelectorAll('.docs-toc a[href^="#"]')];
  const sections = tocLinks.map((link) => document.querySelector(link.getAttribute('href'))).filter(Boolean);
  if ('IntersectionObserver' in window && sections.length) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        tocLinks.forEach((link) => {
          const current = link.hash === `#${entry.target.id}`;
          link.classList.toggle('active', current);
          if (current) link.setAttribute('aria-current', 'location');
          else link.removeAttribute('aria-current');
        });
      }
    }, { rootMargin: '-20% 0px -68% 0px' });
    sections.forEach((section) => observer.observe(section));
  }
})();
