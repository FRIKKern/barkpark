// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// A test file that a js-tests step runs by name runs only there.
//
// A package lists such files in its vitest config as NAMED_STEP_FILES and
// spreads excludeUnlessNamed(NAMED_STEP_FILES, process.argv, <package dir>)
// into `test.exclude`. A plain `vitest run` (turbo's all-packages Test step, a
// local `pnpm test`) then leaves those files out, while the step that names the
// file on the command line still runs it.
//
// A file counts as named only when a command-line argument resolves to the
// same path: plain (`tests/a.test.ts`), `./tests/a.test.ts`, or absolute. A
// partial filter such as `vitest run a` does not name it; that run then finds
// no file and vitest fails loudly ("No test files found").
//
// js/scripts/check-named-test-steps.mjs holds the rule against the workflow
// and tests this function in its --selftest.

import { isAbsolute, resolve } from 'node:path'

/**
 * @param {string[]} files package-relative test files (NAMED_STEP_FILES)
 * @param {string[]} argv the running process's argv
 * @param {string} packageDir absolute directory the files are relative to
 * @param {string} [cwd] directory relative arguments resolve against
 * @returns {string[]} the files this run does not name, to exclude
 */
export function excludeUnlessNamed(files, argv, packageDir, cwd = process.cwd()) {
  const named = new Set(
    argv
      .filter((arg) => typeof arg === 'string' && arg !== '' && !arg.startsWith('-'))
      .map((arg) => (isAbsolute(arg) ? resolve(arg) : resolve(cwd, arg))),
  )
  return files.filter((file) => !named.has(resolve(packageDir, file)))
}
