defmodule BarkparkWeb.StudioRefusalHTML do
  @moduledoc """
  The HTML page `BarkparkWeb.Plugs.ResolveWorkspace` renders for a signed-in
  browser request the Studio membership gate refuses (task-47ab98b3226672ef).

  Rendered through `Phoenix.Controller.render/3` (a `put_view` + template
  lookup, same shape `BarkparkWeb.ErrorHTML` uses for a plug-level page with
  no controller action behind it) rather than a direct
  `Phoenix.Controller.html/2` call: Sobelow's `XSS.HTML` check flags ANY
  non-literal body passed to that specific function regardless of escaping
  (see `RateLimit`'s own `@html_429` comment for the prior case of this),
  and the actual `send_resp` for a template render happens inside Phoenix's
  own compiled code, outside anything Sobelow scans in this app.

  The markup itself is a real `~H` (HEEx) template, not a hand-built string
  passed through `Phoenix.HTML.raw/1` — `error_html.ex`'s `page/2` does the
  latter and carries Sobelow's matching `XSS.Raw` finding uncounted on main
  (same blunt "is the `raw/1` argument a literal" check, same false
  positive: both interpolated values there come from the template name
  Phoenix passes in, never request input). `~H` auto-escapes every `{...}`
  interpolation at compile time and isn't a call to `raw/1` at all, so this
  file carries neither finding. Every interpolated value here is a static
  gettext string (translator-authored, never request input) or
  `StudioLocale.html_lang/0` (the locale the plug put on this process,
  restricted to `Tenancy.known_locales/0`) — nothing from the request
  itself (workspace slug, refusal reason) ever reaches this page, which is
  the point (no existence leak).

  Its palette is `design/tokens.json`'s `color.errorPage` — the same fixed-
  dark family `BarkparkWeb.ErrorHTML`'s 404/500 page uses, via the SAME
  generated `:root` block (design/emit.mjs's `errorPageBlock/0`, now emitted
  into both files). Studio's literal-color gate
  (`scripts/studio-literal-check.sh`) bans a bare hex/hsl() outside that
  block; there is no bespoke accent here for exactly that reason — both
  buttons are styled from `--err-bg`/`--err-fg`/`--err-muted` alone.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.StudioLocale

  def render("refusal.html", assigns) do
    assigns =
      Map.merge(assigns, %{
        lang: StudioLocale.html_lang(),
        title: gettext("Studio · Not a member"),
        heading: gettext("You're not a member of this workspace"),
        body:
          gettext(
            "You're signed in, but this account doesn't have access here. Go to one of your own workspaces, or sign in as someone else."
          ),
        go_home: gettext("Go to your workspace"),
        sign_in_other: gettext("Sign in as someone else")
      })

    ~H"""
    <!DOCTYPE html>
    <html lang={@lang}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
        <style>
          /* INTENTIONALLY ALWAYS-DARK (a stark error card, no theme switch).
             De-literalized onto design/tokens.json (color.errorPage) via the
             page-scoped FIXED-DARK block below — regenerate with
             `node design/emit.mjs --write`, never hand-edit. Shared verbatim
             with error_html.ex's own block (same family, same builder). */
          /* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */
          :root {
            --err-bg: #0f1115;
            --err-fg: #e6e6e6;
            --err-muted: #9aa0a6;
          }
          /* END GENERATED: tokens */
          body {
            font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
            background: var(--err-bg);
            color: var(--err-fg);
            display: flex;
            min-height: 100vh;
            margin: 0;
            align-items: center;
            justify-content: center;
          }
          main { text-align: center; padding: 2rem; max-width: 28rem; }
          h1 { font-size: 1.75rem; margin: 0 0 0.75rem; font-weight: 700; letter-spacing: -0.01em; }
          p { color: var(--err-muted); margin: 0 0 1.5rem; line-height: 1.5; }
          .actions { display: flex; gap: 0.75rem; justify-content: center; flex-wrap: wrap; }
          a.btn {
            display: inline-block;
            padding: 0.5rem 1rem;
            border-radius: 0.375rem;
            text-decoration: none;
            font-weight: 600;
            border: 1px solid var(--err-muted);
          }
          a.btn-primary { background: var(--err-fg); color: var(--err-bg); border-color: var(--err-fg); }
          a.btn-secondary { background: transparent; color: var(--err-fg); }
        </style>
      </head>
      <body>
        <main>
          <h1>{@heading}</h1>
          <p>
            {@body}
          </p>
          <div class="actions">
            <a class="btn btn-primary" href="/">{@go_home}</a>
            <a class="btn btn-secondary" href="/login">{@sign_in_other}</a>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
