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

  @flat ["/admin/projects", "/admin/onixedit/bokbasen", "/admin/github"]

  setup do
    Repo.delete_all(from(d in Document, where: d.type == "task"))
    %{id: default_id} = Tenancy.get_default_workspace()

    ws_a = create_workspace!("ops-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!("ops-b-#{System.unique_integer([:positive])}")

    %{default_id: default_id, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b}
  end

  defp token!(perms, ws_id \\ nil, seat \\ nil) do
    raw = "ops-gate-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ops-gate", "production", perms, ws_id)

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
