// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { FC } from 'react'

export interface PortableTextComponents {
  [k: string]: FC<unknown>
}

export interface PortableTextProps {
  blocks: unknown[]
  components?: PortableTextComponents
}

export const PortableText: FC<PortableTextProps> = () => {
  throw new Error('PortableText not implemented in scaffold')
}
