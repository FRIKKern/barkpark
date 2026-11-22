import { configDefaults, defineConfig } from 'vitest/config'
import { excludeUnlessNamed } from '../../test-utils/named-step-files.mjs'

// Test files a js-tests step runs by name. They run only there: a run that
// does not name a file leaves it out (js/test-utils/named-step-files.mjs), and
// js/scripts/check-named-test-steps.mjs holds this list against the workflow.
// Run them locally with `pnpm test:named-steps` from js/.
const NAMED_STEP_FILES = ['tests/conformance.test.tsx', 'tests/pd-golden-mirror-parity.test.ts']

export default defineConfig({
  test: {
    environment: 'node',
    exclude: [
      ...configDefaults.exclude,
      ...excludeUnlessNamed(NAMED_STEP_FILES, process.argv, import.meta.dirname),
    ],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'json'],
      include: ['src/**'],
    },
    setupFiles: ['../../test-utils/vitest.setup.ts'],
  },
})
