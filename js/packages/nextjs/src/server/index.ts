// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import 'server-only'

export {
  createBarkparkServer,
  defineLive,
  barkparkFetchInner as barkparkFetch,
} from './core'

export type { BarkparkServerConfig, BarkparkFetchOptions } from './types'

// BarkparkLive / BarkparkLiveProvider are intentionally NOT re-exported here.
// They live behind a `'use client'` boundary in `src/client/live.tsx` and
// would pull `React.createContext` into the Next 15 `react-server` graph.
// Import them from `@barkpark/nextjs/client` instead.
