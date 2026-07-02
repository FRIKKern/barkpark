defmodule BarkparkWeb.StudioComponents.PresenceNavTest do
  # DataCase-backed: resolve_presence_doc_title/2 calls Content.get_document,
  # which needs the Repo sandbox checked out even when the doc doesn't exist
  # (the lookup falls back to the raw doc_id without raising).
  use Barkpark.DataCase, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.StudioComponents
  alias BarkparkWeb.StudioComponents.EditorFields
  alias BarkparkWeb.Studio.PresenceState

  defp base_assigns do
    %{
      user_id: "me-1",
      user_name: "Ada",
      user_color: "#336699",
      presences: [],
      editor_doc: nil,
      dataset: "production",
      current_workspace: nil,
      current_project: nil
    }
  end

  describe "presence_nav/1 accessibility" do
    test "a clickable remote collaborator renders as a real button with an accessible name" do
      remote = %{
        user_id: "u-2",
        name: "Grace",
        color: "#cc3300",
        doc_id: "post-123",
        type: "post"
      }

      html =
        render_component(&EditorFields.presence_nav/1, %{
          base_assigns()
          | presences: [remote]
        })

      # A <button>, not a bare <div>, carries the jump handler.
      assert html =~ ~s(<button)
      assert html =~ ~s(phx-click="jump-to-user")
      assert html =~ ~s(phx-value-doc-id="post-123")
      assert html =~ ~s(phx-value-type="post")

      # It has a non-empty aria-label naming the collaborator.
      assert html =~ ~r/aria-label="Jump to Grace[^"]*"/
    end

    test "the self me-group renders as a button with an aria-label" do
      html = render_component(&EditorFields.presence_nav/1, base_assigns())

      assert html =~ ~s(phx-click="show-profile")
      assert html =~ ~r/<button[^>]*class="presence-me-group"[^>]*aria-label="Ada[^"]*"/
    end

    test "the avatar glyphs inside the buttons are aria-hidden" do
      remote = %{
        user_id: "u-2",
        name: "Grace",
        color: "#cc3300",
        doc_id: "post-123",
        type: "post"
      }

      html =
        render_component(&EditorFields.presence_nav/1, %{
          base_assigns()
          | presences: [remote]
        })

      assert html =~ ~s(aria-hidden="true")
    end
  end

  # ── Helpers for the presence-hoist tests ──────────────────────────────
  # Mirror of the components.ex hoist so the test tracks the template.
  defp group_presences(presences, dataset) do
    presences
    |> Enum.filter(&(Map.get(&1, :dataset) == dataset))
    |> Enum.group_by(& &1.doc_id)
  end

  # Render one nav row the way the :doc arm does: pane_doc_item with the
  # grouped presence list projected into the trailing slot as dots.
  defp render_doc_row(item, presences_by_doc) do
    item_presences = Map.get(presences_by_doc, item.id, [])

    dots =
      item_presences
      |> Enum.map(fn p -> ~s(<span class="presence-dot-sm" style="background: #{p.color}"></span>) end)
      |> Enum.join()

    render_component(&StudioComponents.pane_doc_item/1, %{
      id: "doc-#{item.id}",
      phx_click: "select",
      phx_value_pane: "0",
      phx_value_id: item.id,
      title: item.title,
      doc_id: item.id,
      status: "published",
      is_draft: false,
      trailing: [%{inner_block: fn _, _ -> {:safe, dots} end}]
    })
  end

  defp count(substr, str) do
    str |> String.split(substr) |> length() |> Kernel.-(1)
  end

  describe "pane doc-list presence hoist (components.ex :doc arm)" do
    # The nav pane renders one .presence-dot-sm per presence editing that doc
    # in the active dataset. StudioLive.Components hoists the per-item
    # PresenceState.on_doc/3 scan into ONE group_by per pane:
    #
    #   presences_by_doc =
    #     @presences
    #     |> Enum.filter(&(Map.get(&1, :dataset) == @dataset))
    #     |> Enum.group_by(& &1.doc_id)
    #
    # then looks each item up with Map.get(presences_by_doc, item.id, []).
    # These tests pin that the grouped lookup is byte-for-byte equivalent to
    # the old on_doc/3 filter — same per-item lists, so the same dots render
    # under exactly the right rows and none under the others.
    setup do
      dataset = "production"

      presences = [
        %{user_id: "u-1", doc_id: "post-a", dataset: dataset, color: "#3b82f6"},
        %{user_id: "u-2", doc_id: "post-a", dataset: dataset, color: "#ef4444"},
        %{user_id: "u-3", doc_id: "post-b", dataset: dataset, color: "#10b981"},
        # different dataset — same doc_id as post-a but must NOT show here
        %{user_id: "u-4", doc_id: "post-a", dataset: "staging", color: "#f59e0b"},
        # nil doc_id — buckets under the nil key, never fetched by any row
        %{user_id: "u-5", doc_id: nil, dataset: dataset, color: "#8b5cf6"}
      ]

      items = [
        %{type: :doc, id: "post-a", title: "Doc A"},
        %{type: :doc, id: "post-b", title: "Doc B"},
        %{type: :doc, id: "post-c", title: "Doc C"}
      ]

      %{dataset: dataset, presences: presences, items: items}
    end

    test "grouped lookup == PresenceState.on_doc/3 for every doc row",
         %{dataset: dataset, presences: presences, items: items} do
      grouped = group_presences(presences, dataset)

      for item <- items do
        assert Map.get(grouped, item.id, []) ==
                 PresenceState.on_doc(presences, item.id, dataset),
               "grouped lookup diverged from on_doc/3 for #{item.id}"
      end
    end

    test "dots render under exactly the right rows",
         %{dataset: dataset, presences: presences, items: items} do
      grouped = group_presences(presences, dataset)
      [item_a, item_b, item_c] = items

      html_a = render_doc_row(item_a, grouped)
      html_b = render_doc_row(item_b, grouped)
      html_c = render_doc_row(item_c, grouped)

      # Doc A: two same-dataset editors → two dots (staging editor excluded).
      assert count("presence-dot-sm", html_a) == 2
      assert html_a =~ "background: #3b82f6"
      assert html_a =~ "background: #ef4444"
      # The cross-dataset editor's color must not leak onto Doc A.
      refute html_a =~ "background: #f59e0b"

      # Doc B: one editor → one dot.
      assert count("presence-dot-sm", html_b) == 1
      assert html_b =~ "background: #10b981"

      # Doc C: no editors → no dots.
      assert count("presence-dot-sm", html_c) == 0

      # The nil-doc_id presence never renders on any row.
      refute html_a =~ "background: #8b5cf6"
      refute html_b =~ "background: #8b5cf6"
      refute html_c =~ "background: #8b5cf6"
    end
  end
end
