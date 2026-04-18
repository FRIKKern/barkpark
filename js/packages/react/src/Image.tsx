// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { FC, ComponentType } from 'react'

export interface BarkparkImageProps {
  asset: unknown
  as?: ComponentType<unknown>
}

export const BarkparkImage: FC<BarkparkImageProps> = () => {
  throw new Error('BarkparkImage not implemented in scaffold')
}
