// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/** An inline object's display text: the first non-empty string among text,
 * title, label, name, value. Its own module so the PortableText shim can use
 * it without pulling in the PortableDoc inline grammar. Twins: inline.ex
 * inline_object_text/1, inline.go inlineObjectText; locked by
 * api/test/support/fixtures/inline-object-text.json. */
export function inlineObjectText(node: Record<string, unknown>): string {
  for (const k of ['text', 'title', 'label', 'name', 'value']) {
    const v = node[k]
    if (typeof v === 'string' && v !== '') return v
  }
  return ''
}
