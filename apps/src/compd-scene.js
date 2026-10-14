import { WebGLRenderer, Scene, PerspectiveCamera, BufferGeometry, BufferAttribute, DynamicDrawUsage, Points, ShaderMaterial, AdditiveBlending, Group } from './vendor/three-subset.min.js';

// Conceptual illustration only. Particle layouts carry no values, balances or live data.
const TAU = Math.PI * 2;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const tri = (a, b) => a + b - 1;
let ringY = 0.8; // taller orbit in portrait so the closing copy fits inside it

// One layout per stage. Hero and closing keep the text area clear: 0 hero, 1 Agent, 2 Treasury, 3 Flow, 4 Protocol, 5 Docs, 6 closing.
// Each writes x, y, z and fade (0..1) for particle i. Flow layouts advance with time.
const layouts = [
  (r, i, t, o) => {
    const x = (r.a - 0.5) * 18, z = 2.5 - r.b * 9;
    o.x = x; o.z = z; o.y = -2.4 + Math.sin(x * 0.55 + t * 0.6 + z * 0.35) * 0.35 + Math.cos(z * 0.8 - t * 0.4) * 0.2; o.f = 0.35 + 0.65 * smooth(-6.5, 1, z);
  },
  // Agent: a scanning radar. Rings observe; a sweep lights what it reads.
  (r, i, t, o) => {
    const ring = 0.6 + Math.floor(r.b * 5) * 0.62, th = r.a * TAU, sweep = (t * 0.9) % TAU;
    const gap = ((th - sweep) % TAU + TAU) % TAU;
    o.x = Math.cos(th) * ring; o.y = Math.sin(th) * ring; o.z = (r.c - 0.5) * 0.25;
    if (r.d < 0.12) { const u = r.c * 3.4; o.x = Math.cos(sweep) * u; o.y = Math.sin(sweep) * u; }
    o.f = r.d < 0.12 ? 0.9 : 0.18 + 0.82 * Math.exp(-gap * 1.6);
  },
  // Treasury: three separate coin stacks, one per reserve. Equal heights: no amounts implied.
  (r, i, t, o) => {
    const k = (i % 3) - 1, level = Math.floor(r.b * 9), th = r.a * TAU + t * 0.25 * (k + 2) * 0.5, rad = 0.75 * Math.sqrt(r.c * 0.25 + 0.75);
    o.x = k * 2.3 + Math.cos(th) * rad; o.y = -1.9 + level * 0.44 + (r.d - 0.5) * 0.06; o.z = Math.sin(th) * rad * 0.9; o.f = 1;
  },
  (r, i, t, o) => {
    const u = (r.a + t * 0.06) % 1, lane = (i % 3) - 1, split = smooth(0.25, 0.85, u);
    o.x = -5.5 + u * 11; o.y = lane * 2.2 * split + (r.b - 0.5) * (0.25 + 0.45 * split); o.z = (r.c - 0.5) * 0.8; o.f = smooth(0, 0.06, u) * smooth(1, 0.94, u);
  },
  // Protocol: a guarded core inside a lattice of meridians and latitudes.
  (r, i, t, o) => {
    if (r.d < 0.28) {
      const th = r.a * TAU, ph = Math.acos(2 * r.b - 1), rad = 0.9 * Math.cbrt(r.c);
      o.x = rad * Math.sin(ph) * Math.cos(th); o.y = rad * Math.cos(ph); o.z = rad * Math.sin(ph) * Math.sin(th); o.f = 1; return;
    }
    let th, ph;
    if (r.c < 0.55) { th = Math.floor(r.a * 10) / 10 * TAU; ph = r.b * Math.PI; }
    else { ph = (Math.floor(r.a * 6) + 1) / 7 * Math.PI; th = r.b * TAU; }
    th += t * 0.12;
    o.x = 3 * Math.sin(ph) * Math.cos(th); o.y = 3 * Math.cos(ph); o.z = 3 * Math.sin(ph) * Math.sin(th); o.f = 0.75;
  },
  // Docs: three stacked pages, each written in lines of particles.
  (r, i, t, o) => {
    const p = i % 3, row = Math.floor(r.b * 15), len = 0.55 + 0.45 * Math.abs(Math.sin(row * 12.9 + p * 4.1));
    const lx = -1.6 + r.a * 3.2 * (row % 5 === 4 ? len * 0.5 : len), ly = 2.1 - row * 0.3;
    const ang = (p - 1) * 0.16 + Math.sin(t * 0.3 + p) * 0.03;
    o.x = lx * Math.cos(ang) - ly * Math.sin(ang) + (p - 1) * 0.7; o.y = lx * Math.sin(ang) + ly * Math.cos(ang) - (p - 1) * 0.25; o.z = -p * 0.9 + (r.c - 0.5) * 0.05; o.f = p === 2 ? 1 : 0.55;
  },
  (r, i, t, o) => {
    const th = r.a * TAU + t * (0.06 + r.c * 0.06), rad = 3.5 + tri(r.b, r.d) * 0.5;
    o.x = Math.cos(th) * rad * 1.45; o.y = Math.sin(th) * rad * ringY; o.z = tri(r.c, r.d) * 0.8; o.f = 1;
  },
];

