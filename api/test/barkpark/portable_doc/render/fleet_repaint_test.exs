defmodule Barkpark.PortableDoc.Render.FleetRepaintTest do
  # Pure — no DB, safe to run async. Proves the SERVER half of the fleet edit-island
  # loop (pd-ee-fleet-editors). The CLIENT half — a structured in-canvas edit emits ONE
  # patch-block{items|nodes|query} — is proven in
  # api/assets/paper-editor/src/__fleet.test.mjs. Here we prove that applying THAT
  # patch-block to a fleet block (1) shallow-merges the edited content with id+type
  # immutable, and (2) the re-rendered fleet HTML reflects the new content — i.e. the
  # server repaint (shared/paper.ex push_block_renders / @fleet_render_types) drives the
  # preview, so D8 holds (the canvas hand-writes NO fleet markup; the server is the ONE
  # producer). The array key each edit lands on is the SAME key the emitter reads
  # (cards/notes → "items", pipeline → "nodes").
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch
  alias Barkpark.PortableDoc.Render.Components

  defp doc_with(blocks), do: %{"blocks" => blocks}

  describe "a fleet edit-island patch-block merges + repaints (server drives the preview)" do
    test "patch-block{items} on a cards block replaces items, keeps id+type, repaints new content" do
      doc =
        doc_with([
          %{"id" => "c1", "type" => "cards", "items" => [%{"title" => "Old", "text" => "was"}]}
        ])

      {:ok, %{"blocks" => [merged]}} =
        Patch.apply_patch(doc, %{
          "op" => "patch-block",
          "id" => "c1",
          "patch" => %{
            "items" => [%{"title" => "New", "text" => "now", "tone" => "danger"}]
          }
        })

      # id + type are immutable; the items array is REPLACED wholesale (shallow merge).
      assert merged["id"] == "c1"
      assert merged["type"] == "cards"
      assert merged["items"] == [%{"title" => "New", "text" => "now", "tone" => "danger"}]

      # The server repaint reflects the edit: the new card is present (tone-accented),
      # the old one is gone.
      html = Components.cards_html(merged)
      assert html =~ ~s(<div class="bp-card__t">New</div>)
      assert html =~ "bp-card--danger"
      refute html =~ "Old"
    end

    test "patch-block{nodes} on a pipeline block replaces nodes and repaints them" do
      doc =
        doc_with([
          %{
            "id" => "p1",
            "type" => "pipeline",
            "nodes" => [%{"kind" => "gate", "title" => "Build"}]
          }
        ])

      {:ok, %{"blocks" => [merged]}} =
        Patch.apply_patch(doc, %{
          "op" => "patch-block",
          "id" => "p1",
          "patch" => %{"nodes" => [%{"kind" => "gate", "title" => "Ship"}]}
        })

      assert merged["nodes"] == [%{"kind" => "gate", "title" => "Ship"}]

      html = Components.pipeline_html(merged)
      assert html =~ "Ship"
      refute html =~ "Build"
    end

    test "patch-block{items} on a notes block replaces items and repaints them" do
      doc =
        doc_with([
          %{
            "id" => "n1",
            "type" => "notes",
            "items" => [%{"label" => "A", "text" => "alpha"}, %{"label" => "B", "text" => "beta"}]
          }
        ])

      {:ok, %{"blocks" => [merged]}} =
        Patch.apply_patch(doc, %{
          "op" => "patch-block",
          "id" => "n1",
          "patch" => %{"items" => [%{"label" => "B", "text" => "beta"}]}
        })

      assert merged["items"] == [%{"label" => "B", "text" => "beta"}]

      html = Components.notes_html(merged)
      assert html =~ "beta"
      refute html =~ "alpha"
    end
  end
end
