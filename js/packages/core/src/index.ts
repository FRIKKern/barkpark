// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export * from './errors'
export * from './types'
export { createClient } from './client'
export { filter } from './filter-builder'
export { patch } from './patch'
export { transaction } from './transaction'
export { listen } from './listen'

export function defineActions<C>(client: C): C {
  return client
}

export function typedClient<C>(client: C): C {
  return client
}