const vertex = `
attribute vec3 aColor; attribute float aFade; attribute float aSeed;
uniform float uTime; uniform float uPixel; uniform float uOpacity;
varying vec3 vColor; varying float vAlpha;
void main() {
  vec3 p = position + vec3(sin(uTime * .6 + aSeed * 20.), cos(uTime * .5 + aSeed * 15.), sin(uTime * .4 + aSeed * 9.)) * .05;
  vec4 mv = modelViewMatrix * vec4(p, 1.);
  gl_PointSize = (1.4 + aSeed * 1.8) * uPixel * (9. / -mv.z);
  gl_Position = projectionMatrix * mv;
  vColor = aColor; vAlpha = aFade * uOpacity * mix(1., .3, smoothstep(8., 16., -mv.z));
}`;
const fragment = `
varying vec3 vColor; varying float vAlpha;
void main() {
  float d = length(gl_PointCoord - .5);
  float a = smoothstep(.5, .05, d) * vAlpha;
  if (a < .01) discard;
  gl_FragColor = vec4(vColor, a);
}`;

const palette = [[0.89, 0.68, 0.31], [0.96, 0.77, 0.42], [0.82, 0.74, 0.57]];

// Shared particle scene. placement 'landing' follows state.stage through every Chapter layout;
// placement 'intro' shows one layout beside a page intro and fades with state.visible (0..1).
export const layoutIds = { hero: 0, agent: 1, treasury: 2, flow: 3, protocol: 4, docs: 5, closing: 6 };

