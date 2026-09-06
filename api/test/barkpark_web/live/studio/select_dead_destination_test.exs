defmodule BarkparkWeb.Studio.SelectDeadDestinationTest do
  @moduledoc """
  A desk row whose destination CRASHES must not look like a no-op
  (spd-w18-bl-select-detects-dead-destination).

  `spd-w18-nil-icon-500` closed the crash. It did not close the
  BLINDNESS. `Scope.select/2` only assigned `focus_pane_idx` and
  `push_patch`ed, and `push_patch/2` is fire-and-forget: it hands the
  destination to `handle_params/3` and returns. When that transition
  raised, the LiveView process died before anything was flushed — no
  URL change, no `aria-current`, no message, nothing in the console.
  Measured on the deployed build: 8 seconds of silence clicking the
  …Rest desk row while `/studio/rest` returned HTTP 500. A crashing
  destination was byte-identical to a dead button.

  ## The mechanism under test — the navigation receipt

  `Scope.select/2` now writes a RECEIPT (`:pending_select`) naming the
  row it asked for, and `StudioLive.handle_params/3` runs the whole
  transition inside `Scope.settle_pending_select/2`:

    * the transition returns -> the receipt is torn up (every navigation
      that works today, unchanged);
    * the transition RAISES  -> the receipt is still open, so the handler
      knows WHICH row the user clicked, and turns the raise into a named
      flash instead of a dead process.

  The receipt is what makes the rescue legitimate AND narrow: a
  `handle_params` with no open receipt (mount, back/forward, a scope
  switch) is NOT rescued.

  ## The raising destination, with no test backdoor

  The clicked row is a TYPE row in the Content pane — the same shape
  as the `…Rest` row that was measured dead on the deployed build: a
  desk row whose destination is a pane the user has never rendered. Its destination is that type's
  document-list pane, and the fixture makes that pane raise: one
  document of the type has its `content` set to a jsonb ARRAY.

  `documents.content` is a jsonb column read through an Ecto `:map`
  field. Postgres holds an array there happily — an API writer, a bad
  migration or a hand-edit can put one in — and every `Map.get/2`
  downstream then raises. `PaneBuilder.list_documents_preflighted/3`
  (pane_builder.ex, `walk_path/7`) is where it lands, i.e. inside
  `Shared.rebuild_panes/1` inside `Lifecycle.finish_handle_params/6` —
  the destination transition itself.

  Nothing is stubbed, no module is replaced, no `Application.put_env`
  fault flag exists: the destination raises for a reason production
  can actually produce. The DESK ROOT still renders (it does not list
  the type's documents), so the row is there to click — which is
  precisely the shape the row describes: a live desk, one dead
  destination.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo}

  @dataset "production"
  @admin_token "select-dead-destination-admin-token"
  @dead_type "dead_dest_note"
  @good_type "live_dest_note"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "dead destination admin", @dataset, [
        "read",
        "write",
        "admin"
      ])

    for {type, title} <- [{@dead_type, "Dead Dest Note"}, {@good_type, "Live Dest Note"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => title,
            "icon" => "file",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => "#{type}-1", "title" => "#{title} One", "content" => %{}},
          @dataset
        )
    end

    # THE CORRUPTION. A jsonb array in a column an Ecto `:map` field
    # reads — legal in Postgres, fatal for every `Map.get/2` downstream.
    # Raw SQL because the changeset would (correctly) refuse it.
    #
    # `LIKE '%' || $1` on purpose: `create_document/3` writes the row as
    # `drafts.<doc_id>`, so pinning the UPDATE to the bare id corrupts a
    # row the destination never reads — a fixture that looks armed and
    # fires nothing (the click stayed green through three runs before
    # this line was fixed).
    {:ok, %{num_rows: rows}} =
      Repo.query(
        "UPDATE documents SET content = '[]'::jsonb WHERE doc_id LIKE '%' || $1 AND dataset = $2",
        ["#{@dead_type}-1", @dataset]
      )

    assert rows > 0, "the corruption matched no row — the fixture is not armed"

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
  end

  describe "a desk row whose destination raises" do
    test "the click produces a NAMED failure, not silence", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/content-types"))

      assert html =~ ~s(id="item-#{@dead_type}"),
             "the type's desk row must render, or there is nothing to click and this " <>
               "test proves nothing"

      after_click = view |> element(~s(button#item-#{@dead_type})) |> render_click()

      # THE BINARY. The failing shape this test exists to red on is
      # SILENCE: the click returning a page indistinguishable from the
      # one before it. The oracle is the LiveView's OWN render — the
      # flash lives in the layout, which a patch never re-renders, so
      # asserting only on flash would pass a notice that a patched page
      # never shows the user.
      assert after_click =~ ~s(data-test-id="studio-nav-error"),
             "clicking a desk row whose destination raises produced no named state — " <>
               "this is the dead-button shape spd-w18-bl-select-detects-dead-destination " <>
               "exists to forbid"

      assert after_click =~ ~s(role="alert"),
             "the failure notice must be announced, not merely painted"

      assert after_click =~ "Couldn&#39;t open" or after_click =~ "Couldn't open"

      assert after_click =~ @dead_type,
             "the failure notice must NAME the row that failed, not shrug generically"
    end

    test "the socket survives — a healthy sibling row still opens afterwards", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/content-types"))

      view |> element(~s(button#item-#{@dead_type})) |> render_click()

      # The receipt converted a process death into a message; the same
      # LiveView must still be alive and navigable. If the rescue had
      # left a half-built socket this render would die here.
      after_good = view |> element(~s(button#item-#{@good_type})) |> render_click()

      assert after_good =~ "Live Dest Note One"
    end
  end

  describe "the receipt is narrow" do
    test "a healthy drill still navigates, with no failure notice", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/content-types"))

      after_click = view |> element(~s(button#item-#{@good_type})) |> render_click()

      assert after_click =~ "Live Dest Note One"
      refute after_click =~ ~s(data-test-id="studio-nav-error")
      refute after_click =~ "Couldn&#39;t open"
      refute after_click =~ "Couldn't open"
    end
  end
end
