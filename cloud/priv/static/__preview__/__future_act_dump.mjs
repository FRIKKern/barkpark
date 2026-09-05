// __future_act_dump.mjs — print every DEFERRED-ACT sentence the console's
// shipped copy makes, as JSON.
//
// THE POPULATION MECHANISM the promise-actor register did not have
// (cch-w56-bl). `promise_actor_manifest_test.exs` pins, per promise, whether a
// CLOCK reaches its day, an ACTOR runs on it, and an EFFECT is producible. Until
// this script every arm of that register iterated `@register`, so the only
// promises it could be wrong about were the ones somebody had already written
// down: a new deferred promise appearing in `app.js` was neither "verified
// absent" nor "verified present" — it was UNEXAMINED, and the register stayed
// green while it rotted. This script is the ADD direction's input.
//
// ── WHY THIS ONE READS SOURCE TEXT AND ITS SIBLINGS DO NOT ─────────────────
//
// `__plan_features_dump.mjs` CALLS `planFeatures(tier)` in a node:vm sandbox
// because the thing it wants is the return value of one exported pure function.
// There is no such function here. The sentences this script hunts are string
// literals spliced into HTML inside render functions and toast bodies across
// ~27k lines — reaching them by RUNNING would mean rendering every screen in
// every state, which is `smoke.mjs`'s job and still would not enumerate the
// branches nobody wrote a scenario for. So this is a COPY CENSUS over the
// shipped file, which is exactly what the register's own moduledoc said the
// widening would take: "Widening it is a copy census's job, not a resolver's."
//
// A census is not a resolver and this script claims nothing about whether a
// promise is KEPT. It answers one question — WHICH deferred-act sentences does
// the shipped console contain — and the Elixir side decides what that means.
//
// ── THE LEXER, AND WHY IT HAS A SELF-TEST ─────────────────────────────────
//
// It is a real lexer, not a regex sweep: it tracks line/block comments, all
// three quote forms, escapes, `${…}` interpolation, and — the hard one —
// regex literals, which contain arbitrary quote characters that a naive scan
// mistakes for the start of a string and then desynchronises on for the rest of
// the file. `scripts/console-tdz-order-check.mjs` shipped a v1 that mis-lexed
// exactly this and reported `crossings: 0, exit 0` on a file with five live
// crossings, so a heuristic lexer that fails toward green must be MADE to lose
// on a known fixture before its green means anything. `--selftest` runs the
// lexer over an embedded fixture holding every construct above and compares the
// extracted literals against a pinned list; any drift exits 3 and the census
// never runs.
//
// ── WHAT COUNTS AS A DEFERRED ACT ─────────────────────────────────────────
//
// The register's thesis is a promise "that something WILL happen on a day
// nobody is watching" — an act tied to a DEADLINE or a BOUNDARY. That is
// narrower than "any future tense", deliberately: "The instance will restart."
// is a future act, but it is one the user is watching happen and it has no
// clock. `@vocabulary` below is the closed list of deadline constructions, and
// the narrowing is a SCOPE claim the Elixir side republishes rather than a
// filter tuned until the answer was convenient.
//
// ── CONCATENATION ─────────────────────────────────────────────────────────
//
// Console copy is written as `"We'll remind you " + phrase + " before the trial
// ends."`. Read literal-by-literal that promise is invisible: neither half
// carries the sentence. So adjacent literals joined by `+` are GLUED, and a
// non-literal operand in the chain becomes a `…` placeholder — the sentence
// survives with its variable part marked, which is what a census wants.
//
// Output on stdout: [{sentence, lines: [int]}], sorted by sentence.
//
// Exit codes — a census that cannot read a side must RED, never print `[]`:
//   2 — app.js is unreadable
//   3 — the lexer lost its own self-test fixture
//   4 — the lexer found ZERO string literals in app.js (it desynchronised)
// A run that finds literals but NO deferred-act sentence exits 0 with `[]`;
// that is a real answer and the register's DELETE arm is what reds on it.
//
// Not web-reachable: BarkparkCloud.Web.Router's Plug.Static uses an explicit
// `only:` allowlist and __preview__/ is not in it (pinned by
// cloud/test/web/static_allowlist_test.exs).
//
// Run: node cloud/priv/static/__preview__/__future_act_dump.mjs [--selftest]

import fs from "node:fs";

// ── The lexer ──────────────────────────────────────────────────────────────

