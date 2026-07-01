// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import prettier from 'prettier'
import type { BarkparkSchemaJson, FieldDef, SchemaDef } from './types'

/** Past this composite recursion depth the mapper bails to `unknown`. */
const MAX_DEPTH = 5

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

/** Quote a TS string-literal type member. */
function literal(value: string): string {
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
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
      const opts = field.options ?? []
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
      return 'unknown'
    case 'localizedText': {
      const langs = field.languages
      if (Array.isArray(langs) && langs.length > 0) {
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
  const sorted = [...subs].sort((a, b) => a.name.localeCompare(b.name))
  const members = sorted.map((sub) => {
    const opt = isRequired(sub) ? '' : '?'
    return `${propName(sub.name)}${opt}: ${mapField(sub, depth + 1)}`
  })
  return `{ ${members.join('; ')} }`
}

/** Emit one `interface` for a schema, extending BarkparkSystemFields. */
function emitInterface(schema: SchemaDef): string {
  const typeName = pascalCase(schema.name)
  const fields = [...(schema.fields ?? [])].sort((a, b) => a.name.localeCompare(b.name))
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

/** An image value. */
export interface BarkparkImage {
  _type: 'image'
  asset?: { _ref: string }
}

/** A reference value (no target generic). */
export interface BarkparkReference {
  _ref: string
  _type: 'reference'
}`

/** Options for {@link generateTypes}. */
export interface GenerateOptions {
  /**
   * Dataset name for the banner comment. The envelope carries no name (only a
   * hash), so the caller threads it through from config. Defaults to
   * `"unknown"`.
   */
  dataset?: string
}

/**
 * Generate the full TypeScript module from a schema envelope. Deterministic:
 * schemas and fields are sorted by name, union members are sorted, so the same
 * input always produces byte-identical output. The result is formatted with the
 * repo's prettier config.
 */
export async function generateTypes(
  envelope: BarkparkSchemaJson,
  options: GenerateOptions = {},
): Promise<string> {
  const schemas = [...envelope.schemas].sort((a, b) => a.name.localeCompare(b.name))
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

  const config = await prettier.resolveConfig(process.cwd()).catch(() => null)
  return prettier.format(source, {
    ...(config ?? {}),
    parser: 'typescript',
  })
}
