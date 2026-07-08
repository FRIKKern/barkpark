defmodule BarkparkWeb.ErrorHTML do
  @moduledoc """
  Renders errors on browser (HTML) requests (wired in `config/config.exs`
  `render_errors`).

  Phoenix's RenderErrors layer reaches here when an HTML request raises or hits
  an unmatched route. Without this module even a routine 404 on an unknown
  browser path crashes the error renderer itself and drops the connection.

  Minimal, self-contained pages: no layout, no external assets, no leaked
  exception detail. The heading/message are derived purely from the template
  name (`Phoenix.Controller.status_message_from_template/1`) — never from user
  input — so the static string is safe to interpolate.
  """

  # Phoenix hands "<status>.html" (e.g. "404.html", "500.html"). One catch-all
  # clause serves every status, deriving the code + human message from the
  # template name. The page is returned as SAFE iodata (Phoenix.HTML.raw/1) —
  # the HTML format encoder escapes plain binaries, which would ship the markup
  # as literal text. Safe here: both interpolated values derive from the
  # template name Phoenix passes in, never from user input.
  def render(template, _assigns) do
    code = template |> String.split(".") |> hd()
    message = Phoenix.Controller.status_message_from_template(template)
    Phoenix.HTML.raw(page(code, message))
  end

  defp page(code, message) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{code} · #{message}</title>
        <style>
          /* INTENTIONALLY ALWAYS-DARK (a stark error card, no theme switch).
             De-literalized onto design/tokens.json (color.errorPage) via the
             page-scoped FIXED-DARK block below — regenerate with
             `node design/emit.mjs --write`, never hand-edit. */
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
          main { text-align: center; padding: 2rem; }
          h1 { font-size: 3rem; margin: 0; font-weight: 700; letter-spacing: -0.02em; }
          p { color: var(--err-muted); margin: 0.5rem 0 0; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{code}</h1>
          <p>#{message}</p>
        </main>
      </body>
    </html>
    """
  end
end
