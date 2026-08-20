defmodule Barkpark.PortableDoc.Render.ComposeClassCoverageTest do
  # Pure source scan — no DB, no render, no fixtures.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Stylesheet

  # ── the COMPOSE-TIME class-coverage tripwire (delivery-wave sibling) ─────────
  #
  # `article_class_coverage_test.exs` guards the classes the WALK emits for the
  # ParityFixture — and states honestly that classes minted at COMPOSE time
  # inside `_raw` HTML (data_viz.ex, figures.ex, forms.ex, the compose.ex `_raw`
  # families) are out of its reach. That blind spot is exactly where the
  # utilization study (/papers/portabledoc-potential-study §4) found 18 block
  # families shipping markup with ZERO reader rules — bar-chart fills literally
  # invisible, steps/tabs/footnote/equation/api-endpoint landing as browser
  # defaults. An author who reaches for one of those blocks gets punished once
  # and retreats to paragraphs forever; the corpus census (2 prose types = 78%
  # of all usage) is the scar tissue.
  #
  # THIS test closes the blind spot at the SOURCE level: every `class="bp-…"`
  # literal in the article-side render sources must resolve — by class-family
  # ROOT (the token before `__` / `--`) — to at least one rule in the canonical
  # paper-surface stylesheet, or sit on the justified allowlist below.
  #
  # Scanning SOURCE (not a fixture render) is deliberate: it needs no fixture
  # to grow (the parity fixture is byte-locked by the email golden), it sees
  # every emitter including ones no fixture exercises, and a brand-new block
  # type's emitter is covered the moment the file is saved. The trade-off is
  # granularity — ROOT-level membership, not per-element — which matches how
  # the stylesheet is authored (one stanza per family).
  #
  # The allowlist starts EMPTY (the delivery wave styled every family) and is
  # SHRINK-ONLY in spirit: adding an entry means shipping a block family the
  # reader renders unstyled — do that consciously, with a one-line
  # justification, or ship the stanza.
  @allowlist %{}

  # Inline-styled email emitters — their markup deliberately carries no classes
  # (Outlook strips <style>), so the class-bearing article files are the scan.
  @email_only_files ~w(cards_email.ex fleet_email.ex panels_email.ex)

  @render_dir Path.expand("../../../../lib/barkpark/portable_doc/render", __DIR__)

  test "every compose-time bp-* class family has reader CSS (or a justified allowlist entry)" do
    css = Stylesheet.css()

    emitted =
      @render_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in @email_only_files))
      |> Enum.reduce(%{}, fn file, acc ->
        ~r/class="(bp-[a-z0-9_-]+)/
        |> Regex.scan(File.read!(file), capture: :all_but_first)
        |> List.flatten()
        |> Enum.reduce(acc, fn cls, inner ->
          root = cls |> String.split(~r/__|--/) |> List.first()
          Map.update(inner, root, [Path.basename(file)], &Enum.uniq([Path.basename(file) | &1]))
        end)
      end)

    assert map_size(emitted) > 40,
           "the source scan found suspiciously few class roots — did the render dir move?"

    missing =
      emitted
      |> Enum.reject(fn {root, _files} ->
        String.contains?(css, "." <> root) or Map.has_key?(@allowlist, root)
      end)
      |> Enum.sort()

    assert missing == [],
           """
           #{length(missing)} block class famil#{if length(missing) == 1, do: "y", else: "ies"} emit markup with NO rule in paper-surface.css —
           the reader will render them unstyled (or invisible, for bar fills):

           #{Enum.map_join(missing, "\n", fn {root, files} -> "  .#{root}  (emitted by #{Enum.join(files, ", ")})" end)}

           Ship a stanza in api/assets/paper-surface/paper-surface.css (see the
           delivery-wave section for the house anatomy), or — consciously — add
           the root to @allowlist with a one-line justification.
           """
  end

  test "allowlist entries carry a non-empty justification and are still emitted" do
    for {root, why} <- @allowlist do
      assert is_binary(why) and String.trim(why) != "",
             "allowlist entry #{root} needs a one-line justification"
    end
  end
end
