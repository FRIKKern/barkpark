declare const __BARKPARK_VERSION__: string

export const BARKPARK_VERSION: string =
  typeof __BARKPARK_VERSION__ !== 'undefined' ? __BARKPARK_VERSION__ : '1.0.0-preview.0'

export const AVAILABLE_TEMPLATES = ['website-starter', 'blog-starter'] as const

/**
 * The generator-owned shared template source, laid down UNDER every starter at
 * scaffold time. It is deliberately NOT in AVAILABLE_TEMPLATES: it is not a
 * starter a user can pick, it is the single authored copy of the framework
 * boilerplate every starter shares. Ownership note + the file roster: the block
 * comment at the top of scaffold.ts.
 */
export const SHARED_TEMPLATE_DIR = '_shared'

export type TemplateName = (typeof AVAILABLE_TEMPLATES)[number]

export const DEFAULT_TEMPLATE: TemplateName = 'website-starter'

export const HOSTED_DEMO_URL = 'https://barkpark.dev'

// The hosted demo at HOSTED_DEMO_URL does not answer today (no DNS record), so an app
// scaffolded with --hosted-demo would fail every API call. The flag stays, and
// refuses up front while this is false. Remove the flag or bring the host back is the
// owner's call (task-9b5a6d8efdfab59e); flip this when a demo host answers.
export const HOSTED_DEMO_AVAILABLE = false

export const HOSTED_DEMO_UNAVAILABLE_MESSAGE =
  "The hosted demo isn't available yet. Run a local Barkpark instead: leave out --hosted-demo, then run `bp setup --target local --yes` in the new app (see its README)."
