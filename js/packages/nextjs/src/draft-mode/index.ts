// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export function createDraftModeRoutes(_config: {
  previewSecret: string
  resolvePath: (doc: unknown) => string
}): never {
  throw new Error('createDraftModeRoutes not implemented in scaffold (Phase 3)')
}
