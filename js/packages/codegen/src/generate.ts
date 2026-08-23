// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import prettier from 'prettier'
import type { BarkparkSchemaJson, FieldDef, SchemaDef } from './types'

/** Past this composite recursion depth the mapper bails to `unknown`. */
const MAX_DEPTH = 5

/**
 * The server's reserved system keys — content/envelope.ex `@reserved`, the
 * exact set BarkparkSystemFields re-declares in the PRELUDE. A user field with
 * one of these names cannot coexist with the inherited member (a `_type` field
 * would double-declare beside the pinned literal; an `_id` field redeclares
 * the inherited `string` incompatibly), so it is refused loudly up front.
 */
const RESERVED_SYSTEM_KEYS: ReadonlySet<string> = new Set([
  '_id',
  '_type',
  '_rev',
  '_draft',
  '_publishedId',
  '_createdAt',
  '_updatedAt',
])

/**
 * The ONE collator every name sort goes through (cca-backlog-pinned-collator).
 * Bare `localeCompare` reads the HOST's default locale (LANG/LC_ALL at process
 * start), so emitted member order was in principle a function of the machine
 * that ran the generator — a latent contract violation against the drift gate,
 * which runs with no locale pin. Pinned to 'en-US', which is proven
 * byte-identical to the committed web/lib/barkpark.types.ts under every locale
 * measured (md5 6f33e5d1165dab07f4c6f869bb4f8bc8) — so this pin costs ZERO
 * regen. A code-unit sort is NOT equivalent here (two of the fixture's 81 name
 * lists flip, e.g. runRuleset|rune) and would force a regen of the committed
 * artifact — outside this change's fence.
 */
const NAME_COLLATOR = new Intl.Collator('en-US')

/** Read the optionality flag, tolerating both `required` and `required?` keys. */
function isRequired(field: FieldDef): boolean {
  const q = (field as Record<string, unknown>)['required?']
  if (typeof q === 'boolean') return q
  return field.required === true
}

/**
 * Schema name → a valid TS `interface` identifier. Unlike a property name, an
 * interface name can't be quoted, so non-identifier characters (`blog-post`) are
 * replaced with `_` and a leading digit gets an `_` prefix, then the first char
 * is upper-cased. Plain identifiers are unchanged. (A collision between two names
 * that sanitize identically would surface as a loud "duplicate interface" compile
 * error — never silent — and never occurs for conventional type names.)
 */
function pascalCase(name: string): string {
  let s = name.replace(/[^A-Za-z0-9_$]/g, '_')
  if (/^[0-9]/.test(s)) s = '_' + s
  return s.charAt(0).toUpperCase() + s.slice(1)
}

/**
 * Emit a property name bare when it's a valid JS identifier, else quoted —
 * a field named `my-field` / `2col` / `has space` must become `"my-field"?: …`
 * or the generated `.ts` won't compile. `JSON.stringify` also escapes quotes.
 */
function propName(name: string): string {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name) ? name : JSON.stringify(name)
}

/**
 * Quote a TS string-literal type member. Backslash and single-quote are escaped
 * first, then any raw control char (C0 + DEL) is escaped — a select value or
 * localizedText language key with a newline/tab would otherwise emit a
 * syntactically invalid `.ts` module that prettier rejects with an opaque error.
 * Backslash-first ordering means the C0 sweep only touches raw bytes, never the
 * `\n`/`\r`/`\t`/`\u…` sequences it just wrote.
 */
function literal(value: string): string {
  return (
    "'" +
    value
      .replace(/\\/g, '\\\\')
      .replace(/'/g, "\\'")
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '\\r')
      .replace(/\t/g, '\\t')
      .replace(/[\u0000-\u001f\u007f]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) +
    "'"
  )
}

/**
 * Build a one-line JSDoc comment (with trailing newline) from a schema/field's
 * `description`, falling back to its `title` — so consumers get hover docs in
 * the editor. Returns '' when neither is present. Whitespace is collapsed to a
 * single line and a literal `*​/` is neutralized so it can't close the comment
 * early. `indent` prefixes both the comment and its newline consumer.
 */
