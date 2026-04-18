// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdir, stat, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

const CONFIG_TEMPLATE = `import { defineConfig } from "@barkpark/codegen";

export default defineConfig({
  apiUrl: process.env.BARKPARK_API_URL ?? "http://localhost:4000",
  dataset: "production",
  codegen: { out: "barkpark.types.ts" },
  schema: { cachePath: ".barkpark/schema.json" },
});
`

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p)
    return true
  } catch {
    return false
  }
}

export async function runInit(
  opts: { cwd?: string } = {},
): Promise<void> {
  const cwd = resolve(opts.cwd ?? process.cwd())
  await mkdir(cwd, { recursive: true })

  const configPath = join(cwd, 'barkpark.config.ts')
  const dotDir = join(cwd, '.barkpark')
  const gitkeep = join(dotDir, '.gitkeep')

  if (await pathExists(configPath)) {
    process.stdout.write('barkpark.config.ts already exists, skipping\n')
  } else {
    await writeFile(configPath, CONFIG_TEMPLATE, 'utf8')
    process.stdout.write(`wrote ${configPath}\n`)
  }

  await mkdir(dotDir, { recursive: true })
  if (!(await pathExists(gitkeep))) {
    await writeFile(gitkeep, '', 'utf8')
  }

  process.stdout.write(
    'next: run `barkpark schema extract && barkpark codegen`\n',
  )
}
