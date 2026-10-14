export const sourceDirectory = 'src';
export const buildDirectory = 'dist';
export const pageRoutes = Object.freeze({
  '/admin': 'admin.html', '/admin/': 'admin.html', '/admin.html': 'admin.html',
  '/': 'index.html', '/index.html': 'index.html',
  '/treasury': 'treasury.html', '/treasury/': 'treasury.html', '/treasury.html': 'treasury.html',
  '/agent': 'agent.html', '/agent/': 'agent.html', '/agent.html': 'agent.html',
  '/flow': 'flow.html', '/flow/': 'flow.html', '/flow.html': 'flow.html',
  '/protocol': 'protocol.html', '/protocol/': 'protocol.html', '/protocol.html': 'protocol.html',
  '/docs': 'docs.html', '/docs/': 'docs.html', '/docs.html': 'docs.html',
  '/app': 'app.html', '/app/': 'app.html', '/app.html': 'app.html',
});
export const frontendFiles = Object.freeze([
  'admin.html','compd-manual.js', 'index.html', 'treasury.html', 'agent.html', 'flow.html', 'protocol.html', 'docs.html', 'app.html',
  'compd-system.css', 'paper-workspace.css', 'flow-page.css', 'landing.css', 'compd-atmosphere.css',
  'compd-api.js','compd-live.js','compd-integration.css',
  'compd-shell.js', 'flow-page.js', 'landing.js', 'compd-scene.js', 'compd-page.js',
  'vendor/gsap.min.js', 'vendor/ScrollTrigger.min.js', 'vendor/three-subset.min.js',
  'compd-stack-mark.png', 'compd-favicon-32.png', 'compd-touch-icon-180.png',
]);
export const marketSymbols = Object.freeze(['NVDAx', 'TSLAx', 'AMZNx', 'AAPLx', 'SPYx']);