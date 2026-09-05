# Hermetic paper render — NO server, NO database, NO network.
#
#   cd api && MIX_ENV=test mix run --no-start ../tooling/paper-excellence/rig/render.exs \
#     <fixture.json> <out.html>
#
# Why `--no-start`: the Repo is never started, so nothing here can touch a
# database. `config/test.exs` sets `server: false` on the Endpoint, so
# `Endpoint.start_link/0` builds the config/asset machinery WITHOUT opening a
# socket. Only :phoenix + a PubSub + the Endpoint come up.
#
# Two traps this script exists to avoid, both proven on 2026-08-12
# (tooling/grip/ledger/hermetic-paper-render-and-reader-etag-2026-08-12.md):
#
#   1. `Render.render_html/2` takes a Pd TREE, not a paper's `blocks` list.
#      Handing it `%{"blocks" => …}` returns a ~97 KB CSS-only shell with the
#      prose MISSING — a vacuous green. The blocks path is `render_block/2`,
#      which is what the reader LiveView itself calls.
#   2. The `<main class="bp-paper-shell bp-paper-surface bp-paper-article">`
#      wrapper lives in the LiveView (bulldocs_live.ex), NOT in the layout.
#      Omit it and every `.bp-paper-article` rule is dead: the measured column
#      silently becomes BODY / full viewport width. So we hand-add it AND
#      assert the class set against the LiveView source, so LiveView drift
#      reds the rig instead of quietly re-measuring the wrong element.

