// Global polyfills — URL + TextDecoder ONLY (charter D14: crypto degrades
// in-package inside @barkpark/core; do not polyfill it here).
//
// - URL/URLSearchParams: Hermes ships an incomplete WHATWG URL; the SDK's
//   transport builds query strings with it. react-native-url-polyfill/auto
//   installs the full implementation once, idempotently.
// - TextDecoder: listen.ts (SSE) decodes streamed chunks with TextDecoder.
//   Newer Hermes/Expo winter runtimes provide it — install the shim only
//   when it is genuinely missing so a native implementation always wins.
import 'react-native-url-polyfill/auto'

if (typeof globalThis.TextDecoder === 'undefined' || typeof globalThis.TextEncoder === 'undefined') {
  // fast-text-encoding assigns TextEncoder/TextDecoder onto the global scope
  // as a side effect of being imported. Conditional install requires the
  // CJS form — a static import would always shadow a native implementation.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  require('fast-text-encoding')
}