// A `/` starts a regex literal only where an EXPRESSION may begin. The decision
// is made from the previous significant character: after an identifier, a
// number, a string, `)`, `]` or `}` it is division; anywhere else it opens a
// regex. `}` is the known-imperfect case (a block close may be followed by a
// regex) and it is resolved toward DIVISION, because the fixture below proves
// the choice and app.js contains no `}`-then-regex site; a wrong guess there
// would desynchronise and exit 4 rather than silently shrink the census.
function startsRegex(prevSignificant) {
  if (prevSignificant === null) return true;
  return !/[)\]}\w$'"`]/.test(prevSignificant);
}

// Returns [{text, line, glued}] — one entry per string/template literal, with
// `+`-adjacent literals already GLUED into a single entry.
//
// THE GLUE RULE, stated because it is the part that can be wrong quietly.
// A concat chain opens at a literal and survives a `+`. What follows the `+`
// may be another literal (appended verbatim) or an expression (appended as the
// `…` placeholder). The chain CLOSES at the end of the enclosing expression:
// `;`, a `,` / `:` / `=` / `?` at paren-depth zero, a `}`, or a `)` / `]` that
// would drop below the depth the chain opened at. Depth is tracked so
// `'<b>' + esc(email) + '</b>'` glues through the call it interpolates —
// without that, every sentence written around a variable is invisible, which
// is most of the console's promises.
function literals(src) {
  const out = [];
  let i = 0;
  let line = 1;
  let prev = null;

  let chain = null; // {text, line, glued}
  let depth = 0; // paren/bracket depth INSIDE the open chain
  let pendingPlus = false; // a `+` is waiting for its right operand
  let nonLiteralOperand = false; // …and something that is not a literal appeared

  const closeChain = () => {
    if (chain) out.push(chain);
    chain = null;
    depth = 0;
    pendingPlus = false;
    nonLiteralOperand = false;
  };

  const pushLiteral = (text, atLine) => {
    if (chain && pendingPlus) {
      if (nonLiteralOperand) chain.text += "…";
      chain.text += text;
      chain.glued = true;
      pendingPlus = false;
      nonLiteralOperand = false;
      return;
    }
    closeChain();
    chain = { text, line: atLine, glued: false };
  };

  while (i < src.length) {
    const c = src[i];

    if (c === "\n") {
      line++;
      i++;
      continue;
    }
    if (c === " " || c === "\t" || c === "\r") {
      i++;
      continue;
    }
    if (c === "/" && src[i + 1] === "/") {
      while (i < src.length && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && src[i + 1] === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) {
        if (src[i] === "\n") line++;
        i++;
      }
      i += 2;
      continue;
    }
    if (c === "/" && startsRegex(prev)) {
      i++;
      let inClass = false;
      while (i < src.length) {
        const d = src[i];
        if (d === "\\") {
          i += 2;
          continue;
        }
        if (d === "[") inClass = true;
        else if (d === "]") inClass = false;
        else if (d === "/" && !inClass) {
          i++;
          break;
        } else if (d === "\n") break; // unterminated: bail rather than run away
        i++;
      }
      while (i < src.length && /[dgimsuvy]/.test(src[i])) i++;
      prev = "/";
      if (chain) nonLiteralOperand = true;
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      const at = line;
      i++;
      let buf = "";
      while (i < src.length) {
        const d = src[i];
        if (d === "\\") {
          buf += src[i] + src[i + 1];
          i += 2;
          continue;
        }
        if (d === quote) {
          i++;
          break;
        }
        if (d === "\n") line++;
        buf += d;
        i++;
      }
      pushLiteral(buf, at);
      prev = quote;
      continue;
    }
    if (c === "`") {
      const at = line;
      i++;
      let buf = "";
      while (i < src.length) {
        const d = src[i];
        if (d === "\\") {
          buf += src[i] + src[i + 1];
          i += 2;
          continue;
        }
        if (d === "`") {
          i++;
          break;
        }
        if (d === "$" && src[i + 1] === "{") {
          let braces = 1;
          i += 2;
          while (i < src.length && braces > 0) {
            if (src[i] === "{") braces++;
            else if (src[i] === "}") braces--;
            else if (src[i] === "\n") line++;
            i++;
          }
          buf += "…";
          continue;
        }
        if (d === "\n") line++;
        buf += d;
        i++;
      }
      pushLiteral(buf, at);
      prev = "`";
      continue;
    }

    if (chain) {
      if (c === "+") {
        // Do NOT clear `nonLiteralOperand` here. `"a" + expr + "b"` reaches
        // this branch twice, and clearing on the second `+` is what dropped
        // the placeholder — the sentence then read "We'll remind you  before
        // the trial ends." with the variable silently gone.
        pendingPlus = true;
      } else if (c === "(" || c === "[") {
        depth++;
        nonLiteralOperand = true;
      } else if (c === ")" || c === "]") {
        if (depth > 0) depth--;
        else closeChain();
      } else if (c === "}" || c === ";") {
        closeChain();
      } else if (depth === 0 && (c === "," || c === ":" || c === "=" || c === "?")) {
        closeChain();
      } else if (!pendingPlus) {
        // A token after a completed operand with no `+` between: the chain is
        // over (`"a" b` is two expressions, never one sentence).
        closeChain();
      } else {
        nonLiteralOperand = true;
      }
    }

    prev = c;
    i++;
  }
  closeChain();
  return out;
}


