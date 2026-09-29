defmodule BarkparkWeb.Layouts.BulldocsTuiImageMapTest do
  @moduledoc """
  Locks the reader TUI toggle's image-map leg in `bulldocs.html.heex`.

  `bpRenderTUI(blocksJSON, width, mode, themeID, imageMap)` takes an OPTIONAL
  5th argument — the `{src: base64}` object the page builds by pre-fetching
  each image block's same-origin src. Without it every image block renders as
  the labeled "(view in Studio)" box instead of pdrender's half-block mosaic.

  Headless ExUnit cannot execute the Go WASM renderer, so this is a
  source-level needle over the JS seam, the shape every sibling test in this
  directory uses (`bulldocs_tui_fetch_contract_test.exs`). The page-side
  bounds are read straight out of `internal/wasmimages/imagemap.go` and
  compared, so a Go-side tightening reds this test instead of silently letting
  the page fetch bytes the wasm will refuse — the same cross-tree read
  `reader_font_face_test.exs` does against `design/tokens.json`.
  """
  use ExUnit.Case, async: true

  @layout Path.expand(
            "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
            __DIR__
          )

  @wasmimages Path.expand(
                "../../../../internal/wasmimages/imagemap.go",
                __DIR__
              )

  defp layout, do: File.read!(@layout)

  describe "the call site" do
    test "passes five arguments, with the theme identity before the image map" do
      source = layout()

      assert source =~
               ~s|window.bpRenderTUI(JSON.stringify(blocks), TUI_COLS, "dark", "", images)|

      # The 3-arg call is the pre-image-map shape: mode present, theme identity
      # and image map both missing.
      refute source =~ ~s|window.bpRenderTUI(JSON.stringify(blocks), TUI_COLS, "dark")|

      # The map is awaited from the walker, not conjured.
      assert source =~ "var images = await buildImageMap(blocks);"
    end
  end

  describe "the walker" do
    test "collects only image-shaped blocks and only rooted same-origin srcs" do
      source = layout()

      assert source =~ "function collectImageSrcs(blocks)"

      # Same-origin: a rooted path, never protocol-relative, never a backslash
      # path. An absolute "https://…" and a "data:" URI both fail the leading
      # "/" test. Mirrors wasmimages.sameOrigin.
      assert source =~ ~s|src.charAt(0) === "/" && src.slice(0, 2) !== "//"|
      assert source =~ ~s|src.indexOf("\\\\") < 0|

      # Image-shaped: an explicit type:"image", or a typeless {src,alt} media
      # element. asciicast/video carry `src` too and must not be collected.
      assert source =~ ~S(var imageish = type === "image" ||)
      assert source =~ ~s|typeof node.src === "string"|

      # The resolver keys on the TRIMMED src, so the map must key identically.
      assert source =~ "var key = node.src.trim();"
    end

    test "failed fetches are omitted rather than surfaced" do
      source = layout()

      assert source =~ "if (!r || !r.ok) continue;"
      assert source =~ "map[src] = bytesToBase64(new Uint8Array(buf));"
    end
  end

  describe "the bounds" do
    test "every page-side literal is at or under its internal/wasmimages counterpart" do
      source = layout()
      go = File.read!(@wasmimages)

      assert page_int(source, "IMG_MAX_ENTRIES") <= go_int(go, "MaxEntries")
      assert page_int(source, "IMG_MAX_ENTRY_BYTES") <= go_int(go, "MaxEntryBytes")
      assert page_int(source, "IMG_MAX_TOTAL_BYTES") <= go_int(go, "MaxTotalBytes")
    end

    test "the pre-fetch is bounded in concurrency and in wall-clock" do
      source = layout()

      concurrency = page_int(source, "IMG_CONCURRENCY")
      assert concurrency > 0 and concurrency <= 16

      # Two clocks: one per request, one over the whole pre-fetch. The second
      # is what keeps a hanging image off the toggle.
      assert page_int(source, "IMG_FETCH_TIMEOUT_MS") > 0
      assert page_int(source, "IMG_TOTAL_BUDGET_MS") > 0

      assert source =~ "new AbortController()"
      assert source =~ "setTimeout(function () { expired = true; res(); }, IMG_TOTAL_BUDGET_MS);"
      assert source =~ "await Promise.race(["
    end
  end

  # `var NAME = 4 * 1024 * 1024;` / `var NAME = 64;` → the evaluated integer.
  defp page_int(source, name) do
    [_, expr] = Regex.run(~r/var #{name} = ([0-9 *]+);/, source)

    expr
    |> String.split("*")
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
    |> Enum.product()
  end

  # `MaxEntries = 256` / `MaxEntryBytes = 4 << 20` → the evaluated integer.
  defp go_int(go, name) do
    [_, expr] = Regex.run(~r/\n\t#{name} = ([0-9_ <]+)\n/, go)

    case String.split(expr, "<<") do
      [n] -> parse_underscored(n)
      [a, b] -> Bitwise.bsl(parse_underscored(a), parse_underscored(b))
    end
  end

  defp parse_underscored(s),
    do: s |> String.trim() |> String.replace("_", "") |> String.to_integer()
end
