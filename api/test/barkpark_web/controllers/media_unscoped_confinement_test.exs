defmodule BarkparkWeb.MediaUnscopedConfinementTest do
  @moduledoc """
  The flat media surface must never widen an ABSENT tenant scope into an
  ALL-TENANTS read (task-2e4a3692adf5c565).

  `AssignDefaultScope` passes the conn through untouched when no workspace is
  seeded at slug "default" (its own moduledoc says so, and it never halts).
  `ScopeHelpers.scope_opts/1` then emits no `:workspace_id`, and the `Media`
  read helpers hand that nil to `Content.Scope.scope_to_workspace_or_global/3`,
  whose nil arm returns the query UNTOUCHED. The four flat read actions
  therefore served every tenant's rows to an anonymous caller.

  THE RULE PINNED HERE: an unscoped caller may see only the SHARED/GLOBAL layer
  (`workspace_id IS NULL`) — never another tenant's rows. That is a per-ROW
  rule, which is what lets a legacy single-tenant install (every row NULL) keep
  working untouched while a multi-tenant install with a missing Default refuses
  foreign rows.

  Four doors, four arms — they share helpers, but a fix that lands on one and
  not the others is exactly the failure this file exists to catch:

    * index/2            (:45)  Media.list_files/2
    * show/2             (:62)  Media.get_file/2
    * serve/2            (:79)  Media.get_file_by_path/2
    * serve_rendition/2  (:135) Media.get_file/2

  Plus a NEGATIVE arm: a pre-tenancy row (workspace_id IS NULL) must STILL be
  readable unscoped. Without it a blanket refusal would pass every arm above
  while breaking every legacy single-tenant install.
  """

  # sync: deletes whole workspaces (Tenancy.delete_workspace cascade) — the wide locks cancel/deadlock concurrent peers
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.{Repo, Tenancy}

  import Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    # The state under test: NO workspace at slug "default", so AssignDefaultScope
    # has nothing to bind and scope_opts/1 yields no :workspace_id.
    case Tenancy.get_default_workspace() do
      nil -> :ok
      ws -> Tenancy.delete_workspace(ws)
    end

    refute Tenancy.get_default_workspace(),
           "precondition: slug \"default\" must be absent for every arm here"

    owned = tenant_file!("owned", "TENANT-A-SECRET")
    shared = unscoped_file!("shared", "LEGACY-SHARED-BYTES")

    {:ok, owned: owned, shared: shared}
  end

  describe "an absent Default scope must not widen into an all-tenants read" do
    test "serve/2 does not serve another tenant's blob", %{owned: owned} do
      conn = get(build_conn(), "/media/files/#{owned.path}")

      refute conn.status == 200,
             "serve/2 leaked a workspace-owned blob to an unscoped caller: #{inspect(conn.resp_body)}"

      refute conn.resp_body =~ "TENANT-A-SECRET"
    end

    test "show/2 does not expose another tenant's metadata", %{owned: owned} do
      conn = get(build_conn(), "/media/#{owned.id}/meta")

      refute conn.status == 200,
             "show/2 leaked a workspace-owned row to an unscoped caller: #{inspect(conn.resp_body)}"
    end

    test "index/2 does not list another tenant's files", %{owned: owned} do
      body = build_conn() |> get("/media") |> json_response(200)
      ids = Enum.map(body["files"], & &1["id"])

      refute owned.id in ids,
             "index/2 listed a workspace-owned row to an unscoped caller"
    end

    # NOT a status assertion. A .txt cannot be thumbnailed, so this action 404s
    # either way and a bare `refute status == 200` passes VACUOUSLY while the
    # row is still resolved (observed: the pre-fix run logged
    # `workspace_id=global … Renditions.generate thumb … Failed to find load`,
    # i.e. the leak happened and only the image encode failed). The two 404s
    # carry DIFFERENT messages, and that difference is the actual signal:
    #   scope refused the row  -> Media.get_file/2 {:error, :not_found} -> "file not found"
    #   row resolved, encode failed ->            {:error, _}           -> "rendition unavailable"
    test "serve_rendition/2 does not resolve another tenant's file", %{owned: owned} do
      body = build_conn() |> get("/media/renditions/#{owned.id}/thumb") |> response(404)

      refute body =~ "rendition unavailable",
             "serve_rendition/2 RESOLVED a workspace-owned row for an unscoped caller — " <>
               "it only 404'd because the rendition could not be encoded, not because " <>
               "the tenant scope refused it"

      assert body =~ "file not found"
    end
  end

  describe "NEGATIVE ARM — the shared/global layer stays readable" do
    test "serve/2 still serves a pre-tenancy (workspace_id IS NULL) blob", %{shared: shared} do
      conn = get(build_conn(), "/media/files/#{shared.path}")

      assert conn.status == 200,
             "the fix over-reached: an unscoped row must stay readable or every " <>
               "legacy single-tenant install loses its media"

      assert conn.resp_body == "LEGACY-SHARED-BYTES"
    end

    test "index/2 still lists a pre-tenancy row", %{shared: shared} do
      body = build_conn() |> get("/media") |> json_response(200)
      ids = Enum.map(body["files"], & &1["id"])

      assert shared.id in ids, "the fix over-reached: unscoped rows must stay listed"
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp tenant_file!(tag, bytes) do
    ws = create_workspace!("confine-#{tag}")
    proj = create_project!(ws, "confine-#{tag}-p")
    {:ok, ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: @dataset})

    insert_file!(tag, bytes, workspace_id: ws.id, project_id: proj.id, dataset_id: ds.id)
  end

  defp unscoped_file!(tag, bytes), do: insert_file!(tag, bytes, [])

  defp insert_file!(tag, bytes, scope) do
    path = "uploads/confine/#{tag}-#{System.unique_integer([:positive])}.txt"
    full = Media.file_path(path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    attrs =
      %{
        filename: Path.basename(path),
        original_name: Path.basename(path),
        path: path,
        mime_type: "text/plain",
        size: byte_size(bytes),
        dataset: @dataset
      }
      |> Map.merge(Map.new(scope))

    %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert!()
  end
end
