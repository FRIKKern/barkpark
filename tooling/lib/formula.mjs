// formula — a tiny SAFE expression evaluator (no eval, no Function).
//
// Lets a scoring FORMULA or a piecewise FUNCTION be tuned through a Barkpark
// paper without executing arbitrary code. Grammar (precedence low→high):
//   ternary    cond ? a : b
//   comparison >  <  >=  <=  ==  !=        (yield 1 / 0)
//   additive   +  -
//   term       *  /  %
//   factor     unary -, numbers, variables, func(args), ( … )
// Functions are a fixed whitelist. Anything else — a stray identifier, bad
// syntax, a non-finite result — throws, so a bound expression is validated by
// trying to evaluate it. Ternary + comparison make it a real (pure) function
// language: rung ③ (formulas) and ④ (piecewise function-cells) of cody.

const FUNCS = { max: Math.max, min: Math.min, sqrt: Math.sqrt, abs: Math.abs,
  log: Math.log, log2: Math.log2, pow: Math.pow, round: Math.round, floor: Math.floor, ceil: Math.ceil };

export function evalFormula(src, vars = {}) {
  const s = String(src); let i = 0;
  const ws = () => { while (i < s.length && /\s/.test(s[i])) i++; };

  function ternary() {
    const c = compare(); ws();
    if (s[i] === "?") {
      i++; const a = ternary(); ws();
      if (s[i++] !== ":") throw new Error("expected : in ternary");
      const b = ternary();
      return c ? a : b;
    }
    return c;
  }
  function compare() {
    let v = additive(); ws();
    const two = s.slice(i, i + 2);
    if (two === ">=" || two === "<=" || two === "==" || two === "!=") {
      i += 2; const r = additive(); ws();
      return two === ">=" ? (v >= r ? 1 : 0) : two === "<=" ? (v <= r ? 1 : 0)
        : two === "==" ? (v === r ? 1 : 0) : (v !== r ? 1 : 0);
    }
    if (s[i] === ">" || s[i] === "<") { const op = s[i++]; const r = additive(); ws(); return op === ">" ? (v > r ? 1 : 0) : (v < r ? 1 : 0); }
    return v;
  }
  function additive() { let v = term(); ws(); while (s[i] === "+" || s[i] === "-") { const op = s[i++]; const r = term(); v = op === "+" ? v + r : v - r; ws(); } return v; }
  function term() { let v = factor(); ws(); while (s[i] === "*" || s[i] === "/" || s[i] === "%") { const op = s[i++]; const r = factor(); v = op === "*" ? v * r : op === "/" ? v / r : v % r; ws(); } return v; }
  function factor() {
    ws();
    if (s[i] === "(") { i++; const v = ternary(); ws(); if (s[i++] !== ")") throw new Error("expected )"); return v; }
    if (s[i] === "-") { i++; return -factor(); }
    if (s[i] === "+") { i++; return factor(); }
    if (/[0-9.]/.test(s[i])) { let j = i; while (i < s.length && /[0-9.]/.test(s[i])) i++; return parseFloat(s.slice(j, i)); }
    if (/[a-zA-Z_]/.test(s[i])) {
      let j = i; while (i < s.length && /[a-zA-Z0-9_]/.test(s[i])) i++; const name = s.slice(j, i); ws();
      if (s[i] === "(") {            // function call
        i++; const args = []; ws();
        if (s[i] !== ")") { args.push(ternary()); ws(); while (s[i] === ",") { i++; args.push(ternary()); ws(); } }
        if (s[i++] !== ")") throw new Error("expected )");
        const fn = FUNCS[name]; if (!fn) throw new Error(`unknown function: ${name}`);
        return fn(...args);
      }
      if (!(name in vars)) throw new Error(`unknown variable: ${name}`);
      return vars[name];
    }
    throw new Error(`unexpected token: ${s[i] || "end of input"}`);
  }

  const v = ternary(); ws();
  if (i < s.length) throw new Error(`trailing input: ${s.slice(i)}`);
  if (typeof v !== "number" || !Number.isFinite(v)) throw new Error("non-finite result");
  return v;
}

// the variable names a formula references (excludes the function whitelist) —
// used to validate a bound expression against the variables it's allowed to use.
export function formulaVars(src) {
  const used = new Set();
  for (const m of String(src).matchAll(/[a-zA-Z_]\w*/g)) if (!(m[0] in FUNCS)) used.add(m[0]);
  return [...used];
}
