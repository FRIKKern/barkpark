// level.mjs — the pure authority-level grammar over the `rerun` command string.
//
// The load-bearing inversion (charter D1/D2): authority level is DERIVED by
// this program from the shape of the ONE literal shell command that re-derives
// a fact — and can never be raised by what the author claims. The `evidence`
// narrative is L6 BY CONSTRUCTION: nothing in this module ever reads it. A
// prose-scanning extractor was built first and measured against 60
// hand-labelled real evidence strings: L1/L2 precision 0.67 — it stamped L1 on
// a string beginning "OPEN — requires a run against the deployed build" and on
// a local source read whose file merely CONTAINED an https:// literal. Markers
// fire on MENTION; this grammar levels only the INVOCATION.
//
// The ladder (ratified in /papers/survey-once-build-forever):
//   L1  running system   — ssh to a host, curl to a non-loopback host
//   L2  origin/main      — git show <remote-ref>:<path>, gh api
//   L3  local checkout   — local read, scoped grep, local test, node <script>
//   L4  generated artifact — a read whose target is a known emitted path
//   L5  charters / docs  — never derived here; reading a doc locally is
//                          mechanically L3 (the ladder keeps the slot)
//   L6  no command       — or a command the grammar cannot classify
//
// The derived level is a CEILING (D2). A missing command DEMOTES to L6, never
// rejects (D3) — the honest path must stay the cheap one. What this grammar
// certifies is RE-DERIVABILITY of a fact from its command — never that the
// author actually ran it; authorship is outside its jurisdiction (D4).
//
// Pure, dependency-free, no side effect on import. ESM named exports only.

// Ordered ladder. Lower rank = higher authority. Exported so callers compare
// via rank, never by string arithmetic.
export const LEVELS = Object.freeze({
  L1: 1,
  L2: 2,
  L3: 3,
  L4: 4,
  L5: 5,
  L6: 6,
});

// --- host classification -----------------------------------------------------

// Loopback hosts a curl can hit without leaving the laptop. A loopback curl is
// a read of the LOCAL running dev system — a claim about the local checkout,
// so it derives L3, never L1.
const LOOPBACK_HOST = /^(localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[?::1\]?)$/i;

