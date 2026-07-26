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
  // KNOWN GAP, left deliberately: a string-keyed `{'fontSize': 12}` escapes,
  // since the selector reads `key.name`. Widening to `key.value` makes the
  // `> Literal` child match the KEY as well as the value and double-reports
  // every site. No call site in the app uses that form; a narrow rule that
  // never lies beats a broad one that cries twice.
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
