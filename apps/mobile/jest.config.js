// jest-expo is the Expo-blessed preset: babel-preset-expo transforms +
// react-native module mocks. Tests here are deliberately pure-TS heavy (the
// cascade/MRU/device-flow engines are UI-free modules transliterated from
// internal/cli), so the suite stays fast and stable under pnpm's symlinked
// node_modules. transformIgnorePatterns is widened for pnpm's .pnpm paths —
// the stock pattern only matches hoisted layouts.
module.exports = {
  preset: 'jest-expo',
  transformIgnorePatterns: [
    'node_modules/(?!(?:.pnpm/)?((jest-)?react-native|@react-native(-community)?|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|react-native-url-polyfill|fast-text-encoding))',
  ],
  testMatch: ['**/__tests__/**/*.test.ts', '**/__tests__/**/*.test.tsx'],
  // GATE-HONESTY, not a slow-test allowance (mob-bl-jest-testtimeout): with no
  // explicit testTimeout every test rides jest's 5000 ms default, and a
  // COLD-cache run on a loaded host reproducibly reds the FIRST test of the
  // three heaviest suites (chatLifecycleWiring, chatScreenWiring, chatRichTail)
  // — the per-worker babel transform of the suite's import graph is billed to
  // that first test. Measured: warm cache 49 suites / 866 tests green in ~10 s
  // at load ~72; cold cache green in 11.5 s at load ~95 with the slowest single
  // test at 783 ms (10-core M-series, worktree at 60b08453f9) — yet the same
  // cold run at load ~27 has been observed to blow 5000 ms on exactly those
  // three first tests. 30 s = 6x the default: far above any observed
  // transform-billed first test, still small enough that a genuinely hung test
  // cannot stall the ~10-18 s suite for long. No test on main was ever broken.
  testTimeout: 30000,
}
