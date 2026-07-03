// bp-sheet-formula.js — pure formula-UX kernel for the Studio sheet grid.
//
// The Google-Sheets / Excel formula muscle memory (point-mode reference
// insertion, F4 $-cycling, live rainbow ref-coloring, range extension,
// caret-aware click semantics) all reduce to a handful of PURE string
// transforms over the formula text + a caret. This module is that kernel:
// zero dependencies, no DOM, no LiveView — just `value` in, `{value,caret}`
// out. The DOM/hook wiring (mouse point-mode, keydown F4, rainbow paint) is a
// separate wave that CALLS these; keeping the grammar pure means it is unit-
// testable in node:vm with no browser, exactly like the grid hook harness.
//
// Loaded as a browser IIFE assigning `window.BarkparkSheetFormula`, with a
// `module.exports` guard so the node harness can require it OR run it verbatim
// in a vm sandbox. ES5-ish (var + function declarations) to match bp-sheet-
// grid.js and dodge any transpile step.
//
// Reference shape parity: a token matching /^[A-Za-z]{1,3}[0-9]+$/ is a CELL
// REF, never a function name — the same rule `_fnToken` uses in bp-sheet-
// grid.js, so `LOG10(` reads as the ref LOG10, not a call. One grammar, two
// files.
(function () {
  // ── shared shapes ─────────────────────────────────────────────────────────
  // A reference is: a cell (A1 / $A$1 / A$1 / $A1), a cell:cell range with any
  // $ mix (B3:B5), a whole-column (B:B / $B:$B) or a whole-row (3:3 / $3:$3).
  // Alternation order matters: the cell(:cell)? form is tried first so B3:B5
  // is one ref, not B3 + : + B5.
  var RE_REF = /^(?:\$?[A-Za-z]{1,3}\$?[0-9]+(?::\$?[A-Za-z]{1,3}\$?[0-9]+)?|\$?[A-Za-z]{1,3}:\$?[A-Za-z]{1,3}|\$?[0-9]+:\$?[0-9]+)/;
  var RE_IDENT = /^[A-Za-z_][A-Za-z0-9_.]*/;
  var RE_NUM = /^[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?/;
  var RE_CELL = /^(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)$/;
  var REF_SHAPE = /^[A-Za-z]{1,3}[0-9]+$/; // grid _fnToken parity: a ref, never a fn
  var OP_CHARS = "+-*/^&<>=%";
  // Caret sitting immediately after one of these (spaces allowed between) is a
  // point-INSERT slot: = ( , : and the binary/unary operators + - * / ^ & < > %.
  var POINT_AFTER = "=(,:+-*/^&<>%";

  function isAlpha(c) { return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z"); }
  function isDigit(c) { return c >= "0" && c <= "9"; }
  function clampCaret(len, caret) {
    if (caret == null || caret > len) return len;
    if (caret < 0) return 0;
    return caret;
  }

  // ── (a) tokenize ──────────────────────────────────────────────────────────
  // Contiguous, lossless tokens: concatenating .text reproduces the input
  // exactly (every char lands in exactly one token, including ws / other), so
  // normalizeFormula can rebuild from tokens. `depth` = paren nesting; a '('
  // and its matching ')' share a depth, the content between them is deeper.
  function tokenize(value) {
    var out = [];
    if (value == null) return out;
    var s = String(value);
    var n = s.length;
    var i = 0;
    var depth = 0;
    while (i < n) {
      var c = s[i];
      var m;
      var text;

      if (c === " " || c === "\t") {
        var j = i;
        while (j < n && (s[j] === " " || s[j] === "\t")) j++;
        out.push({ type: "ws", text: s.slice(i, j), start: i, end: j, depth: depth });
        i = j;
        continue;
      }

      // String literal with "" escape. An unterminated string runs to EOL.
      if (c === '"') {
        var k = i + 1;
        while (k < n) {
          if (s[k] === '"') {
            if (s[k + 1] === '"') { k += 2; continue; } // escaped quote
            k++; // consume closing quote
            break;
          }
          k++;
        }
        out.push({ type: "str", text: s.slice(i, k), start: i, end: k, depth: depth });
        i = k;
        continue;
      }

      if (c === "(") {
        out.push({ type: "paren", text: "(", start: i, end: i + 1, depth: depth });
        depth++;
        i++;
        continue;
      }
      if (c === ")") {
        if (depth > 0) depth--;
        out.push({ type: "paren", text: ")", start: i, end: i + 1, depth: depth });
        i++;
        continue;
      }
      if (c === ",") {
        out.push({ type: "comma", text: ",", start: i, end: i + 1, depth: depth });
        i++;
        continue;
      }

      var rest = s.slice(i);

      // Reference before identifier/number: a ref is shaped like a name but
      // isn't one (A1), and 3:3 is shaped like a number but isn't.
      if ((isAlpha(c) || c === "$" || isDigit(c)) && (m = RE_REF.exec(rest))) {
        text = m[0];
        out.push({ type: "ref", text: text, start: i, end: i + text.length, depth: depth });
        i += text.length;
        continue;
      }

      // Identifier → fn if immediately followed by '(' (and not ref-shaped;
      // ref-shaped never reaches here — RE_REF already claimed it), else other
      // (TRUE / FALSE / named range).
      if (isAlpha(c) || c === "_") {
        m = RE_IDENT.exec(rest);
        text = m[0];
        var after = s[i + text.length];
        var isFn = after === "(" && !REF_SHAPE.test(text);
        out.push({ type: isFn ? "fn" : "other", text: text, start: i, end: i + text.length, depth: depth });
        i += text.length;
        continue;
      }

      if (isDigit(c) || (c === "." && isDigit(s[i + 1]))) {
        m = RE_NUM.exec(rest);
        if (m) {
          text = m[0];
          out.push({ type: "num", text: text, start: i, end: i + text.length, depth: depth });
          i += text.length;
          continue;
        }
      }

      if (OP_CHARS.indexOf(c) >= 0 || c === ":") {
        out.push({ type: "op", text: c, start: i, end: i + 1, depth: depth });
        i++;
        continue;
      }

      out.push({ type: "other", text: c, start: i, end: i + 1, depth: depth });
      i++;
    }
    return out;
  }

  // Walk the prefix [0, caret) tracking string state + the enclosing fn-call
  // stack, so caretContext can answer inString + fnName + argIndex without
  // re-tokenizing per query. Commas / parens INSIDE a string do not count.
  function scanTo(s, caret) {
    var inStr = false;
    var stack = [];
    for (var i = 0; i < caret; i++) {
      var c = s[i];
      if (inStr) {
        if (c === '"') {
          if (s[i + 1] === '"') { i++; continue; } // escaped quote — stay in string
          inStr = false;
        }
        continue;
      }
      if (c === '"') { inStr = true; continue; }
      if (c === "(") {
        var head = s.slice(0, i);
        var mm = /([A-Za-z_][A-Za-z0-9_.]*)$/.exec(head);
        var name = mm && !REF_SHAPE.test(mm[1]) ? mm[1] : null;
        stack.push({ fnName: name, argIndex: 0 });
      } else if (c === ")") {
        if (stack.length) stack.pop();
      } else if (c === ",") {
        if (stack.length) stack[stack.length - 1].argIndex++;
      }
    }
    var top = stack.length ? stack[stack.length - 1] : null;
    return { inString: inStr, fnName: top ? top.fnName : null, argIndex: top ? top.argIndex : 0 };
  }

  // ── (b) caretContext ──────────────────────────────────────────────────────
  // The contract table, in order:
  //   1. value not starting '='               -> commit
  //   2. caret inside a string literal         -> commit (inString:true)
  //   3. caret at end of the caller's hotSpan  -> point-replace that span
  //   4. caret inside/adjacent an existing ref -> point-replace that ref
  //   5. caret after = ( , : or an operator    -> point-insert (span:null)
  //   6. otherwise (after ) or a complete expr) -> commit
  //
  // Rule-order note vs the charter table (decision 4): the charter lists the
  // after-operator POINT-insert row before the adjacent-ref row. The two rows
  // overlap in exactly one case — caret at the LEFT edge of a ref whose
  // previous char is an operator ('=A1+|B2') — and there insert-before would
  // splice garbage ('=A1+C3B2'), so adjacent-ref (replace, Sheets' actual
  // muscle memory) deliberately wins here. Rows are disjoint everywhere else.
  // hotSpan stays ABOVE adjacent-ref so a ':'-extended range ('=B3:B5' with
  // hot span on the B5 half) replaces only the live half, not the whole range.
  function caretContext(value, caret, hotSpan) {
    var s = String(value == null ? "" : value);
    caret = clampCaret(s.length, caret);
    var scan = scanTo(s, caret);
    var fnName = scan.fnName;
    var argIndex = scan.argIndex;

    if (s.charAt(0) !== "=") {
      return { action: "commit", span: null, fnName: null, argIndex: 0, inString: false };
    }
    if (scan.inString) {
      return { action: "commit", span: null, fnName: fnName, argIndex: argIndex, inString: true };
    }
    if (hotSpan && typeof hotSpan.end === "number" && caret === hotSpan.end) {
      return {
        action: "point-replace",
        span: { start: hotSpan.start, end: hotSpan.end },
        fnName: fnName, argIndex: argIndex, inString: false,
      };
    }
    var toks = tokenize(s);
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i];
      if (t.type === "ref" && caret >= t.start && caret <= t.end) {
        return {
          action: "point-replace",
          span: { start: t.start, end: t.end },
          fnName: fnName, argIndex: argIndex, inString: false,
        };
      }
    }
    var prefix = s.slice(0, caret).replace(/[ \t]+$/, "");
    var last = prefix.charAt(prefix.length - 1);
    if (last && POINT_AFTER.indexOf(last) >= 0) {
      return { action: "point-insert", span: null, fnName: fnName, argIndex: argIndex, inString: false };
    }
    return { action: "commit", span: null, fnName: fnName, argIndex: argIndex, inString: false };
  }

  // ── (c) insertRef ─────────────────────────────────────────────────────────
  // Point-insert -> splice refText at caret; point-replace -> overwrite the
  // resolved span (existing ref, or the caller's volatile hotSpan). Returns the
  // new value, the caret past the inserted text, and the span it now occupies
  // (so a live drag can pass it back as hotSpan on the next move).
  function insertRef(value, caret, refText, hotSpan) {
    var s = String(value == null ? "" : value);
    caret = clampCaret(s.length, caret);
    var ref = String(refText == null ? "" : refText);
    var ctx = caretContext(s, caret, hotSpan);
    if (ctx.action === "point-replace" && ctx.span) {
      var sp = ctx.span;
      var nv = s.slice(0, sp.start) + ref + s.slice(sp.end);
      var ns = { start: sp.start, end: sp.start + ref.length };
      return { value: nv, caret: ns.end, span: ns };
    }
    var v2 = s.slice(0, caret) + ref + s.slice(caret);
    var s2 = { start: caret, end: caret + ref.length };
    return { value: v2, caret: s2.end, span: s2 };
  }

  // ── column/cell helpers ───────────────────────────────────────────────────
  function colToNum(letters) {
    var up = letters.toUpperCase();
    var num = 0;
    for (var i = 0; i < up.length; i++) num = num * 26 + (up.charCodeAt(i) - 64);
    return num;
  }
  function numToCol(num) {
    var out = "";
    while (num > 0) {
      var r = (num - 1) % 26;
      out = String.fromCharCode(65 + r) + out;
      num = Math.floor((num - 1) / 26);
    }
    return out;
  }
  function parseCell(text) {
    var m = RE_CELL.exec(text);
    if (!m) return null;
    return { colAbs: m[1] === "$", col: colToNum(m[2]), rowAbs: m[3] === "$", row: parseInt(m[4], 10) };
  }
  function fmtCell(c) {
    return (c.colAbs ? "$" : "") + numToCol(c.col) + (c.rowAbs ? "$" : "") + c.row;
  }
  // Top-left:bottom-right of the box spanned by two cells; each corner keeps
  // the $ flag of whichever source cell contributes that coordinate.
  function normalizeRange(aText, bText) {
    var a = parseCell(aText);
    var b = parseCell(bText);
    if (!a || !b) return aText + ":" + bText;
    var tl = {
      colAbs: a.col <= b.col ? a.colAbs : b.colAbs, col: Math.min(a.col, b.col),
      rowAbs: a.row <= b.row ? a.rowAbs : b.rowAbs, row: Math.min(a.row, b.row),
    };
    var br = {
      colAbs: a.col >= b.col ? a.colAbs : b.colAbs, col: Math.max(a.col, b.col),
      rowAbs: a.row >= b.row ? a.rowAbs : b.rowAbs, row: Math.max(a.row, b.row),
    };
    if (tl.col === br.col && tl.row === br.row) return fmtCell(tl);
    return fmtCell(tl) + ":" + fmtCell(br);
  }

  // ── (d) extendRef ─────────────────────────────────────────────────────────
  // Rewrite the ref at `span` to anchor:endRef, normalized top-left:bottom-
  // right. If the ref already holds a range, its first cell is the anchor.
  // Species algebra: cell+cell -> normalizeRange box; whole-col anchor + col
  // end (a header drag hands endRef as 'D' or 'D:D' — either works) -> min:max
  // col range; whole-row likewise. Each side keeps its own $ flag. Mixed
  // species fall back to plain anchor:endRef.
  var RE_COLPART = /^(\$?)([A-Za-z]{1,3})$/;
  var RE_ROWPART = /^(\$?)([0-9]+)$/;
  function extendRef(value, span, endRef) {
    var s = String(value == null ? "" : value);
    var cur = s.slice(span.start, span.end);
    var anchor = cur.split(":")[0];
    var endText = String(endRef == null ? "" : endRef);
    var endHead = endText.split(":")[0];
    var newText = null;
    var ca = RE_COLPART.exec(anchor);
    var cb = RE_COLPART.exec(endHead);
    if (ca && cb) {
      var lo = colToNum(ca[2]) <= colToNum(cb[2]) ? ca : cb;
      var hi = lo === ca ? cb : ca;
      newText = lo[1] + lo[2].toUpperCase() + ":" + hi[1] + hi[2].toUpperCase();
    } else {
      var ra = RE_ROWPART.exec(anchor);
      var rb = RE_ROWPART.exec(endHead);
      if (ra && rb) {
        var lo2 = parseInt(ra[2], 10) <= parseInt(rb[2], 10) ? ra : rb;
        var hi2 = lo2 === ra ? rb : ra;
        newText = lo2[1] + lo2[2] + ":" + hi2[1] + hi2[2];
      }
    }
    if (newText == null) newText = normalizeRange(anchor, endText);
    var nv = s.slice(0, span.start) + newText + s.slice(span.end);
    var ns = { start: span.start, end: span.start + newText.length };
    return { value: nv, caret: ns.end, span: ns };
  }

  // ── (e) cycleDollar ───────────────────────────────────────────────────────
  // The F4 muscle: A1 -> $A$1 -> A$1 -> $A1 -> A1 on the ref at (or immediately
  // left of) the caret. Ranges cycle both endpoints in lockstep off the first
  // endpoint's state; whole-col/row toggle two-state. No ref under caret -> null.
  function nextCellState(colAbs, rowAbs) {
    if (!colAbs && !rowAbs) return [true, true];
    if (colAbs && rowAbs) return [false, true];
    if (!colAbs && rowAbs) return [true, false];
    return [false, false]; // colAbs && !rowAbs
  }
  function cycleRefText(text) {
    var c = parseCell(text);
    if (c) {
      var st = nextCellState(c.colAbs, c.rowAbs);
      return fmtCell({ colAbs: st[0], col: c.col, rowAbs: st[1], row: c.row });
    }
    var parts = text.split(":");
    if (parts.length === 2) {
      var a = parseCell(parts[0]);
      var b = parseCell(parts[1]);
      if (a && b) {
        var s2 = nextCellState(a.colAbs, a.rowAbs); // lockstep: both endpoints
        return fmtCell({ colAbs: s2[0], col: a.col, rowAbs: s2[1], row: a.row }) + ":" +
               fmtCell({ colAbs: s2[0], col: b.col, rowAbs: s2[1], row: b.row });
      }
      var cm = /^(\$?)([A-Za-z]{1,3})$/.exec(parts[0]);
      var cm2 = /^(\$?)([A-Za-z]{1,3})$/.exec(parts[1]);
      if (cm && cm2) {
        var onC = cm[1] !== "$"; // absent -> add $, present -> strip
        return (onC ? "$" : "") + cm[2] + ":" + (onC ? "$" : "") + cm2[2];
      }
      var rm = /^(\$?)([0-9]+)$/.exec(parts[0]);
      var rm2 = /^(\$?)([0-9]+)$/.exec(parts[1]);
      if (rm && rm2) {
        var onR = rm[1] !== "$";
        return (onR ? "$" : "") + rm[2] + ":" + (onR ? "$" : "") + rm2[2];
      }
    }
    return null;
  }
  function cycleDollar(value, caret) {
    var s = String(value == null ? "" : value);
    caret = clampCaret(s.length, caret);
    var toks = tokenize(s);
    var target = null;
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i];
      if (t.type === "ref" && caret >= t.start && caret <= t.end) target = t; // last containing ref wins (only overlaps when two refs abut)
    }
    if (!target) return null;
    var nt = cycleRefText(target.text);
    if (nt == null) return null;
    var nv = s.slice(0, target.start) + nt + s.slice(target.end);
    return { value: nv, caret: target.start + nt.length };
  }

  // ── (f) refColorIndex ─────────────────────────────────────────────────────
  // First-occurrence order → hue slot 0..7; the same ref (normalized: upper-
  // cased, ranges reordered top-left:bottom-right) always maps to its slot;
  // the 9th distinct ref wraps to slot 0.
  function normalizeRefText(text) {
    var up = text.toUpperCase();
    var parts = up.split(":");
    if (parts.length === 2) {
      var a = parseCell(parts[0]);
      var b = parseCell(parts[1]);
      if (a && b) return normalizeRange(parts[0], parts[1]).toUpperCase();
    }
    return up;
  }
  function refColorIndex(value) {
    var toks = tokenize(value);
    var map = {};
    var slot = 0;
    for (var i = 0; i < toks.length; i++) {
      if (toks[i].type !== "ref") continue;
      var key = normalizeRefText(toks[i].text);
      if (!(key in map)) {
        map[key] = slot % 8;
        slot++;
      }
    }
    return map;
  }

  // ── (g) normalizeFormula ──────────────────────────────────────────────────
  // Uppercase known fn names + all ref tokens (string literals untouched — they
  // are their own token) and append (never remove) trailing ')' to balance
  // unclosed parens. Non-formulas returned verbatim. knownFns omitted ⇒ every
  // fn-shaped token is uppercased.
  function normalizeFormula(value, knownFns) {
    var s = String(value == null ? "" : value);
    if (s.charAt(0) !== "=") return s;
    var known = null;
    if (knownFns && knownFns.length) {
      known = {};
      for (var i = 0; i < knownFns.length; i++) known[String(knownFns[i]).toUpperCase()] = true;
    }
    var toks = tokenize(s);
    var out = "";
    var open = 0;
    for (var j = 0; j < toks.length; j++) {
      var t = toks[j];
      if (t.type === "fn") {
        var up = t.text.toUpperCase();
        out += known === null || known[up] ? up : t.text;
      } else if (t.type === "ref") {
        out += t.text.toUpperCase();
      } else {
        out += t.text;
        if (t.type === "paren") {
          if (t.text === "(") open++;
          else if (open > 0) open--;
        }
      }
    }
    for (var k = 0; k < open; k++) out += ")";
    return out;
  }

  var API = {
    tokenize: tokenize,
    caretContext: caretContext,
    insertRef: insertRef,
    extendRef: extendRef,
    cycleDollar: cycleDollar,
    refColorIndex: refColorIndex,
    normalizeFormula: normalizeFormula,
  };

  if (typeof window !== "undefined") window.BarkparkSheetFormula = API;
  if (typeof module !== "undefined" && module.exports) module.exports = API;
})();
