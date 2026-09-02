defmodule BarkparkWeb.WorkspaceImportOperatorGrantTest do
  @moduledoc """
  IMPORT-THEN-PUSH — the operator flow `bp cloud workspace import --with-blobs`
  drives, end to end, with ONE token throughout (task-ed7ae8110c7c8b41).

  Until the grant landed, an imported workspace arrived on the target instance
  with ZERO valid administrators: the bundle carries only the SOURCE instance's
  `workspace_memberships` rows, and those name principals that do not exist
  here. Nothing on the import path wrote a membership for a target-side token
  (`Auth.insert_token_with_membership/3` is the token-MINT seam and mints a new
  token; import never called it). So the operator who had just landed the
  workspace could not push its blobs, could not re-export it and could not
  delete it — all three now on `TenancyAuth.workspace_admin?/2`, the blob route
  since task-62d9364937b538e5 ruled CONFINE.

  THE TWO DENIAL SHAPES ARE DIFFERENT AND BOTH ARE DELIBERATE, so a test that
  expects one law on the other route reds for the wrong reason. The blob route
  is `ResolveWorkspace`-shaped: a non-member gets 404 `workspace not found` and
  learns nothing about whether the slug exists. `export/2` and `delete/2` follow
  the path-addressed law documented on `WorkspaceController.delete/2` — unknown
  slug 404, real workspace the caller does not administer 403.

  That gap PREDATES the tenancy binding of PRs #12824/#12826/#12827 — the old
  workspace-blind `require_admin` was papering over it. Closing the hole made
  the missing grant visible; these tests pin the completed flow.

  ROLE LEVEL IS LOAD-BEARING, and MORE so since task-62d9364937b538e5. All
  three routes now bind on `workspace_admin?/2` (`owner`/`admin` only) — the
  blob route used to bind on the floorless `member?/2`, so a plain `member`
  grant would once have fixed the blob arm while leaving the imported workspace
  with no administrator (the same hole, one route narrower). Under the
  harmonised floor a `member` grant reds ALL THREE arms, which only widens what
  a downgrade mutation cannot slip past.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Media, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership
  alias Barkpark.Tenancy.WorkspaceBundle

  import Ecto.Query

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp verified(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token
  end

  # An admin-permissioned token whose HOME workspace is its own — never the
  # workspace under import. This is the target-side operator credential.
  defp operator_token(label) do
    n = System.unique_integer([:positive])
    raw = "#{label}-#{n}"

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "#{label}-home-#{n}", name: "#{label} home #{n}"})

    {:ok, token} = Auth.create_token(raw, label, "test", ["read", "write", "admin"], ws.id)
    {raw, token, ws}
  end

  # Build a real bp-export-v1 bundle for a workspace owned by a DIFFERENT
  # principal (the SOURCE instance's owner), then remove the workspace so the
  # import lands into a clean target — the cross-instance restore, modelled.
  defp source_bundle! do
    n = System.unique_integer([:positive])
    raw_src = "ws-import-source-#{n}"
    {:ok, _src} = Auth.create_token(raw_src, "source owner", "test", ["read", "write", "admin"])

    {:ok, target} =
      Tenancy.create_workspace_with_owner(%{name: "Imported WS #{n}"}, verified(raw_src))

    project = Tenancy.get_project(target.slug, "default")
    {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

    {:ok, bundle} = WorkspaceBundle.export(target.id)

    ws_id = target.id
    ws_slug = target.slug
    src_membership = Repo.one!(from m in Membership, where: m.workspace_id == ^ws_id)

    {:ok, _} = Tenancy.delete_workspace(target)
    {:ok, ws_bin} = Ecto.UUID.dump(ws_id)
    purge_fkless_audit!(ws_bin)
    refute Tenancy.get_workspace_by_slug(ws_slug)

    %{
      bundle: bundle,
      ws_id: ws_id,
      ws_slug: ws_slug,
      src_raw: raw_src,
      src_membership: src_membership
    }
  end

  # audit_events / audit_export_sinks carry workspace_id with NO foreign key, so
  # delete_workspace's cascade cannot reach them and the copy-strategy members
  # would collide on re-import. Same clean-target trick the engine round-trip
  # and workspace_controller_test use.
  defp purge_fkless_audit!(ws_bin) do
    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1", [ws_bin])
      Repo.query!("DELETE FROM audit_export_sinks WHERE workspace_id = $1", [ws_bin])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  defp import_bundle(conn, raw, slug, bundle) do
    conn
    |> authed(raw)
    |> put_req_header("content-type", "application/x-tar")
    |> post("/api/workspaces/#{slug}/import", bundle)
  end

  defp push_blob(conn, raw, slug, rel, body) do
    conn
    |> authed(raw)
    |> put_req_header("content-type", "application/octet-stream")
    |> put("/api/workspaces/#{slug}/media/blob/#{rel}", body)
  end

  defp blob_key do
    rel = "uploads/import-grant-test/b-#{System.unique_integer([:positive])}.png"
    on_exit(fn -> File.rm_rf(Media.file_path(rel)) end)
    rel
  end

  describe "the importing token administers what it imported" do
    test "IMPORT-THEN-BLOB-PUSH with ONE token: the blob PUT lands (was 404 'workspace not found')",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug} = source_bundle!()
      {raw_op, _op, _op_ws} = operator_token("op-blob")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      rel = blob_key()
      resp = push_blob(conn, raw_op, slug, rel, "IMPORTED-BLOB-BYTES")

      assert resp.status == 200,
             "import-then-push must work with one token; got #{resp.status}: #{resp.resp_body}"

      assert Jason.decode!(resp.resp_body)["written"] == rel
      assert File.read!(Media.file_path(rel)) == "IMPORTED-BLOB-BYTES"
    end

    test "the grant is an ADMIN membership on the imported workspace — `member` would not do",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!()
      {raw_op, op, _op_ws} = operator_token("op-role")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      # THE ROUTES FIRST, THE LABEL LAST — and the order is the proof, not
      # style. `export/2` and `delete/2` bind on `workspace_admin?/2`
      # (owner|admin), so a `member`-role grant answers 403 on both. Asserting
      # `membership_role == "admin"` ahead of these would short-circuit a
      # downgrade mutation on the LABEL and never exercise the routes —
      # pinning the string rather than the reach it buys. Under a member-grant
      # mutation the first red here is a real 403 off a real request. Since
      # task-62d9364937b538e5 the blob push above sits on the same predicate,
      # so such a mutation now reds there too rather than sliding past it.
      export = conn |> authed(raw_op) |> get("/api/workspaces/#{slug}/export")

      assert export.status == 200,
             "the importer must be able to re-export what it imported; got #{export.status}"

      assert TenancyAuth.workspace_admin?(op, ws_id)
      assert TenancyAuth.membership_role(op, ws_id) == "admin"

      # …and delete, the third sibling on the same predicate. LAST, because it
      # cascades the workspace away — every read above must happen while the
      # membership row still exists.
      deleted = conn |> authed(raw_op) |> delete("/api/workspaces/#{slug}")

      assert deleted.status == 200,
             "the importer must be able to delete what it imported; got #{deleted.status}"

      refute Tenancy.get_workspace_by_slug(slug)
    end

    test "the bundle's OWN membership rows are untouched — the grant is purely ADDITIVE",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id, src_membership: src} = source_bundle!()
      {raw_op, op, _op_ws} = operator_token("op-additive")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      restored = Repo.get(Membership, src.id)

      assert restored, "the bundle's own membership row must be restored by the import"
      assert restored.workspace_id == src.workspace_id
      assert restored.principal_id == src.principal_id
      assert restored.principal_type == src.principal_type
      assert restored.role == src.role
      assert restored.role == "owner"
      assert restored.inserted_at == src.inserted_at
      assert restored.updated_at == src.updated_at

      # Exactly two rows now: the bundle's own, plus the operator's grant.
      rows = Repo.all(from m in Membership, where: m.workspace_id == ^ws_id)
      assert length(rows) == 2
      assert Enum.find(rows, &(&1.principal_id == op.id)).role == "admin"
    end

    test "a FAILED import grants nothing — the membership rides the import transaction",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!()
      {raw_op, op, _op_ws} = operator_token("op-rollback")

      # The engine's test-only fault seam returns an error term AFTER unpack, so
      # the transaction never commits.
      Application.put_env(:barkpark, :import_fault, {:error, :injected_fault})
      on_exit(fn -> Application.delete_env(:barkpark, :import_fault) end)

      assert import_bundle(conn, raw_op, slug, bundle).status == 500

      refute Tenancy.get_workspace_by_slug(slug)
      refute TenancyAuth.membership_role(op, ws_id)
      assert Repo.all(from m in Membership, where: m.workspace_id == ^ws_id) == []
    end
  end

  describe "the grant widens nothing else (negative arm)" do
    test "a token that did NOT import gains nothing: blob PUT 404s and no membership exists",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!()
      {raw_op, _op, _op_ws} = operator_token("op-neg")
      {raw_bystander, bystander, _b_ws} = operator_token("bystander")

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      # The bystander holds the SAME global `admin` permission and imported
      # nothing. It gets no membership and no reach.
      refute TenancyAuth.membership_role(bystander, ws_id)
      refute TenancyAuth.member?(bystander, ws_id)

      rel = blob_key()
      resp = push_blob(conn, raw_bystander, slug, rel, "SHOULD-NOT-LAND")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "workspace not found"
      refute File.exists?(Media.file_path(rel))

      # …nor the admin-predicate siblings. The two families answer a denial
      # DIFFERENTLY and both shapes are deliberate: the blob route is
      # `ResolveWorkspace`-shaped and 404s a non-member (a stranger learns
      # nothing about whether the slug exists), while export/delete follow the
      # path-addressed law documented on `WorkspaceController.delete/2` —
      # unknown slug 404, real workspace the caller does not administer 403.
      refute TenancyAuth.workspace_admin?(bystander, ws_id)

      export = conn |> authed(raw_bystander) |> get("/api/workspaces/#{slug}/export")
      assert export.status == 403

      assert conn
             |> authed(raw_bystander)
             |> delete("/api/workspaces/#{slug}")
             |> Map.get(:status) ==
               403

      # The refusal is a DENIAL, not a deletion: the workspace is still here.
      assert Tenancy.get_workspace_by_slug(slug)
    end

    test "the importer gains membership ONLY in the workspace it imported — not instance-wide",
         %{conn: conn} do
      %{bundle: bundle, ws_slug: slug, ws_id: ws_id} = source_bundle!()
      {raw_op, op, op_ws} = operator_token("op-scope")

      # An unrelated tenant that exists throughout.
      {:ok, unrelated} =
        Tenancy.create_workspace(%{
          slug: "unrelated-#{System.unique_integer([:positive])}",
          name: "Unrelated"
        })

      assert import_bundle(conn, raw_op, slug, bundle).status == 200

      # Exactly the imported workspace plus its own home — nothing else.
      ws_ids =
        from(m in Membership, where: m.principal_id == ^op.id, select: m.workspace_id)
        |> Repo.all()
        |> MapSet.new()

      assert ws_ids == MapSet.new([ws_id, op_ws.id])

      refute TenancyAuth.member?(op, unrelated.id)

      rel = blob_key()
      assert push_blob(conn, raw_op, unrelated.slug, rel, "NOPE").status == 404
      refute File.exists?(Media.file_path(rel))
    end
  end
end
