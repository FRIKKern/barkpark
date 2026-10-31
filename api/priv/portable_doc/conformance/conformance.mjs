import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const HERE = import.meta.dirname ?? __dirname;
export const PACK = join(HERE, "..", "goldens");
export const MISSING = Symbol("missing");

const VARIABLE_ATTRS = new Set(["href", "src", "srcset", "poster", "id"]);
const SIZING_HINT_TAGS = new Set(["img", "video", "audio", "iframe", "source", "embed", "canvas", "object"]);
const DIFF_CAP = 12;

export function loadPack(dir = PACK) {
  const stampPath = join(dir, "stamp.json");
  const blocksDir = join(dir, "blocks");
  if (!existsSync(stampPath)) throw new Error(`no golden pack at ${dir}`);
  const cases = readdirSync(blocksDir)
    .filter((f) => f.endsWith(".golden.json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(blocksDir, f), "utf8")));
  if (cases.length === 0) throw new Error(`golden pack at ${dir} has zero block cases`);
  return { stamp: packStamp(dir), cases };
}

export function packStamp(dir = PACK) {
  return createHash("sha256").update(readFileSync(join(dir, "stamp.json"))).digest("hex");
}

const squash = (s) => s.replace(/\s+/g, " ").trim();

function parseStyle(raw) {
  const out = {};
  for (const decl of (raw || "").split(";")) {
    const at = decl.indexOf(":");
    if (at === -1) continue;
    const prop = decl.slice(0, at).trim().toLowerCase();
    if (prop) out[prop] = squash(decl.slice(at + 1));
  }
  return out;
}

function element(el) {
  const tag = el.localName.toLowerCase();
  const attrs = {};
  for (const { name, value } of Array.from(el.attributes)) {
    const key = name.toLowerCase();
    if (key === "class" || key === "style" || VARIABLE_ATTRS.has(key)) continue;
    if ((key === "width" || key === "height") && SIZING_HINT_TAGS.has(tag)) continue;
    attrs[key] = squash(value);
  }
  const classes = [...new Set(el.classList)].sort();
  const children = tag === "template" && el.content ? el.content.childNodes : el.childNodes;
  return { tag, classes, attrs, style: parseStyle(el.getAttribute("style")), children: shapeOf(children) };
}

export function shapeOf(nodes) {
  const out = [];
  let text = null;
  const flush = () => {
    if (text !== null && squash(text)) out.push({ text: squash(text) });
    text = null;
  };
  for (const node of Array.from(nodes)) {
    if (node.nodeType === 3) text = (text ?? "") + node.nodeValue;
    else if (node.nodeType === 1) {
      flush();
      out.push(element(node));
    }
  }
  flush();
  return out;
}

const label = (n) => ("text" in n ? "#text" : n.classes.length ? `${n.tag}.${n.classes.join(".")}` : n.tag);

function diffMap(a, b, path, kind, out) {
  for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
    if (!(k in a)) out.push(`${path}: ${kind} ${k}="${b[k]}" missing`);
    else if (!(k in b)) out.push(`${path}: ${kind} ${k}="${a[k]}" extra`);
    else if (a[k] !== b[k]) out.push(`${path}: ${kind} ${k} "${a[k]}" != "${b[k]}"`);
  }
}

function diffList(actual, golden, path, out) {
  if (actual.length !== golden.length)
    out.push(`${path}: ${actual.length} children [${actual.map(label)}] != ${golden.length} [${golden.map(label)}]`);
  for (let i = 0; i < Math.min(actual.length, golden.length); i++) diffNode(actual[i], golden[i], `${path} > ${label(golden[i])}[${i}]`, out);
}

function diffNode(a, b, path, out) {
  if ("text" in a || "text" in b) {
    if (a.text !== b.text) out.push(`${path}: ${"text" in a ? `"${a.text}"` : `<${a.tag}>`} != ${"text" in b ? `"${b.text}"` : `<${b.tag}>`}`);
    return;
  }
  if (a.tag !== b.tag) return void out.push(`${path}: <${a.tag}> != <${b.tag}>`);
  if (a.classes.join(" ") !== b.classes.join(" ")) out.push(`${path}: class {${a.classes.join(" ")}} != {${b.classes.join(" ")}}`);
  diffMap(a.attrs, b.attrs, path, "attr", out);
  diffMap(a.style, b.style, path, "style", out);
  diffList(a.children, b.children, path, out);
}

export function diffShapes(actual, golden) {
  const out = [];
  diffList(actual, golden, "root", out);
  return out;
}

const words = (s) =>
  s
    .toLowerCase()
    .split(/\s+/)
    .map((w) => w.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, ""))
    .filter(Boolean);

