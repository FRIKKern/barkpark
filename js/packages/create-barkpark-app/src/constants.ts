declare const __BARKPARK_VERSION__: string

export const BARKPARK_VERSION: string =
  typeof __BARKPARK_VERSION__ !== 'undefined' ? __BARKPARK_VERSION__ : '0.1.0'

export const AVAILABLE_TEMPLATES = ['website-starter', 'blog-starter'] as const

export type TemplateName = (typeof AVAILABLE_TEMPLATES)[number]

export const DEFAULT_TEMPLATE: TemplateName = 'website-starter'

export const HOSTED_DEMO_URL = 'https://barkpark.dev'
