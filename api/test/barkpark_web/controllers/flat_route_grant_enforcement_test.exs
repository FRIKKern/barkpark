defmodule BarkparkWeb.FlatRouteGrantEnforcementTest do
  @moduledoc """
  ag-enforcement — flat-routes arm. Grants are honoured on the FLAT (back-compat)
  `/v1/data` READ routes, which pre-date path-based tenancy and infer the seeded
  Default workspace via `AssignDefaultScope` (they never touch `ResolveWorkspace`,
  where the scoped routes run their grant arm).

  The wiring under test: `:api_grant_read` (`ResolveTokenOwner` + `AssignGrantScope`)
  layered on the flat read scope ONLY. An OWNED api_token whose owner holds an
  ACTIVE Default-workspace grant reads EXACTLY that grant's (dataset, type) scope;
  a member, an unowned/service token, and an owned non-grantee token are ALL
  byte-identical to before; and the WRITE path is untouched (the plugs aren't on
  it). Proved NON-VACUOUSLY — the grantee both SEES the in-scope row and is DENIED
  the out-of-scope one on the same live HTTP surface.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo

  @password "correct-horse-battery"

  # Two datasets, two types — all rows in the Default workspace/project so the
  # flat path surfaces them; the grant scopes to (dataset "granted", type "post").
  @granted_ds "granted"
  @other_ds "other"

  setup do
    {ws, project} = ensure_default_scope!()

    for {type, ds} <- [{"post", @granted_ds}, {"post", @other_ds}, {"note", @granted_ds}] do
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
        ds
      )
    end

    seed = fn id, type, ds, title ->
      {:ok, _} = create_document_in!(ws, project, type, %{"_id" => id, "title" => title}, ds)
      {:ok, _} = Content.publish_document(id, type, ds)
    end

    seed.("in", "post", @granted_ds, "in-scope")
    seed.("wrongds", "post", @other_ds, "wrong-dataset")
    seed.("wrongtype", "note", @granted_ds, "wrong-type")

    {:ok, ws: ws, project: project}
  end

  # ── token + user helpers ──────────────────────────────────────────────────

  defp register_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp insert_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "t",
            dataset: "test",
            permissions: ["read"]
          },
          attrs
        )
      )
      |> Repo.insert()

    {raw, token}
  end

  defp owned_token(user, perms \\ ["read"]),
    do: insert_token!(%{owner_user_id: user.id, permissions: perms})

  defp unowned_token(perms \\ ["read"]), do: insert_token!(%{permissions: perms})

  # `grant_authority!/1` + `bind_grant!/3` moved to `Barkpark.AccessFixtures`
  # (imported above). This suite's grants are project-scoped, so each call site
  # folds the Default project ladder (project_id / dataset "granted" / type
  # "post") into `bind_grant!`'s `overrides` map — see `grant_ladder/1`.

  # The project-scoped ladder these flat-path grants carry: the Default project,
  # dataset "granted", type "post" (merge extra overrides like capabilities on
  # top). Keeps the call sites terse without a second `bind_grant!` clause.
  defp grant_ladder(project, extra \\ %{}),
    do: Map.merge(%{project_id: project.id, dataset: @granted_ds, type: "post"}, extra)

  defp auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  defp query(conn, raw, ds, type) do
    conn
    |> auth(raw)
    |> get("/v1/data/query/#{ds}/#{type}")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp titles(result), do: result["documents"] |> Enum.map(& &1["title"]) |> Enum.sort()

  # ── 1 + 5. Grantee sees EXACTLY the grant scope; containment ⊆ ─────────────

  describe "owned-token grantee — narrowed to the grant scope" do
    test "sees exactly the in-scope (dataset,type) row, nothing outside it", %{
      ws: ws,
      project: project
    } do
      user = register_user()
      {raw, _} = owned_token(user)
      bind_grant!(ws, user, grant_ladder(project))

      # in-scope dataset+type → EXACTLY the granted row
      assert titles(query(scoped_conn(), raw, @granted_ds, "post")) == ["in-scope"]

      # containment (non-vacuous): the OTHER dataset HAS a readable row
      # ("wrong-dataset") that an unowned token DOES see — but the grantee is
      # narrowed to their ladder, so it is invisible here.
      other = query(scoped_conn(), raw, @other_ds, "post")
      assert other["count"] == 0
      assert other["documents"] == []

      # the granted type is the only readable type — the note yields nothing
      assert query(scoped_conn(), raw, @granted_ds, "note")["count"] == 0
    end
  end

  # ── 3. Fail-closed: a grant that doesn't cover the request → zero rows ─────

  describe "fail-closed" do
    test "an owned grantee whose grant misses the dataset sees no rows (never the workspace)", %{
      ws: ws,
      project: project
    } do
      user = register_user()
      {raw, _} = owned_token(user)
      # grant covers dataset "granted" only
      bind_grant!(ws, user, grant_ladder(project))

      # request the OTHER dataset — a fail-open bug would leak "wrong-dataset"
      assert query(scoped_conn(), raw, @other_ds, "post")["count"] == 0
    end
  end

  # ── 2. Non-grantee / unowned-token byte-identical (grants only ADD) ────────

  describe "byte-identical for non-grantees" do
    test "an unowned service token reads the whole Default dataset as before" do
      {raw, _} = unowned_token()
      # sees the other-dataset row (no narrowing) — the flat path's prior behavior
      assert titles(query(scoped_conn(), raw, @other_ds, "post")) == ["wrong-dataset"]
      assert titles(query(scoped_conn(), raw, @granted_ds, "post")) == ["in-scope"]
    end

    test "an owned token whose owner has NO covering grant is NOT narrowed" do
      user = register_user()
      {raw, _} = owned_token(user)
      # no grant bound → no flag → full Default read, byte-identical to unowned
      assert titles(query(scoped_conn(), raw, @other_ds, "post")) == ["wrong-dataset"]
      assert titles(query(scoped_conn(), raw, @granted_ds, "post")) == ["in-scope"]
    end
  end

  # ── 4. WRITE PATH UNAFFECTED — the blast-radius guard ──────────────────────

  describe "write path untouched (blast-radius containment)" do
    test "an owned grantee with a WRITE grant is NOT elevated on a flat write route", %{
      ws: ws,
      project: project
    } do
      user = register_user()
      # read-only TOKEN, but a WRITE-capable grant: if the grant leaked onto the
      # write path it could elevate. It must not — the grant plugs are read-only.
      {owned_raw, _} = owned_token(user, ["read"])
      bind_grant!(ws, user, grant_ladder(project, %{capabilities: ["read", "write"]}))

      {unowned_raw, _} = unowned_token(["read"])

      body = %{"mutations" => [%{"create" => %{"_type" => "post", "title" => "x"}}]}

      owned_status =
        scoped_conn()
        |> auth(owned_raw)
        |> post("/v1/data/mutate/#{@granted_ds}", body)
        |> Map.fetch!(:status)

      unowned_status =
        scoped_conn()
        |> auth(unowned_raw)
        |> post("/v1/data/mutate/#{@granted_ds}", body)
        |> Map.fetch!(:status)

      # byte-identical to a plain read-only token — the grant never reached the
      # write path (ResolveTokenOwner/AssignGrantScope are mounted on reads only),
      # so a read-only token stays denied write regardless of any write grant.
      assert owned_status == unowned_status
      refute owned_status in [200, 201]
    end
  end

  # ── 6. EXPIRY + REVOCATION enforced at the flat HTTP surface ───────────────
  #
  # Expiry/revocation are re-evaluated SERVER-SIDE at request time: `AssignGrantScope`
  # folds only ACTIVE grants (`CallerContext.from_user/2` filters expired /
  # revoked in-query), so a lapsed grant is never flagged `grant_scoped` and the
  # caller is not narrowed. No grace, no stale narrowing carried into the next
  # request.
  #
  # NOTE on "zero rows": the flat back-compat route's grants NARROW a token that
  # already holds the Default read — they never GATE it (ratified above by
  # "byte-identical for non-grantees"). So a lapsed grant reverts to that
  # back-compat read, NOT to zero rows; the sole-access "expired ⇒ no rows"
  # scenario is the SCOPED non-member route (ResolveWorkspace 403), already
  # proven by access_enforcement_test + scoped_studio_mount_test. What the flat
  # HTTP surface uniquely proves here: the grant's narrowing is LIVE — an ACTIVE
  # grant denies the out-of-scope dataset (zero rows), and the instant it expires
  # or is revoked that denial lifts (the stale scope does not persist).
  describe "expiry + revocation are live at the flat HTTP surface" do
    test "an EXPIRED grant stops narrowing — the out-of-scope deny lifts, back-compat returns",
         %{ws: ws, project: project} do
      user = register_user()
      {raw, _} = owned_token(user)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      bind_grant!(ws, user, grant_ladder(project, %{expires_at: past}))

      # An ACTIVE grant would deny this out-of-scope dataset (zero rows — proven
      # in "fail-closed" above). The EXPIRED grant does not narrow, so the read
      # reverts to the token's back-compat Default view — the row is visible.
      assert titles(query(scoped_conn(), raw, @other_ds, "post")) == ["wrong-dataset"]

      # And byte-identical to an owned token with NO grant at all (no residue).
      {plain_raw, _} = owned_token(register_user())

      assert query(scoped_conn(), raw, @granted_ds, "post") ==
               query(scoped_conn(), plain_raw, @granted_ds, "post")
    end

    test "a REVOKED grant stops narrowing — the out-of-scope deny lifts, back-compat returns",
         %{ws: ws, project: project} do
      user = register_user()
      {raw, _} = owned_token(user)
      bind_grant!(ws, user, grant_ladder(project, %{revoked_at: DateTime.utc_now()}))

      assert titles(query(scoped_conn(), raw, @other_ds, "post")) == ["wrong-dataset"]

      {plain_raw, _} = owned_token(register_user())

      assert query(scoped_conn(), raw, @granted_ds, "post") ==
               query(scoped_conn(), plain_raw, @granted_ds, "post")
    end
  end
end
