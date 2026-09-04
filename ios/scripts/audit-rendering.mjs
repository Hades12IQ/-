import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../FirasAI');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const raw = text => {
  const match = text.match(/#"""([\s\S]*?)"""#/);
  assert.ok(match, 'Swift raw JavaScript string exists');
  return match[1];
};
const typesetter = raw(read('Rendering/MathIsland+Typesetting.swift'));
for (const script of read('Rendering/Documents/DocumentPrinter.swift').matchAll(/#"""([\s\S]*?)"""#/g)) {
  new vm.Script(script[1]);
}
new vm.Script(raw(read('Rendering/Documents/DocumentPrinter+Layout.swift')));
const assets = raw(read('Rendering/MathIsland+Assets.swift'))
  .replace('\\#(typesettingScript)', typesetter);
for (const script of assets.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
  new vm.Script(script[1]);
}
// Exercise the exact bundled function with a deterministic clock and RAF queue. Timer completion
// must not depend on the very RAF callbacks which WebKit may suspend behind the foreground app.
const settleStart = assets.indexOf('      function settle(done) {');
const settleEnd = assets.indexOf('      function measure() {', settleStart);
assert.ok(settleStart >= 0 && settleEnd > settleStart, 'Bundled settle function is available');
const settleSource = assets.slice(settleStart, settleEnd);
function settleHarness({fonts = true} = {}) {
  let now = 0, nextTimer = 0, doneCount = 0, onFonts, onFontFailure;
  const timers = new Map();
  const frames = [];
  const ctx = vm.createContext({
    document: fonts ? {fonts: {ready: {then: (resolve, reject) => { onFonts = resolve; onFontFailure = reject; }}}} : {},
    setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, {callback, at: now + delay}); return id; },
    clearTimeout: id => timers.delete(id),
    requestAnimationFrame: callback => { frames.push(callback); return frames.length; },
  });
  vm.runInContext(settleSource + '\nglobalThis.runSettle = settle;', ctx);
  ctx.runSettle(() => { doneCount++; });
  return {
    fontsReady: () => onFonts?.(),
    fontsFailed: () => onFontFailure?.(),
    frame: () => frames.shift()?.(),
    advance: milliseconds => {
      now += milliseconds;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) { timers.delete(id); timer.callback(); }
      }
    },
    get done() { return doneCount; },
    get timers() { return timers.size; },
    get frames() { return frames.length; },
  };
}
const settled = settleHarness();
settled.fontsReady(); settled.fontsReady();
assert.equal(settled.frames, 1, 'Font callbacks schedule the first frame once');
settled.frame(); assert.equal(settled.done, 0, 'Happy path waits for two frames');
settled.frame(); assert.equal(settled.done, 1);
assert.equal(settled.timers, 0, 'Happy path cancels its safety timer');
settled.advance(1500); settled.fontsReady(); settled.frame();
assert.equal(settled.done, 1, 'Completed work ignores late fonts and timer callbacks');
for (const framesBeforeStall of [0, 1]) {
  const stalled = settleHarness();
  stalled.fontsReady();
  for (let i = 0; i < framesBeforeStall; i++) stalled.frame();
  stalled.advance(1499); assert.equal(stalled.done, 0);
  stalled.advance(1); assert.equal(stalled.done, 1, `Safety timer bypasses stalled RAF ${framesBeforeStall + 1}`);
  stalled.fontsReady(); stalled.frame(); stalled.frame(); stalled.advance(1500);
  assert.equal(stalled.done, 1, 'Late stalled frames cannot measure twice');
  assert.equal(stalled.frames, 0, 'Late first frame does not schedule another frame');
}
const lateFonts = settleHarness();
lateFonts.advance(1500); assert.equal(lateFonts.done, 1, 'Safety timer also bypasses unresolved fonts');
lateFonts.fontsReady(); lateFonts.fontsFailed();
assert.equal(lateFonts.frames, 0, 'Late font completion does not enqueue stale measurement');
assert.equal(lateFonts.done, 1);
const noFonts = settleHarness({fonts: false});
noFonts.advance(1500); noFonts.frame(); noFonts.frame();
assert.equal(noFonts.done, 1, 'No-font path remains bounded if RAF stalls');
const failedFonts = settleHarness();
failedFonts.fontsFailed(); failedFonts.frame(); failedFonts.frame();
assert.equal(failedFonts.done, 1, 'Failed fonts use the two-frame fallback once');
assert.equal(failedFonts.timers, 0);
const authored = raw(read('Rendering/Documents/DocumentHTML+Authored.swift'))
  .replace('\\#(MathIslandAssets.typesettingScript)', typesetter)
  .replace('\\#(readyFlag)', 'firasDocumentReady');
