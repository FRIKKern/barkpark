defmodule BarkparkWeb.Studio.StudioLivePlusPressRetryTest do
  @moduledoc """
  THE SECOND PRESS OF "+" (spd-w18-plus-creates-without-navigating, criterion 2).

  WHAT WAS MEASURED. `tooling/studio-journey/journey.mjs` walked four served
  builds. On `e4ed31a10` the "+" navigated in 6.4s on one press. On
  `4f046cce1` it never navigated in 20.0s across THREE presses — and the desk
  list still grew "Untitled ⋅ Updated 2m ago" rows, because every one of those
  presses DID create a document. Three orphan drafts survived on production and
  were swept by hand. The create path is not broken; the ANSWER is missing, and
  a human who cannot see an answer presses again.

  WHY THE FIX IS NOT A PENDING ASSIGN. `new_document/2` ends in `push_patch`,
  and a `push_patch` from `handle_event` replies with the event's OWN ref
  (D242), so `handle_event` + `handle_params` + `render` collapse into ONE
  reply frame: there is no intermediate render in which a server-side
  "creating…" state could be painted, and when that single frame is dropped
  client-side (D265 — the browser's three silent drop gates) the server has
  already finished believing it navigated. The pending state for the press
  itself is therefore the CLIENT half, shipped by spd-w19/#16624 and guarded by
  `row_press_state_guard_test.exs`. This file guards the other half, which is
  the one with a data tail: the press that follows.

  WHAT IS GUARDED HERE. A second "+" on the same type, inside the client's own
  30s PUSH_TIMEOUT window, whose first draft is still exactly as it was born,
  is answered instead of obeyed — it re-navigates to that draft and SAYS so.
  One draft, one sentence, instead of two drafts and silence.

  AND THE THREE WAYS IT MUST NOT FIRE, each its own arm, because a coalescing
  guard that is too eager is a WORSE defect than the one it fixes (it would
  refuse a human who genuinely wants two blank drafts):

    * the first press of all (arm 2) — nothing to coalesce onto,
    * a draft that has been WRITTEN to since birth (arm 3) — `rev` moved, the
      human has seen it and is now asking for a second one,
    * a different type (arm 4) — a Papers create never eats a Notes create.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"

  # The exact sentence the human is owed. Named once so an arm asserting its
  # ABSENCE cannot drift away from the arm asserting its presence.
  @answer "already created an untitled"

  defp seed_schema!(name, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => title,
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  setup do
    seed_schema!("paper", "Papers")
    seed_schema!("note", "Notes")
    :ok
  end

  defp papers, do: Content.list_documents("paper", @dataset, perspective: :raw)

  defp press_plus(view) do
    # SCOPE the selector: the airdrop/access header buttons share
    # `.pane-add-btn`, and more than one element on the desk carries
    # [phx-click="new-document"].
    view
    |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
    |> render_click()
  end

  describe "arm 1 — the human presses + twice because the screen did not move" do
    test "the second press opens the first draft and says so; it does not make a second",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      first = press_plus(view)
      refute first =~ @answer, "the FIRST press has nothing to coalesce onto"
      assert [created] = papers()

      second = press_plus(view)

      assert second =~ @answer,
             "the second press said nothing — that silence is what left three orphan Untitled drafts on production"

      assert [survivor] = papers(),
             "a second draft was created: the press was obeyed instead of answered"

      assert survivor.doc_id == created.doc_id,
             "the human was re-navigated to a DIFFERENT document than the one their first press made"
    end
  end

  describe "arm 2 — the first press is never coalesced" do
    test "one press creates exactly one draft and says nothing about a retry", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      html = press_plus(view)

      refute html =~ @answer
      refute html =~ "Failed to create"
      assert length(papers()) == 1
    end
  end

  describe "arm 3 — a draft that has been written to is not a retry target" do
    test "once rev moves, the next + creates a real second draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      press_plus(view)
      assert [created] = papers()

      # THE HUMAN TYPED. `rev` is exactly what any write of any type moves, and
      # it is the predicate the guard reads — so moving it here is the same
      # event an autosave is, at the level the guard actually looks. (Writing
      # through the editor would drag the whole canvas/autosave stack into a
      # test about press counting.)
      {1, _} =
        Repo.update_all(
          from(d in Document, where: d.id == ^created.id),
          set: [rev: "rev-the-human-typed"]
        )

      html = press_plus(view)

      refute html =~ @answer,
             "the guard claimed a retry for a draft the human had already written to"

      assert length(papers()) == 2,
             "a human who edited their draft and pressed + again is asking for a SECOND document, and must get one"
    end
  end

  describe "arm 4 — the window is scoped to the type that was pressed" do
    test "a create of another type is never eaten by the paper marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      press_plus(view)
      assert length(papers()) == 1

      html = render_click(view, "new-document", %{"type" => "note"})

      refute html =~ @answer
      assert length(Content.list_documents("note", @dataset, perspective: :raw)) == 1
    end
  end
end