// scheme://host[:port] extractor — first URL-shaped token in the command.
const URL_TOKEN = /\b[a-z][a-z0-9+.-]*:\/\/([^/\s:'"]+)/gi;

// --- generated-artifact paths (L4) -------------------------------------------

// A read whose TARGET is one of these is a read of an emitted artifact, not of
// source: it derives L4. Exported so later slices (the adjudicator, the
// executor) share one list instead of forking it.
export const GENERATED_ARTIFACT_PATTERNS = Object.freeze([
  /(^|\/)docs\/openapi\.json$/,
  /(^|\/)design\/(dist|out|generated|emitted)\//,
  /\.golden\.json$/,
  /(^|\/)tooling\/[^/\s]+\/[^/\s]+-report\.json$/,
]);

function isGeneratedArtifactPath(token) {
  return GENERATED_ARTIFACT_PATTERNS.some((re) => re.test(token));
}

// --- command-shape predicates ------------------------------------------------

// ssh: ALLOW FLAGS between `ssh` and the `user@host` — an adjacency regex
// false-demoted a genuine `ssh -o BatchMode=yes … root@…` read during
// verification. The ratified pattern is /\bssh\b[^\n]*@/ (charter D2). The
// zero-false-demotion bar on honest flag-bearing invocations outranks the
// residual promotion risk of an `@` elsewhere on the line.
const SSH_READ = /\bssh\b[^\n]*@/;

// git show against a REMOTE ref (origin/…, upstream/…, refs/remotes/…) is an
// L2 read of what the remote actually holds. `git show HEAD:…` or a local
// branch is a read of the local checkout's object store — L3.
const GIT_SHOW_REMOTE = /\bgit\s+show\s+(?:['"]?)(?:refs\/remotes\/|origin\/|upstream\/)\S*:/;
const GH_API = /\bgh\s+api\b/;

// Local readers / scoped search / local runs — the L3 family. Head-token
// oriented: we look at the first command word (after env assignments and
// harmless wrappers) plus a few whole-line runners.
const L3_HEADS = new Set([
  "cat", "head", "tail", "less", "more", "sed", "awk", "cut", "sort", "uniq",
  "wc", "ls", "stat", "file", "diff", "jq", "grep", "rg", "ag", "find",
  "node", "go", "mix", "npm", "pnpm", "yarn", "make", "elixir", "python",
  "python3", "bash", "sh", "zsh", "git", "tree", "shasum", "md5", "openssl",
]);

// Strip leading env assignments (`FOO=bar cmd`) and harmless prefix wrappers
// so `timeout 10 grep …` still levels on `grep`.
const PREFIX_WRAPPERS = new Set(["timeout", "time", "env", "nice", "xargs", "sudo"]);

function headToken(command) {
  const tokens = command.trim().split(/\s+/);
  let i = 0;
  while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i += 1;
  while (i < tokens.length) {
    const bare = tokens[i].replace(/^.*\//, ""); // basename for /usr/bin/grep
    if (PREFIX_WRAPPERS.has(bare)) {
      i += 1;
      // `timeout 10 cmd` — skip a numeric duration argument
      if (i < tokens.length && /^\d+[smh]?$/.test(tokens[i])) i += 1;
      continue;
    }
    return { head: bare, rest: tokens.slice(i + 1) };
  }
  return { head: "", rest: [] };
}

// Non-loopback URL anywhere in the command (curl/wget/http reads).
function firstRemoteUrlHost(command) {
  URL_TOKEN.lastIndex = 0;
  let m;
  while ((m = URL_TOKEN.exec(command)) !== null) {
    const host = m[1];
    if (!LOOPBACK_HOST.test(host)) return host;
  }
  return null;
}

// --- deriveLevel -------------------------------------------------------------

// deriveLevel(rerun) → "L1" | "L2" | "L3" | "L4" | "L6"
//
// PURE over the command string alone. It never receives — and must never be
// handed — the evidence prose, the claim, or any narrative field. Unknown
// shapes DEMOTE to L6 (D3); nothing here throws on honest input.
export function deriveLevel(rerun) {
  if (typeof rerun !== "string" || rerun.trim() === "") return "L6";
  const command = rerun.trim();

  // L1 — a running system was touched.
  if (SSH_READ.test(command)) return "L1";
  const { head, rest } = headToken(command);
  if ((head === "curl" || head === "wget") && firstRemoteUrlHost(command)) return "L1";

  // L2 — origin/main (or another remote) was read.
  if (GIT_SHOW_REMOTE.test(command) || GH_API.test(command)) return "L2";

  // L4 — the read's TARGET is a known generated artifact. Checked before the
  // generic L3 family: `cat docs/openapi.json` is an artifact read, not a
  // source read. Only reader-shaped heads qualify — `node design/emit.mjs`
  // REGENERATES an artifact (a local run, L3), it does not read one.
  const READER_HEADS = new Set(["cat", "head", "tail", "less", "more", "jq", "grep", "rg", "sed", "awk", "wc", "diff"]);
  if (READER_HEADS.has(head) && rest.some((t) => isGeneratedArtifactPath(t.replace(/^['"]|['"]$/g, "")))) {
    return "L4";
  }

  // L3 — local checkout: reads, scoped grep, local tests, node <script>,
  // loopback curl (the local dev server is a property of the checkout).
  if (head === "curl" || head === "wget") return "L3"; // loopback-only URL
  if (L3_HEADS.has(head)) return "L3";
  if (/^\.?\.?\//.test(head)) return "L3"; // ./script.sh, ../bin/tool, /path/tool

  // Unclassifiable — demoted, never rejected (D3).
  return "L6";
}

// --- checkCeiling ------------------------------------------------------------

// The derived level is a CEILING. A claim ABOVE it (numerically lower rank —
// higher authority) is a LEVEL-SKIP and is REJECTED, naming both levels.
// Equal or below is accepted: an author may honestly under-claim.
export function checkCeiling(claimed, derived) {
  const claimedRank = LEVELS[claimed];
  const derivedRank = LEVELS[derived];
  if (claimedRank === undefined) {
    return { ok: false, reason: "UNKNOWN-LEVEL", message: `UNKNOWN-LEVEL: claimed level ${JSON.stringify(claimed)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`, claimed, derived };
  }
  if (derivedRank === undefined) {
    return { ok: false, reason: "UNKNOWN-LEVEL", message: `UNKNOWN-LEVEL: derived level ${JSON.stringify(derived)} is not on the ladder ${Object.keys(LEVELS).join(" ")}`, claimed, derived };
  }
  if (claimedRank < derivedRank) {
    return {
      ok: false,
      reason: "LEVEL-SKIP",
      message: `LEVEL-SKIP: claimed ${claimed} above derived ${derived} — the rerun command re-derives this fact at ${derived}; a ${claimed} claim needs a ${claimed}-shaped command`,
      claimed,
      derived,
    };
  }
  return { ok: true, claimed, derived, level: claimed };
}

// --- classifyRef -------------------------------------------------------------

// A path:line reference MUST carry a directory component. A bare
// `notifications.ex:389-397` sent a verifier to api/lib and returned empty —
// the real file was cloud/lib/barkpark_cloud/notifications.ex. Ambiguity in a
// reference is a wrong value waiting to be read.
const PATH_LINE_REF = /^(?<path>[^:\s]+):(?<start>\d+)(?:-(?<end>\d+))?$/;

export function classifyRef(ref) {
  if (typeof ref !== "string" || ref.trim() === "") {
    return { ok: false, reason: "NOT-A-REF", message: "NOT-A-REF: empty or non-string reference", ref };
  }
  const m = PATH_LINE_REF.exec(ref.trim());
  if (!m) {
    return { ok: false, reason: "NOT-A-REF", message: `NOT-A-REF: ${JSON.stringify(ref)} is not <path>:<line>[-<line>]`, ref };
  }
  const { path, start, end } = m.groups;
  if (!path.includes("/")) {
    return {
      ok: false,
      reason: "PATHLESS-REF",
      message: `PATHLESS-REF: ${JSON.stringify(ref)} has no directory component — a bare filename resolves against whichever tree the reader happens to stand in`,
      ref,
    };
  }
  return { ok: true, path, lines: { start: Number(start), end: end ? Number(end) : Number(start) } };
}

// --- isDiscretePredicate -----------------------------------------------------

// D7: only DISCRETE predicates are admissible. A continuous measurement (a
// float with a time unit — duration, latency) drifts run to run: one L1 curl
// returned a stable code=200 while t_total moved 0.116 / 0.135 / 0.118 across
// three runs. Such a quantity is admissible only when the claim declares a
// PREDICATE over it (a threshold comparison), which collapses the
// distribution to a boolean. Callers flag a false return as
// INADMISSIBLE-CONTINUOUS.
const CONTINUOUS_MEASUREMENT = /\b\d+\.\d+\s*(?:s|ms|us|µs|ns|sec|secs|seconds|millis|milliseconds|minutes?)\b/i;
const BARE_FLOAT_TIMEY = /\bt_(?:total|connect|ttfb|pretransfer|starttransfer)\b[^\n]*?\b\d+\.\d+\b|\b\d+\.\d+\b[^\n]*?\bt_(?:total|connect|ttfb|pretransfer|starttransfer)\b/i;
const THRESHOLD_PREDICATE = /(?:<=|>=|<|>|\bunder\b|\bover\b|\bbelow\b|\babove\b|\bat\s+most\b|\bat\s+least\b|\bwithin\b)/i;

export function isDiscretePredicate(claim) {
  if (typeof claim !== "string" || claim.trim() === "") return true; // nothing continuous declared
  const continuous = CONTINUOUS_MEASUREMENT.test(claim) || BARE_FLOAT_TIMEY.test(claim);
  if (!continuous) return true;
  return THRESHOLD_PREDICATE.test(claim);
}
