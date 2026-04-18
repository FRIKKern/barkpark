// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { FC } from 'react'

export interface BarkparkReferenceProps {
  ref: unknown
  fetcher?: (id: string) => Promise<unknown>
}

export const BarkparkReference: FC<BarkparkReferenceProps> = () => {
  throw new Error('BarkparkReference not implemented in scaffold')
}
