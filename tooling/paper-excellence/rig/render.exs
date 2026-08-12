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
    {fixture_path, out_path} =
      case argv do
        [f, o] -> {f, o}
        _ -> die("usage: render.exs <fixture.json> <out.html>")
      end

    assert_wrapper_matches_live_view!()
    assert_theme_pin!()

    fixture = fixture_path |> File.read!() |> Jason.decode!()
    blocks = fixture["blocks"] || die("fixture has no \"blocks\": #{fixture_path}")
    blocks == [] && die("fixture has zero blocks: #{fixture_path}")

    boot_phoenix!()

    body =
      blocks
      |> Enum.map(&Barkpark.PortableDoc.Render.render_block(&1, %{style: :article}))
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
  # match the `<main class={[...]}>` line and compare the quoted tokens.
  defp assert_wrapper_matches_live_view!() do
    src = File.read!(@live_view_path)

    line =
      src
      |> String.split("\n")
      |> Enum.find(&(String.contains?(&1, "<main class={[") and String.contains?(&1, "bp-paper-")))
      |> case do
        nil -> die("no `<main class={[…bp-paper-…]}>` line in #{@live_view_path} — LiveView drift")
        l -> l
      end

    found = Regex.scan(~r/"(bp-paper-[a-z-]+)"/, line) |> Enum.map(&List.last/1)

    if found != @wrapper_classes do
      die("""
      wrapper drift: #{@live_view_path} now renders #{inspect(found)}
      but the rig hand-adds #{inspect(@wrapper_classes)}.
      Update @wrapper_classes (and re-baseline) — do NOT ignore this.
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
