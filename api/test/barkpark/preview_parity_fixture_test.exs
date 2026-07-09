defmodule Barkpark.PreviewParityFixtureTest do
  @moduledoc """
  Cross-surface **preview-parity** lock (preview-contract W4, charter D20).

  ONE fixture — `Barkpark.Preview.project/3` itself, two variants (rich +
  core-only) — written to three byte-equal mirrors, then asserted through the
  REAL render path of every Elixir-side surface that consumes the manifest:

    * the **freshness lock** — the committed api mirror equals a fresh `build/0`
      and the three mirrors decode term-identical (a `Preview.project` change
      shipped without regenerating reds HERE, not silently on five surfaces);
    * the **papers reader** — `ShareMeta.head/1` via `render_component` (no DB);
    * the **v1 envelope wire hoist** — a ConnCase query proving a stamped
      `content["preview"]` survives to the response's top level `preview` key.
      Field-visibility read paths are historically leaky (fail-open on undeclared
      fields), so this POSITIVE assert is the first-ever wire proof of the hoist,
      not ceremony (charter errata D22);
    * the **Studio doc row** — `PaneBuilder.build/2` surfaces the manifest
      description as the row `:meta`.

  The web (`metadataFromPreview`) and Go TUI (`rowMeta`) legs of the same
  fixture live in `web/__tests__/preview-parity.test.ts` and
  `cmd/barkpark/preview_parity_test.go` — all three read the SAME mirror.

  DEGRADATION INVARIANT: the `core` variant (title/type/url only) renders a
  VALID BRANDED card on every surface — the reader emits the `/images/og-default.jpg`
  fallback, the envelope still hoists it, the Studio row degrades to no meta
  (never a crash).

  Regenerate with `mix barkpark.preview.gen_parity` whenever the freshness lock
  reds.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo
  alias BarkparkWeb.ShareMeta
  alias BarkparkWeb.Studio.PaneBuilder
  alias Mix.Tasks.Barkpark.Preview.GenParity

  @api_path Path.expand("../support/fixtures/preview-parity.json", __DIR__)
  @web_path Path.expand("../../../web/__tests__/fixtures/preview-parity.json", __DIR__)
  @go_path Path.expand("../../../cmd/barkpark/testdata/preview-parity.json", __DIR__)

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  defp fixture, do: decode!(@api_path)
  defp rich_manifest, do: fixture()["rich"]["manifest"]
  defp core_manifest, do: fixture()["core"]["manifest"]

  defp head(assigns), do: render_component(&ShareMeta.head/1, assigns)

  # The attribute-escaped form of a manifest string, exactly as HEEx emits it
  # into a `content="…"` value (`'` → `&#39;`, `&` → `&amp;`, …).
  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # ── freshness lock ──────────────────────────────────────────────────────────

  describe "fixture freshness lock" do
    test "committed api mirror equals a fresh regeneration (build/0)" do
      assert decode!(@api_path) == GenParity.build(),
             "preview-parity.json is stale — run `mix barkpark.preview.gen_parity` " <>
               "and re-verify all five surfaces."
    end

    test "the three mirrors decode term-identical" do
      api = decode!(@api_path)

      assert api == decode!(@web_path),
             "web mirror drifted — run `mix barkpark.preview.gen_parity`."

      assert api == decode!(@go_path),
             "Go mirror drifted — run `mix barkpark.preview.gen_parity`."
    end

    test "the fixture carries both variants at the coverage floor" do
      m = rich_manifest()

      # Rich: a real 5-field image object, a derived (inline-mark-flattened)
      # description, and the full paper extension ring — the shapes the surface
      # legs assert over. A gutted regen reds here, not just on one surface.
      assert m["description"] == "How Barkpark's design tokens fan out to every surface."
      assert Map.keys(m["image"]) |> Enum.sort() == ~w(alt height type url width)
      assert m["image"]["url"] == "/media/renditions/theme-og/og"
      assert m["extensions"]["authors"] == ["Kalle", "Fable"]
      assert m["extensions"]["tags"] == ["opengraph", "branding"]

      # Core: the degradation baseline — nil image + nil description.
      c = core_manifest()
      assert c["image"] == nil
      assert c["description"] == nil
      assert c["type"] == "paper"
    end
  end

  # ── surface (a): papers reader — ShareMeta.head ─────────────────────────────

  describe "reader head parity (ShareMeta.head/1)" do
    test "the rich manifest renders every field into the og/twitter/JSON-LD head" do
      m = rich_manifest()
      html = head(preview: m)
      base = BarkparkWeb.Endpoint.url()

      # title / type / canonical url — each from the manifest.
      assert html =~ ~s(<meta property="og:title" content="#{m["title"]}")
      assert html =~ ~s(<meta property="og:type" content="article")
      assert html =~ ~s(<meta property="og:url" content="#{base}#{m["url"]}")

      # description — the inline-mark run flattened to plain text (no <strong>),
      # attribute-escaped exactly as every surface must escape the same field.
      assert html =~ ~s(<meta property="og:description" content="#{esc(m["description"])}")
      refute html =~ "<strong>"
      refute html =~ "marks"

      # image — the RELATIVE manifest url absolutized, all five fields.
      img = m["image"]
      assert html =~ ~s(<meta property="og:image" content="#{base}#{img["url"]}")
      assert html =~ ~s(<meta property="og:image:width" content="#{img["width"]}")
      assert html =~ ~s(<meta property="og:image:height" content="#{img["height"]}")
      assert html =~ ~s(<meta property="og:image:alt" content="#{img["alt"]}")
      assert html =~ ~s(<meta property="og:image:type" content="#{img["type"]}")

      # extensions — every author + tag + section + published_time.
      for author <- m["extensions"]["authors"],
          do: assert(html =~ ~s(<meta property="article:author" content="#{author}"))

      for tag <- m["extensions"]["tags"],
          do: assert(html =~ ~s(<meta property="article:tag" content="#{tag}"))

      assert html =~ ~s(<meta property="article:section" content="Engineering")
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "DEGRADATION: the core manifest renders a valid BRANDED default card" do
      c = core_manifest()
      html = head(preview: c)
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:title" content="#{c["title"]}")
      # No image in the manifest → the branded 1200×630 default card (D5).
      assert html =~ ~s(<meta property="og:image" content="#{base}/images/og-default.jpg")
      assert html =~ ~s(<meta property="og:image:width" content="1200")
      assert html =~ ~s(<meta property="og:image:height" content="630")
      # Nil description → the tag is OMITTED, never emitted empty.
      refute html =~ ~s(property="og:description")
    end
  end

  # ── surface (b): the v1 envelope — wire hoist ───────────────────────────────

  describe "envelope wire-hoist parity" do
    setup do
      dataset = "preview_parity_wire_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "parityitem",
            "title" => "Parity Item",
            "visibility" => "public",
            # NOTE: `preview` is deliberately UNDECLARED — the hoist proof rests
            # on an undeclared content key surviving to the wire (public / kept).
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          dataset
        )

      {:ok, dataset: dataset}
    end

    defp seed_stamped!(dataset, id, manifest) do
      {:ok, _} =
        Content.create_document(
          "parityitem",
          %{"_id" => id, "title" => manifest["title"], "content" => %{"preview" => manifest}},
          dataset
        )

      {:ok, _} = Content.publish_document(id, "parityitem", dataset)
    end

    test "a stamped content[\"preview\"] hoists intact to the response top level",
         %{conn: conn, dataset: dataset} do
      m = rich_manifest()
      seed_stamped!(dataset, "rich", m)

      result =
        conn
        |> get("/v1/data/doc/#{dataset}/parityitem/rich")
        |> json_response(200)
        |> Map.fetch!("result")

      # The FIRST-ever positive wire proof: the whole manifest is present at the
      # top level as `preview`, field-for-field identical to the fixture — not
      # buried under `content`, not redacted, not reshaped.
      assert result["preview"] == m
    end

    test "DEGRADATION: the core manifest also hoists intact",
         %{conn: conn, dataset: dataset} do
      c = core_manifest()
      seed_stamped!(dataset, "core", c)

      result =
        conn
        |> get("/v1/data/doc/#{dataset}/parityitem/core")
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["preview"] == c
    end
  end

  # ── surface (d): Studio doc rows — PaneBuilder ──────────────────────────────

  describe "Studio doc-row parity (PaneBuilder.build/2)" do
    defp insert_schema!(dataset) do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        name: "parityrow",
        title: "Parity Rows",
        icon: "file-text",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })
      |> Repo.insert!()
    end

    defp seed_row!(dataset, id, manifest) do
      {:ok, _} =
        Content.create_document(
          "parityrow",
          %{"_id" => id, "title" => manifest["title"], "content" => %{"preview" => manifest}},
          dataset
        )
    end

    test "a stamped doc row surfaces the manifest description as :meta" do
      dataset = "preview_parity_row_#{System.unique_integer([:positive])}"
      insert_schema!(dataset)
      m = rich_manifest()
      seed_row!(dataset, "rich", m)

      {panes, _editor} = PaneBuilder.build(dataset, ["parityrow"])
      pane = Enum.find(panes, &(Map.get(&1, :type_name) == "parityrow"))
      row = Enum.find(pane.items, &(&1.id == "rich"))

      assert row.meta == m["description"]
      # The sparse share manifest carries no badge vocabulary.
      assert row.badge == nil
    end

    test "DEGRADATION: the core doc (nil description) row degrades to no meta" do
      dataset = "preview_parity_row_core_#{System.unique_integer([:positive])}"
      insert_schema!(dataset)
      seed_row!(dataset, "core", core_manifest())

      {panes, _editor} = PaneBuilder.build(dataset, ["parityrow"])
      pane = Enum.find(panes, &(Map.get(&1, :type_name) == "parityrow"))
      row = Enum.find(pane.items, &(&1.id == "core"))

      assert row.meta == nil
      assert row.badge == nil
    end
  end
end
