#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { cac } from 'cac'
import { buildSchemaPath } from './schema-url'

const cli = cac('barkpark')

cli
  .command('schema-path <dataset>', 'Print the schema-introspection path for a dataset')
  .option('--workspace <slug>', 'Workspace slug (scoped path; requires --project)')
  .option('--project <slug>', 'Project slug (scoped path; requires --workspace)')
  .action((dataset: string, options: { workspace?: string; project?: string }) => {
    const args: { dataset: string; workspace?: string; project?: string } = { dataset }
    if (options.workspace !== undefined) args.workspace = options.workspace
    if (options.project !== undefined) args.project = options.project
    process.stdout.write(buildSchemaPath(args) + '\n')
  })

cli.help()
cli.parse()
