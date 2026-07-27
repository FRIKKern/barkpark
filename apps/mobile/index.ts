// Entry point. Polyfills MUST land before anything imports @barkpark/core:
// listen.ts decodes SSE with TextDecoder and transport builds URLs — both
// must exist on the global before module-eval of the SDK.
import './src/polyfills'

import { registerRootComponent } from 'expo'

import App from './App'

registerRootComponent(App)
