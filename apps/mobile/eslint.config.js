// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config')
const expoConfig = require('eslint-config-expo/flat')

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*', '.expo/*', 'android/*', 'ios/*'],
  },
  // THE TYPE VALUE BAN (t3w2-s8, charter D32; widened by
  // mob-bl-token-guard-residuals).
  //
  // S8 moved 189 raw fontSize/lineHeight literals across 14 files onto
  // src/ui/typography.ts. This rule is what keeps them there: without it the
  // next screen quietly hand-types a 15 and the scale is decorative again.
  //
  // S8 shipped this as a LITERAL ban — a numeric literal sitting on a
  // fontSize/lineHeight property — and disclosed two evasions it could not
  // reach: const laundering (`const S = 15; { fontSize: S }`, the exact idiom
  // chat.tsx used until that wave, which hid 16 of its 28 hand-typed values
  // from the census) and string keys (`{'fontSize': 12}`). Widening the
  // literal selector to `key.value` made its `> Literal` child match the KEY
  // as well as the value and double-reported every site, so both gaps were
  // left open and named.
  //
  // THE RESIDUAL SLICE CLOSES BOTH BY INVERTING THE RULE. Instead of
  // blacklisting the bad value shapes one at a time — literal, then
  // identifier, then cast, then call, forever — the rule now WHITELISTS the
  // one shape that is allowed:
  //
  //     on a fontSize/lineHeight property, the only legal value is a member
  //     access into the token module: `scale.<step>.fontSize` or
  //     `roles.<role>.lineHeight`.
  //
  // Everything else on those two keys reds, in one report per site, whether
  // the key is written bare or quoted: `fontSize: 15`, the fractional
  // `fontSize: 16.5` (how a half-pixel drift usually arrives), the laundered
  // `fontSize: ROW_SIZE`, the cast `fontSize: S as number`, the computed
  // `fontSize: s.fontSize * 1.3`, and the foreign member `fontSize: T.size`.
  // Spreads are untouched by construction — `...scale.sm` is a SpreadElement,
  // there is no Property to match — and so is every other numeric style prop:
  // padding, borderRadius, gap, letterSpacing and width are layout, not type,
  // and the token module does not own them.
  //
  // Two behaviour changes came with the inversion, both deliberate:
  //   · a COMPUTED lead is now an error where S8 allowed it. A lead derived at
  //     the call site is precisely how a rounding drift enters; if a register
  //     needs `size × 1.3`, that belongs in typography.ts, where the heading
  //     roles already are.
  //   · the report lands on the PROPERTY, not on the literal — one report per
  //     site regardless of key form, which is what made the string-key gap
  //     unfixable before.
  //
  // WHAT IS STILL OUT OF REACH, named rather than papered over: a value that
  // reaches the property through something ESLint cannot see without types —
  // `fontSize: px(15)` (a call), or a spread of a non-token object literal
  // defined in an unscanned file. Both are wider than "type geometry" and want
  // a type-aware rule; within this repo the geometry ledger
  // (__tests__/typeGeometry.test.ts) is the second net — it resolves every
  // call site through the real token table and pins the resulting numbers, so
  // a value that sneaks past the linter still has to survive a diff on the
  // app's rendered geometry.
  //
  // SCOPE is now the whole package, not just src/** — App.tsx, index.ts and
  // any future root-level module are inside the fence (S8 shipped them
  // outside it; App.tsx happens to set no type today, which is exactly the
  // kind of accident a guard should not depend on).
  //
  // TWO EXEMPTIONS, both load-bearing:
  //   · typography.ts is where the numbers are supposed to live. Dropping
  //     that ignore reds the token module itself with 64 errors.
  //   · __tests__/** is exempt because a test that pins the 16/23 bubble law
  //     has to be allowed to WRITE 16 and 23 — otherwise the pin would read
  //     the value it is pinning, which is exactly the hole reviewer mutant M4
  //     found in the heading assertions.
  {
    files: ['**/*.ts', '**/*.tsx'],
    ignores: ['src/ui/typography.ts', '__tests__/**'],
    rules: {
      'no-restricted-syntax': [
        'error',
        {
          selector:
            "Property[key.name=/^(fontSize|lineHeight)$/]:not([value.object.object.name='scale']):not([value.object.object.name='roles'])",
          message:
            'Hand-typed fontSize/lineHeight. Use a token from src/ui/typography.ts — `...scale.base` for a chrome step, `...roles.userBubble` for a named outlier, or `scale.sm.fontSize` alone for a run nested inside another Text. A computed or laundered value belongs in typography.ts, not here.',
        },
        {
          selector:
            "Property[key.value=/^(fontSize|lineHeight)$/]:not([value.object.object.name='scale']):not([value.object.object.name='roles'])",
          message:
            "Hand-typed fontSize/lineHeight behind a quoted key. A string key is not an escape hatch — use a token from src/ui/typography.ts, and write the key bare while you are there.",
        },
      ],
    },
  },
])