export function startScene(canvas, state, options = {}) {
  const intro = options.placement === 'intro';
  let renderer;
  try { renderer = new WebGLRenderer({ canvas, alpha: true, antialias: false, powerPreference: 'low-power' }); }
  catch { return false; }
  const coarse = matchMedia('(pointer: coarse)').matches || innerWidth < 700;
  let count = (coarse ? 4500 : 9000) * (intro ? 0.75 : 1);
  const max = count;
  let pixelCap = coarse ? 1.25 : 1.5;
  const rnd = { a: new Float32Array(max), b: new Float32Array(max), c: new Float32Array(max), d: new Float32Array(max), k: new Float32Array(max) };
  for (let i = 0; i < max; i++) { rnd.a[i] = Math.random(); rnd.b[i] = Math.random(); rnd.c[i] = Math.random(); rnd.d[i] = Math.random(); rnd.k[i] = 0.5 + Math.random(); }
  const pos = new Float32Array(max * 3), color = new Float32Array(max * 3), fade = new Float32Array(max), seed = new Float32Array(max);
  for (let i = 0; i < max; i++) { color.set(palette[i % 3], i * 3); seed[i] = rnd.d[i]; pos.set([(rnd.a[i] - 0.5) * 12, (rnd.b[i] - 0.5) * 6, 0], i * 3); }
  const geometry = new BufferGeometry();
  const posAttr = new BufferAttribute(pos, 3).setUsage(DynamicDrawUsage), fadeAttr = new BufferAttribute(fade, 1).setUsage(DynamicDrawUsage);
  geometry.setAttribute('position', posAttr);
  geometry.setAttribute('aColor', new BufferAttribute(color, 3));
  geometry.setAttribute('aFade', fadeAttr);
  geometry.setAttribute('aSeed', new BufferAttribute(seed, 1));
  const material = new ShaderMaterial({ vertexShader: vertex, fragmentShader: fragment, transparent: true, depthWrite: false, blending: AdditiveBlending, uniforms: { uTime: { value: 0 }, uPixel: { value: 1 }, uOpacity: { value: 0.8 } } });
  const points = new Points(geometry, material);
  points.frustumCulled = false;
  const group = new Group();
  group.add(points);
  const scene = new Scene();
  scene.add(group);
  const dustCount = coarse ? 700 : 1500;
  const dustPos = new Float32Array(dustCount * 3), dustCol = new Float32Array(dustCount * 3), dustFade = new Float32Array(dustCount).fill(1), dustSeed = new Float32Array(dustCount);
  for (let i = 0; i < dustCount; i++) {
    dustPos.set([(Math.random() - 0.5) * 30, (Math.random() - 0.5) * 22, -4 - Math.random() * 12], i * 3);
    dustCol.set(palette[2], i * 3); dustSeed[i] = Math.random() * 0.4;
  }
  const dustGeometry = new BufferGeometry();
  dustGeometry.setAttribute('position', new BufferAttribute(dustPos, 3));
  dustGeometry.setAttribute('aColor', new BufferAttribute(dustCol, 3));
  dustGeometry.setAttribute('aFade', new BufferAttribute(dustFade, 1));
  dustGeometry.setAttribute('aSeed', new BufferAttribute(dustSeed, 1));
  const dustMaterial = material.clone();
  dustMaterial.uniforms = { uTime: material.uniforms.uTime, uPixel: material.uniforms.uPixel, uOpacity: { value: 0.55 } };
  const dust = new Points(dustGeometry, dustMaterial);
  dust.frustumCulled = false;
  scene.add(dust);
  const camera = new PerspectiveCamera(50, 1, 0.1, 50);
  camera.position.z = 9;

  let wide = innerWidth > 900;
  const sideX = [0, 2.6, -2.6, 0, 2.6, -2.6, 0], sideY = [0, 0, 0, 0.9, 0, 0, 0], camZ = [9, 8, 9, 8.6, 7.6, 9, 9.6];
  let fit = 1, baseOpacity = 0.85;
  function resize() {
    const w = innerWidth, h = innerHeight;
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, pixelCap));
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    material.uniforms.uPixel.value = renderer.getPixelRatio() * (h / 900) * (wide ? 1 : 1.7);
    wide = w > 900;
    // Portrait: shrink layouts to the visible width and use bigger, brighter points.
    fit = wide ? 1 : Math.max(0.42, Math.min(1, (8.4 * w / h) / 9));
    group.scale.setScalar(fit);
    ringY = wide ? 0.8 : 1.5;
    baseOpacity = intro ? (wide ? 0.85 : 0.3) : (wide ? 0.85 : 0.9);
  }
  addEventListener('resize', resize);
  resize();

  const out = { x: 0, y: 0, z: 0, f: 1 }, r = { a: 0, b: 0, c: 0, d: 0 };
  let last = performance.now(), slow = 0, frames = 0, running = true, px = 0, py = 0;
  addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse') { px = e.clientX / innerWidth - 0.5; py = e.clientY / innerHeight - 0.5; } }, { passive: true });
  document.addEventListener('visibilitychange', () => { running = !document.hidden; if (running) { last = performance.now(); requestAnimationFrame(frame); } });

  function frame(now) {
    if (!running) return;
    const visible = state.visible ?? 1;
    if (visible <= 0.001) { last = now; requestAnimationFrame(frame); return; }
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    // Adaptive quality: if frames stay slow, drop particle count and pixel ratio. Looks the same, runs lighter.
    frames++;
    slow += dt > 0.026 ? 1 : 0;
    if (frames === 90) {
      if (slow > 30 && count > max * 0.3) { count = Math.floor(count * 0.6); geometry.setDrawRange(0, count); pixelCap = Math.max(1, pixelCap - 0.25); resize(); }
      frames = 0; slow = 0;
    }
    const t = now / 1000, layout = layouts[state.stage] || layouts[0], k = 1 - Math.exp(-dt * 2.2);
    for (let i = 0; i < count; i++) {
      r.a = rnd.a[i]; r.b = rnd.b[i]; r.c = rnd.c[i]; r.d = rnd.d[i];
      layout(r, i, t, out);
      const j = i * 3, ki = Math.min(1, k * rnd.k[i]);
      if (out.f < 0.02) { pos[j] = out.x; pos[j + 1] = out.y; pos[j + 2] = out.z; }
      else { pos[j] += (out.x - pos[j]) * ki; pos[j + 1] += (out.y - pos[j + 1]) * ki; pos[j + 2] += (out.z - pos[j + 2]) * ki; }
      fade[i] += (out.f - fade[i]) * Math.min(1, dt * 6);
    }
    posAttr.needsUpdate = true;
    fadeAttr.needsUpdate = true;
    material.uniforms.uTime.value = t;
    material.uniforms.uOpacity.value = baseOpacity * visible;
    dustMaterial.uniforms.uOpacity.value = 0.55 * visible;
    const st = state.stage;
    const tx = intro ? (wide ? 3.4 : 0) : (wide ? sideX[st] || 0 : 0);
    const ty = intro ? (wide ? 0 : 3.3) : (wide ? sideY[st] || 0 : (st === 0 ? -1.1 : st === 6 ? 1.7 : 2.1));
    group.position.x += (tx - group.position.x) * 0.04;
    group.position.y += (ty - group.position.y) * 0.04;
    camera.position.z += ((intro ? 10 : camZ[st] || 9) - (state.scrollStage || 0) * 1.2 - camera.position.z) * 0.04;
    group.rotation.y += (((state.scroll ?? 0.5) - 0.5) * 0.5 + px * 0.45 - group.rotation.y) * 0.05;
    group.rotation.x += (py * 0.25 + (state.stage === 0 ? 0.12 : 0) - group.rotation.x) * 0.05;
    camera.position.x += (px * 0.8 - camera.position.x) * 0.04;
    camera.position.y += (-py * 0.5 - camera.position.y) * 0.04;
    camera.lookAt(0, 0, 0);
    dust.position.y += ((state.scroll ?? 0.5) * 7 - 3.5 - dust.position.y) * 0.06;
    dust.rotation.y = t * 0.008;
    renderer.render(scene, camera);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  return true;
}