export function goldenWords(shape) {
  const leaves = [];
  const walk = (nodes) => nodes.forEach((n) => ("text" in n ? leaves.push(n.text) : walk(n.children)));
  walk(shape);
  return words(leaves.join(" "));
}

export function diffWords(actualText, expected) {
  const seen = words(actualText);
  const out = [];
  let at = 0;
  expected.forEach((word, i) => {
    const found = seen.indexOf(word, at);
    if (found === -1) out.push(`word ${i + 1}/${expected.length} "${word}" not found in order`);
    else at = found + 1;
  });
  return out;
}

function row(type, verdict) {
  if (verdict === MISSING) return { type, status: "missing" };
  if (verdict.length === 0) return { type, status: "pass" };
  const diff = verdict.length > DIFF_CAP ? [...verdict.slice(0, DIFF_CAP), `… ${verdict.length - DIFF_CAP} more`] : verdict;
  return { type, status: "fail", diff };
}

function headSha() {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: HERE, encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

export async function conform({ renderer, compare, judge, pack = PACK }) {
  const { stamp, cases } = loadPack(pack);
  const probe = { type: "conformance-unknown", input: { type: "conformance-unknown" }, expectedHtml: "", shape: [] };
  if ((await judge(probe)) !== MISSING) throw new Error("the runner cannot see a missing type: an unknown block did not read as missing");
  const rows = [];
  for (const c of cases) rows.push(row(c.type, await judge(c)));
  return { renderer, compare, pack_stamp: stamp, ran_at_sha: headSha(), rows };
}

export const reportPath = (renderer) => join(HERE, `${renderer}.json`);

export function settle(report, { write = false, strict = false, path = reportPath(report.renderer) } = {}) {
  const problems = [];
  if (write) writeFileSync(path, JSON.stringify(report, null, 2) + "\n");
  else if (!existsSync(path)) problems.push(`${path} is not committed; run with CONFORMANCE_WRITE=1`);
  else {
    const committed = JSON.parse(readFileSync(path, "utf8"));
    for (const key of ["renderer", "compare", "pack_stamp"])
      if (committed[key] !== report[key]) problems.push(`${key}: committed ${committed[key]} != now ${report[key]}`);
    const before = new Map(committed.rows.map((r) => [r.type, JSON.stringify(r)]));
    for (const r of report.rows) if (before.get(r.type) !== JSON.stringify(r)) problems.push(`row ${r.type} drifted: committed ${before.get(r.type) ?? "absent"} now ${JSON.stringify(r)}`);
    if (committed.rows.length !== report.rows.length) problems.push(`committed ${committed.rows.length} rows, pack has ${report.rows.length}`);
  }
  if (strict) for (const r of report.rows) if (r.status !== "pass") problems.push(`strict: ${r.type} is ${r.status}`);
  return problems;
}

export function counts(report) {
  const c = { pass: 0, fail: 0, missing: 0 };
  for (const r of report.rows) c[r.status]++;
  return c;
}

export const modeFromEnv = (env = process.env) => ({ write: env.CONFORMANCE_WRITE === "1", strict: env.CONFORMANCE_STRICT === "1" });

export async function cli(options) {
  try {
    const report = await conform(options);
    const problems = settle(report, modeFromEnv());
    const c = counts(report);
    console.log(`${report.renderer}: ${c.pass} pass, ${c.fail} fail, ${c.missing} missing of ${report.rows.length}`);
    for (const p of problems) console.error(p);
    process.exitCode = problems.length ? 1 : 0;
  } catch (e) {
    console.error(`${options.renderer}: ${e.message}`);
    process.exitCode = 1;
  }
}
