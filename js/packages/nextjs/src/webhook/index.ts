// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export function createWebhookHandler(_config: {
  secret: string
  onMutation?: (evt: unknown) => unknown
  previousSecret?: string
}): never {
  throw new Error('createWebhookHandler not implemented in scaffold (Phase 3)')
}
