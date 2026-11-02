// check.mjs — a host's profile against what the editor build offers (surface.json).
//
// A profile names the files a host embeds the editor from and the contract names it
// uses. Fails when:
//   - a source uses a contract name (a member, static, attribute, event, global,
//     class or token) the profile does not list;
//   - a source touches an internal name the profile does not list under
//     "internals", each with a reason: a private member the host does not define
//     itself, an internal class with an editor prefix (bp-, ProseMirror, tiptap,
//     hljs), an internal data-bp-* or data-pm-* attribute, an internal event, or
//     one of the ENGINE reach-ins below;
//   - the profile lists a name the contract does not have, or a name no source uses;
//   - a "notEditor" entry (a contract name the host's sources use for something
//     of their own, such as history.state or a link's target) has no reason, is
//     not a contract name, is also listed under "uses", or no source uses it;
//   - "fleet" disagrees with whether the host dispatches bp-fleet-paint;
//   - "minContract" is above the build's contract;
//   - the profile lacks host, root, minContract, fleet, sources or uses, or names a
//     source that does not exist.
// A member is matched as `.name` in scripts, HTML and HEEx, so a member of the same
// name on another object counts as a use unless "notEditor" names it, and then a
// real use of that name passes unseen. Comments are skipped in every source but
// Elixir; only the first use of each name is reported.
// No dependencies: hosts copy this file and surface.json, pinned by surface.build.
//
// Run: node check.mjs <host-profile.json> [surface.json]   (exit 1 on a failure,
// 2 without a profile or when a file cannot be read as JSON)

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED = ["host", "root", "minContract", "fleet", "sources", "uses"];
const MEMBER_SCANNED = /\.(?:[cm]?js|jsx|tsx?|html|heex)$/;
const SCANNED = /\.(?:[cm]?js|jsx|tsx?|css|html|heex|ex)$/;
const EDITOR_CLASS = /^(?:bp-|ProseMirror|prosemirror-|tiptap|hljs)/;
const EDITOR_ATTRIBUTE = /^data-(?:bp|pm)-/;
const ENGINE = [
  { name: "domObserver", what: "engine internal", pattern: /(?<![\w$-])domObserver(?![\w$-])/ },
  { name: "pmViewDesc", what: "engine internal", pattern: /(?<![\w$-])pmViewDesc(?![\w$-])/ },
  { name: "[contenteditable] query", what: "the editor's own DOM", pattern: /querySelector(?:All)?\(\s*["'`][^"'`]*\[contenteditable/ },
  { name: "[data-bp-id] > child", what: "the editor's own DOM", pattern: /\[data-bp-id[^\]]*\]\s*>/ },
];
const ATTRIBUTE_KINDS = new Set(["attribute", "ancestor attribute", "DOM attribute"]);
const CLASS_KINDS = new Set(["class", "host class"]);

const escape = (name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const camel = (name) => name.replace(/^data-/, "").replace(/-(\w)/g, (_, c) => c.toUpperCase());
const blank = (text) => text.replace(/[^\n]/g, "");
const stripComments = (text) => text.replace(/(^|\s)\/\*[\s\S]*?\*\//g, (comment, before) => before + blank(comment)).replace(/(^|[\s;{}),])\/\/.*$/gm, "$1");

const word = (name) => new RegExp(`(?<![\\w$-])${escape(name)}(?![\\w$-])`);
const member = (name) => new RegExp(`\\.${escape(name)}(?![\\w$-])`);
const defines = (name) => new RegExp(`(?:^|[\\s,{;])(?:async\\s+|static\\s+|get\\s+|set\\s+)*${escape(name)}\\s*(?:\\(|:)|this\\.${escape(name)}\\s*=(?!=)`);
const className = (name) => new RegExp([
  `\\.${escape(name)}(?![\\w-])`,
  `class(?:Name)?\\s*[=:]\\s*\\\\?["'{\`][^"'\`}]*(?<![\\w-])${escape(name)}(?![\\w-])`,
  `classList\\.\\w+\\([^)]*["'\`]${escape(name)}["'\`]`,
].join("|"));
const attribute = (name) => new RegExp([
  `(?<![\\w-])${escape(name)}=\\\\?["'{\`]`,
  `<[\\w-]+[^<>]*\\s${escape(name)}(?=[\\s/>])`,
  `["'\`]${escape(name)}["'\`]`,
  `\\[\\s*${escape(name)}(?![\\w-])`,
  ...(name.startsWith("data-") ? [`\\.dataset\\.${camel(name)}(?![\\w$])`] : []),
].join("|"));

const files = (root, sources) => sources.filter((source) => existsSync(path.join(root, source))).flatMap((source) => {
  const walk = (p) => statSync(p).isDirectory() ? readdirSync(p).sort().flatMap((n) => walk(path.join(p, n))) : SCANNED.test(p) ? [p] : [];
  return walk(path.join(root, source));
});

const firstUse = (texts, pattern, scriptsOnly) => {
  for (const { file, lines, script } of texts) {
    if (scriptsOnly && !script) continue;
    const at = lines.findIndex((line) => pattern.test(line));
    if (at !== -1) return `${file}:${at + 1}`;
  }
  return null;
};

const entries = (groups) => Object.entries(groups).flatMap(([element, kinds]) => Object.entries(kinds).flatMap(([kind, names]) => names.map((name) => ({ element, kind, name }))));

export function check(profile, surface, profileDir) {
  const missing = REQUIRED.filter((key) => profile[key] === undefined);
  if (missing.length) return missing.map((key) => `profile has no ${key}`);
  const root = path.resolve(profileDir, profile.root);
  const errors = profile.sources.filter((source) => !existsSync(path.join(root, source))).map((source) => `no such source: ${source}`);
  const texts = files(root, profile.sources).map((file) => {
    const raw = readFileSync(file, "utf8");
    const text = file.endsWith(".ex") ? raw : stripComments(raw);
    return { file: path.relative(root, file), lines: text.split("\n"), script: MEMBER_SCANNED.test(file) };
  });
  if (texts.length === 0) errors.push(`no source files under ${profile.sources.join(", ")}`);

  const contract = entries(surface.declared);
  const uses = entries(profile.uses);
  const listed = new Set(uses.map((u) => u.name));
  const pattern = ({ kind, name }) => kind === "member" ? member(name) : ATTRIBUTE_KINDS.has(kind) ? attribute(name) : CLASS_KINDS.has(kind) ? className(name) : word(name);

  for (const u of uses) {
    if (!contract.some((c) => c.element === u.element && c.kind === u.kind && c.name === u.name)) errors.push(`not in contract ${surface.contract}: ${u.element} ${u.kind} ${u.name}`);
    else if (!firstUse(texts, pattern(u), u.kind === "member")) errors.push(`listed but no source uses it: ${u.element} ${u.kind} ${u.name}`);
  }
  const elsewhere = new Set((profile.notEditor ?? []).flatMap((o) => o.names));
  for (const o of profile.notEditor ?? []) {
    if (!o.why) errors.push(`notEditor entry without a why: ${o.names.join(", ")}`);
  }
  for (const name of elsewhere) {
    const named = contract.filter((c) => c.name === name);
    if (named.length === 0) errors.push(`notEditor lists ${name}, which is not a contract name`);
    else if (listed.has(name)) errors.push(`notEditor lists ${name}, which uses also lists`);
    else if (!named.some((c) => firstUse(texts, pattern(c), c.kind === "member"))) errors.push(`notEditor lists ${name} but no source uses it`);
  }
  for (const c of contract) {
    if (listed.has(c.name) || elsewhere.has(c.name)) continue;
    const at = firstUse(texts, pattern(c), c.kind === "member");
    if (at) errors.push(`undeclared ${c.element} ${c.kind} ${c.name} at ${at}`);
  }

  const { members, classes, attributes, events } = surface.internal;
  const internal = [
    ...[...new Set([...members.canvas, ...members.editor])].filter((name) => !firstUse(texts, defines(name), true)).map((name) => ({ name, what: "private member", pattern: member(name), scriptsOnly: true })),
    ...classes.filter((name) => EDITOR_CLASS.test(name)).map((name) => ({ name, what: "internal class", pattern: className(name) })),
    ...attributes.filter((name) => EDITOR_ATTRIBUTE.test(name)).map((name) => ({ name, what: "internal attribute", pattern: attribute(name) })),
    ...events.map((name) => ({ name, what: "internal event", pattern: word(name) })),
    ...ENGINE,
  ];
  const allowed = new Set((profile.internals ?? []).flatMap((i) => i.names));
  for (const i of profile.internals ?? []) {
    if (!i.why) errors.push(`internals entry without a why: ${i.names.join(", ")}`);
  }
  for (const name of allowed) {
    const known = internal.find((i) => i.name === name);
    if (!known) errors.push(`internals lists ${name}, which is not internal to build ${surface.build}`);
    else if (!firstUse(texts, known.pattern, known.scriptsOnly)) errors.push(`internals lists ${name} but no source touches it`);
  }
  for (const i of internal) {
    if (allowed.has(i.name)) continue;
    const at = firstUse(texts, i.pattern, i.scriptsOnly);
    if (at) errors.push(`reach-in: ${i.what} ${i.name} at ${at}`);
  }

  const paints = listed.has("bp-fleet-paint");
  if (profile.fleet !== paints) errors.push(`fleet is ${profile.fleet} but the profile ${paints ? "lists" : "does not list"} bp-fleet-paint`);
  const version = (v) => v.split(".").map(Number);
  const [a, b] = [version(profile.minContract), version(surface.contract)];
  if (a.some(Number.isNaN) || a.length !== 3) errors.push(`minContract ${profile.minContract} is not major.minor.patch`);
  else if (a[0] > b[0] || (a[0] === b[0] && (a[1] > b[1] || (a[1] === b[1] && a[2] > b[2])))) errors.push(`minContract ${profile.minContract} is above the build's contract ${surface.contract}`);
  return errors;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [profilePath, surfacePath = path.join(path.dirname(fileURLToPath(import.meta.url)), "surface.json")] = process.argv.slice(2);
  if (!profilePath) {
    console.error("usage: node check.mjs <host-profile.json> [surface.json]");
    process.exit(2);
  }
  const read = (file) => {
    try {
      return JSON.parse(readFileSync(file, "utf8"));
    } catch (error) {
      console.error(`cannot read ${file}: ${error.message}`);
      process.exit(2);
    }
  };
  const profile = read(profilePath);
  const errors = check(profile, read(surfacePath), path.dirname(profilePath));
  for (const e of errors) console.log(`FAIL  ${profile.host}: ${e}`);
  if (errors.length) process.exit(1);
  console.log(`PASS  ${profile.host}: every editor name its sources use is in its profile`);
}
