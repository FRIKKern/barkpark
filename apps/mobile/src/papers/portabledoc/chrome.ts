// The renderer's own words — chrome, never author content — in the workspace's
// language (task-5ba3360aecba7a99).
//
// Mirrors @barkpark/react's `makeCtx` and the Elixir `Render.Chrome`: words are
// keyed by the ENGLISH text the renderer emits, and a locale with no entry
// answers the English key. So a ctx without `locale` renders exactly as before
// in English. The translations match the server's nb gettext catalogue
// (`pgettext "data source"`: Source → Kilde, Sources → Kilder).

/** English key → translation, per workspace locale (BCP-47, as the server
 * reports it from GET /v1/workspace/locale). */
const STRINGS: Record<string, Record<string, string>> = {
  'nb-NO': {
    Source: 'Kilde',
    Sources: 'Kilder',
  },
}

/** The chrome word `english` in `locale` (English when the locale or the word
 * has no translation). */
export function chromeWord(locale: string | undefined, english: string): string {
  const map = locale !== undefined ? STRINGS[locale] : undefined
  return map?.[english] ?? english
}
