import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const app = path.join(root, "FirasAI");

const productFiles = [
  "Models/AgentModels.swift",
  "Stores/AgentStore.swift",
  "Stores/BrainStore.swift",
  "Stores/CodeStore.swift",
  "Features/Agent/AgentScreen.swift",
  "Features/Agent/AgentStrings.swift",
  "Features/Brain/BrainDocumentExtractor.swift",
  "Features/Brain/BrainScreen.swift",
  "Features/Brain/BrainStrings.swift",
  "Features/Code/CodeScreen.swift",
  "Features/Code/CodeStrings.swift",
];

function fail(message) {
  throw new Error(message);
}

function source(relativePath) {
  const absolutePath = path.join(app, relativePath);
  if (!fs.existsSync(absolutePath)) fail(`Missing ${relativePath}`);
  return fs.readFileSync(absolutePath, "utf8");
}

function requireFragments(relativePath, fragments) {
  const value = source(relativePath);
  for (const fragment of fragments) {
    if (!value.includes(fragment)) {
      fail(`${relativePath} is missing contract fragment: ${fragment}`);
    }
  }
}

function auditSwiftStructure(relativePath) {
  const value = source(relativePath);
  const stack = [];
  let blockCommentDepth = 0;
  let lineComment = false;
  let stringEnd = null;

  for (let index = 0; index < value.length; index += 1) {
    if (lineComment) {
      if (value[index] === "\n") lineComment = false;
      continue;
    }

    if (blockCommentDepth > 0) {
      if (value.startsWith("/*", index)) {
        blockCommentDepth += 1;
        index += 1;
      } else if (value.startsWith("*/", index)) {
        blockCommentDepth -= 1;
        index += 1;
      }
      continue;
    }

    if (stringEnd !== null) {
      if (value.startsWith(stringEnd, index)) {
        index += stringEnd.length - 1;
        stringEnd = null;
      } else if (value[index] === "\\" && !stringEnd.endsWith("#")) {
        index += 1;
      }
      continue;
    }

    if (value.startsWith("//", index)) {
      lineComment = true;
      index += 1;
      continue;
    }
    if (value.startsWith("/*", index)) {
      blockCommentDepth = 1;
      index += 1;
      continue;
    }

    const stringStart = value.slice(index).match(/^(#+)?("""|")/);
    if (stringStart) {
      const hashes = stringStart[1] ?? "";
      const quote = stringStart[2];
      stringEnd = quote + hashes;
      index += hashes.length + quote.length - 1;
      continue;
    }

    const character = value[index];
    if ("([{".includes(character)) stack.push(character);
    if (")]}".includes(character)) {
      const expected = { ")": "(", "]": "[", "}": "{" }[character];
      const actual = stack.pop();
      if (actual !== expected) {
        fail(`${relativePath} has an unmatched ${character} at byte ${index}`);
      }
    }
  }

  if (lineComment) lineComment = false;
  if (blockCommentDepth !== 0) fail(`${relativePath} has an open block comment`);
  if (stringEnd !== null) fail(`${relativePath} has an open string literal`);
  if (stack.length !== 0) fail(`${relativePath} has unclosed delimiters: ${stack.join("")}`);
}

function auditCatalog(product) {
  const stringsPath = `Features/${product}/${product}Strings.swift`;
  const catalogPath = path.join(app, `Features/${product}/${product}.xcstrings`);
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const keys = Array.from(
    source(stringsPath).matchAll(/LocalizedStringResource\("([^"]+)"/g),
    (match) => match[1],
  );

  for (const key of keys) {
    const localizations = catalog.strings?.[key]?.localizations;
    if (!localizations?.ar?.stringUnit?.value) fail(`${product}: ${key} has no Arabic value`);
    if (!localizations?.en?.stringUnit?.value) fail(`${product}: ${key} has no English value`);
  }
}

for (const file of productFiles) auditSwiftStructure(file);
for (const product of ["Agent", "Brain", "Code"]) auditCatalog(product);

requireFragments("Stores/AgentStore.swift", [
  "chargeUsage(product: .agent",
  "kind: .agentRun",
  "agentJobStatus(id:",
  "agentArtifact(jobID:",
  "firas.ios.agent-missions.v1",
  "scheduleLocalFallbackIfNeeded",
]);
requireFragments("Stores/CodeStore.swift", [
  "chargeUsage(product: .code",
  "kind: .codeBuild",
  "chatJobStatus(id:",
  "CodeProject.decode(fromJobText:",
  "firas.ios.code-builds.v1",
  "scheduleLocalFallbackIfNeeded",
]);
requireFragments("Stores/BrainStore.swift", [
  "brainDocuments()",
  "uploadBrainDocument",
  "deleteBrainDocument",
  "searchBrain",
  "brainPassage",
  "let maximumCharacters = 680_000",
  "let maximumRecords = 950",
  "docId: documentID",
  "ocr: index == 0 ? extracted.ocrPages : nil",
  "documentID = response.id",
]);

for (const store of ["Stores/AgentStore.swift", "Stores/CodeStore.swift"]) {
  const value = source(store);
  for (const forbidden of ["cancelChatJob", "onDisappear", "owningTask?.cancel()"] ) {
    if (value.includes(forbidden)) fail(`${store} contains forbidden lifecycle cancellation: ${forbidden}`);
  }
}

console.log(`CLEAN: ${productFiles.length} Swift files, 3 catalogs, durable product contracts`);