function docComment(node: Record<string, unknown>, indent: string): string {
  const desc = typeof node.description === 'string' ? node.description.trim() : ''
  const title = typeof node.title === 'string' ? node.title.trim() : ''
  const text = desc || title
  if (!text) return ''
  const safe = text.replace(/\s+/g, ' ').replace(/\*\//g, '* /')
  return `${indent}/** ${safe} */\n`
}

/**
 * Map a single field descriptor to its TypeScript type expression.
 * Recursive for `composite`, `array`, and `arrayOf`. `depth` counts composite
 * nesting; past {@link MAX_DEPTH} a composite degrades to `unknown`.
 */
function mapField(field: FieldDef, depth: number): string {
  switch (field.type) {
    // PRIMITIVES
    case 'string':
    case 'text':
    case 'color':
    case 'datetime':
      return 'string'
    case 'number':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'slug':
      return 'BarkparkSlug'
    case 'image':
      return 'BarkparkImage'

    // ENUMS
    case 'select': {
      const opts = Array.isArray(field.options) ? field.options : []
      const values: string[] = []
      for (const opt of opts) {
        const v = typeof opt === 'string' ? opt : opt?.value
        if (typeof v === 'string') values.push(v)
      }
      if (values.length === 0) return 'string'
      const members = [...new Set(values)].sort().map(literal)
      return members.join(' | ')
    }
    case 'codelist':
      // Registry-backed — no inline values, so no union.
      return 'string'

    // STRUCTURAL
    case 'reference':
      return 'BarkparkReference'
    case 'array': {
      // schema v1 — `of` is an ARRAY; element descriptor is of[0].
      const of = field.of
      if (Array.isArray(of) && of[0]) return `Array<${mapField(of[0], depth)}>`
      return 'Array<unknown>'
    }
    case 'arrayOf': {
      // schema v2 — `of` is a SINGLE descriptor object.
      const of = field.of
      if (of && !Array.isArray(of)) return `Array<${mapField(of, depth)}>`
      return 'Array<unknown>'
    }
    case 'composite':
      return mapComposite(field, depth)
    case 'object':
      return 'Record<string, unknown>'

    // SPECIAL
    case 'richText':
      return 'Array<BarkparkPortableTextBlock>'
    case 'localizedText': {
      // `languages` feeds `literal()` (which calls `.replace`), so a non-string
      // entry — reachable because zod doesn't validate nested field bodies —
      // would crash with an opaque TypeError. Filter to strings, mirroring the
      // `select` options defense above.
      const langs = Array.isArray(field.languages)
        ? field.languages.filter((l): l is string => typeof l === 'string')
        : []
      if (langs.length > 0) {
        const keys = [...new Set(langs)].sort().map(literal).join(' | ')
        return `Partial<Record<${keys}, string>>`
      }
      return 'Partial<Record<string, string>>'
    }

    // UNKNOWN — never silently dropped; surfaced as `unknown`.
    default:
      return 'unknown'
  }
}

/** Render a `composite` field as an inline anonymous object, recursing on its sub-fields. */
function mapComposite(field: FieldDef, depth: number): string {
  if (depth >= MAX_DEPTH) return 'unknown'
  const subs = field.fields ?? []
  if (subs.length === 0) return 'Record<string, unknown>'
  // A composite sub-field becomes a named object member, so it MUST carry a
  // `name`. zod's envelope check only asserts name/type on the top-level field
  // of each schema (its lazy body doesn't recurse into `fields`/`of`), so a
  // nameless nested descriptor slips through — reading `a.name.localeCompare`
  // below would then throw an opaque `TypeError: … reading 'localeCompare'`
  // (only when 2+ subs make Array.sort actually invoke the comparator). Fail
  // loud with a locatable message instead, matching how the envelope validator
  // rejects a top-level field with no name.
  //
  // The null/non-object arm comes FIRST: zod's field body is
  // `.object({name,type}).passthrough()`, so a nested `fields` entry is an
  // unvalidated passthrough key and `[{name:'a',…}, null]` parses clean. Reading
  // `sub.name` inside the guard's own test expression would then throw the very
  // `TypeError: Cannot read properties of null (reading 'name')` this guard
  // exists to eliminate. One error path, one message — a primitive sub (123,
  // 'x') lands here too.
  for (const sub of subs) {
    if (sub == null || typeof sub !== 'object' || typeof sub.name !== 'string' || sub.name === '') {
      throw new Error(
        `codegen: a composite field${field.name ? ` ("${field.name}")` : ''} has a sub-field with no \`name\`; every composite sub-field needs a name to become a typed member`,
      )
    }
  }
  const sorted = [...subs].sort((a, b) => NAME_COLLATOR.compare(a.name, b.name))
  const members = sorted.map((sub) => {
    const opt = isRequired(sub) ? '' : '?'
    return `${propName(sub.name)}${opt}: ${mapField(sub, depth + 1)}`
  })
  return `{ ${members.join('; ')} }`
}

/** Emit one `interface` for a schema, extending BarkparkSystemFields. */
function emitInterface(schema: SchemaDef): string {
  const typeName = pascalCase(schema.name)
  const fields = [...(schema.fields ?? [])].sort((a, b) => NAME_COLLATOR.compare(a.name, b.name))
  // Narrow `_type` from the inherited `string` to the schema-name literal — this
  // is what makes the BarkparkAnyDocument union discriminable (`if (d._type ===
  // 'post')` narrows `d` to Post). Valid TS: a literal is assignable to string.
  const lines = [
    `  _type: ${literal(schema.name)}`,
    ...fields.map((f) => {
      const opt = isRequired(f) ? '' : '?'
      return `${docComment(f, '  ')}  ${propName(f.name)}${opt}: ${mapField(f, 0)}`
    }),
  ]
  const body = `\n${lines.join('\n')}\n`
  return `${docComment(schema, '')}export interface ${typeName} extends BarkparkSystemFields {${body}}`
}

/** The fixed prelude: system fields + value-type aliases, all self-declared. */
const PRELUDE = `/**
 * System fields present on every Barkpark document. Self-declared here so the
 * generated module is fully standalone. No index signature — that is the
 * point: \`post.unknownField\` is a compile error.
 *
 * Mirrors the server's reserved keys (content/envelope.ex @reserved) and
 * @barkpark/core's BarkparkDocument — every document envelope carries \`_draft\`
 * and \`_publishedId\`, so a codegen-typed \`doc._draft\` must type-check.
 */
export interface BarkparkSystemFields {
  _id: string
  _type: string
  _createdAt: string
  _updatedAt: string
  _rev: string
  _draft: boolean
  _publishedId: string
}

/** A slug value. */
export interface BarkparkSlug {
  current: string
}

/** An image value (flat, structurally an ImageRef the core resolver reads). */
export interface BarkparkImage {
  _type: 'image'
  _ref?: string
  _id?: string
  url?: string
}

/** A reference value (no target generic). */
export interface BarkparkReference {
  _ref: string
  _type: 'reference'
}

/** A PortableText / rich-text block. */
export interface BarkparkPortableTextBlock {
  _type: string
  _key?: string
  [k: string]: unknown
}`

/** Options for {@link generateTypes}. */
export interface GenerateOptions {
  /**
   * Dataset name for the banner comment. The envelope carries no name (only a
   * hash), so the caller threads it through from config. Defaults to
   * `"unknown"`.
   */
  dataset?: string
  /**
   * Absolute path of the file the caller will write the result to. When set,
   * the prettier config is resolved against THIS path (the generated file is
   * formatted like its committed siblings), so formatting is a function of the
   * output location — never of the invoking CWD. When absent, no config search
   * happens at all and prettier defaults apply (deterministic by construction).
   */
  outputPath?: string
}

/**
 * Generate the full TypeScript module from a schema envelope. Deterministic:
 * schemas and fields are sorted by name, union members are sorted, and the
 * prettier config is resolved against `outputPath` (or skipped entirely when
 * none is given), so the same input + output location always produces
 * byte-identical output regardless of the directory the generator runs from.
 */
export async function generateTypes(
  envelope: BarkparkSchemaJson,
  options: GenerateOptions = {},
): Promise<string> {
  // A schema name becomes an `interface` identifier, so it MUST be non-empty:
  // `pascalCase('')` is `''` and the envelope's `name: z.string()` carries no
  // `.min(1)`, so an empty name emitted `export interface  extends …` and died
  // downstream in prettier with `SyntaxError: Declaration or statement expected.
  // (48:1)` — a line number in GENERATED output, pointing at nothing the author
  // wrote. Fail here instead, naming the offending schema's position in the
  // envelope (pre-sort, so it matches what the author sees). Deliberately not
  // sanitized into an invented name: emitting a type nobody asked for is worse
  // than refusing.
  envelope.schemas.forEach((schema, i) => {
    if (schema.name === '') {
      throw new Error(
        `codegen: schema #${i} has an empty \`name\`; every schema needs a name to become a typed interface`,
      )
    }
  })

  // Belt-and-suspenders guards (cca-backlog-reserved-system-field-names). All
  // three shapes are unreachable from the live /v1/schemas API — the server
  // rejects reserved keys (content/envelope.ex @reserved) and duplicate names —
  // so they arrive only via a hand-authored --from fixture. They used to emit
  // TypeScript that failed at the CONSUMER's tsc (two identical interfaces, a
  // twice-declared `_type` member, an `_id` redeclaring the inherited string
  // with an incompatible type): invalid-but-loud in the wrong place. Fail HERE,
  // with a locatable message, before writing a byte. Positions are pre-sort so
  // they match what the author sees in the fixture.
  const byInterface = new Map<string, { index: number; name: string }>()
  envelope.schemas.forEach((schema, i) => {
    const typeName = pascalCase(schema.name)
    const prev = byInterface.get(typeName)
    if (prev !== undefined) {
      throw new Error(
        `codegen: schema #${prev.index} ("${prev.name}") and schema #${i} ("${schema.name}") both become interface "${typeName}" — duplicate type names emit invalid TypeScript; rename one`,
      )
    }
    byInterface.set(typeName, { index: i, name: schema.name })

    ;(schema.fields ?? []).forEach((field, j) => {
      if (typeof field?.name === 'string' && RESERVED_SYSTEM_KEYS.has(field.name)) {
        throw new Error(
          `codegen: schema "${schema.name}" field #${j} is named "${field.name}", a server-reserved system key — generated interfaces already carry it via BarkparkSystemFields; rename the field`,
        )
      }
    })
  })

  const schemas = [...envelope.schemas].sort((a, b) => NAME_COLLATOR.compare(a.name, b.name))
  const dataset = options.dataset ?? 'unknown'

  const banner = `// Generated by @barkpark/codegen from dataset "${dataset}" at schema hash ${envelope.datasetSchemaHash}. DO NOT EDIT — run barkpark generate.`

  const interfaces = schemas.map(emitInterface).join('\n\n')

  // Emitted as a `type` (not an `interface`) so it satisfies the
  // `TMap extends Record<string, object>` constraint on
  // `@barkpark/core`'s `typedClient<TMap>` — an interface lacks the implicit
  // index signature that constraint requires, so `typedClient<BarkparkTypeMap>`
  // would otherwise be a compile error. A type alias has it.
  const mapEntries = schemas.map((s) => `  ${propName(s.name)}: ${pascalCase(s.name)}`).join('\n')
  const typeMap = `export type BarkparkTypeMap = {\n${mapEntries}\n}`

  // Discriminated union of every document type — narrow a mixed/unknown document
  // by `_type` with full type safety (each interface pins its `_type` literal).
  const members = schemas.map((s) => pascalCase(s.name))
  const union = `export type BarkparkAnyDocument = ${members.length > 0 ? members.join(' | ') : 'never'}`

  const source = [banner, '', PRELUDE, '', interfaces, '', typeMap, '', union, ''].join('\n')

  // Config resolution is anchored to the OUTPUT file, never process.cwd():
  // prettier treats the argument as a FILE path (the search starts in its
  // parent), so the old resolveConfig(process.cwd()) made the emitted bytes a
  // function of where the generator happened to run — cwd=js/ found nothing
  // (defaults) while cwd=js/packages/codegen found js/.prettierrc, and the
  // whole diff was semicolons. Without an outputPath there is deliberately NO
  // filesystem search: prettier defaults, byte-stable anywhere.
  const config =
    options.outputPath !== undefined
      ? await prettier.resolveConfig(options.outputPath).catch(() => null)
      : null
  return prettier.format(source, {
    ...(config ?? {}),
    parser: 'typescript',
  })
}
