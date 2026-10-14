// Flow diagrams: one tab per flow, drawn as cards joined by sankey bands.
// Band thickness follows each Allocation; each Flow dot is 1% of the flow shown (never a token or amount).
(() => {
  const panels = [...document.querySelectorAll('[data-flow-panel]')];
  if (!panels.length) return;
  const SVG = 'http://www.w3.org/2000/svg';
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let portrait = innerWidth < 760;

  // Geometry is authored in landscape units: x runs along the flow (0–1000), y across it (0–560).
  // Portrait swaps the axes so the same diagram reads top to bottom.
  const W = 1000, H = 560, CARD_SPAN = 170, CARD_THICK = 66;
  const flows = {
    revenue: {
      cards: [
        { id: 'src', x: 105, y: 280, index: '01 / SOURCE', label: 'Flap revenue', detail: 'Protocol revenue only: Flap tax proceeds enter through a single path.', links: ['t1'] },
        { id: 'rcv', x: 385, y: 280, index: '02 / INTAKE', label: 'Native BNB Fee Receiver', detail: 'Receives the Flap allocation, then forwards it to the V3 Vault Kernel.', links: ['t1', 't2'] },
        { id: 'vault', x: 645, y: 280, index: '03 / ACCOUNTING', label: 'V3 Vault Kernel', detail: 'One custody boundary that accounts Strategy Capital, Buyback Reserve and Protocol Reserve separately.', links: ['t2', 'b1', 'b2', 'b3'] },
        { id: 'sc', x: 915, y: 120, label: 'Strategy Capital', share: 35, detail: 'Guarded strategy use. Receives 35 of every 100 parts of protocol revenue.', links: ['b1'] },
        { id: 'bb', x: 915, y: 280, label: 'Buyback Reserve', share: 15, detail: 'Funds only guarded buybacks. Receives 15 of every 100 parts of protocol revenue.', links: ['b2'] },
        { id: 'pr', x: 915, y: 440, label: 'Protocol Reserve', share: 50, detail: 'Protocol-owned operating capital, separately accounted. Receives 50 of every 100 parts.', links: ['b3'] },
      ],
      // A trunk carries every branch; each branch keeps its own slice of the trunk.
      trunk: { ids: ['t1', 't2'], path: ['src', 'rcv', 'vault'], thick: 56 },
      branches: [{ id: 'b1', to: 'sc', share: 0.35 }, { id: 'b2', to: 'bb', share: 0.15 }, { id: 'b3', to: 'pr', share: 0.5 }],
      from: 'vault',
    },
    strategy: {
      cards: [
        { id: 'sc', x: 105, y: 250, index: '01 / CAPITAL', label: 'Strategy Capital', detail: 'Capital reserved for approved strategy execution within protocol-defined risk boundaries.', links: ['p1', 'ret'] },
        { id: 'pos', x: 385, y: 250, index: '02 / EXPOSURE', label: 'Bounded position', detail: 'Spot-equivalent 1× only, inside exposure limits. No borrowing or margin.', links: ['p1', 'p2'] },
        { id: 'set', x: 645, y: 250, index: '03 / SETTLEMENT', label: 'Settlement', detail: 'Separates returned principal from the realized result.', links: ['p2', 'ret', 'q1', 'q2', 'q3', 'q4'] },
        { id: 'q1', x: 915, y: 80, label: 'Strategy Capital', note: 'compound', share: 65, detail: 'Compounding allocation: 65 of every 100 parts of positive realized Agent profit.', links: ['q1'] },
        { id: 'q2', x: 915, y: 213, label: 'Buyback Reserve', share: 15, detail: 'Separate ledger: 15 of every 100 parts of positive realized Agent profit.', links: ['q2'] },
        { id: 'q4', x: 915, y: 346, label: 'Holder Rewards', share: 10, detail: 'Passive top30 eligible TWAB holders receive10% of positive realized profit; initial15-minute payout remains unsupported.', links: ['q4'] },
        { id: 'q3', x: 915, y: 479, label: 'Protocol Reserve', share: 10, detail: 'Separate ledger: 10 of every 100 parts of positive realized Agent profit.', links: ['q3'] },
      ],
      trunk: { ids: ['p1', 'p2'], path: ['sc', 'pos', 'set'], thick: 22, tone: 'ivory' },
      principal: { id: 'ret', from: 'set', to: 'sc', depth: 120, label: 'Returned principal stays capital' },
      branches: [{ id: 'q1', to: 'q1', share: 0.65 }, { id: 'q2', to: 'q2', share: 0.15 }, { id: 'q4', to: 'q4', share: 0.1 }, { id: 'q3', to: 'q3', share: 0.1 }],
      branchThick: 56,
      from: 'set',
    },
    buyback: {
      cards: [
        { id: 'res', x: 105, y: 150, index: '01 / SOURCE', label: 'Buyback Reserve', detail: 'Protected capital reserved for COMPD buybacks under fixed execution guards.', links: ['g1'] },
        { id: 'guards', x: 500, y: 150, span: 470, index: '02 / GUARDS', label: 'Every check must pass', guards: ['Reserve trigger', 'Per-execution limit', 'Hard cap', 'Cooldown', 'Slippage & quote'], detail: 'Reserve trigger, per-execution limit, hard cap, cooldown and spending cap, then slippage and quote deviation are all checked before execution.', links: ['g1', 'g2'] },
        { id: 'exe', x: 895, y: 150, index: '03 / EXECUTION', label: 'Buyback Executor', detail: 'Permissionless trigger within Kernel limits; activation remains restricted. Uses approved routes and bounded amounts; cannot custody reserves or change limits.', links: ['g2', 'g3'] },
        { id: 'dex', x: 330, y: 420, index: '04 / ROUTE', label: 'Approved DEX', detail: 'Converts reserve assets into COMPD only after quote and execution guards pass.', links: ['g3', 'g4'] },
        { id: 'compd', x: 610, y: 420, index: '05 / OUTPUT', label: 'COMPD', detail: 'The conceptual buyback output. No buyback execution or amount is reported here.', links: ['g4', 'g5'] },
        { id: 'burn', x: 890, y: 420, index: 'CONCEPTUAL', label: 'Burn', conceptual: true, detail: 'Conceptual endpoint. The production destination and mechanism remain unverified; no live burn is claimed.', links: ['g5'] },
      ],
      line: [['g1', 'res', 'guards'], ['g2', 'guards', 'exe'], ['g3', 'exe', 'dex', 'wrap'], ['g4', 'dex', 'compd'], ['g5', 'compd', 'burn', 'conceptual']],
    },
  };
  const dotCounts = { revenue: 100, strategy: 100, buyback: 9 };

  const cardSize = (c) => (portrait ? { main: c.span ? c.span : 104, cross: c.share && c.id.startsWith('q') ? 128 : 140 } : { main: c.span || CARD_SPAN, cross: CARD_THICK });
  const P = (x, y) => (portrait ? [y, x] : [x, y]);
  const fmt = (n) => n.toFixed(1);
  const pt = (x, y) => P(x, y).map(fmt).join(' ');
  const curve = (x0, y0, x1, y1) => { const m = (x0 + x1) / 2; return `C${pt(m, y0)} ${pt(m, y1)} ${pt(x1, y1)}`; };

  // Filled sankey band from (x0, a0..b0) to (x1, a1..b1).
  const bandD = (x0, a0, b0, x1, a1, b1) => `M${pt(x0, a0)} ${curve(x0, a0, x1, a1)} L${pt(x1, b1)} ${curve(x1, b1, x0, b0)} Z`;
  const laneD = (x0, y0, x1, y1) => `M${pt(x0, y0)} ${curve(x0, y0, x1, y1)}`;

  function buildScene(name) {
    const data = flows[name];
    const cards = Object.fromEntries(data.cards.map((c) => [c.id, c]));
    const edge = (c, side) => c.x + (side * cardSize(c).main) / 2;
    const scene = document.createElement('div');
    scene.className = 'flow-diagram';
    scene.dataset.flow = name;
    const svg = document.createElementNS(SVG, 'svg');
    const [vw, vh] = P(W, H);
    svg.setAttribute('viewBox', `0 0 ${vw} ${vh}`);
    svg.setAttribute('aria-hidden', 'true');
    svg.innerHTML = `<defs><linearGradient id="g-${name}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="${portrait ? 0 : W}" y2="${portrait ? W : 0}"><stop offset="0" stop-color="#b8823c" stop-opacity=".28"/><stop offset="1" stop-color="#f0c070" stop-opacity=".42"/></linearGradient></defs>`;
    const bands = {}, lanes = [];
    const addBand = (id, d, tone = 'gold', extra = '') => {
      const el = document.createElementNS(SVG, 'path');
      el.setAttribute('d', d);
      el.setAttribute('class', `band band--${tone}${extra}`);
      if (tone === 'gold') el.setAttribute('fill', `url(#g-${name})`);
      el.dataset.id = id;
      el.style.setProperty('--order', Object.keys(bands).length);
      svg.append(el);
      bands[id] = el;
    };
    const lanePath = (d) => { const el = document.createElementNS(SVG, 'path'); el.setAttribute('d', d); return el; };

    if (data.trunk) {
      const tr = data.trunk, steps = tr.path.map((id) => cards[id]);
      const half = tr.thick / 2;
      steps.slice(1).forEach((to, i) => {
        const from = steps[i];
        addBand(tr.ids[i], bandD(edge(from, 1), from.y - half, from.y + half, edge(to, -1), to.y - half, to.y + half), tr.tone || 'gold');
      });
      // Branches leave the source card stacked in order; each arrives centred on its target.
      const src = cards[data.from], bt = data.branchThick || tr.thick;
      let cursor = src.y - bt / 2;
      data.branches.forEach((b) => {
        const t = cards[b.to], th = bt * b.share, a0 = cursor, b0 = cursor + th;
        addBand(b.id, bandD(edge(src, 1), a0, b0, edge(t, -1), t.y - th / 2, t.y + th / 2));
        b.slot = [a0, b0, t.y - th / 2, t.y + th / 2];
        cursor = b0;
      });
      // Dot lanes: revenue dots ride their branch's slice through the trunk; profit dots start at settlement.
      const total = dotCounts[name];
      data.branches.forEach((b) => {
        const count = Math.round(total * b.share), nLanes = Math.max(1, Math.round((b.slot[1] - b.slot[0]) / 7));
        for (let i = 0; i < count; i++) {
          const f = ((i % nLanes) + 0.5) / nLanes;
          const segs = [];
          if (!data.trunk.tone) {
            const ty = (src.y - tr.thick / 2) + (b.slot[0] - (src.y - bt / 2)) + f * (b.slot[1] - b.slot[0]);
            steps.slice(1).forEach((to, k) => segs.push(lanePath(laneD(edge(steps[k], 1) - (k ? 0 : 0), ty, edge(to, -1), ty))));
          }
          segs.push(lanePath(laneD(edge(src, 1), b.slot[0] + f * (b.slot[1] - b.slot[0]), edge(cards[b.to], -1), b.slot[2] + f * (b.slot[3] - b.slot[2]))));
          lanes.push({ segs, tone: 'gold', phase: Math.floor(i / nLanes) / Math.ceil(count / nLanes) + (i % nLanes) * 0.013 });
        }
      });
      if (data.trunk.tone === 'ivory') {
        for (let i = 0; i < 14; i++) {
          const f = ((i % 2) + 0.5) / 2, y = steps[0].y - half + f * tr.thick;
          lanes.push({ segs: steps.slice(1).map((to, k) => lanePath(laneD(edge(steps[k], 1), y, edge(to, -1), y))), tone: 'ivory', phase: Math.floor(i / 2) / 7 + (i % 2) * 0.07 });
        }
      }
      if (data.principal) {
        const pr = data.principal, a = cards[pr.from], b = cards[pr.to], low = a.y + CARD_THICK / 2;
        const d = `M${pt(a.x, low)} C${pt(a.x, low + pr.depth)} ${pt(b.x, low + pr.depth)} ${pt(b.x, low)}`;
        const el = document.createElementNS(SVG, 'path');
        el.setAttribute('d', d);
        el.setAttribute('class', 'principal-line');
        el.setAttribute('marker-end', `url(#arrow-${name})`);
        el.dataset.id = pr.id;
        svg.querySelector('defs').insertAdjacentHTML('beforeend', `<marker id="arrow-${name}" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="#efe6d2"/></marker>`);
        svg.append(el);
        bands[pr.id] = el;
        for (let i = 0; i < 8; i++) lanes.push({ segs: [lanePath(d)], tone: 'ivory', phase: i / 8 });
        // Portrait has no room beside the loop; the step text below says the same thing.
        if (!portrait) {
        const [lx, ly] = P((a.x + b.x) / 2, low + pr.depth * 0.75 + 22);
        const label = document.createElementNS(SVG, 'text');
        label.setAttribute('x', fmt(lx)); label.setAttribute('y', fmt(ly));
        label.setAttribute('class', 'principal-label');
        label.textContent = pr.label;
        svg.append(label);
        }
      }
    }

    if (data.line) {
      // One constant-width line: guards in a row, then a wrap down to the route, output and burn.
      const routeSegs = [];
      data.line.forEach(([id, from, to, kind]) => {
        const a = cards[from], b = cards[to];
        let d;
        if (kind === 'wrap') {
          const top = a.y + CARD_THICK / 2, mid = (a.y + b.y) / 2, enter = edge(b, -1), side = enter - 60;
          d = `M${pt(a.x, top)} L${pt(a.x, mid - 20)} Q${pt(a.x, mid)} ${pt(a.x - 20, mid)} L${pt(side + 20, mid)} Q${pt(side, mid)} ${pt(side, mid + 20)} L${pt(side, b.y - 20)} Q${pt(side, b.y)} ${pt(side + 20, b.y)} L${pt(enter, b.y)}`;
        } else d = `M${pt(edge(a, 1), a.y)} L${pt(edge(b, -1), b.y)}`;
        const el = document.createElementNS(SVG, 'path');
        el.setAttribute('d', d);
        el.setAttribute('class', `line${kind === 'conceptual' ? ' line--conceptual' : ''}`);
        el.dataset.id = id;
        el.style.setProperty('--order', Object.keys(bands).length);
        svg.append(el);
        bands[id] = el;
        routeSegs.push(lanePath(d));
        // Dots pass straight through the guards card.
        if (id === 'g1') routeSegs.push(lanePath(`M${pt(edge(b, -1), b.y)} L${pt(edge(b, 1), b.y)}`));
      });
      for (let i = 0; i < dotCounts[name]; i++) lanes.push({ segs: routeSegs, tone: 'gold', phase: i / dotCounts[name], fadeEnd: true });
    }

    const dots = document.createElementNS(SVG, 'g');
    dots.setAttribute('class', 'dots');
    svg.append(dots);
    scene.append(svg);

    // Cards are real buttons positioned over the drawing.
    const layer = document.createElement('div');
    layer.className = 'flow-cards';
    const guardChips = [];
    data.cards.forEach((c, i) => {
      const s = cardSize(c), [cx, cy] = P(c.x, c.y), [w, h] = P(s.main, s.cross);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `flow-card${c.share ? ' flow-card--target' : ''}${c.guards ? ' flow-card--guards' : ''}${c.conceptual ? ' flow-card--conceptual' : ''}`;
      Object.assign(btn.style, { left: `${((cx - w / 2) / vw) * 100}%`, top: `${((cy - h / 2) / vh) * 100}%`, width: `${(w / vw) * 100}%`, height: `${(h / vh) * 100}%` });
      btn.style.setProperty('--order', i);
      btn.dataset.links = c.links.join(' ');
      btn.dataset.title = c.label;
      btn.dataset.detail = c.detail;
      btn.setAttribute('aria-pressed', 'false');
      const chips = c.guards ? `<span class="guard-chips">${c.guards.map((g) => `<span class="guard-chip">${g}</span>`).join('')}</span>` : '';
      btn.innerHTML = `${c.index ? `<small>${c.index}</small>` : ''}<strong>${c.label}${c.note ? ` <i>· ${c.note}</i>` : ''}</strong>${c.share ? `<span class="share"><b>${c.share}%</b><span class="share-note"> of every 100</span></span>` : ''}${chips}`;
      layer.append(btn);
      if (c.guards) {
        const start = c.x - s.main / 2, step = s.main / c.guards.length;
        btn.querySelectorAll('.guard-chip').forEach((chip, k) => guardChips.push({ el: chip, from: start + k * step, to: start + (k + 1) * step }));
      }
    });
    scene.append(layer);
    return { scene, svg, bands, lanes, dots, guardChips };
  }

  // Selecting a card lights the bands touching it and dims the rest.
  const detail = document.getElementById('flow-detail');
  let pinned = null;
  function highlight(s, btn) {
    const links = btn ? btn.dataset.links.split(' ') : null;
    s.scene.classList.toggle('is-tracing', Boolean(btn));
    Object.entries(s.bands).forEach(([id, el]) => el.classList.toggle('is-lit', Boolean(links && links.includes(id))));
    s.scene.querySelectorAll('.flow-card').forEach((card) => card.classList.toggle('is-lit', Boolean(links && card.dataset.links.split(' ').some((id) => links.includes(id)))));
    if (btn && detail) {
      detail.querySelector('small').textContent = `SELECTED / ${btn.dataset.title}`.toUpperCase();
      detail.querySelector('span').textContent = btn.dataset.detail;
    }
  }
  function wireCards(s) {
    s.scene.querySelectorAll('.flow-card').forEach((btn) => {
      const restore = () => highlight(s, pinned && s.scene.contains(pinned) ? pinned : null);
      btn.addEventListener('pointerenter', () => highlight(s, btn));
      btn.addEventListener('focus', () => highlight(s, btn));
      btn.addEventListener('pointerleave', restore);
      btn.addEventListener('blur', restore);
      btn.addEventListener('click', () => {
        pinned = pinned === btn ? null : btn;
        s.scene.querySelectorAll('.flow-card').forEach((n) => n.setAttribute('aria-pressed', String(n === pinned)));
        highlight(s, pinned);
      });
    });
  }

  const tabs = [...document.querySelectorAll('[data-flow-tab]')];
  const scenes = {};
  function build() {
    panels.forEach((panel) => {
      const name = panel.dataset.flowPanel;
      scenes[name] = buildScene(name);
      panel.querySelector('[data-flow-stage]').replaceChildren(scenes[name].scene);
      wireCards(scenes[name]);
    });
  }
  build();

  // Dots for the visible flow only, evenly spaced and moving at one speed.
  let active = [], current = null, startedAt = 0, seen = false, visible = false;
  function startDots(name) {
    const s = scenes[name];
    s.dots.replaceChildren();
    active = [];
    if (reduced) return;
    s.lanes.forEach((lane) => {
      const lens = lane.segs.map((p) => p.getTotalLength());
      const c = document.createElementNS(SVG, 'circle');
      c.setAttribute('r', portrait ? 3.2 : 2.4);
      c.setAttribute('class', `dot dot--${lane.tone}`);
      c.setAttribute('opacity', '0');
      s.dots.append(c);
      active.push({ el: c, segs: lane.segs, lens, total: lens.reduce((a, b) => a + b, 0), phase: lane.phase % 1, fadeEnd: lane.fadeEnd });
    });
  }
  function enter(name) {
    const el = scenes[name].scene;
    el.classList.remove('is-entered');
    void el.offsetWidth;
    el.classList.add('is-entered');
    current = name;
    startedAt = performance.now();
    startDots(name);
  }
  function selectMode(name, moveFocus = false) {
    tabs.forEach((tab) => {
      const on = tab.dataset.flowTab === name;
      tab.setAttribute('aria-selected', String(on));
      tab.tabIndex = on ? 0 : -1;
      if (on && moveFocus) tab.focus();
    });
    panels.forEach((panel) => { panel.hidden = panel.dataset.flowPanel !== name; });
    if (seen) enter(name);
    else current = name;
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectMode(tab.dataset.flowTab));
    tab.addEventListener('keydown', (event) => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      else return;
      event.preventDefault();
      selectMode(tabs[next].dataset.flowTab, true);
    });
  });

  const experience = panels[0].closest('.flow-experience');
  selectMode('revenue');
  if (reduced || !('IntersectionObserver' in window)) { seen = true; visible = true; enter('revenue'); }
  else new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    if (visible && !seen) { seen = true; enter(current); }
  }, { threshold: 0.2 }).observe(experience);

  const clamp = (x) => Math.min(1, Math.max(0, x));
  const SPEED = 0.075; // route traversals per second
  function frame(now) {
    requestAnimationFrame(frame);
    if (!visible || !current || !active.length) return;
    const s = scenes[current], t = now / 1000, ramp = clamp((now - startedAt - 1300) / 800);
    if (ramp <= 0) return;
    const hits = new Set();
    for (const d of active) {
      const u = (t * SPEED + d.phase) % 1;
      let dist = u * d.total, p;
      for (let i = 0; i < d.segs.length; i++) {
        if (dist <= d.lens[i] || i === d.segs.length - 1) { p = d.segs[i].getPointAtLength(Math.min(dist, d.lens[i])); break; }
        dist -= d.lens[i];
      }
      d.el.setAttribute('cx', fmt(p.x));
      d.el.setAttribute('cy', fmt(p.y));
      let o = clamp(u / 0.04) * clamp((1 - u) / 0.04) * ramp;
      if (d.fadeEnd) o *= 1 - clamp((u - 0.88) / 0.12) * 0.9;
      d.el.setAttribute('opacity', o.toFixed(2));
      const along = portrait ? p.y : p.x;
      s.guardChips.forEach((g) => { if (along >= g.from && along < g.to && Math.abs((portrait ? p.x : p.y) - 150) < 40) hits.add(g.el); });
    }
    s.guardChips.forEach((g) => g.el.classList.toggle('is-checking', hits.has(g.el)));
  }
  requestAnimationFrame(frame);

  addEventListener('resize', () => {
    const next = innerWidth < 760;
    if (next === portrait) return;
    portrait = next;
    build();
    if (seen) enter(current);
  });
})();
