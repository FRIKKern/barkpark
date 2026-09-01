'use client'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export {
  BarkparkLive,
  BarkparkLiveProvider,
  startLiveSubscription,
  detectEdgeRuntime,
} from './live'

export type {
  BarkparkLiveProps,
  BarkparkLiveProviderProps,
  StartLiveOpts,
  // The return type of `detectEdgeRuntime` (core's `EdgeSignal`), so a consumer
  // can name what it holds without reaching into `@barkpark/core` directly.
  EdgeSignal,
} from './live'
