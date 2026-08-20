# Hermetic paper render + reader-ETag warm-fetch hazard — re-derivation recipe (2026-08-12)

Lane v7-hermetic-render, paper-excellence wave. Every number below is reproducible on a
checkout of `main` with `api/deps` fetched. **No database, no Phoenix server, no network**
is needed for the render itself.

## 0. Prereqs

    cd api && CC=clang mix deps.get      # mix.lock is NOT modified (shasum before/after)

## 1. The render entry point (the briefed probe was wrong twice)

`Barkpark.PortableDoc.Render.render_html/2` (api/lib/barkpark/portable_doc/render.ex:144)
returns a **plain binary**, not a tuple — `elem(_, 1)` raises — and it takes a **Pd TREE**
(`%{"kind" => "PdContainer", ...}`), not a paper's `blocks` list. Feeding it `%{"blocks" => …}`
returns `""` for `doctype: false` (silently empty) and a ~97 KB CSS-only shell for the default
`doctype: true`. The blocks-list entry points are `render_blocks/2` (render.ex:353) and
`render_block/2` (render.ex:243) — the latter is what the reader LiveView calls.

## 2. Hermetic render of a real paper, byte-identical to production

    curl -s https://guerrilla.barkpark.cloud/papers/heggemsnes-act/source -o /tmp/src.json
    curl -s https://guerrilla.barkpark.cloud/papers/heggemsnes-act        -o /tmp/live.html
    cd api && CC=clang MIX_ENV=test mix run --no-start -e '
      live = File.read!("/tmp/live.html")
      blocks = File.read!("/tmp/src.json") |> Jason.decode!() |> get_in(["source","blocks"])
      res = for b <- blocks do
        {b["type"], String.contains?(live, Barkpark.PortableDoc.Render.render_block(b, %{style: :article}))}
      end
      IO.puts("MATCH #{Enum.count(res, &elem(&1,1))}/#{length(res)}")'
    # => MATCH 19/19

## 3. Full reader page, hermetically (layout + shell + CSS)

    cd api && CC=clang MIX_ENV=test mix run --no-start -e '
      {:ok,_} = Application.ensure_all_started(:phoenix)
      {:ok,_} = Phoenix.PubSub.Supervisor.start_link(name: Barkpark.PubSub)
      {:ok,_} = BarkparkWeb.Endpoint.start_link()          # config/test.exs:71 server: false
      blocks = File.read!("/tmp/src.json") |> Jason.decode!() |> get_in(["source","blocks"])
      body  = Barkpark.PortableDoc.Render.render_blocks(blocks, %{style: :article})
      inner = ~s(<main class="bp-paper-shell bp-paper-surface bp-paper-article"><article id="paper-body">) <> body <> "</article></main>"
      assigns = %{inner_content: Phoenix.HTML.raw(inner), page_title: "x", preview: nil, csp_nonce: "n0", bp_theme: nil}
      html = BarkparkWeb.Layouts.bulldocs(assigns) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      File.write!("/tmp/herm.html", html)'

Two pieces the layout does NOT give you and the rig must add by hand:

* the `<main class="bp-paper-shell bp-paper-surface bp-paper-article">` wrapper —
  it lives in the LiveView (`bulldocs_live.ex:974`), not the layout. Omit it and every
  `.bp-paper-article` rule is dead: the measured column becomes `BODY`/1440px.
* `<html data-bp-theme="fjord">` — the workspace theme identity. Omit it and only the
  COLORS drift (light bg `234,241,238` vs live `231,240,242`); geometry/type are unaffected.

The concatenated `<style>` bytes are **identical** live vs hermetic (154 732 B both).

## 4. Screenshot + computed-style parity (playwright, vendored)

    mkdir -p /tmp/root/fonts /tmp/root/assets
    cp api/priv/static/fonts/*.woff2 /tmp/root/fonts/
    cp api/priv/static/assets/{phoenix.js,phoenix_live_view.js,bp-graph.js} /tmp/root/assets/
    cp /tmp/herm.html /tmp/root/index.html
    (cd /tmp/root && python3 -m http.server 8917 &)     # VERIFY THE BIND — see §6
    node <measure.mjs> /tmp/shots http://127.0.0.1:8917/index.html HERM

Result, hermetic vs live, all four (light|dark)×(1440|768) cells: **zero diffs** on
container classes, containerW 720, left 360/24, plainCount 13, body-p 16px/26.4px/start/
hyphens:auto/Iowan Old Style/640px, ingress 20.48px/30.72px, h1 32px, body bg, main bg.

## 5. Two fidelity limits of an OFFLINE run

* CDN-blocked (`page.route('**://cdn.jsdelivr.net/**', abort)`): type + geometry are
  unchanged (720 / 16px / 26.4px) but `window.mermaid === "undefined"` — mermaid and
  asciicast blocks do not render. Vendor those libs locally or exclude those blocks.
* Font stack: `document.fonts.check('16px "Source Serif 4"') === false` on macOS because
  **Iowan Old Style** wins. A Linux CI runner has neither and falls further down the stack,
  so baselines must be captured in the SAME image as the gate.
* Wikilinks / valuerefs / note-embeds / live-task blocks resolve through caller-supplied
  maps (`:wikilinks`, `:embeds`, `:values` — render.ex:144 docstring). A hermetic rig must
  pin them in the fixture or those blocks degrade to fallbacks.

## 6. Trap that produced a false green here

`python3 -m http.server 8917` silently loses the bind if the port is taken; `curl -o /dev/null`
still returned `200` — from an unrelated JSON service. Always assert the body:

    curl -s http://127.0.0.1:$PORT/index.html | grep -c bp-paper-article   # must be > 0

## 7. Reader ETag: no cache in front, but a real warm-fetch hazard

    curl -s -D - -o /dev/null https://guerrilla.barkpark.cloud/papers/heggemsnes-act

`cache-control: private, max-age=0, must-revalidate`, `via: 1.1 Caddy`, **no `age`, no
`x-cache`**, and a fresh `x-request-id` per fetch ⇒ no shared/CDN cache.

But the validator is content-only:

    etag: W/"sha256:<canonical_digest(content)>.<div(os_time,604800)>"
    # api/lib/barkpark_web/plugs/paper_revision_headers.ex:176-179 ; bucket 2953 == now/604800

Proof it ignores the rendered bytes: two fetches, different body sha1
(`5ec17d9b…` vs `6ae8c63a…`, CSP nonce + LV token), **identical ETag**. A conditional
request with that ETag gets `304`. So after a CSS/renderer deploy that does not touch paper
content, any caching client (warm browser profile, caching HTTP client) may be served its
OLD copy for up to the 7-day bucket edge. A screenshot rig pointed at guerrilla must send
`Cache-Control: no-cache` / use a cold context, or it can photograph pre-change bytes.

## 8. `scripts/pdrender-dump.sh` is not an HTML path

    bash scripts/pdrender-dump.sh --help   # -> "read --help: open --help: no such file", exit 1

It is `go run ./internal/pdrender/cmd/dump <paper.json> [width]` — the TERMINAL renderer.
Useful for TUI goldens, irrelevant to the screenshot gate.
