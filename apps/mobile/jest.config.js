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
}
