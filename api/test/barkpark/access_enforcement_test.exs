defmodule Barkpark.AccessEnforcementTest do
  @moduledoc """
  ag-enforcement — the LOAD-BEARING airdrop-grants security layer, proved
  NON-VACUOUSLY. A grantee's ACTIVE grants are folded into `CallerContext` and
  honoured at TWO layers:

    * Layer 1 (coarse) — `Barkpark.Tenancy.Auth.authorize/3` admits a folded
      grant that authorizes the action (membership OR grant), fail-closed.
    * Layer 2 (fine)   — `Barkpark.Content.Query` narrows reads to the union of
      the caller's grant scopes when the read is GRANT-DERIVED
      (`grant_scoped: true`), fail-closed to `where: false` otherwise.

  The whole invariant: grant access ⊆ capabilities ∩ scope. Never wider, never
  a member's byte-identical read altered.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Access.Grant
  alias Barkpark.Accounts
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy.Auth

  @password "correct-horse-battery"
  @dataset "test"

  defp grantee_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # Insert a grant bound (claimed) to `grantee`, so
  # `Access.list_active_grants_for_grantee/1` (which `from_user/2` calls) loads
  # it. `overrides` set the scope ladder / capabilities / expiry / revocation.
  defp bind_grant!(ws, grantee, overrides) do
    attrs =
      %{
        grantor_id: Ecto.UUID.generate(),
        grantee_email: grantee.email,
        grantee_user_id: grantee.id,
        claimed_at: DateTime.utc_now(),
        workspace_id: ws.id,
        capabilities: ["read"],
        link_token_hash: "hash-" <> Ecto.UUID.generate()
      }
      |> Map.merge(overrides)

    {:ok, grant} = %Grant{} |> Grant.changeset(attrs) |> Repo.insert()
    grant
  end

  # A grant-derived read: caller_context folds the grantee's active grants, the
  # `grant_scoped` flag is on (set by ResolveWorkspace in prod), workspace scoped.
  defp grant_read(type, ws, ctx) do
    Content.list_documents(type, @dataset,
      workspace_id: ws.id,
      caller_context: ctx,
      grant_scoped: true
    )
  end

  defp titles(docs), do: docs |> Enum.map(& &1.title) |> Enum.sort()

  # ---------------------------------------------------------------------------
  # 1 + 7. Exact scope: grantee sees EXACTLY the granted (project, dataset, type)
  #        and nothing outside it — including no other project (containment).
  # ---------------------------------------------------------------------------

  describe "Layer 2 — grantee sees exactly the granted scope" do
    test "in-scope rows only; other dataset / type / project are invisible" do
      ws = create_workspace!()
      proj_p = create_project!(ws)
      proj_q = create_project!(ws)
      grantee = grantee_user()

      {:ok, _in} = create_document_in!(ws, proj_p, "post", %{"title" => "in-scope"}, @dataset)
      {:ok, _wrong_type} = create_document_in!(ws, proj_p, "note", %{"title" => "wrong-type"}, @dataset)
      {:ok, _wrong_ds} = create_document_in!(ws, proj_p, "post", %{"title" => "wrong-dataset"}, "other")
      {:ok, _wrong_proj} = create_document_in!(ws, proj_q, "post", %{"title" => "other-project"}, @dataset)

      # grant scoped to (project P, dataset test, type post), read capability
      bind_grant!(ws, grantee, %{
        project_id: proj_p.id,
        dataset: @dataset,
        type: "post",
        capabilities: ["read"]
      })

      ctx = CallerContext.from_user(grantee.id)
      assert length(ctx.grants) == 1

      # EXACTLY the in-scope post — not the note, not the "other" dataset post,
      # not the project-Q post (containment: a grant cannot widen across project).
      assert titles(grant_read("post", ws, ctx)) == ["in-scope"]
      # the granted type is the only readable type; a note read yields nothing
      assert grant_read("note", ws, ctx) == []
    end

    test "a broader (workspace-only) grant sees all projects/types in the workspace" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()

      {:ok, _a} = create_document_in!(ws, proj, "post", %{"title" => "a"}, @dataset)
      {:ok, _b} = create_document_in!(ws, nil, "post", %{"title" => "b"}, @dataset)

      # workspace-only grant (all ladder levels below workspace NULL → covers all)
      bind_grant!(ws, grantee, %{capabilities: ["read"]})
      ctx = CallerContext.from_user(grantee.id)

      assert titles(grant_read("post", ws, ctx)) == ["a", "b"]
    end

    test "the DATASET ladder level is enforced independently (mutation-proof)" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()

      # Two rows identical on EVERY ladder level EXCEPT dataset — same workspace,
      # same project, same type. The only thing that can separate them is the
      # grant's dataset clause, so this test is load-bearing on that clause: drop
      # `x.dataset == grant.dataset` from grant_ladder_condition and the
      # "granted-only" read would leak the other-dataset row.
      {:ok, _granted} =
        create_document_in!(ws, proj, "post", %{"title" => "granted-dataset-row"}, "granted")

      {:ok, _other} =
        create_document_in!(ws, proj, "post", %{"title" => "other-dataset-row"}, "other")

      # Grant scoped to dataset "granted". project_id is SET (the ladder halts at
      # the first NULL, so dataset only binds when project above it is non-null);
      # type/doc_id left NULL → null-covers-below.
      bind_grant!(ws, grantee, %{
        project_id: proj.id,
        dataset: "granted",
        capabilities: ["read"]
      })

      ctx = CallerContext.from_user(grantee.id)

      read = fn dataset ->
        Content.list_documents("post", dataset,
          workspace_id: ws.id,
          caller_context: ctx,
          grant_scoped: true
        )
      end

      # EXACTLY the granted-dataset row; the other dataset yields nothing.
      assert titles(read.("granted")) == ["granted-dataset-row"]
      assert read.("other") == []
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Write only with the write capability.
  # ---------------------------------------------------------------------------

  describe "Layer 1 — capability gate (risk #2)" do
    test "a read-only grant authorizes :read but NEVER :write" do
      ws = create_workspace!()
      grantee = grantee_user()
      bind_grant!(ws, grantee, %{capabilities: ["read"]})
      ctx = CallerContext.from_user(grantee.id)

      assert Auth.authorize(ctx, ws.id, :read) == :ok
      assert Auth.authorize(ctx, ws.id, :write) == {:error, :forbidden}
      assert Auth.authorize(ctx, ws.id, :admin) == {:error, :forbidden}
    end

    test "a write grant authorizes :write" do
      ws = create_workspace!()
      grantee = grantee_user()
      bind_grant!(ws, grantee, %{capabilities: ["read", "write"]})
      ctx = CallerContext.from_user(grantee.id)

      assert Auth.authorize(ctx, ws.id, :read) == :ok
      assert Auth.authorize(ctx, ws.id, :write) == :ok
      assert Auth.authorize(ctx, ws.id, :admin) == {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Expired grant → ZERO access (both layers), per-request granularity.
  # ---------------------------------------------------------------------------

  describe "expired grant fails closed (risk #3, request granularity)" do
    test "an expired grant is neither loaded nor authorized nor read" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()
      {:ok, _doc} = create_document_in!(ws, proj, "post", %{"title" => "secret"}, @dataset)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      bind_grant!(ws, grantee, %{capabilities: ["read"], expires_at: past})

      # A fresh request rebuilds the context: the expired grant drops out
      # in-query, so the grantee has zero grants → zero access.
      ctx = CallerContext.from_user(grantee.id)
      assert ctx.grants == []
      assert Auth.authorize(ctx, ws.id, :read) == {:error, :forbidden}
      assert grant_read("post", ws, ctx) == []
    end

    test "non-vacuous: the SAME grant while active DOES grant access" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()
      {:ok, _doc} = create_document_in!(ws, proj, "post", %{"title" => "secret"}, @dataset)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      bind_grant!(ws, grantee, %{capabilities: ["read"], expires_at: future})

      ctx = CallerContext.from_user(grantee.id)
      assert Auth.authorize(ctx, ws.id, :read) == :ok
      assert titles(grant_read("post", ws, ctx)) == ["secret"]
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Revoked grant → zero access.
  # ---------------------------------------------------------------------------

  describe "revoked grant fails closed" do
    test "a revoked grant is neither loaded nor authorized nor read" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()
      {:ok, _doc} = create_document_in!(ws, proj, "post", %{"title" => "secret"}, @dataset)

      bind_grant!(ws, grantee, %{capabilities: ["read"], revoked_at: DateTime.utc_now()})

      ctx = CallerContext.from_user(grantee.id)
      assert ctx.grants == []
      assert Auth.authorize(ctx, ws.id, :read) == {:error, :forbidden}
      assert grant_read("post", ws, ctx) == []
    end
  end

  # ---------------------------------------------------------------------------
  # 5. nil / absent scope fails CLOSED — never the whole workspace.
  # ---------------------------------------------------------------------------

  describe "grant-derived read fails closed when uncovered" do
    setup do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, _doc} = create_document_in!(ws, proj, "post", %{"title" => "workspace-secret"}, @dataset)
      {:ok, ws: ws}
    end

    test "grant_scoped flag with a nil caller_context → zero rows", %{ws: ws} do
      docs =
        Content.list_documents("post", @dataset,
          workspace_id: ws.id,
          caller_context: nil,
          grant_scoped: true
        )

      assert docs == []
    end

    test "grant covering a DIFFERENT workspace → zero rows here", %{ws: ws} do
      other_ws = create_workspace!()
      grantee = grantee_user()
      bind_grant!(other_ws, grantee, %{capabilities: ["read"]})
      ctx = CallerContext.from_user(grantee.id)

      # ctx HAS an active grant, but none covering `ws` → fail closed, not the
      # whole workspace.
      assert grant_read("post", ws, ctx) == []
    end

    test "a grantee whose only grant is for another workspace cannot authorize here", %{ws: ws} do
      other_ws = create_workspace!()
      grantee = grantee_user()
      bind_grant!(other_ws, grantee, %{capabilities: ["read"]})
      ctx = CallerContext.from_user(grantee.id)

      assert Auth.authorize(ctx, ws.id, :read) == {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Member unaffected — grants only ADD; a member read is byte-identical.
  # ---------------------------------------------------------------------------

  describe "member reads are byte-identical (grants only ADD)" do
    test "a member (no grant flag) sees the whole workspace regardless of any grants" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, _a} = create_document_in!(ws, proj, "post", %{"title" => "a"}, @dataset)
      {:ok, _b} = create_document_in!(ws, proj, "post", %{"title" => "b"}, @dataset)

      # Ordinary member-style read: no caller_context, no grant_scoped flag.
      member_opts = [workspace_id: ws.id]
      before = titles(Content.list_documents("post", @dataset, member_opts))
      assert before == ["a", "b"]

      # Even if a grantee ALSO holds a workspace grant, a read WITHOUT the flag
      # (the member path) is unchanged — the grant code path never fires.
      grantee = grantee_user()
      bind_grant!(ws, grantee, %{project_id: proj.id, type: "post", capabilities: ["read"]})
      ctx = CallerContext.from_user(grantee.id)

      after_with_ctx =
        titles(
          Content.list_documents("post", @dataset,
            workspace_id: ws.id,
            caller_context: ctx
          )
        )

      # No grant_scoped flag → no narrowing → identical full-workspace result.
      assert after_with_ctx == before
    end
  end
end
