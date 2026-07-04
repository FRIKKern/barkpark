defmodule Barkpark.PortableDoc.Render do
  @moduledoc """
  Pd-tree → inline-styled HTML string. Pure string emission. NO React, NO JSX,
  NO Node sidecar — a direct in-process port of the TS `walk()` in
  `portable-doc/packages/backend-web/src/static/render.ts`.

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
    * `Render.Inline`   — compose_inline* (kernel.ts composeInline)
    * `Render.Forms`    — form / questionnaire block HTML
    * `Render.Figures`  — diagram / asciicast / code / divider `_raw` HTML
    * `Render.Compose`  — compose_block (block → Pd-tree) + field helpers
    * `Render.Walk`     — walk/3 (Pd-tree → HTML) + per-kind renderers

  Behaviour-preserving: render output is byte-identical to the single-module
  engine that preceded the split.
  """

  alias Barkpark.PortableDoc.Render.{Compose, Palettes, Util, Walk}

  # Render-output version for the body_html cache. Bump when render output
  # semantics change — e.g. the #857/#861 tolerance change class — so a paper
  # whose frozen `content["body_html"]` was written by an OLDER renderer is
  # detectable as stale (its `content["body_html_sv"]` lags this) and can be
  # rehydrated by `mix barkpark.rehydrate_body_html`.
  #
  # v2: article prose emits bare semantic elements styled by Render.Stylesheet —
  # deploy step: run mix barkpark.rehydrate_body_html on guerrilla + prod after
  # the Stage-2 emit waves merge; prerequisite for deleting the root.html.heex
  # de-inline overrides. Old cached v1 HTML stays self-styled (inline) and keeps
  # rendering; block_ops stamps body_html_sv on every fresh render.
  @body_html_render_version 2

  @doc """
  The current body_html render-version. Stamped onto `content["body_html_sv"]`
  at every fresh block→HTML render (the paper write path) so a stale frozen
  cache — one rendered by a prior renderer — is detectable and rehydratable.
  """
  def body_html_render_version, do: @body_html_render_version

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
  """
  def render_html(root, opts \\ %{}) do
    palette =
      Map.get(opts, :style, :email)
      |> Palettes.palette_for()
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
      ~s(<!doctype html><html><head><meta charset="utf-8"></head>) <>
        ~s(<body style="background:#{palette.bg};margin:0;padding:0;">) <>
        body <>
        "</body></html>"
    end
  end

  # ── block → HTML (Wave 4 entry point) ──────────────────────────────────────
  #
  # The function above renders a *Pd-tree* (`%{"kind" => "PdText", …}`). The
  # functions below render a portable-doc *block list* — the AST shape that
  # `Barkpark.PortableDoc.Patch` operates on (`%{"id" => …, "type" => …}`) and
  # that the Papers context stores. They first `compose_block/2` each block into
  # a Pd-tree (the in-process twin of `composeBlock` in
  # `portable-doc/packages/primitives/src/kernel.ts`), then walk it — the
  # exact pairing of `renderBlockHtml` in the TS `backend-web` static renderer.

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

    block
    |> resolve_ref_title(opts)
    |> resolve_code_label(opts)
    |> redact_encrypted_value()
    |> compose_block(style)
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
