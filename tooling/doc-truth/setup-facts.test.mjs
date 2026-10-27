// Tests for setup-facts.mjs: the extractor and matchers on small inputs, then
// planted wrong facts checked against this repo's real code.
//
//   node --test tooling/doc-truth/setup-facts.test.mjs

import { test, before } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  scanMarkdown, githubSlug, anchorsOf, setupSectionLines, extractFacts, routeMatches,
  parsePhoenixRouter, parsePlugRouter, codeDocLinks, parseAllow, applyAllow, nearest,
  editDistance, isOurHost, loadContext, checkDocText, formatFinding,
} from "./setup-facts.mjs";

const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: dirname(fileURLToPath(import.meta.url)) }).toString().trim();
const kinds = (facts, kind) => facts.filter((f) => f.kind === kind).map((f) => f.value);
const TICKS = "```";

// ── markdown ────────────────────────────────────────────────────────────────

test("scanMarkdown separates fences, spans and prose", () => {
  const lines = scanMarkdown(["a `x` b", TICKS + "bash", "echo `y`", TICKS, "<!-- `hidden` -->", "c"].join("\n"));
  assert.deepEqual(lines.map((l) => [l.line, l.fenced]), [[1, false], [3, true], [5, false], [6, false]]);
  assert.deepEqual(lines[0].spans, ["x"]);
  assert.equal(lines[1].lang, "bash");
  assert.deepEqual(lines[2].spans, []);
});

test("githubSlug follows GitHub's heading ids", () => {
  assert.equal(githubSlug("Path A: a single VM"), "path-a-a-single-vm");
  assert.equal(githubSlug("Set `BARKPARK_KEK` now"), "set-barkpark_kek-now");
  assert.equal(githubSlug("[Link](x.md) and *bold*"), "link-and-bold");
  assert.equal(githubSlug("Rotate keys / KEK"), "rotate-keys--kek");
});

test("anchorsOf numbers repeated headings and reads explicit ids", () => {
  const a = anchorsOf("# Top\n## Step\n## Step\n<a id=\"manual\"></a>\n## Custom {#own}\n" + TICKS + "\n## not a heading\n" + TICKS);
  for (const id of ["top", "step", "step-1", "manual", "own", "custom"]) assert.ok(a.has(id), id);
  assert.ok(!a.has("not-a-heading"));
});

test("setupSectionLines keeps only setup sections of a README", () => {
  const keep = setupSectionLines("# P\nintro\n## Get started\nrun\n### Sub\nmore\n## License\nMIT");
  assert.deepEqual([...keep], [3, 4, 5, 6]);
});

// ── extraction ──────────────────────────────────────────────────────────────

test("extractFacts finds env names in code and BARKPARK_* in prose", () => {
  const f = extractFacts("docs/setup/X.md", [
    "Set `DATABASE_URL` and BARKPARK_KEK in prose; plain WORD_IN_PROSE is ignored.",
    TICKS + "bash",
    'export PHX_HOST=x; echo "$CLIENT_ID" ${OTHER_VAR} $BARKPARK_TOKEN',
    TICKS,
    "Any `BARKPARK_S3_*` setting.",
  ].join("\n"));
  assert.deepEqual(kinds(f, "env").sort(), ["BARKPARK_KEK", "BARKPARK_S3_", "BARKPARK_TOKEN", "DATABASE_URL", "PHX_HOST"]);
});

test("extractFacts finds links, routes and repo paths", () => {
  const f = extractFacts("docs/setup/X.md", [
    "See [guide](SELF-HOST.md#pensum-settings) and [ext](https://example.org/a).",
    "[ref]: ../ops/x.md",
    "Open `https://<host>/v1/auth/oidc/<org>/start` or https://learn.microsoft.com/v1/x.",
    "Probe /livez, not /opt/barkpark/.env, and `/studio/new`.",
    "Run `scripts/doc-drift-check.sh:12` and `config/runtime.exs`; not `.cursor/mcp.json` or `~/x/y.md`.",
  ].join("\n"), { routeFirst: new Set(["studio"]), topLevel: new Set(["scripts", "api"]) });
  assert.deepEqual(kinds(f, "link"), ["SELF-HOST.md#pensum-settings", "https://example.org/a", "../ops/x.md"]);
  assert.deepEqual(kinds(f, "route").sort(), ["/livez", "/studio/new", "/v1/auth/oidc/<org>/start"]);
  assert.deepEqual(kinds(f, "path"), ["scripts/doc-drift-check.sh", "config/runtime.exs"]);
  assert.equal(f.find((x) => x.value === "config/runtime.exs").anchored, false);
});

