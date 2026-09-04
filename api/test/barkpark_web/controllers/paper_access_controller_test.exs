defmodule BarkparkWeb.PaperAccessControllerTest do
  @moduledoc """
  Edit-on-the-link slice 4 (task-e99a8e946f80f52c, epic task-a19eeb215f653529),
  criterion 3: *"GET /v1/papers/<slug>/access lists view and edit rows with
  principal and time, admin-only."*

  Four things, each asserted on its own:

    * **view and edit rows.** Both actions are produced by DRIVING THE READER,
      not by inserting rows — a log that only a test can write proves nothing
      about the feature. A LiveView mount makes the "view" row; an accepted op
      makes the "edit" row.
    * **with principal and time.** The actor triple and `at` come back on every
      row; an anonymous row carries the kind and NOTHING else.
    * **admin-only.** No token 401s, a non-admin token 403s. Both refusals come
      from the `:flat_admin_api` pipeline rather than from anything this
      controller re-implements, which is the point of mounting it there.
    * **newest first.** Asserted against a known write order, not against a
      single row that could be ordered any way at all.

  `async: false` — the Default scope is process-global and the reader mounts
  drive shared presence.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.{PaperAccess, PaperAccessLog}

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()
    slug = "eol-access-#{System.unique_integer([:positive])}"
    seed_paper!(slug)

    %{conn: conn, slug: slug, default_ws: default_ws, default_proj: default_proj}
  end

  defp seed_paper!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Access probe",
          "blocks" => [
            %{"id" => "b-head", "type" => "heading", "text" => "Access probe", "level" => 1},
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body text"}]
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ]
        })
      )

    paper
  end

  defp session_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp make_token!(name, perms) do
    raw = "eol-access-#{name}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, name, @dataset, perms)
    {token, raw}
  end

  defp admin_conn(conn) do
    {_token, raw} = make_token!("admin", ["read", "write", "admin"])
    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  defp get_access(conn, slug, query \\ "") do
    get(conn, "/v1/papers/#{slug}/access" <> query)
  end

  # The reader's trail write is fire-and-forget on `Barkpark.TaskSupervisor`
  # (`PaperAccess.record/1`), so a row is not in the table the instant `live/2`
  # or an op returns. Poll for the expected count against a deadline rather
  # than sleeping: a sleep proves a row arrived eventually, a bounded poll
  # proves it arrived at all and fails loudly naming what was missing.
  #
  # It also keeps the sandbox honest — the test cannot finish, and its owner
  # cannot stop, while the write is still in flight.
  @await_ms 2_000
  defp await_rows(slug, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @await_ms
    count = Repo.aggregate(from(r in PaperAccessLog, where: r.slug == ^slug), :count)

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "only #{count} access row(s) for #{slug} after #{@await_ms}ms, expected #{expected}"
        )

      true ->
        Process.sleep(20)
        await_rows(slug, expected, deadline)
    end
  end

  describe "criterion 3 — the rows the reader actually produces" do
    test "a view and an edit are both listed, with principal and time", %{
      conn: conn,
      slug: slug
    } do
      {token, raw} = make_token!("writer", ["read", "write"])

      # DRIVE THE READER: mounting writes the view row, the accepted op writes
      # the edit row.
      {:ok, view, _html} = live(session_token(conn, raw), "/papers/#{slug}")

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "Edited"}]}
      })

      await_rows(slug, 2)

      body = conn |> admin_conn() |> get_access(slug) |> json_response(200)

      assert body["slug"] == slug
      assert body["count"] == 2

      actions = Enum.map(body["access"], & &1["action"])
      assert Enum.sort(actions) == ["edit", "view"]

      for row <- body["access"] do
        assert row["actor_kind"] == "api_token"
        assert row["actor_id"] == token.id
        assert row["actor_label"] == "writer"
        assert row["dataset"] == @dataset
        # The time is present and parseable, not a nil the client must guess at.
        assert {:ok, _dt, _} = DateTime.from_iso8601(row["at"])
      end
    end

    test "rows come back newest first", %{conn: conn, slug: slug} do
      {_token, raw} = make_token!("ordered", ["read", "write"])
      {:ok, view, _html} = live(session_token(conn, raw), "/papers/#{slug}")

      # view, then edit, then edit — a known order to assert the inverse of.
      for text <- ["First", "Second"] do
        render_hook(view, "paper-op", %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
        })
      end

      await_rows(slug, 3)

      body = conn |> admin_conn() |> get_access(slug) |> json_response(200)

      assert Enum.map(body["access"], & &1["action"]) == ["edit", "edit", "view"]

      # Explicitly descending by time, not merely "the view is last".
      times = Enum.map(body["access"], & &1["at"])
      assert times == Enum.sort(times, :desc)
    end

    test "an anonymous view is logged with the kind and nothing else", %{
      conn: conn,
      slug: slug
    } do
      {:ok, _view, _html} = live(conn, "/papers/#{slug}")
      await_rows(slug, 1)

      body = conn |> admin_conn() |> get_access(slug) |> json_response(200)

      assert [row] = body["access"]
      assert row["action"] == "view"
      assert row["actor_kind"] == "anonymous"
      assert row["actor_id"] == nil
      assert row["actor_label"] == nil
    end

    test "a DEAD render logs nothing — a crawler is not a reader", %{conn: conn, slug: slug} do
      # `get/2` renders the LiveView statically: no socket, no connected mount.
      assert conn |> get("/papers/#{slug}") |> html_response(200) =~ "Original body text"

      body = conn |> admin_conn() |> get_access(slug) |> json_response(200)
      assert body["access"] == []
      assert body["count"] == 0
    end

    test "?limit= and ?dataset= narrow the listing", %{conn: conn, slug: slug} do
      {_token, raw} = make_token!("narrow", ["read", "write"])
      {:ok, view, _html} = live(session_token(conn, raw), "/papers/#{slug}")

      for text <- ["a", "b", "c"] do
        render_hook(view, "paper-op", %{
          "op" => "patch-block",
          "id" => "b-body",
          "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
        })
      end

      await_rows(slug, 4)

      full = conn |> admin_conn() |> get_access(slug) |> json_response(200)
      assert full["count"] == 4

      limited = conn |> admin_conn() |> get_access(slug, "?limit=2") |> json_response(200)
      assert limited["count"] == 2

      matching =
        conn |> admin_conn() |> get_access(slug, "?dataset=#{@dataset}") |> json_response(200)

      assert matching["count"] == 4

      other = conn |> admin_conn() |> get_access(slug, "?dataset=staging") |> json_response(200)
      assert other["count"] == 0
    end

    test "a malformed limit falls back instead of 500ing", %{conn: conn, slug: slug} do
      {:ok, _view, _html} = live(conn, "/papers/#{slug}")
      await_rows(slug, 1)

      assert conn |> admin_conn() |> get_access(slug, "?limit=banana") |> json_response(200)
      assert conn |> admin_conn() |> get_access(slug, "?limit[]=1") |> json_response(200)
      assert conn |> admin_conn() |> get_access(slug, "?limit=-5") |> json_response(200)
    end
  end

  describe "criterion 3 — admin-only" do
    test "no token is a 401", %{conn: conn, slug: slug} do
      assert conn |> get_access(slug) |> json_response(401)
    end

    test "a read/write token that is not admin is a 403", %{conn: conn, slug: slug} do
      {_token, raw} = make_token!("nonadmin", ["read", "write"])

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> get_access(slug)
             |> json_response(403)
    end

    test "a read-only token is a 403", %{conn: conn, slug: slug} do
      {_token, raw} = make_token!("readonly", ["read"])

      assert conn
             |> put_req_header("authorization", "Bearer #{raw}")
             |> get_access(slug)
             |> json_response(403)
    end

    test "a garbage bearer is a 401, not a 403", %{conn: conn, slug: slug} do
      assert conn
             |> put_req_header("authorization", "Bearer not-a-real-token")
             |> get_access(slug)
             |> json_response(401)
    end
  end

  describe "the store beneath it" do
    test "record_now/1 never raises and never fails a caller" do
      # Invalid on every axis the changeset checks.
      assert PaperAccess.record_now(%{}) == :ok
      assert PaperAccess.record_now(%{slug: "s", dataset: "d", action: "nonsense"}) == :ok
      assert PaperAccess.record_now(:not_even_a_map) == :ok
    end

    test "record/1 schedules the write off the caller and still says :ok", %{slug: slug} do
      assert PaperAccess.record(%{
               slug: slug,
               dataset: @dataset,
               action: "view",
               actor_kind: "anonymous"
             }) == :ok

      await_rows(slug, 1)
      assert [_row] = PaperAccess.list(slug, workspace_id: nil)
    end

    test "record/1 is a no-op when the trail is switched off", %{slug: slug} do
      Application.put_env(:barkpark, :paper_access_log_enabled, false)
      on_exit(fn -> Application.delete_env(:barkpark, :paper_access_log_enabled) end)

      refute PaperAccess.enabled?()

      assert PaperAccess.record(%{
               slug: slug,
               dataset: @dataset,
               action: "view",
               actor_kind: "anonymous"
             }) == :ok

      # Nothing scheduled, so nothing to wait for.
      assert PaperAccess.list(slug, workspace_id: nil) == []
    end

    test "an anonymous row cannot carry an identity, however it is handed one", %{slug: slug} do
      :ok =
        PaperAccess.record_now(%{
          slug: slug,
          dataset: @dataset,
          action: "view",
          actor_kind: "anonymous",
          actor_id: "sneaky",
          actor_label: "sneaky@example.com"
        })

      assert [row] = PaperAccess.list(slug, workspace_id: nil)
      assert row.actor_kind == "anonymous"
      assert row.actor_id == nil
      assert row.actor_label == nil
    end

    test "prune/1 deletes past the window and leaves the rest", %{slug: slug} do
      :ok =
        PaperAccess.record_now(%{
          slug: slug,
          dataset: @dataset,
          action: "view",
          actor_kind: "anonymous"
        })

      # A zero-day window sweeps everything already written.
      assert {:ok, 1} = PaperAccess.prune(0)
      assert PaperAccess.list(slug, workspace_id: nil) == []

      :ok =
        PaperAccess.record_now(%{
          slug: slug,
          dataset: @dataset,
          action: "view",
          actor_kind: "anonymous"
        })

      # The default window keeps a row written a moment ago.
      assert {:ok, 0} = PaperAccess.prune()
      assert [_row] = PaperAccess.list(slug, workspace_id: nil)
    end

    test "the sweeper worker runs the prune", %{slug: slug} do
      :ok =
        PaperAccess.record_now(%{
          slug: slug,
          dataset: @dataset,
          action: "view",
          actor_kind: "anonymous"
        })

      assert {:ok, %{deleted: 1}} =
               Barkpark.Content.Workers.PaperAccessSweeper.perform(%Oban.Job{
                 args: %{"days" => 0}
               })

      assert PaperAccess.list(slug, workspace_id: nil) == []
    end

    test "the configured ttl is the default when unset or nonsense" do
      assert PaperAccess.ttl_days() == 90

      Application.put_env(:barkpark, :paper_access_log_ttl_days, 7)
      on_exit(fn -> Application.put_env(:barkpark, :paper_access_log_ttl_days, 90) end)
      assert PaperAccess.ttl_days() == 7

      Application.put_env(:barkpark, :paper_access_log_ttl_days, "nope")
      assert PaperAccess.ttl_days() == 90
    end
  end
end