const authoredJS = authored.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(authoredJS);
const context = vm.createContext({ console });
vm.runInContext(read('Resources/KaTeX/katex.min.js'), context);
vm.runInContext(read('Resources/KaTeX/mhchem.min.js'), context);
vm.runInContext('katex.render = (tex, host, options) => { host.innerHTML = katex.renderToString(tex, options); };', context);
vm.runInContext(typesetter + '\nglobalThis.renderMath = (tex, display) => { const host = {}; return {ok: attempt(tidy(tex),display,host,"#b3261e") || attempt(repair(tex),display,host,"#b3261e"), html:host.innerHTML}; };', context);
const expressions = [
  String.raw`\frac{-b\pm\sqrt{b^2-4ac}}{2a}`,
  String.raw`\int_0^{\pi/4}\ln 2\,dx=\frac{\pi\ln2}{4}`,
  String.raw`\begin{pmatrix}1&2\\3&4\end{pmatrix}`,
  String.raw`\begin{align}x&=2\\ y&=x^2\end{align}`,
  String.raw`\ce{CuSO4 . 5H2O}`,
  String.raw`\ce{2H2 + O2 -> 2H2O}`,
  String.raw`\pu{9.81 m s-2}`,
  String.raw`\bra{\psi}\hat H\ket{\psi}`,
  // Native recovery preserves the source for copy and gives the shared typesetter these forms.
  String.raw`dv = \cot \theta d\theta \Rightarrow v = \ln (\sin \theta)`,
  String.raw`\pi /4 \ln (\sin (\pi /4)) = \pi /4 \ln (1/(\sqrt{2})) = -\pi /8`,
  String.raw`\frac{\pi}{4}\ln\left(\sin\frac{\pi}{4}\right)=\frac{\pi}{4}\ln\frac{1}{\sqrt2}=-\frac{\pi}{8}\ln2`,
  // Incomplete streaming previews use empty TeX groups, never invented numerical arguments.
  String.raw`\frac{}{}`,
  String.raw`\frac{1}{}`,
  String.raw`\sqrt{}`,
  String.raw`\begin{aligned}a&=1\\b&=2\end{aligned}`,
];
for (const tex of expressions) {
  const result = context.renderMath(tex, true);
  assert.equal(result.ok, true, `Typesets ${tex}`);
  assert.ok(result.html.includes('katex'), `Rendered math exists for ${tex}`);
  assert.ok(!result.html.includes('katex-error'), `No error in ${tex}`);
}
const scannerSource = authoredJS.slice(0, authoredJS.indexOf('          function typeset(node)'));
vm.runInContext(scannerSource + '\nglobalThis.scanMath = pieces;})();', context);
const fixtures = [
  [String.raw`التكلفة $ ثم $x^2$ و $\int_0^1 x\,dx=\frac12$ و $$e^{i\pi}+1=0$$`, 3],
  ['Tea is $5 and coffee is $3.', 0],
  [String.raw`unfinished \[ followed by $x^2$`, 1],
  [String.raw`المساحة تساوي $\pi r^2$ في المستوى.`, 1],
  [String.raw`\$5 is a price. $x$ is math.`, 1],
];
for (const [text, count] of fixtures) {
  assert.equal((context.scanMath(text) || []).filter(part => part.math).length, count, text);
}
console.log(`PASS: ${expressions.length} bundled KaTeX math/chemistry cases, ${fixtures.length} authored delimiter cases, 6 deterministic font/RAF settling cases, both JavaScript runtimes parse.`);