test("extractFacts skips a path the doc says does not exist", () => {
  const f = extractFacts("docs/setup/X.md", "There is no `/register`.\nthere is no\nworkspace-scoped `/w/a/v1/graph` twin. Use `/v1/x`, not /opt/y, and `/v1/z`.", { routeFirst: new Set(["register", "w"]) });
  assert.deepEqual(kinds(f, "route"), ["/v1/x", "/v1/z"]);
});

test("extractFacts honours the line filter", () => {
  const f = extractFacts("README.md", "`BARKPARK_A`\n`BARKPARK_B`", { inScope: (ln) => ln === 2 });
  assert.deepEqual(kinds(f, "env"), ["BARKPARK_B"]);
});

test("isOurHost accepts placeholders and local hosts only", () => {
  for (const h of ["<host>", "{server}", "$HOST", "localhost:4000", "127.0.0.1", "api.example.com"]) assert.ok(isOurHost(h), h);
  for (const h of ["github.com", "learn.microsoft.com", "portal.azure.com"]) assert.ok(!isOurHost(h), h);
});

// ── routers ─────────────────────────────────────────────────────────────────

const ROUTER = `
defmodule R do
  scope "/v1/auth", W do
    pipe_through(:api)
    get("/oidc/:org/start", C, :start)
    post(
      "/oidc/:org/callback",
      C,
      :cb
    )
    scope "/nested" do
      get "/deep", C, :d
    end
  end
  scope "/", W do
    get("/livez", S, :live)
    forward "/mcp", Plug
  end
  scope "/v1/plugins" do
    plugin_routes(scope: :api)
  end
end`;

test("parsePhoenixRouter joins nested scopes, multi-line calls and plugin routes", () => {
  const r = parsePhoenixRouter(ROUTER, "router.ex", [{ path: "/tasks/:id", at: "p.ex:1" }]);
  assert.deepEqual(r.map((x) => x.path), ["/v1/auth/oidc/:org/start", "/v1/auth/oidc/:org/callback", "/v1/auth/nested/deep", "/livez", "/mcp", "/v1/plugins/tasks/:id"]);
  assert.equal(r.find((x) => x.path === "/mcp").prefix, true);
});

test("parsePlugRouter reads flat routes", () => {
  const r = parsePlugRouter('  get "/health" do\n  post("/v1/launch", x)\n  match _ do', "c.ex");
  assert.deepEqual(r.map((x) => x.path), ["/health", "/v1/launch"]);
});

test("routeMatches handles params, placeholders, prefixes and mounts", () => {
  const r = parsePhoenixRouter(ROUTER, "router.ex", []);
  assert.ok(routeMatches("/v1/auth/oidc/<org>/start", r));
  assert.ok(routeMatches("/v1/auth/oidc/acme/callback", r));
  assert.ok(routeMatches("/v1/auth", r), "a prefix of a route");
  assert.ok(routeMatches("/mcp/anything", r), "under a forward");
  assert.ok(routeMatches("/v1/auth/*", r));
  assert.ok(!routeMatches("/v1/auth/oidc/<org>/begin", r));
  assert.ok(!routeMatches("/livez/extra", r));
  assert.ok(!routeMatches("/readyz", r));
});

// ── code link constants ─────────────────────────────────────────────────────

test("codeDocLinks reads string literals and skips comments", () => {
  const go = codeDocLinks("x.go", [
    '// see "docs/setup/A.md#gone"',
    'const d = "docs/setup/A.md#here"',
    'u := "https://github.com/FRIKKern/barkpark/blob/main/docs/setup/B.md#b"',
  ].join("\n"));
  assert.deepEqual(go.map((l) => [l.line, l.target]), [[2, "docs/setup/A.md#here"], [3, "docs/setup/B.md#b"]]);
  const ex = codeDocLinks("x.ex", ['  @moduledoc """', '  "docs/in/doc.md"', '  """', '  # "docs/c.md"', '  @url "docs/setup/C.md"'].join("\n"));
  assert.deepEqual(ex.map((l) => l.target), ["docs/setup/C.md"]);
});

// ── allow-list ──────────────────────────────────────────────────────────────

