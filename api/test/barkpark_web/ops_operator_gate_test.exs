defmodule BarkparkWeb.OpsOperatorGateTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #4 (task-6605a01e0b9f85a6): the Tasks board,
  Bokbasen and GitHub ops screens are operator-gated on their flat mounts and
  clamped to the mounted workspace on their scoped mounts.

  `async: false`: the operator allowlist is node-global Application env, and
  the board reads the whole `type:task` corpus of the dataset.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.Conflict
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # Fleet and ONIX staleness span every workspace too and were left out of the
  # ruling's first pass (task-dc80c8cbf7d7473d).
  @flat [
    "/admin/projects",
    "/admin/projects/list",
    "/admin/onixedit/bokbasen",
    "/admin/github",
    "/admin/fleet",
    "/admin/onixedit/staleness",
    "/admin/pulse"
  ]

  setup do
    Repo.delete_all(from(d in Document, where: d.type == "task"))
    %{id: default_id} = Tenancy.get_default_workspace()

    ws_a = create_workspace!("ops-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!("ops-b-#{System.unique_integer([:positive])}")

    %{default_id: default_id, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b}
  end

  defp token!(perms, ws_id \\ nil, seat \\ nil, dataset \\ "production", opts \\ []) do
    raw = "ops-gate-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ops-gate", dataset, perms, ws_id, opts)

    if seat do
      {ws, role} = seat
      {:ok, _} = TenancyAuth.create_membership(ws, token.id, role, "api_token")
    end

    {raw, token}
  end

  defp session(raw), do: scoped_conn() |> init_test_session(%{"api_token" => raw})

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  describe "flat mounts are the operator's" do
    test "an ops token bound to a tenant workspace is turned away from every flat screen",
         %{ws_b: ws_b} do
      {raw, _} = token!(["read", "ops"], ws_b.id)

      for path <- @flat do
        result = live(session(raw), path)

        assert match?({:error, {:redirect, %{to: "/studio"}}}, result),
               "#{path} must refuse a tenant-bound ops token"
      end
    end

    test "with the allowlist armed, an unlisted admin token is turned away", %{default_id: d} do
      {raw, _} = token!(["read", "write", "admin"], d)
      {_op_raw, op} = token!(["read", "write", "admin"], d)
      arm([op.id])

      for path <- @flat do
        assert {:error, {:redirect, %{to: "/studio"}}} = live(session(raw), path)
      end
    end

    test "the listed operator still opens every flat screen", %{default_id: d} do
      {raw, op} = token!(["read", "write", "admin"], d)
      arm([op.id])

      for path <- @flat, do: assert({:ok, _view, _html} = live(session(raw), path))
    end

    test "single-tenant (allowlist unset): a Default-bound ops token still opens them",
         %{default_id: d} do
      {raw, _} = token!(["read", "ops"], d)
      for path <- @flat, do: assert({:ok, _view, _html} = live(session(raw), path))
    end
  end

  describe "scoped mounts are clamped to the mounted workspace" do
    setup %{ws_a: ws_a, proj_a: proj_a} do
      {raw, _} = token!(["read", "write", "ops"], ws_a.id)
      %{conn: session(raw), base: "/w/#{ws_a.slug}/p/#{proj_a.slug}/admin"}
    end

    test "the GitHub console lists and resolves only this workspace's conflicts",
         %{conn: conn, base: base, ws_a: ws_a, ws_b: ws_b} do
      mine = conflict!(101, ws_a.id)
      theirs = conflict!(202, ws_b.id)

      {:ok, view, html} = live(conn, base <> "/github")
      assert html =~ "gh-101"
      refute html =~ "gh-202"

      render_click(view, "resolve", %{"id" => to_string(theirs.id)})
      assert is_nil(Repo.get!(Conflict, theirs.id).resolved_at)

      render_click(view, "resolve", %{"id" => to_string(mine.id)})
      refute is_nil(Repo.get!(Conflict, mine.id).resolved_at)
    end

    test "the board shows and peeks only this workspace's tasks",
         %{conn: conn, base: base, ws_a: ws_a, ws_b: ws_b} do
      task!("ops-a-task", "Alpha task in A", ws_a.id)
      task!("ops-b-task", "Bravo secret in B", ws_b.id)

      {:ok, _view, html} = live(conn, base <> "/projects")
      assert html =~ "Alpha task in A"
      refute html =~ "Bravo secret in B"

      {:ok, _view, peek} = live(conn, base <> "/projects?task=ops-b-task")
      refute peek =~ "Bravo secret in B"
    end
  end

  # The consoles are pinned to `production`. A token minted with an explicit
  # other dataset is held to that one, so it opens none of them
  # (task-6b02208a730fc4fd).
  describe "a dataset-bound token" do
    @consoles ~w(/projects /projects/list /onixedit/bokbasen /github /fleet /onixedit/staleness)

    test "bound to another dataset is turned away from every console, scoped and flat",
         %{ws_a: ws_a, proj_a: proj_a, default_id: d} do
      perms = ["read", "write", "ops"]
      {scoped_raw, _} = token!(perms, ws_a.id, nil, "bound-own", dataset_bound: true)
      {flat_raw, _} = token!(perms, d, nil, "bound-own", dataset_bound: true)

      for console <- @consoles do
        scoped = "/w/#{ws_a.slug}/p/#{proj_a.slug}/admin" <> console

        assert {:error, {:redirect, %{to: "/studio"}}} = live(session(scoped_raw), scoped)

        assert {:error, {:redirect, %{to: "/studio"}}} =
                 live(session(flat_raw), "/admin" <> console)
      end
    end

    test "bound to production still opens them (control)", %{ws_a: ws_a, proj_a: proj_a} do
      {raw, _} = token!(["read", "write", "ops"], ws_a.id, nil, "production", dataset_bound: true)

      for console <- @consoles do
        assert {:ok, _view, _html} =
                 live(session(raw), "/w/#{ws_a.slug}/p/#{proj_a.slug}/admin" <> console)
      end
    end
  end

  # Pulse has no workspace to clamp to, so its scoped mount is the operator's
  # too (task-198c3d82d9158d17).
  describe "Pulse, scoped" do
    test "a tenant's ops token is turned away; the Default operator opens it",
         %{ws_a: ws_a, proj_a: proj_a, default_id: d} do
      {tenant, _} = token!(["read", "write", "ops"], ws_a.id)
      path = "/w/#{ws_a.slug}/p/#{proj_a.slug}/admin/pulse"
      assert {:error, {:redirect, %{to: "/studio"}}} = live(session(tenant), path)

      {operator, _} = token!(["read", "write", "ops"], d)
      assert {:ok, _view, _html} = live(session(operator), "/admin/pulse")
    end
  end

  describe "Fleet and ONIX staleness, scoped" do
    setup %{ws_a: ws_a, proj_a: proj_a} do
      {raw, _} = token!(["read", "write", "ops"], ws_a.id)
      %{conn: session(raw), base: "/w/#{ws_a.slug}/p/#{proj_a.slug}/admin"}
    end

    test "the fleet lists only this workspace's listeners",
         %{conn: conn, base: base, ws_a: ws_a, ws_b: ws_b} do
      listener!("LISTENER-IN-A", ws_a.id)
      listener!("LISTENER-IN-B", ws_b.id)

      {:ok, view, _html} = live(conn, base <> "/fleet")
      html = render(view)
      assert html =~ "LISTENER-IN-A"
      refute html =~ "LISTENER-IN-B"
    end

    test "staleness lists and acknowledges only this workspace's books",
         %{conn: conn, base: base, ws_a: ws_a, ws_b: ws_b} do
      mine = book!("BOOK-IN-A", ws_a.id)
      theirs = book!("BOOK-IN-B", ws_b.id)

      {:ok, view, _html} = live(conn, base <> "/onixedit/staleness")
      html = render(view)
      assert html =~ "BOOK-IN-A"
      refute html =~ "BOOK-IN-B"

      render_hook(view, "acknowledge", %{"doc_id" => theirs.doc_id, "id" => theirs.id})
      refute Repo.get!(Document, theirs.id).content["staleness_acknowledged"]

      render_hook(view, "acknowledge", %{"doc_id" => mine.doc_id, "id" => mine.id})
      assert Repo.get!(Document, mine.id).content["staleness_acknowledged"] == true
    end
  end

  defp listener!(worker, ws_id) do
    doc!("listener", "listener-#{worker}-#{System.unique_integer([:positive])}", ws_id, %{
      "worker" => worker,
      "status" => "idle",
      "ttl_s" => 120,
      "last_seen" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp book!(doc_id, ws_id),
    do: doc!("book", "#{doc_id}-#{System.unique_integer([:positive])}", ws_id, %{})

  defp doc!(type, doc_id, ws_id, content) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: type,
      dataset: "production",
      status: "published",
      title: doc_id,
      rev: "rev-#{doc_id}",
      workspace_id: ws_id,
      content: content
    })
  end

  defp conflict!(issue, ws_id) do
    {:ok, c} =
      Barkpark.Plugins.Github.Conflicts.record(%{
        repo: "FRIKKern/barkpark",
        issue: issue,
        doc_id: "gh-#{issue}",
        dataset: "production",
        kind: "detached",
        detail: %{}
      })

    c |> Ecto.Changeset.change(workspace_id: ws_id) |> Repo.update!()
  end

  defp task!(doc_id, title, ws_id) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: "production",
      status: "published",
      title: title,
      rev: "rev-#{doc_id}",
      workspace_id: ws_id,
      content: %{"lifecycle_status" => "open"}
    })
  end
end
