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
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

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

  # `grant_authority!/1` + `bind_grant!/3` moved to `Barkpark.AccessFixtures`
  # (imported above) — shared byte-identically across the four enforcement suites.

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

      {:ok, _wrong_type} =
        create_document_in!(ws, proj_p, "note", %{"title" => "wrong-type"}, @dataset)

      {:ok, _wrong_ds} =
        create_document_in!(ws, proj_p, "post", %{"title" => "wrong-dataset"}, "other")

      {:ok, _wrong_proj} =
        create_document_in!(ws, proj_q, "post", %{"title" => "other-project"}, @dataset)

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

    test "a WRITE-ONLY grant never widens the read-union (write ⊅ read)" do
      # The read-cap filter on the covering set. A caller holds TWO grants in the
      # same workspace: (i) a READ grant narrowed to project P (scope Y), and
      # (ii) a WRITE-ONLY grant (capabilities ["write"], no read) covering
      # project Q (scope X). Layer-2 read narrowing must union ONLY the read
      # grant's ladder — scope-X rows the caller holds only :write on must NOT
      # leak into the read. Without the read-cap filter the write-only grant's
      # ladder ORs into the read-union and scope-X rows leak.
      ws = create_workspace!()
      proj_y = create_project!(ws)
      proj_x = create_project!(ws)
      grantee = grantee_user()

      {:ok, _y} = create_document_in!(ws, proj_y, "post", %{"title" => "read-scope-Y"}, @dataset)

      {:ok, _x} =
        create_document_in!(ws, proj_x, "post", %{"title" => "write-only-scope-X"}, @dataset)

      # (i) read grant on project Y
      bind_grant!(ws, grantee, %{project_id: proj_y.id, capabilities: ["read"]})
      # (ii) write-only grant on project X — covers the workspace, confers NO read
      bind_grant!(ws, grantee, %{project_id: proj_x.id, capabilities: ["write"]})

      ctx = CallerContext.from_user(grantee.id)
      assert length(ctx.grants) == 2

      # ONLY the read-scope-Y row; the write-only-scope-X row must be invisible.
      assert titles(grant_read("post", ws, ctx)) == ["read-scope-Y"]
    end

    test "a read+write grant still narrows normally (read cap present)" do
      # The filter excludes ONLY grants lacking read. A ["read","write"] grant
      # confers read, so it contributes its ladder unchanged — no regression.
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()

      {:ok, _in} = create_document_in!(ws, proj, "post", %{"title" => "rw-in-scope"}, @dataset)

      {:ok, _out} =
        create_document_in!(ws, create_project!(ws), "post", %{"title" => "rw-out"}, @dataset)

      bind_grant!(ws, grantee, %{project_id: proj.id, capabilities: ["read", "write"]})
      ctx = CallerContext.from_user(grantee.id)

      assert titles(grant_read("post", ws, ctx)) == ["rw-in-scope"]
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

    # Defense-in-depth for the LIVE read path (ag-liveview-read-liveness). The
    # Studio socket feeds `scope_to_grants` a caller_context SNAPSHOT. If a
    # refresh path is ever missed, an expired grant could linger in that snapshot
    # — so `covers_workspace_read?` re-applies the expiry time-compare on the
    # grant STRUCT. Here we bypass the in-query active filter by passing the
    # expired grant EXPLICITLY in `grants:`; the read-union must STILL exclude it
    # (zero rows) purely on the struct-level expiry compare.
    test "an expired grant in a STALE snapshot is still excluded by the struct compare" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()
      {:ok, _doc} = create_document_in!(ws, proj, "post", %{"title" => "secret"}, @dataset)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired = bind_grant!(ws, grantee, %{capabilities: ["read"], expires_at: past})

      # A stale context that STILL carries the expired grant (as if a refresh was
      # missed) — `from_user` would have dropped it, so we inject it directly.
      stale_ctx = %CallerContext{
        principal_type: :user,
        user_id: grantee.id,
        grants: [expired]
      }

      assert grant_read("post", ws, stale_ctx) == []

      # Non-vacuous control: the SAME grant, unexpired, in the same stale-shaped
      # context DOES serve — proving the struct compare (not some other clause)
      # is what excludes the expired one.
      live_grant = %{expired | expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)}
      live_ctx = %{stale_ctx | grants: [live_grant]}
      assert titles(grant_read("post", ws, live_ctx)) == ["secret"]
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

      {:ok, _doc} =
        create_document_in!(ws, proj, "post", %{"title" => "workspace-secret"}, @dataset)

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

  # ---------------------------------------------------------------------------
  # The Indx count seal (ag-search-grant-leak D2). The Indx retriever reports its
  # total via `Content.count_documents_by_ids/3` for a grant-derived caller, so
  # a reported total can never exceed the grant-visible matches. These pin that
  # count function grant-narrows + fails closed — the exact mechanism the Indx
  # `total_for/3` relies on (the light-record harness has no DB-backed do_search
  # mock, so this is the tightest protection of the count seal).
  # ---------------------------------------------------------------------------
  describe "Layer 2 — count_documents_by_ids grant-narrows the reported total" do
    test "a grant_scoped caller counts ONLY grant-visible ids; out-of-grant ids drop" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()

      {:ok, in_doc} = create_document_in!(ws, proj, "post", %{"title" => "in"}, @dataset)
      {:ok, out_doc} = create_document_in!(ws, proj, "note", %{"title" => "out"}, @dataset)
      ids = [in_doc.doc_id, out_doc.doc_id]

      # grant covers type "post" only → the note id must not be counted
      bind_grant!(ws, grantee, %{
        project_id: proj.id,
        dataset: @dataset,
        type: "post",
        capabilities: ["read"]
      })

      ctx = CallerContext.from_user(grantee.id)

      assert Content.count_documents_by_ids(ids, @dataset,
               workspace_id: ws.id,
               caller_context: ctx,
               grant_scoped: true
             ) == 1

      # WITHOUT the flag the same id set counts BOTH — proving the narrowing is
      # the grant clause, not some unrelated filter. The SAME caller_context
      # rides along, so `grant_scoped` is now the only variable between the two
      # calls (it was previously two: the flag AND the context). Load-bearing
      # since task-38786b2edab15955 added a schema-visibility clamp at this
      # seat: the clamp is keyed on the caller's TIER, and these fixture types
      # have no schema row at all, so a context-less caller would legitimately
      # count ZERO here and the control would stop isolating the grant clause.
      assert Content.count_documents_by_ids(ids, @dataset,
               workspace_id: ws.id,
               caller_context: ctx
             ) == 2
    end

    test "fail-closed: a grant_scoped caller with NO covering grant counts ZERO" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantee = grantee_user()

      {:ok, a} = create_document_in!(ws, proj, "post", %{"title" => "a"}, @dataset)

      # grantee holds NO grant → empty union → where:false → 0
      ctx = CallerContext.from_user(grantee.id)

      assert Content.count_documents_by_ids([a.doc_id], @dataset,
               workspace_id: ws.id,
               caller_context: ctx,
               grant_scoped: true
             ) == 0

      # nil caller_context under the flag also fails closed
      assert Content.count_documents_by_ids([a.doc_id], @dataset,
               workspace_id: ws.id,
               grant_scoped: true
             ) == 0
    end
  end
end
