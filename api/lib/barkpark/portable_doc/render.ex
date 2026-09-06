defmodule Barkpark.PortableDoc.Render do
  @moduledoc """
  Pd-tree → inline-styled HTML string. Pure string emission. NO React, NO JSX,
  NO Node sidecar — a STANDALONE Elixir renderer. Its real cross-runtime twin is
  the Go terminal renderer in `internal/pdrender` (ANSI instead of HTML), which
  walks the same `%{version, blocks[]}` document; the two are held in lock-step
  by the golden fixtures under `internal/pdrender/testdata/golden/`.

  Output sticks to inline styles only (no `<style>` blocks, no class selectors)
  so it stays byte-comparable with the email backend.

  A Pd-tree node is a plain map keyed by string keys, e.g.

      %{"kind" => "PdText", "weight" => "bold", "children" => ["hi"]}

  This module is **pure**: no Repo, no GenServer, no I/O.

  ## Structure (post-decomposition)

  This module is now a thin **facade** over a family of focused sub-modules —
  the public surface (`render_html/2`, `render_block/2`, `render_blocks/2`,
  `compose_block/1,2`, plus the `escape_html` / `safe_url` / palette helpers)
  is unchanged for every caller; only the implementation moved:

    * `Render.Util`     — escape_html / escape_attr / safe_url / tone_palette
    * `Render.Palettes` — email / article palettes + colour / font constants
    * `Render.Inline`   — compose_inline* (inline nodes/marks → Pd-tree)
    * `Render.Forms`    — form / questionnaire block HTML
    * `Render.Figures`  — diagram / asciicast / code / divider `_raw` HTML
    * `Render.Compose`  — compose_block (block → Pd-tree) + field helpers
    * `Render.Walk`     — walk/3 (Pd-tree → HTML) + per-kind renderers

  Behaviour-preserving: render output is byte-identical to the single-module
  engine that preceded the split.
  """

  alias Barkpark.PortableDoc.Render.{Compose, Palettes, Stylesheet, Util, Walk}

  # Render-output version for the body_html cache: a sha256 DIGEST OF THE
  # RENDERER'S OWN SOURCE TEXT, computed at compile time. It replaces the
  # hand-typed integer that preceded it (v1→v3), which was a version only as
  # long as a human remembered to bump it — four S-tier pdrender rounds landed
  # without a bump and the published papers went stale behind a matching stamp.
  # Derived, the stamp cannot lag the renderer: editing any covered file moves
  # the digest, and `mix barkpark.rehydrate_body_html` sees the drift.
  #
  # Covered set: this file + every `render/*.ex` + `slots.ex` — the whole render
  # path and nothing else (Tiers and Constraints are not on it). `@external_resource`
  # on each one makes mix recompile this module whenever any of them changes.
  #
  # The bytes are hashed in an EXPLICITLY SORTED order (never filesystem
  # enumeration order) and each file contributes its basename alongside its
  # contents, so the digest is stable across machines and build directories but
  # still moves if files are renamed or swapped.
  #
  # NOT a .beam hash: a raw whole-.beam MD5 embeds the absolute source path and
  # is therefore not rebuild-stable, and `:beam_lib.md5/1` needs already-loaded
  # modules — a chicken-and-egg at this module's own compile time, and sensitive
  # to the OTP toolchain (the prod host is ARM/ASDF).
  #
  # KNOWN AND ACCEPTED: a transitive Hex dependency bump can change rendered
  # bytes without touching a covered file, leaving the digest unmoved. The
  # rehydrate sweep's byte-compare is the backstop for that class; solving it
  # here is explicitly out of scope.
  # Sorted as names RELATIVE to this directory, never as absolute paths: the
  # relative names are identical on every machine and in every build directory,
  # so the hash order cannot shift with a checkout location.
  @render_source_names ([
                          "render.ex",
                          "slots.ex"
                        ] ++
                          Enum.map(
                            ~w(
                              cards_email.ex components.ex compose.ex data_viz.ex figures.ex
                              fleet_email.ex forms.ex inline.ex math.ex palettes.ex
                              panels_email.ex section_layout.ex status_vocab.ex stylesheet.ex tokens_gen.ex
                              util.ex walk.ex
                            ),
                            &("render/" <> &1)
                          ))
                       |> Enum.sort()

  @render_source_files Enum.map(@render_source_names, &Path.join(__DIR__, &1))

  for path <- @render_source_files do
    @external_resource path
  end

  @body_html_render_version @render_source_names
                            |> Enum.reduce(:crypto.hash_init(:sha256), fn name, acc ->
                              :crypto.hash_update(
                                acc,
                                name <> "\0" <> File.read!(Path.join(__DIR__, name))
                              )
                            end)
                            |> :crypto.hash_final()
                            |> Base.encode16(case: :lower)

  @doc """
  The current body_html render-version — a sha256 hex digest of the renderer's
  own source. Stamped onto `content["body_html_sv"]` at every fresh block→HTML
  render (the paper write path) so a stale frozen cache — one rendered by a
  prior renderer — is detectable and rehydratable.

  A content hash has NO TOTAL ORDER: only identity is meaningful. Compare it
  with `==`, never `>=`.
  """
  def body_html_render_version, do: @body_html_render_version

  @doc """
  The covered file names — relative to the portable_doc directory, in the exact
  sorted order the digest hashes them. Exposed so a test can assert the covered
  set against the render directory on disk: a newly added `render/*.ex` that is
  not listed here would otherwise fall silently outside the digest.
  """
  def render_source_names, do: @render_source_names

  @doc """
  The absolute paths whose bytes feed `body_html_render_version/0`, in hash order.
  """
  def render_source_files, do: @render_source_files

  @doc false
  defdelegate email_palette, to: Palettes
  @doc false
  defdelegate article_palette, to: Palettes

  @doc """
  Render a Pd-tree `root` to an HTML string.

  Options (a map):

    * `:doctype` — wrap the body in a full `<!doctype html>…</html>` document.
      Defaults to `true`; pass `false` to emit only the body fragment.
    * `:container_width` — outer width budget in px. Defaults to `600`.
    * `:style` — render palette: `:email` (default, the module constants) or
      `:article` (native paper-article serif/parchment palette). Opt-in only; the
      `:email` default keeps existing output byte-unchanged.
    * `:theme` — theme identity (charter D28): an id (atom/string; `:evergreen`
      default, unknown → evergreen) or a `{slot => value}` override map. Threads
      to `Palettes.palette_for/2` → every colour the walker emits. `:evergreen`
      keeps output byte-identical; a non-evergreen theme moves the bytes.
  """
  def render_html(root, opts \\ %{}) do
    theme = Map.get(opts, :theme, :evergreen)

    palette =
      Map.get(opts, :style, :email)
      |> Palettes.palette_for(theme)
      # Wikilink resolution rides the palette (already threaded to every walk/3).
      # `:wikilinks` is a caller-supplied %{raw_target => %{id: ...}} map — the
      # caller pre-resolves targets (via Content.resolve_wikilink) and passes it.
      # Absent ⇒ %{} ⇒ every wikilink stays the unresolved dotted span (the
      # render is byte-identical for callers that don't opt in). Same
      # pure-renderer + injected-resolution pattern as :ref_resolver below.
      |> Map.put(:wikilinks, Map.get(opts, :wikilinks, %{}))
      # Note-embed transclusion rides the palette the same way as `:wikilinks`.
      # `:embeds` is a caller-supplied %{raw_target => prerendered_html_string}
      # map — the caller pre-renders each transcluded target paper to an HTML
      # string (via Papers.resolve_embeds_in_blocks) and passes it. Absent ⇒ %{}
      # ⇒ every embed degrades to the unresolved broken-embed fallback (render
      # byte-identical for callers that don't opt in). The walker only INJECTS
      # the string — it never renders recursively (one-level + cycle-safe).
      |> Map.put(:embeds, Map.get(opts, :embeds, %{}))
      # Inline live values (lvw-t1, wire §5) ride the palette the same way.
      # `:values` is a caller-supplied `%{{target, field} => rendered_string}`
      # map — the caller pre-resolves every (target, field) pair in ONE batched
      # pass (via Papers.resolve_values_in_blocks) and passes it. Absent ⇒ %{}
      # ⇒ every valueref degrades to its pinned `fallback` literal (render
      # byte-identical for callers that don't opt in; never a raise/blank).
      # The walker derives the lvw-t2 marker state from this map at the
      # injection point: hit + fallback match ⇒ `resolved`, hit + pinned
      # fallback differs ⇒ `drift`, miss ⇒ `dangling` (drift uncomputable).
      |> Map.put(:values, Map.get(opts, :values, %{}))
      # ACCEPT-BASELINE opt-in (lvw-t2, D4): `valueref_accept: true` makes a
      # DRIFTED valueref carry Studio's accept-baseline control. Studio's own
      # per-request paper view is the only caller that sets it — the body_html
      # cache, delta frames, and the public reader keep the default `false`,
      # so the control never leaks into shared caches or anonymous HTML.
      |> Map.put(:valueref_accept, Map.get(opts, :valueref_accept, false))

    width = Map.get(opts, :container_width, Map.fetch!(palette, :width))
    body = Walk.render_body(root, width, palette)

    if Map.get(opts, :doctype, true) == false do
      body
    else
      document(body, palette)
    end
  end

  # Standalone document wrapper.
  #
  # `:article` — a self-contained `.html` export. It embeds the ONE canonical
  # paper-surface stylesheet (`Stylesheet.css/0`, compile-time-inlined from
  # `api/assets/paper-surface/paper-surface.css`) inside `<head>` and stamps
  # `class="bp-paper-surface"` on `<body>`, so the article styles itself from the
  # single source — no network fetch (CSP-safe), no hand-mirror to drift. The
  # existing inline `background:#{palette.bg}` stays as the no-CSS fallback.
  #
  # A standalone export has NO `html[data-theme]` ancestor, so the stylesheet's
  # unscoped `.bp-paper-surface` fallback token block paints its LIGHT values;
  # dark mode only engages under a host that stamps `data-theme` on an ancestor.
  defp document(body, %{style: :article} = palette) do
    ~s(<!doctype html><html><head><meta charset="utf-8"><style>) <>
      Stylesheet.css() <>
      ~s(</style></head>) <>
      ~s(<body class="bp-paper-surface" style="background:#{palette.bg};margin:0;padding:0;">) <>
      body <>
      "</body></html>"
  end

  # Every other palette (`:email` — Outlook is the contract) keeps today's inline
  # wrapper BYTE-FOR-BYTE: email clients strip `<style>`, so inline is the only
  # correct emission there. This wrapper is byte-frozen by a render_test freeze
  # (and the email golden rides `doctype: false`, so the freeze is the only guard
  # on the `:email` `doctype: true` document envelope).
  defp document(body, palette) do
    ~s(<!doctype html><html><head><meta charset="utf-8"></head>) <>
      ~s(<body style="background:#{palette.bg};margin:0;padding:0;">) <>
      body <>
      "</body></html>"
  end

  # ── block → HTML (Wave 4 entry point) ──────────────────────────────────────
  #
  # The function above renders a *Pd-tree* (`%{"kind" => "PdText", …}`). The
  # functions below render a portable-doc *block list* — the AST shape that
  # `Barkpark.PortableDoc.Patch` operates on (`%{"id" => …, "type" => …}`) and
  # that the Papers context stores. They first `compose_block/2` each block into
  # a Pd-tree (via `Render.Compose.compose_block/2`), then walk it — the same
  # compose-then-walk pairing the Go `internal/pdrender` twin performs.

  @doc """
  Render a single portable-doc block to a bare HTML fragment — no `<!doctype>`,
  no `<html>`, no container `<div>`.

  The composed Pd-tree is walked with `doctype: false`, so the output is the
  same fragment that block would produce inside a full-document render. A
  `section` block carries its own leading/trailing `PdHr` rules (they live in
  the block's composed sub-tree), so they survive here by design.
  """
  def render_block(block, opts \\ %{}) when is_map(block) do
    style = Map.get(opts, :style, :email)
    theme = Map.get(opts, :theme, :evergreen)

    block
    |> resolve_ref_title(opts)
    |> resolve_code_label(opts)
    |> resolve_paper_links(opts)
    |> redact_encrypted_value()
    |> compose_block(style, theme)
    |> render_html(Map.put(opts, :doctype, false))
  end

  # A bound block whose schema field is `encrypted: true` stores its value as a
  # FieldCipher envelope (`%{"_bpenc" => …}`) — ciphertext-at-rest. The renderer
  # feeds the body_html cache and the PubSub delta frames, both of which are
  # public surfaces that MUST never emit plaintext; they equally cannot emit the
  # envelope MAP (`to_string/1` on a map raises, crashing the streaming editor on
  # the next op when the stored block already carries ciphertext). So redact a
  # top-level envelope value to "" — an encrypted field renders empty in the
  # cache/broadcast; the privileged reveal API is the only path to plaintext.
  defp redact_encrypted_value(%{"value" => %{"_bpenc" => _}} = block),
    do: Map.put(block, "value", "")

  defp redact_encrypted_value(block), do: block

  # field-reference View resolves the referenced doc's TITLE for display. The
  # renderer itself stays pure (no Repo): the caller supplies a `:ref_resolver`
  # fn in `opts` — `fn value, ref_type -> title_string end` — typically
  # `&Content.reference_title(&1, &2, dataset)`. We stash the resolved title on
  # a transient `"_ref_title"` key the field-reference compose clause reads;
  # the key never reaches the AST/cache (compose only emits a Pd-tree). With no
  # resolver the block is untouched and View falls back to the raw id, matching
  # the prior behaviour (and keeping pure unit tests Repo-free).
  defp resolve_ref_title(%{"type" => "field-reference", "value" => value} = block, opts)
       when is_binary(value) and value != "" do
    case Map.get(opts, :ref_resolver) do
      resolver when is_function(resolver, 2) ->
        ref_type = Map.get(block, "refType", "")
        Map.put(block, "_ref_title", to_string(resolver.(value, ref_type)))

      _ ->
        block
    end
  end

  defp resolve_ref_title(block, _opts), do: block

  # codelist View resolves the selected CODE → its human LABEL for display,
  # using the same pure-renderer + injected-resolver pattern as
  # `resolve_ref_title`. The caller supplies a `:codelist_resolver` fn in
  # `opts` — `fn plugin, codelist_id, code -> label_string end` — typically
  # `&Content.codelist_label(&1, &2, &3)`. We stash the resolved label on a
  # transient `"_code_label"` key the codelist compose clause reads. With no
  # resolver the block is untouched and View falls back to the raw code
  # (pure unit tests stay Repo-free). The `plugin` discriminator defaults to
  # `"core"` — the same default `CodelistField` carries — so blocks pointing
  # at a non-core registry (e.g. OnixEdit) must set `"plugin"`.
  defp resolve_code_label(%{"type" => "codelist", "value" => code} = block, opts)
       when is_binary(code) and code != "" do
    case Map.get(opts, :codelist_resolver) do
      resolver when is_function(resolver, 3) ->
        plugin = Map.get(block, "plugin", "core")
        codelist_id = Map.get(block, "codelistId", "")
        Map.put(block, "_code_label", to_string(resolver.(plugin, codelist_id, code)))

      _ ->
        block
    end
  end

  defp resolve_code_label(block, _opts), do: block

  # `paper-links` is useful in every renderer even when no database exists: its
  # authored refs always render as ordinary `/papers/:slug` links. The public
  # reader may additionally inject a `%{slug => metadata}` map under
  # `:paper_links`; keep that read-time data transient so it never enters the
  # stored block or body_html cache.
  defp resolve_paper_links(%{"type" => "paper-links"} = block, opts) do
    Map.put(block, "_paper_links", Map.get(opts, :paper_links, %{}))
  end

  defp resolve_paper_links(block, _opts), do: block

  @doc """
  Render a full portable-doc block list as a COMPLETE standalone HTML document
  — the email envelope: `<!doctype>` + tinted page background + a centered
  paper card at the palette width, every style inline (email clients strip
  `<style>`; Outlook is the contract). This is the EXACT byte stream a mail
  backend should send, and what `GET /papers/:slug/email` serves so authors
  can see it.
  """
  def render_document(blocks, opts \\ %{}) when is_list(blocks) do
    style = Map.get(opts, :style, :email)
    theme = Map.get(opts, :theme, :evergreen)
    palette = Barkpark.PortableDoc.Render.Palettes.palette_for(style, theme)
    body = render_blocks(blocks, opts)

    card =
      ~s(<div style="max-width:#{palette.width}px;margin:0 auto;padding:28px 24px;background:#{palette.paper};border-radius:12px;">) <>
        body <> "</div>"

    document(~s(<div style="padding:28px 12px;">) <> card <> "</div>", palette)
  end

  @doc "Wrap an already-sanitized legacy HTML fragment in the email document chrome."
  def render_html_document(html, opts \\ %{}) when is_binary(html) do
    style = Map.get(opts, :style, :email)
    theme = Map.get(opts, :theme, :evergreen)
    palette = Barkpark.PortableDoc.Render.Palettes.palette_for(style, theme)

    card =
      ~s(<div style="max-width:#{palette.width}px;margin:0 auto;padding:28px 24px;background:#{palette.paper};border-radius:12px;">) <>
        html <> "</div>"

    document(~s(<div style="padding:28px 12px;">) <> card <> "</div>", palette)
  end

  @doc """
  Render a full portable-doc block list to one concatenated HTML fragment, in
  order. Used to refresh the `body_html` cache from the block source of truth.
  """
  def render_blocks(blocks, opts \\ %{}) when is_list(blocks) do
    blocks
    |> Enum.map(&render_block(&1, opts))
    |> Enum.join("")
  end

  @doc false
  defdelegate compose_block(block), to: Compose

  @doc false
  defdelegate compose_block(block, style), to: Compose

  @doc false
  defdelegate compose_block(block, style, theme), to: Compose

  @doc """
  Escape the five HTML-significant characters in the EXACT order `& < > " '`.

  The ampersand must go first so we never double-escape the entities the later
  replacements introduce.
  """
  defdelegate escape_html(s), to: Util

  @doc "Stricter escape for attribute values — same as `escape_html/1`."
  defdelegate escape_attr(s), to: Util

  @doc """
  Return the URL attribute-escaped if its scheme is allowlisted
  (`http | https | mailto | tel`, case-insensitive), else `#`.

  Leading ASCII control characters / whitespace are stripped before matching,
  mirroring browser tolerance for `\\tjavascript:…`.
  """
  defdelegate safe_url(href), to: Util

  @doc "Background / foreground palette for a callout tone."
  defdelegate tone_palette(tone), to: Util
end
