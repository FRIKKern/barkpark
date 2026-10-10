/**
 * The renderer's own words — chrome, never author content — in the caller's
 * language (task-8e96278fc4ee7097).
 *
 * Mirrors `Barkpark.PortableDoc.Render.Chrome`: the `strings` map is keyed by
 * the English text the renderer emits. A render builds ONE `RenderCtx` from it
 * and passes that ctx explicitly down every emitter — there is no module-level
 * state, so two renders running side by side on a server (RSC/SSR) can never
 * see each other's words. With no map, `ctx.t()` answers the English key, so a
 * render without `strings` is byte-identical to before. `%{name}` slots are
 * filled after lookup, as in Elixir.
 */
export type ChromeStrings = Record<string, string>

/** Per-render context threaded through every emitter. */
export interface RenderCtx {
  /** The chrome word `english` in this render's language (English when absent). */
  t: (english: string, vars?: Record<string, string | number>) => string
}

/** Build the render context for `strings` (English when omitted or malformed). */
export function makeCtx(strings?: ChromeStrings | null): RenderCtx {
  const map = strings && typeof strings === 'object' ? strings : null
  return {
    t(english, vars) {
      const hit = map && typeof map[english] === 'string' ? map[english] : english
      if (!vars) return hit
      return Object.keys(vars).reduce((acc, k) => acc.split(`%{${k}}`).join(String(vars[k])), hit)
    },
  }
}

/** The English context: what a render without `strings` uses. */
export const EN: RenderCtx = makeCtx()