// ── Copy normalisation ─────────────────────────────────────────────────────

// The block-level tags that end a sentence. Everything not named here (b, i,
// em, strong, span, a, code, small, br is deliberately here as a block…) is
// treated as inline and glues.
const BLOCK_TAG =
  /<\/?(p|div|section|article|aside|header|footer|nav|main|form|label|fieldset|legend|h[1-6]|ul|ol|li|dl|dt|dd|table|thead|tbody|tr|td|th|button|option|select|textarea|blockquote|pre|figure|figcaption|hr|br)\b[^>]*>/gi;
const BOUNDARY = "\u0001";

const ENTITIES = {
  "&mdash;": "—",
  "&ndash;": "–",
  "&rsquo;": "\u2019",
  "&lsquo;": "\u2018",
  "&rdquo;": "\u201d",
  "&ldquo;": "\u201c",
  "&hellip;": "…",
  "&nbsp;": " ",
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&#39;": "'",
};

function plainText(raw) {
  let s = raw
    .replace(/\\n/g, " ")
    .replace(/\\t/g, " ")
    .replace(/\\r/g, " ")
    .replace(/\\(["'\\])/g, "$1");

  // A BLOCK tag is a sentence boundary; an INLINE one is not. Console copy is
  // written as one concatenated HTML run, so without this a heading and the
  // paragraph under it glue into a single "sentence" ("Pending invitations
  // Invitation links are emailed…") — a key no reader would recognise and one
  // that changes when unrelated markup moves. Inline tags must NOT split: "it
  // works <b>once</b> and expires in <b>7 days</b>" is one sentence.
  s = s.replace(BLOCK_TAG, BOUNDARY);
  s = s.replace(/<[^>]*>/g, " ");
  s = s.replace(/&[a-z]+;|&#\d+;/gi, (m) => (m in ENTITIES ? ENTITIES[m] : " "));
  // A tag stripped from inside a sentence leaves a space before its
  // punctuation ("7 days</b>:" → "7 days :"); close it up so the census keys on
  // the sentence a reader sees, not on where the markup happened to sit.
  s = s.replace(/\s+([.,;:!?])/g, "$1");
  return s.replace(/[^\S\u0001]+/g, " ").replace(/ ?\u0001 ?/g, BOUNDARY).trim();
}

// THE CLOSED LIST OF DEADLINE CONSTRUCTIONS (see the header). Every entry names
// a boundary the act is deferred to; a bare future tense is deliberately NOT
// here.
const VOCABULARY = [
  /until the end of/i,
  /at the end of the (current )?billing period/i,
  /stays active until/i,
  /continues until/i,
  /keeps your plan until/i,
  /until you resume/i,
  /after the grace period/i,
  /(when|before|after) the trial ends/i,
  /the trial ends/i,
  /expires? (in|on|after) /i,
  /expire (in|on|after) /i,
  /after \d+ days?/i,
];

function isDeferredAct(sentence) {
  return VOCABULARY.some((re) => re.test(sentence));
}

// Split on sentence-final punctuation followed by whitespace. A trailing
// fragment with no terminator is KEPT — button labels ("Yours when the trial
// ends") are promises too, and dropping them would be the census quietly
// choosing what it is willing to see.
function sentences(text) {
  return text
    .split(BOUNDARY)
    .flatMap((segment) => segment.split(/(?<=[.!?])\s+/))
    .map((s) => s.trim())
    .filter((s) => s !== "");
}

function census(src) {
  const found = new Map();
  for (const lit of literals(src)) {
    const text = plainText(lit.text);
    if (!text) continue;
    for (const s of sentences(text)) {
      // Three words, not four. "expires in …s" is the sub-minute arm of the
      // very same device-code countdown whose "expires in …m …s" arm is four —
      // a floor that keeps one arm of one sentence and drops the other is a
      // census choosing what it is willing to see.
      if (s.split(/\s+/).length < 3) continue;
      if (!isDeferredAct(s)) continue;
      if (!found.has(s)) found.set(s, new Set());
      found.get(s).add(lit.line);
    }
  }
  return [...found]
    .map(([sentence, lines]) => ({ sentence, lines: [...lines].sort((a, b) => a - b) }))
    .sort((a, b) => (a.sentence < b.sentence ? -1 : a.sentence > b.sentence ? 1 : 0));
}

// ── The self-test: the lexer must lose on a known fixture ──────────────────

const FIXTURE = [
  '// a line comment holding "a string" and a stray \' quote',
  "/* a block comment with 'quotes' and a /regex/ */",
  'var re = /["\'\\/]+/g;',            // a regex literal full of quote chars
  "var half = total / count;",          // division, not a regex
  'var kept = "after the division";',
  "var esc = 'it\\'s escaped';",
  "var tpl = `a ${expr} template`;",
  'var joined = "We\'ll remind you " + phrase + " before the trial ends.";',
  'var tagged = \'<b>bold</b> and &mdash; an entity\';',
].join("\n");

// The literals the lexer MUST extract from FIXTURE, in order, verbatim (raw —
// before plainText). If the regex arm breaks, `["'\/]+` desynchronises the scan
// and this list changes; if the division arm breaks, `kept` is swallowed.
const FIXTURE_EXPECTED = [
  "after the division",
  "it\\'s escaped",
  "a … template",
  "We'll remind you … before the trial ends.",
  "<b>bold</b> and &mdash; an entity",
];

function selftest(announce) {
  const got = literals(FIXTURE).map((l) => l.text);
  const same =
    got.length === FIXTURE_EXPECTED.length &&
    got.every((t, n) => t === FIXTURE_EXPECTED[n]);

  if (!same) {
    console.error(
      "the future-act lexer LOST its own fixture — it extracted\n  " +
        JSON.stringify(got) +
        "\nbut the fixture pins\n  " +
        JSON.stringify(FIXTURE_EXPECTED) +
        "\nA lexer that mis-reads a regex literal desynchronises for the rest of the file and " +
        "reports an EMPTY census as agreement. Refusing to run the census.",
    );
    process.exit(3);
  }

  // The vocabulary must also be able to fire and to stay silent, on this same
  // fixture: the glued sentence is a deferred act, the division line is not.
  const hits = census(FIXTURE).map((r) => r.sentence);
  if (!hits.includes("We'll remind you … before the trial ends.")) {
    console.error(
      "the lexer read its fixture but the vocabulary did not catch the fixture's one deferred-act " +
        "sentence — the census would report nothing on a console full of promises. Got: " +
        JSON.stringify(hits),
    );
    process.exit(3);
  }
  if (hits.some((h) => h.includes("after the division"))) {
    console.error(
      "the vocabulary fired on the fixture's NON-promise control line — a filter that matches " +
        "everything accounts for nothing. Got: " + JSON.stringify(hits),
    );
    process.exit(3);
  }

  // Announce ONLY in --selftest mode: in census mode stdout carries the JSON
  // the Elixir side parses, and a chatty guard would corrupt its own output.
  if (announce) {
    process.stdout.write("future-act dump selftest: lexer and vocabulary both lose and both hold\n");
  }
}

// ── main ───────────────────────────────────────────────────────────────────

if (process.argv.includes("--selftest")) {
  selftest(true);
} else {
  const path = new URL("../app.js", import.meta.url);
  let src;
  try {
    src = fs.readFileSync(path, "utf8");
  } catch (err) {
    console.error(`the shipped console client is unreadable at ${path}: ${err && err.message}`);
    process.exit(2);
  }

  // The census self-tests BEFORE every real run, in-process: a guard whose
  // own proof is a separate CI step is a guard that runs unproven whenever
  // somebody invokes the script directly.
  selftest(false);

  const all = literals(src);
  if (all.length === 0) {
    console.error(
      "the lexer found ZERO string literals in app.js — it desynchronised, and an empty census " +
        "must never read as 'the console promises nothing'",
    );
    process.exit(4);
  }

  process.stdout.write(JSON.stringify(census(src)));
}
