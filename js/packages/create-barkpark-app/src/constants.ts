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