test("parseAllow wants a task or a label and a reason", () => {
  const e = parseAllow("# c\ndocs/a.md | env | X_Y | task-0123456789abcdef | wrong name\ndocs/b.md | env | Z_Q | external | set by Copilot\n");
  assert.equal(e.length, 2);
  assert.equal(e[1].task, "external");
  assert.throws(() => parseAllow("docs/a.md | env | X | | why"), /want/);
  assert.throws(() => parseAllow("docs/a.md | env | X | task-1 | why"), /want/);
  assert.throws(() => parseAllow("docs/a.md | env | X | task-0123456789abcdef |"), /want/);
});

test("applyAllow splits fresh, allowed and stale, ignoring line numbers", () => {
  const entries = parseAllow("a.md | env | A_B | task-0123456789abcdef | x\nb.md | env | GONE_X | task-0123456789abcdef | y");
  const { fresh, allowed, stale } = applyAllow([
    { file: "a.md", line: 9, kind: "env", value: "A_B" },
    { file: "a.md", line: 3, kind: "env", value: "NEW_X" },
  ], entries);
  assert.deepEqual(allowed.map((f) => f.value), ["A_B"]);
  assert.deepEqual(fresh.map((f) => f.value), ["NEW_X"]);
  assert.deepEqual(stale.map((e) => e.value), ["GONE_X"]);
});

test("nearest picks the closest candidate", () => {
  assert.equal(editDistance("kitten", "sitting"), 3);
  assert.equal(nearest("BARKPARK_API_TOKN", ["BARKPARK_API_TOKEN", "BARKPARK_API_URL"]), "BARKPARK_API_TOKEN");
});

// ── planted facts against this repo ─────────────────────────────────────────

let ctx;
before(async () => { ctx = await loadContext(ROOT); });

const PLANTED = [
  /* 1 */ "Set `BARKPARK_API_TOKEN` and `BARKPARK_NOT_A_REAL_SETTING`.",
  /* 2 */ "Run `bp login --email a@b.c` and `bp login --no-such-flag-here`.",
  /* 3 */ "Run `bp nosuchnoun ls` and `bp task nosuchverb`.",
  /* 4 */ "Run `bp org create acme Acme` and `bp onramp cursor --write`.",
  /* 5 */ "Probe `/livez` and `https://<host>/v1/auth/oidc/<org>/start`, then `/v1/auth/oidc/<org>/begin`.",
  /* 6 */ "Run `scripts/doc-drift-check.sh`, not `scripts/no-such-script-here.sh`.",
  /* 7 */ "See [ok](../../tooling/doc-truth/README.md#what-it-does) and [bad](../../tooling/doc-truth/README.md#no-such-heading).",
  /* 8 */ "See [missing](./NO-SUCH-DOC.md).",
].join("\n");

test("sources load from this repo", () => {
  assert.ok(ctx.ok, (ctx.errors || []).join("; "));
  assert.ok(ctx.rt.routes.length > 500);
  assert.ok(ctx.env.has("BARKPARK_API_TOKEN"));
});

test("every planted wrong fact is caught, and nothing else", () => {
  const found = checkDocText(ctx, "docs/setup/PLANTED.md", PLANTED);
  const got = found.map((f) => `${f.line} ${f.kind} ${f.value}`).sort();
  assert.deepEqual(got, [
    "1 env BARKPARK_NOT_A_REAL_SETTING",
    "2 flag --no-such-flag-here",
    "3 cmd bp nosuchnoun",
    "3 cmd bp task nosuchverb",
    "5 route /v1/auth/oidc/<org>/begin",
    "6 path scripts/no-such-script-here.sh",
    "7 link ../../tooling/doc-truth/README.md#no-such-heading",
    "8 link ./NO-SUCH-DOC.md",
  ].sort(), found.map(formatFinding).join("\n"));
});

test("findings name the nearest correct value", () => {
  const found = checkDocText(ctx, "docs/setup/PLANTED.md", "`BARKPARK_API_TOKN` and `bp task claimm` and `/readyzz`");
  const by = Object.fromEntries(found.map((f) => [f.kind, f.nearest]));
  assert.equal(by.env, "BARKPARK_API_TOKEN");
  assert.equal(by.cmd, "bp task claim");
  assert.equal(by.route, "/readyz");
  assert.match(formatFinding(found[0]), /^docs\/setup\/PLANTED\.md:1: \w+: .*; nearest: /);
});
