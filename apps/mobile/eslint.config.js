// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config')
const expoConfig = require('eslint-config-expo/flat')

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*', '.expo/*', 'android/*', 'ios/*'],
  },
  // THE TYPE LITERAL BAN (t3w2-s8, charter D32).
  //
  // S8 moved 189 raw fontSize/lineHeight literals across 14 files onto
  // src/ui/typography.ts. This rule is what keeps them there: without it the
  // next screen quietly hand-types a 15 and the scale is decorative again.
  //
  // The selector is deliberately narrow. It flags a NUMERIC LITERAL sitting
  // directly on a fontSize/lineHeight property — including a fractional one
  // like 16.5, which is how a half-pixel drift usually arrives. It does NOT
  // flag a token member access (`fontSize: scale.sm.fontSize`), a spread
  // (`...scale.sm` is a SpreadElement, so there is no Property to match), a
  // computed value (`fontSize: s.fontSize * 1.3`), or any other numeric style
  // prop — padding, borderRadius, gap and letterSpacing are untouched,
  // because those are layout, not type, and the token module does not own
  // them.
  //
  // TWO KNOWN EVASIONS, both left open deliberately — a syntactic rule bans a
  // SHAPE, not an intent, and pretending otherwise is worse than saying so:
  //
  //   1. CONST LAUNDERING. `const S = 15; ... { fontSize: S }` passes, because
  //      the value is an Identifier by the time it reaches the property. This
  //      is not hypothetical: it is the exact idiom chat.tsx used until this
  //      wave (`const ROW_SIZE = 13; const ROW_LINE = 19`). Measured at the
  //      base sha, chat.tsx carried 28 hand-typed type values in property
  //      position and this rule saw 12 of them: the other 16 were laundered
  //      through those two bindings. Closing it needs constant folding or a
  //      type-aware rule that resolves the binding — a different instrument,
  //      filed as a follow-up rather than bolted on here.
  //   2. STRING KEYS. `{'fontSize': 12}` escapes, since the selector reads
  //      `key.name`. Widening to `key.value` makes the `> Literal` child match
  //      the KEY as well as the value and double-reports every site.
  //
  // Neither form appears at any call site in the app today. A narrow rule that
  // never lies beats a broad one that cries twice — but the gaps are named
  // here so the next reader knows a green run means "no raw literal in a style
  // property", not "no hand-typed type value anywhere".
  //
  // typography.ts is exempt for the obvious reason: it is where the numbers
  // are supposed to live — dropping that ignore reds the token module itself
  // with 64 errors. Tests are out of scope too (this block only covers
  // src/**): a test that pins the 16/23 bubble law must be allowed to write
  // 16 and 23, or the pin would have to read the value it is pinning.
  {
    files: ['src/**/*.ts', 'src/**/*.tsx'],
    ignores: ['src/ui/typography.ts'],
    rules: {
      'no-restricted-syntax': [
        'error',
        {
          selector: 'Property[key.name=/^(fontSize|lineHeight)$/] > Literal',
          message:
            'Raw fontSize/lineHeight literal. Use a token from src/ui/typography.ts — `...scale.base` for a chrome step, `...roles.userBubble` for a named outlier, or `scale.sm.fontSize` alone for a run nested inside another Text.',
        },
      ],
    },
  },
])
