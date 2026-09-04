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
const assets = raw(read('Rendering/MathIsland+Assets.swift'))
  .replace('\\#(typesettingScript)', typesetter);
for (const script of assets.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
  new vm.Script(script[1]);
}
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
console.log(`PASS: ${expressions.length} bundled KaTeX math/chemistry cases, ${fixtures.length} authored delimiter cases, both JavaScript runtimes parse.`);
