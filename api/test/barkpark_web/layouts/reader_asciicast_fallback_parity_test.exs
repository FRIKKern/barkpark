defmodule BarkparkWeb.Layouts.ReaderAsciicastFallbackParityTest do
  @moduledoc """
  task-ab8646d8e1fe51d6 — the asciicast honest fallback, on BOTH mount sites.

  Two surfaces mount an asciinema player over `div.bp-asciicast`:

    * `js/packages/react/src/client.ts` (`hydrateAsciicast`) — the npm reader
      a consuming app runs.
    * `lib/barkpark_web/layouts/bulldocs.html.heex` (`runAsciicast`) — the
      Studio / `/papers` reader's LiveView hook.

  The honest fallback (message + raw link + `data-asciicast-failed`, swapped in
  on asciinema's own `.ap-overlay-error`) shipped on the FIRST only. A failed
  cast in the reader showed a bordered box containing a 💥 glyph and nothing
  else — the empty box the komposisjon law forbids.

  ## Why two copies and not one shared source

  The reader's other lazy embed, mermaid, WAS unified into a shared asset
  (`priv/static/assets/bp-paper-mermaid.js`, pinned by
  `ReaderMermaidSharedAssetTest`) — but that unified two PHOENIX surfaces, both
  of which fetch the same static file. This pair cannot take that shape: one
  side is a TypeScript module published to npm and bundled by a consumer, the
  other is inline JavaScript in a HEEx template served by Phoenix. Neither
  runtime can read the other's source at load time, and `runCodeTabs` /
  `runTabs` already record the reason in this very file — "reimplemented here
  rather than shared (this hook has no npm dependency on `@barkpark/react`)".

  So the copies stay two, and THIS FILE is the lock. Every expected value below
  is READ OUT of `client.ts` at test time; not one of them is typed here. That
  is the whole point: a test whose expected side is a second hand-typed copy of
  the string is a tautology that stays green while the mirror is already wrong
  in production. Because the assertion is "the heex contains the literal parsed
  from client.ts", it reds in BOTH directions — edit client.ts and the heex no
  longer carries the new value; edit the heex and it no longer carries the old
  one.

  And it refuses on an empty read: `extract!/3` flunks by name when its pattern
  misses, and `control` below proves the two files were actually opened and
  parsed before any absence is read as evidence. A vacuous green here would be
  worse than no test.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @layout Path.expand("../../../lib/barkpark_web/layouts/bulldocs.html.heex", __DIR__)
  @client Path.expand(
            "../../../../js/packages/react/src/client.ts",
            __DIR__
          )

  @slug "reader-asciicast-fallback-parity"

  defp layout, do: File.read!(@layout)
  defp client, do: File.read!(@client)

  # Pull one literal out of client.ts BY NAME. Flunks loudly rather than
  # returning nil: a silent nil would make every assertion below compare
  # against nothing and pass.
  defp extract!(source, label, regex) do
    case Regex.run(regex, source) do
      [_, value] when is_binary(value) and byte_size(value) > 0 ->
        value

      other ->
        flunk("""
        REFUSING on an empty read: could not extract #{label} from #{@client}.
        Pattern #{inspect(regex)} returned #{inspect(other)}.
        The constant was renamed, re-quoted or deleted on the client.ts side —
        fix THIS extractor before trusting any verdict from this file, because
        an unextracted expectation is not a passing parity check, it is no
        check at all.
        """)
    end
  end

  # Every fallback literal, derived from client.ts. Single source of the
  # expectations for all the file-level tests below.
  defp derived do
    src = client()

    %{
      error_selector:
        extract!(src, "ASCIICAST_ERROR_SELECTOR", ~r/ASCIICAST_ERROR_SELECTOR = '([^']+)'/),
      ready_selector:
        extract!(src, "ASCIICAST_READY_SELECTOR", ~r/ASCIICAST_READY_SELECTOR = '([^']+)'/),
      message:
        extract!(src, "ASCIICAST_FALLBACK_MESSAGE", ~r/ASCIICAST_FALLBACK_MESSAGE = '([^']+)'/),
      link_text:
        extract!(src, "ASCIICAST_FALLBACK_LINK", ~r/ASCIICAST_FALLBACK_LINK = '([^']+)'/),
      style: extract!(src, "FALLBACK_STYLE", ~r/FALLBACK_STYLE = '([^']+)'/),
      step_ms: extract!(src, "ASCIICAST_PROBE_STEP_MS", ~r/ASCIICAST_PROBE_STEP_MS = (\d+)/),
      timeout_ms:
        extract!(src, "ASCIICAST_PROBE_TIMEOUT_MS", ~r/ASCIICAST_PROBE_TIMEOUT_MS = (\d+)/),
      box_class: extract!(src, "the fallback box class", ~r/box\.className = '([^']+)'/),
      link_class: extract!(src, "the fallback link class", ~r/link\.className = '([^']+)'/)
    }
  end

  describe "the instrument itself" do
    test "both files were opened, are non-trivial, and parse — the control" do
      heex = layout()
      ts = client()

      assert byte_size(heex) > 10_000, "read #{byte_size(heex)} bytes of #{@layout}"
      assert byte_size(ts) > 10_000, "read #{byte_size(ts)} bytes of #{@client}"

      assert heex =~ "runAsciicast()",
             "the heex hook method this file is about is not in #{@layout} — every " <>
               "absence read below would be an artefact of reading the wrong file"

      assert ts =~ "function renderCastFallback",
             "client.ts no longer defines renderCastFallback — the side this file " <>
               "DERIVES from is gone, so nothing here measures anything"

      values = derived() |> Map.values()

      assert length(values) == 9,
             "expected 9 derived literals, got #{length(values)}"

      assert Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
             "a derived expectation came back blank: #{inspect(derived())}"
    end

    test "extract!/3 flunks instead of returning nil when a constant is missing" do
      assert_raise ExUnit.AssertionError, fn ->
        extract!(
          "const SOMETHING_ELSE = 'x'",
          "A_MISSING_CONSTANT",
          ~r/A_MISSING_CONSTANT = '([^']+)'/
        )
      end
    end
  end

  describe "the reader hook carries the fallback client.ts defines" do
    setup do
      {:ok, heex: layout(), d: derived()}
    end

    test "the fallback copy is term-identical to client.ts's", %{heex: heex, d: d} do
      assert heex =~ ~s("#{d.message}"),
             """
             bulldocs.html.heex does not carry the fallback MESSAGE client.ts
             defines: #{inspect(d.message)}.
             One of the two mount sites moved. Both must say the same thing to a
             reader — the copy is the product, not an implementation detail.
             """

      assert heex =~ ~s("#{d.link_text}"),
             "bulldocs.html.heex does not carry client.ts's raw-recording link " <>
               "text #{inspect(d.link_text)}"

      assert heex =~ ~s("#{d.style}"),
             "bulldocs.html.heex does not carry client.ts's inline fallback " <>
               "style #{inspect(d.style)}"
    end

    test "the detector and the ready markers are term-identical", %{heex: heex, d: d} do
      assert heex =~ ~s("#{d.error_selector}"),
             """
             bulldocs.html.heex does not probe for #{inspect(d.error_selector)} —
             asciinema-player 3.x fires no `error` event, so this selector IS the
             error channel. Without it the reader cannot know a cast failed and
             the 💥 box stays on the page.
             """

      assert heex =~ ~s("#{d.ready_selector}"),
             "bulldocs.html.heex does not carry client.ts's ready markers " <>
               "#{inspect(d.ready_selector)} — a loaded cast would wait out the " <>
               "whole probe deadline"
    end

    test "the probe cadence and ceiling match client.ts", %{heex: heex, d: d} do
      assert heex =~ "= #{d.step_ms};",
             "bulldocs.html.heex does not use client.ts's #{d.step_ms}ms probe step"

      assert heex =~ "= #{d.timeout_ms};",
             "bulldocs.html.heex does not use client.ts's #{d.timeout_ms}ms probe ceiling"
    end

    test "the fallback DOM classes and the failed stamp match client.ts", %{heex: heex, d: d} do
      assert heex =~ ~s("#{d.box_class}"),
             "bulldocs.html.heex's fallback box is not #{inspect(d.box_class)}"

      assert heex =~ ~s("#{d.link_class}"),
             "bulldocs.html.heex's fallback link is not #{inspect(d.link_class)}"

      assert client() =~ "el.dataset.asciicastFailed = 'true'",
             "client.ts no longer stamps dataset.asciicastFailed — re-derive this test"

      assert heex =~ ~s(el.dataset.asciicastFailed = "true"),
             """
             bulldocs.html.heex never stamps `data-asciicast-failed`. client.ts
             does, and a consumer (or a screenshot test) selects faulted casts by
             that stamp rather than by parsing our copy.
             """
    end

    test "a create() that throws goes straight to the card, like client.ts", %{heex: heex} do
      assert heex =~ "catch (_e)",
             "the reader's AsciinemaPlayer.create() is not wrapped — a throwing " <>
               "create leaves a blank mount div, which is the empty box again"

      assert client() =~ "renderCastFallback(el, src)",
             "client.ts no longer calls renderCastFallback — re-derive this test"

      assert heex =~ "renderCastFallback(el, src)",
             "the reader defines no renderCastFallback(el, src) call"
    end

    test "the link allow-list is the same shape — no javascript:/data: href", %{heex: heex} do
      assert client() =~ "function castHref", "client.ts lost castHref — re-derive"

      assert heex =~ "let castHref = (src) =>",
             """
             the reader builds its fallback link without client.ts's castHref
             allow-list. A hostile `data-cast-src` (`javascript:`, `data:`) would
             become a clickable payload in the reader while the npm client
             refuses it.
             """
    end
  end

  describe "the SHIPPED reader page carries it" do
    setup %{conn: conn} do
      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @slug,
            body_html:
              ~s(<section id="b1"><p>A paper carrying a terminal recording, so ) <>
                ~s(the reader page emits the hook this test reads.</p>) <>
                ~s(<div class="bp-asciicast" data-cast-src="/media/files/2026/09/demo.cast"></div></section>),
            event_type: "plan-written"
          })
        )

      {:ok, html: conn |> get("/papers/#{@slug}") |> html_response(200), d: derived()}
    end

    test "the served HTML, not just the template on disk, holds the fallback", %{
      html: html,
      d: d
    } do
      assert html =~ "runAsciicast",
             "the reader page does not ship the asciicast hook at all"

      assert html =~ d.message,
             """
             the reader page at /papers/#{@slug} ships runAsciicast WITHOUT the
             fallback copy #{inspect(d.message)}. The template may hold it while
             the rendered page does not — this is the arm that reds if the hook
             is reverted, whatever the file on disk says.
             """

      assert html =~ d.error_selector,
             "the served reader page never probes #{inspect(d.error_selector)}"

      assert html =~ "data-asciicast-failed" or html =~ "asciicastFailed",
             "the served reader page never stamps the failed marker"
    end
  end
end
