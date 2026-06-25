defmodule BarkparkWeb.Studio.PaperEditor.SearchTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — wikilink + tag search handler units.

  Pure handler-unit coverage for `Paper.paper_wikilink_search/2` and
  `Paper.paper_tag_search/2`: a minimal LiveView socket (`bare_socket/1`) is
  driven directly past the handler, asserting blank/oversized queries short-
  circuit, matches return the right shape, and non-matches return `[]`. These
  do NOT mount the editor — they exercise the handler functions directly.

  `bare_socket/1` is section-local. The shared base-paper `setup` from
  `BarkparkWeb.PaperEditorTestHelpers` still runs (each describe layers its own
  candidate fixtures on top) — preserved verbatim from the original module.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  defp bare_socket(dataset) do
    # Build a minimal LiveView socket carrying only the assigns the handler
    # reads: `dataset` (direct) and `current_workspace` / `current_project`
    # (consumed by ScopeHelpers.scope_opts/1 — nil means no tenancy scope).
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        dataset: dataset,
        current_workspace: nil,
        current_project: nil
      }
    }
  end

  # ── paper_wikilink_search handler ────────────────────────────────────────────

  describe "paper_wikilink_search/2 — handler unit" do
    @wikilink_slug "2026-06-24-wikilink-candidate"

    setup do
      {:ok, _} =
        Content.upsert_paper(%{
          slug: @wikilink_slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "h-1",
              "type" => "heading",
              "text" => "Wikilink Candidate Paper",
              "level" => 1
            }
          ]
        })

      :ok
    end

    test "blank query returns empty results without hitting the DB" do
      socket = bare_socket(@dataset)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search("", socket)
    end

    test "oversized query (> 100 chars) returns empty results" do
      socket = bare_socket(@dataset)
      long_q = String.duplicate("x", 101)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search(long_q, socket)
    end

    test "matching query returns candidate with title, string id, and type 'paper'" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("Wikilink", socket)

      assert Enum.any?(results, fn r ->
               r.title == "Wikilink Candidate Paper" and
                 is_binary(r.id) and
                 r.type == "paper"
             end)
    end

    test "non-matching query returns empty list" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("zzzzzzzz-nomatch", socket)

      assert results == []
    end
  end

  # ── paper_tag_search handler ──────────────────────────────────────────────────

  describe "paper_tag_search/2 — handler unit" do
    setup do
      # Tags live in `content["tags"]` (JSONB string array). Seed two papers so
      # the DISTINCT unnest has a duplicate to collapse.
      {:ok, _} =
        Content.create_document(
          "paper",
          %{"_id" => "tag-paper-a", "title" => "Tag Paper A", "tags" => ["design", "obsidian"]},
          @dataset
        )

      {:ok, _} = Content.publish_document("tag-paper-a", "paper", @dataset)

      {:ok, _} =
        Content.create_document(
          "paper",
          %{"_id" => "tag-paper-b", "title" => "Tag Paper B", "tags" => ["design", "draft"]},
          @dataset
        )

      {:ok, _} = Content.publish_document("tag-paper-b", "paper", @dataset)

      :ok
    end

    test "blank query returns empty results without hitting the DB" do
      socket = bare_socket(@dataset)
      assert {:reply, %{results: []}, _socket} = Paper.paper_tag_search("", socket)
    end

    test "oversized query (> 100 chars) returns empty results" do
      socket = bare_socket(@dataset)
      long_q = String.duplicate("x", 101)
      assert {:reply, %{results: []}, _socket} = Paper.paper_tag_search(long_q, socket)
    end

    test "matching query returns DISTINCT tag-name strings" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} = Paper.paper_tag_search("des", socket)

      assert results == ["design"]
      assert Enum.all?(results, &is_binary/1)
    end

    test "non-matching query returns empty list" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_tag_search("zzzzzzzz-nomatch", socket)

      assert results == []
    end
  end
end
