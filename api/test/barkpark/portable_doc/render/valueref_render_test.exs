defmodule Barkpark.PortableDoc.Render.ValuerefRenderTest do
  @moduledoc """
  lvw-t1 — the inline live-value node (wire §3/§6/§9), PURE render side.

  Fixture-driven off the SHARED golden home (`fixtures/portable-doc-inline/`,
  copied verbatim into this tree, `internal/pdrender/testdata/`, and the web
  `__tests__` tree — one JSON per case, consumed by all three renderers):

    1. resolved            — the palette `:values` hit renders, the D6 fallback
                             child text does NOT (renderers IGNORE children).
    2. unresolved-fallback — an empty values map renders the pinned `fallback`.
    3. missing-resolver    — no values opt at all renders the fallback too.

  Plus the wire §9 safety set: the CHILDLESS-node fallback (non-vacuous — a
  with-children node passes against a blank), the again-unknown inline type
  (degrade, never the historical raise), the valueref MARK form, and the
  injection case (`<script>` + raw ESC bytes render inert).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @fixtures_dir Path.join(__DIR__, "../../../support/fixtures/portable-doc-inline")

  defp fixture!(name) do
    @fixtures_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # The palette `:values` map is tuple-keyed; the shared fixture stores the
  # JSON-representable nested form (target → field → value).
  defp values_opt(%{"values" => values}) do
    %{
      values:
        for {target, fields} <- values, {field, v} <- fields, into: %{} do
          {{target, field}, v}
        end
    }
  end

  defp values_opt(_fixture), do: %{}

  defp visible_text(html), do: Regex.replace(~r/<[^>]*>/, html, "")

  for name <- [
        "valueref-resolved.json",
        "valueref-baseline-match.json",
        "valueref-unresolved-fallback.json",
        "valueref-missing-resolver.json"
      ] do
    test "golden: #{name}" do
      fixture = fixture!(unquote(name))
      html = Render.render_block(fixture["block"], values_opt(fixture))
      text = visible_text(html)

      assert text == fixture["expect_visible"]
      refute String.contains?(text, fixture["expect_absent"])
    end
  end

  # lvw-t2: the shared "resolved" fixture pins fallback "12 weeks" against a
  # canonical "6 weeks" — i.e. it resolves AND has drifted, so the marker is
  # `drift` (the ONE comparison, fallback vs resolved, at the palette-injection
  # point of the pre-resolve pass — wire §8). The value still renders.
  test "resolved-but-drifted valueref carries the data hooks and the DRIFT state" do
    fixture = fixture!("valueref-resolved.json")
    html = Render.render_block(fixture["block"], values_opt(fixture))

    assert html =~ ~s(data-valueref="launch-metrics")
    assert html =~ ~s(data-field="launch_delay")
    assert html =~ ~s(data-valueref-state="drift")
  end

  # lvw-t2 NON-drift guard (distrust vacuous green): a node whose pinned
  # fallback MATCHES the resolved value must stay `resolved` — if every
  # palette hit marked drift, the drifted-fixture test above would pass
  # vacuously.
  test "baseline-match fixture: resolved value equal to the pinned fallback stays state=resolved" do
    fixture = fixture!("valueref-baseline-match.json")
    html = Render.render_block(fixture["block"], values_opt(fixture))

    assert html =~ ~s(data-valueref-state="resolved")
    refute html =~ ~s(data-valueref-state="drift")
  end

  test "unresolved valueref is marked DANGLING (drift uncomputable), distinct from drift" do
    fixture = fixture!("valueref-unresolved-fallback.json")
    html = Render.render_block(fixture["block"], values_opt(fixture))

    assert html =~ ~s(data-valueref-state="dangling")
    refute html =~ ~s(data-valueref-state="drift")
  end

  test "a resolved valueref with NO pinned fallback has no baseline to drift from: state=resolved" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{"type" => "valueref", "target" => "t", "field" => "f"}
      ]
    }

    html = Render.render_block(block, %{values: %{{"t", "f"} => "6 weeks"}})

    assert html =~ ~s(data-valueref-state="resolved")
    assert visible_text(html) == "6 weeks"
  end

  # Wire §9 (5): the safety node is CHILDLESS and the assertion is VISIBLE
  # fallback text — a no-crash assertion (or a with-children node) would pass
  # vacuously against a blank render.
  test "CHILDLESS valueref with no resolver renders its fallback VISIBLY" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "valueref",
          "target" => "launch-metrics",
          "field" => "launch_delay",
          "fallback" => "12 weeks"
        }
      ]
    }

    assert visible_text(Render.render_block(block, %{})) == "12 weeks"
  end

  test "valueref MARK form (the editor round-trip shape) renders from attrs, not the display text" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "text",
          "value" => "STALE DISPLAY TOKEN",
          "marks" => [
            %{
              "type" => "valueref",
              "attrs" => %{
                "target" => "launch-metrics",
                "field" => "launch_delay",
                "fallback" => "12 weeks"
              }
            }
          ]
        }
      ]
    }

    html =
      Render.render_block(block, %{values: %{{"launch-metrics", "launch_delay"} => "6 weeks"}})

    text = visible_text(html)

    assert text == "6 weeks"
    refute text =~ "STALE DISPLAY TOKEN"
  end

  # Wire §6/§9: the again-unknown inline type must DEGRADE — the historical
  # behaviour was `raise ArgumentError` (inline.ex), which 500ed saves,
  # body_html refresh, delta frames, and Studio the moment one forward-compat
  # node reached the renderer.
  test "an unknown inline type never raises: childless renders empty, children render visibly" do
    childless = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{"type" => "text", "value" => "before "},
        %{"type" => "some-2027-node"},
        %{"type" => "text", "value" => " after"}
      ]
    }

    assert visible_text(Render.render_block(childless, %{})) == "before  after"

    with_children = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "some-2027-node",
          "children" => [%{"type" => "text", "value" => "dual-written fallback"}]
        }
      ]
    }

    assert visible_text(Render.render_block(with_children, %{})) == "dual-written fallback"
  end

  # Wire §9 (6): a hostile canonical value — markup plus raw terminal escape
  # bytes — must render INERT. The resolved string rides the PdText
  # escape_html path (never `_raw`), so the markup arrives entity-escaped.
  test "injection: a canonical value carrying <script> and raw ESC bytes renders inert" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "valueref",
          "target" => "launch-metrics",
          "field" => "launch_delay",
          "fallback" => "12 weeks"
        }
      ]
    }

    hostile = "<script>alert(1)</script>\e[2J\"onmouseover=\"x"

    html =
      Render.render_block(block, %{
        values: %{{"launch-metrics", "launch_delay"} => hostile}
      })

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    # The double quote is escaped too, so the value cannot break out of an
    # attribute context either.
    refute html =~ ~s("onmouseover=")
  end

  # ── lvw-t2 accept-baseline control (D4) ───────────────────────────────────
  # The control is DOUBLE-gated: palette `valueref_accept: true` (only
  # Studio's per-request view sets it) AND state == "drift". Everything else —
  # resolved, dangling, or any render without the flag (body_html cache,
  # delta frames, public reader) — must NOT carry it.

  @drifted_block %{
    "id" => "b1",
    "type" => "paragraph",
    "content" => [
      %{
        "type" => "valueref",
        "target" => "launch-metrics",
        "field" => "launch_delay",
        "fallback" => "12 weeks"
      }
    ]
  }

  test "accept-baseline control renders on a DRIFTED valueref when the palette opts in" do
    html =
      Render.render_block(@drifted_block, %{
        values: %{{"launch-metrics", "launch_delay"} => "6 weeks"},
        valueref_accept: true
      })

    assert html =~ ~s(phx-click="valueref-accept-baseline")
    assert html =~ ~s(phx-value-target="launch-metrics")
    assert html =~ ~s(phx-value-field="launch_delay")
    # The control carries the CURRENT pinned literal so the server can
    # re-check drift + address exactly the matching nodes.
    assert html =~ ~s(phx-value-fallback="12 weeks")
    assert html =~ ~s(class="bp-valueref-accept")
  end

  test "accept-baseline control NEVER renders without the palette opt-in (public reader protection)" do
    html =
      Render.render_block(@drifted_block, %{
        values: %{{"launch-metrics", "launch_delay"} => "6 weeks"}
      })

    assert html =~ ~s(data-valueref-state="drift")
    refute html =~ "valueref-accept-baseline"
    refute html =~ "phx-click"
  end

  test "accept-baseline control NEVER renders on resolved or dangling nodes, even opted-in" do
    resolved_html =
      Render.render_block(@drifted_block, %{
        values: %{{"launch-metrics", "launch_delay"} => "12 weeks"},
        valueref_accept: true
      })

    dangling_html = Render.render_block(@drifted_block, %{values: %{}, valueref_accept: true})

    assert resolved_html =~ ~s(data-valueref-state="resolved")
    assert dangling_html =~ ~s(data-valueref-state="dangling")
    refute resolved_html =~ "valueref-accept-baseline"
    refute dangling_html =~ "valueref-accept-baseline"
  end

  test "accept-baseline control escapes a hostile pinned fallback in its attributes" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "valueref",
          "target" => "t",
          "field" => "f",
          "fallback" => ~s|"><script>alert(1)</script>|
        }
      ]
    }

    html =
      Render.render_block(block, %{
        values: %{{"t", "f"} => "6 weeks"},
        valueref_accept: true
      })

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "as/label are RESERVED: ignored by the renderer, display comes from the resolver/fallback only" do
    block = %{
      "id" => "b1",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "valueref",
          "target" => "t",
          "field" => "f",
          "as" => "duration",
          "label" => "SHOULD NOT RENDER",
          "fallback" => "fb"
        }
      ]
    }

    text = visible_text(Render.render_block(block, %{}))
    assert text == "fb"
    refute text =~ "SHOULD NOT RENDER"
  end
end
