// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export interface BarkparkClient {}

export interface BarkparkConfig {
  projectId?: string
  dataset?: string
  apiVersion?: string
  useCdn?: boolean
  token?: string
  perspective?: 'published' | 'drafts' | 'raw'
}

export interface ListenEvent {}

export interface RequestContext {}

export interface ResponseContext {}

export interface BarkparkHooks {
  onRequest?: (ctx: RequestContext) => void
  onResponse?: (ctx: ResponseContext) => void
}