defmodule Rig.Render do
  # The wrapper the reader LiveView puts around the paper body. Kept in ONE
  # place and cross-checked against the LiveView below.
  @wrapper_classes ["bp-paper-shell", "bp-paper-surface", "bp-paper-article"]

  # Theme pin. `Layouts.bp_theme_attr/1` emits `data-bp-theme` only when the
  # theme differs from the default, so pinning the default reproduces the
  # default page BYTE-IDENTICALLY (attribute absent). We assert the pin equals
  # `Tenancy.default_theme/0`: if the product default moves, the rig reds
  # rather than silently re-baselining every screenshot against new colors.
  # A workspace on a non-default theme (e.g. "fjord") drifts COLORS only —
  # geometry and type are unaffected.
  @theme_pin "evergreen"

  @live_view_path "lib/barkpark_web/live/bulldocs_live.ex"

  def main(argv) do
    assert_wrapper_matches_live_view!()
    assert_stream_item_matches_live_view!()
    assert_theme_pin!()
    boot_phoenix!()

    case argv do
      [fixture_path, out_path] ->
        render_one!(fixture_path, out_path)

      ["--batch", fixture_dir, site_dir] ->
        fixtures = Path.wildcard(Path.join(fixture_dir, "*.json")) |> Enum.sort()
        fixtures == [] && die("batch directory has no JSON fixtures: #{fixture_dir}")

        Enum.each(fixtures, fn fixture_path ->
          slug = fixture_path |> Path.basename() |> Path.rootname()
          render_one!(fixture_path, Path.join([site_dir, "papers", slug, "index.html"]))
        end)

        File.cp!(
          Path.join([site_dir, "papers", "barkpark-chronicle", "index.html"]),
          Path.join(site_dir, "index.html")
        )

        IO.puts("rig/render: batch rendered #{length(fixtures)} papers -> #{site_dir}")

      _ ->
        die("usage: render.exs <fixture.json> <out.html> | --batch <fixture-dir> <site-dir>")
    end
  end

  defp render_one!(fixture_path, out_path) do
    fixture = fixture_path |> File.read!() |> Jason.decode!()
    blocks = fixture["blocks"] || die("fixture has no \"blocks\": #{fixture_path}")
    blocks == [] && die("fixture has zero blocks: #{fixture_path}")

    # THE SHIPPING SHAPE, not the convenient one. The block-backed reader does
    # not concatenate block HTML into the article: it streams each top-level
    # block as its OWN keyed item, `<div id={dom_id} data-block-id={block.id}>`
    # (bulldocs_live.ex, `phx-update="stream"`). Rendering the bare concatenation
    # here measured a DOM the reader never serves — margins collapse to the same
    # numbers either way, so it read as harmless, but any rule that selects on
    # document POSITION (the section head's `> div:not([class]) > h2`) is true in
    # one shape and dead in the other. A rig that photographs the wrong one
    # cannot tell those apart. So the wrapper is reproduced, and asserted
    # against the LiveView below so a stream-shape change reds here.
    body =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        html = Barkpark.PortableDoc.Render.render_block(block, %{style: :article})
        id = stream_block_id(block, index)
        ~s(<div id="#{id}" data-block-id="#{Map.get(block, "id")}">) <> html <> "</div>"
      end)
      |> Enum.join()

    if String.trim(body) == "" do
      die("render produced an EMPTY body for #{length(blocks)} blocks — vacuous render")
    end

    inner =
      ~s(<main class="#{Enum.join(@wrapper_classes, " ")}">) <>
        ~s(<article id="paper-body">) <> body <> "</article></main>"

    assigns = %{
      inner_content: Phoenix.HTML.raw(inner),
      page_title: fixture["title"] || "Paper",
      preview: nil,
      csp_nonce: "rig-nonce",
      bp_theme: @theme_pin
    }

    html =
      assigns
      |> BarkparkWeb.Layouts.bulldocs()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    # Post-conditions: the wrapper survived into the document and the prose is
    # actually present (never trust "it rendered" — assert CONTENT).
    for cls <- @wrapper_classes do
      String.contains?(html, cls) || die("rendered HTML is missing wrapper class #{cls}")
    end

    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, html)

    IO.puts(
      "rig/render: #{length(blocks)} blocks -> #{byte_size(html)} bytes " <>
        "(body #{byte_size(body)} B, theme pin #{@theme_pin}) -> #{out_path}"
    )
  end

  defp boot_phoenix!() do
    {:ok, _} = Application.ensure_all_started(:phoenix)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Barkpark.PubSub)
    {:ok, _} = BarkparkWeb.Endpoint.start_link()
    :ok
  end

  # Drift tripwire: the wrapper string we hand-add must be exactly the class
  # set the reader LiveView renders. The LiveView writes it as a HEEx list
  # (`class={["bp-paper-shell", @article? && "bp-paper-surface", …]}`), so we
  # match the `<main class={[...]}>` CONSTRUCT and compare the quoted tokens.
  #
  # ACROSS NEWLINES, and that is the whole point of this shape. The finder used
  # to require `<main class={[` and `bp-paper-` on the SAME source line. #14141
  # reformatted the list onto four lines and the finder stopped matching — so
  # every rig run since has died with `no <main class={[…bp-paper-…]}> line …
  # LiveView drift`, a tripwire firing on its own blind spot rather than on any
  # drift. A formatting change must never be able to speak as a class-set
  # change: the construct is read whole, from `<main class={[` to its first
  # closing `]}`, and only the quoted `bp-paper-*` tokens inside it are compared.
  defp assert_wrapper_matches_live_view!() do
    src = File.read!(@live_view_path)

    construct =
      case Regex.run(~r/<main class=\{\[(.*?)\]\}/s, src, capture: :all_but_first) do
        [body] -> body
        _ -> die("no `<main class={[…]}>` construct in #{@live_view_path} — LiveView drift")
      end

    found = Regex.scan(~r/"(bp-paper-[a-z-]+)"/, construct) |> Enum.map(&List.last/1)

    if found != @wrapper_classes do
      die("""
      wrapper drift: #{@live_view_path} now renders #{inspect(found)}
      but the rig hand-adds #{inspect(@wrapper_classes)}.
      Update @wrapper_classes (and re-baseline) — do NOT ignore this.
      """)
    end

    :ok
  end

  # The block's own id, else a positional fallback — byte-for-byte the LiveView's
  # `stream_block_id/2`. Duplicated rather than called because that function is
  # private to the LiveView; the assertion below is what keeps the copy honest.
  defp stream_block_id(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "block-#{index}"
    end
  end

  # Drift tripwire for the STREAM ITEM, the sibling of the wrapper check above.
  # The section-head rule selects `#paper-body > div:not([class]) > h2`, so the
  # keyed item being a CLASS-LESS div carrying id + data-block-id is not
  # incidental markup — it is the thing the rule matches on. If the LiveView ever
  # gives that div a class, or drops the wrapper, the reader's section heads go
  # flat and this rig would keep photographing its own hand-built shape and pass.
  defp assert_stream_item_matches_live_view!() do
    src = File.read!(@live_view_path)

    line =
      src
      |> String.split("\n")
      |> Enum.find(&(String.contains?(&1, "@streams.blocks") and String.contains?(&1, "<div")))
      |> case do
        nil -> die("no `<div :for={… <- @streams.blocks}>` stream item in #{@live_view_path} — reader stream drift")
        l -> l
      end

    unless String.contains?(line, "id={dom_id}") and String.contains?(line, "data-block-id=") do
      die("stream-item drift: #{@live_view_path} renders #{String.trim(line)}; the rig reproduces <div id=… data-block-id=…>")
    end

    if String.contains?(line, "class") do
      die("""
      stream-item drift: the keyed block wrapper in #{@live_view_path} now carries a CLASS.
      The section-head rule matches `#paper-body > div:not([class]) > h2` — a class on this
      wrapper silently kills every section head on the reader. Update BOTH (paper-surface.css
      and this rig) deliberately, and re-baseline.
      """)
    end

    :ok
  end

  defp assert_theme_pin!() do
    default = Barkpark.Tenancy.default_theme()

    if default != @theme_pin do
      die(
        "theme pin drift: rig pins #{inspect(@theme_pin)} but " <>
          "Barkpark.Tenancy.default_theme/0 is #{inspect(default)} — re-baseline, then move the pin"
      )
    end

    :ok
  end

  defp die(msg) do
    IO.puts(:stderr, "rig/render: FAIL — #{msg}")
    System.halt(1)
  end
end

Rig.Render.main(System.argv())
