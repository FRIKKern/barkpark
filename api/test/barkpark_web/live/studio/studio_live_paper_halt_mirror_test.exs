defmodule BarkparkWeb.Studio.StudioLivePaperHaltMirrorTest do
  @moduledoc """
  The Studio paper canvas MIRRORS a server-owned write halt
  (task p-hollow-studio-mirror). Two invariants at the handler seam
  (`Shared.Paper`):

    1. SET — a `{:error, {:halted, reason}}` write result raises the mirror:
       `paper_halt` carries the server reason VERBATIM, `save_status` reads
       "Save failed", and the reason flashes. Both the single-op
       (`paper_pane_op/2`) and batch (`paper_ops/2`) seams run the SAME
       `put_paper_halt/2` helper, so a rejected canvas run halts identically —
       and the batch path, which never set `save_status` on error before, now
       does. A live halt only arrives once the sibling server gate
       (`p-hollow-gate-server`) lands at this write seam, so the SET wiring is
       proven directly against the shared helper every clause invokes.

    2. CLEAR — the next ACCEPTED edit dismisses the banner. A real successful
       op through either seam resets `paper_halt` to nil. This is exercised
       end-to-end against a live paper on both the single-op and batch paths.

  The editor never authors the copy (charter D5/D6): the banner string is
  always the server's reason. The banner render itself is guarded by
  `PaperHaltBannerTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @slug "2026-07-10-paper-halt-mirror"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp seed_block_paper! do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "b-intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body."}]
            }
          ]
        })
      )

    paper
  end

  # A paper-pane editor socket the paper handlers accept — mirrors the fixture
  # in StudioLiveSaveStatusTest, but seeds `paper_halt` so the CLEAR path has a
  # banner to dismiss.
  #
  # spd-w19 — taken from a REAL `live/2` mount, for the same reason
  # StudioLiveSaveStatusTest's is: the accepted-write arm of `paper_pane_op/2` now
  # re-derives the pane through `refetch_paper/1` (`stream/3` → `attach_hook`),
  # which needs `socket.private[:lifecycle]` and `assigns.streams` — neither of
  # which a `%Phoenix.LiveView.Socket{}` literal has (`** (KeyError) key
  # :lifecycle not found in: %{live_temp: %{}}`). The two seeded assigns are then
  # set on top, because a halt is a state the mount cannot be in.
  defp paper_socket(conn, paper, halt) do
    path =
      case paper do
        %{doc_id: slug} -> "/d/#{@dataset}/studio/paper/#{slug}"
        _ -> "/d/#{@dataset}/studio"
      end

    {:ok, view, _html} = live(conn, scoped_studio(path))

    :sys.get_state(view.pid).socket
    |> Phoenix.Component.assign(
      paper_doc: paper,
      save_status: "Save failed",
      paper_halt: halt
    )
  end

  # A benign, template-safe op: append a fresh paragraph. Passes the op layer
  # cleanly so both seams reach their {:ok, _} branch.
  defp append_op(id) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "More body."}]
      }
    }
  end

  describe "SET — put_paper_halt/2 (the shared clause both seams run)" do
    test "stashes the server reason verbatim, flags Save failed, flashes the copy", %{conn: conn} do
      reason = "document is hollow — add a content block beyond the title"
      socket = Paper.put_paper_halt(paper_socket(conn, nil, nil), reason)

      assert socket.assigns.paper_halt == reason
      assert socket.assigns.save_status == "Save failed"
      assert socket.assigns.flash["error"] == reason
    end

    test "a non-binary reason falls back to the API envelope's inspect form", %{conn: conn} do
      socket = Paper.put_paper_halt(paper_socket(conn, nil, nil), {:weird, :shape})

      assert socket.assigns.paper_halt =~ "mutation vetoed by a plugin lifecycle hook"
      assert socket.assigns.save_status == "Save failed"
    end
  end

  describe "CLEAR — the next accepted edit dismisses the mirror" do
    setup do
      seed_paper_schema!()
      paper = seed_block_paper!()
      {:ok, paper: paper}
    end

    test "single-op path (paper_pane_op) clears paper_halt on a clean edit",
         %{conn: conn, paper: paper} do
      socket = paper_socket(conn, paper, "a stale halt from a prior save")

      op =
        append_op("b-single")
        |> Map.put("request_id", Ecto.UUID.generate())
        |> Map.put("if_rev", socket.assigns.paper_rev)

      out = Paper.paper_pane_op(socket, op)

      assert out.assigns.paper_halt == nil
      assert out.assigns.save_status == "Auto-saved"
    end

    test "batch path (paper_ops) clears paper_halt on a clean batch",
         %{conn: conn, paper: paper} do
      socket = paper_socket(conn, paper, "a stale halt from a prior save")

      assert {:ok, out, _receipt, :applied} =
               Paper.paper_ops(
                 socket,
                 [append_op("b-batch")],
                 Ecto.UUID.generate(),
                 socket.assigns.paper_rev
               )

      assert out.assigns.paper_halt == nil
    end
  end
end
