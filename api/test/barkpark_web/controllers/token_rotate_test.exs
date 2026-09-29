defmodule BarkparkWeb.TokenRotateTest do
  @moduledoc """
  `POST /w/:ws/p/:proj/v1/tokens/:id/rotate` (task-e78edcc2145ed3df).

  One describe per acceptance criterion:

    1. the successor is a COPY (every carried field, every seat) and it
       authenticates;
    2. the old token authenticates inside the grace window and not after it;
       grace 0 kills it now; a revoked or expired token cannot be rotated;
    3. revoke's gate, plus the two ceilings a secret-returning verb needs, and
       an audit row with actor + both ids and no secret.

  The auth oracle is the credential outcome on a real scoped read (the same
  oracle `MemberControllerTest` uses for revoke), backed by `verify_token/1`.
  Every "stops working" assertion is preceded by a "works" assertion so a route
  that denies for an unrelated reason cannot make it vacuously green.
  """
  use BarkparkWeb.ConnCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.RotationRetireWorker
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"
  @denials [401, 403]

  setup do
    a = workspace_with_admin("a")
    b = workspace_with_admin("b")
    %{ws: a.ws, project: a.project, admin_raw: a.raw, admin: a.token, other_ws: b.ws}
  end

  defp workspace_with_admin(tag, perms \\ ["read", "write", "admin"]) do
    ws = create_workspace!("rot-#{tag}-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    raw = "rot-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "rot-#{tag}", @dataset, perms)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")
    %{ws: ws, project: project, raw: raw, token: token}
  end

  defp victim!(ws, perms \\ ["read"], role \\ "member") do
    raw = "victim-#{System.unique_integer([:positive])}"

    {:ok, t} =
      Auth.create_token(raw, "victim-#{System.unique_integer([:positive])}", @dataset, perms)

    {:ok, _} = TenancyAuth.create_membership(ws.id, t.id, role, "api_token")
    {raw, t}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp base(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1"

  defp rotate(raw, ws, project, id, body \\ %{}) do
    req(raw) |> post("#{base(ws, project)}/tokens/#{id}/rotate", Jason.encode!(body))
  end

  defp read_status(raw, ws, project) do
    req(raw) |> get("#{base(ws, project)}/data/query/#{@dataset}/post") |> Map.fetch!(:status)
  end

  defp seats(token_id) do
    Repo.all(
      from m in Membership,
        where: m.principal_type == "api_token" and m.principal_id == ^token_id,
        select: {m.workspace_id, m.role},
        order_by: m.workspace_id
    )
  end

  defp tokens_labelled(label),
    do: Repo.aggregate(from(t in ApiToken, where: t.label == ^label), :count)

  defp secs_from_now(%DateTime{} = dt), do: DateTime.diff(dt, DateTime.utc_now(), :second)

  # ── criterion 1 ─────────────────────────────────────────────────────────────

  describe "criterion 1 — the successor is a copy, and it authenticates" do
    test "every carried field and every seat match; the new secret works", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx

      {:ok, owner} =
        Barkpark.Accounts.register_user(%{
          email: "rot-owner-#{Ecto.UUID.generate()}@example.com",
          password: "correct horse battery"
        })

      {:ok, {old_raw, old}} =
        Auth.create_personal_access_token("ci deploy", ["read", "write"],
          role: "owner",
          workspace_id: ws.id,
          created_by: "someone@example.com",
          owner_user_id: owner.id
        )

      conn = rotate(admin_raw, ws, project, old.id)
      body = json_response(conn, 201)
      new_raw = body["token"]

      assert is_binary(new_raw) and new_raw != old_raw
      assert String.starts_with?(new_raw, "bppat_"), "a PAT keeps its leak-scanner prefix"

      new = Repo.get!(ApiToken, body["id"])
      old_after = Repo.get!(ApiToken, old.id)

      for field <- [
            :label,
            :name,
            :kind,
            :permissions,
            :dataset,
            :dataset_id,
            :workspace_id,
            :share_scope,
            :owner_user_id,
            :created_by,
            # the ORIGINAL expiry: a rotation never extends a lifetime
            :expires_at
          ] do
        assert Map.fetch!(new, field) == Map.fetch!(old, field),
               "#{field} must carry over: old=#{inspect(Map.fetch!(old, field))} " <>
                 "new=#{inspect(Map.fetch!(new, field))}"
      end

      assert new.id != old.id
      assert seats(new.id) == seats(old.id)
      assert seats(new.id) != []

      # response shape mirrors the mint
      assert body["label"] == old.label
      assert body["name"] == "ci deploy"
      assert body["kind"] == "api"
      assert body["permissions"] == ["read", "write"]
      assert body["dataset"] == @dataset
      assert body["workspace"] == ws.slug
      assert body["rotated_from"]["id"] == old.id

      # only the hash is stored
      assert new.token_hash == ApiToken.hash_token(new_raw)
      refute old_after.token_hash == new.token_hash

      # the successor authenticates
      assert {:ok, %ApiToken{id: id}} = Auth.verify_token(new_raw)
      assert id == new.id
      refute read_status(new_raw, ws, project) in @denials
    end

    test "the secret is returned exactly once — the inventory never carries it", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)

      new_raw =
        rotate(admin_raw, ws, project, victim.id) |> json_response(201) |> Map.get("token")

      inventory = req(admin_raw) |> get("#{base(ws, project)}/tokens") |> response(200)
      refute String.contains?(inventory, new_raw)
    end
  end

  # ── criterion 2 ─────────────────────────────────────────────────────────────

  describe "criterion 2 — grace window, grace 0, and what cannot be rotated" do
    # THE WINDOW TEST. Deleting the `expires_at` update in `Auth.rotate_token/3`
    # reds the "after" half: the old token keeps authenticating forever.
    test "old token works inside the window and stops after it", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {old_raw, victim} = victim!(ws)

      body = rotate(admin_raw, ws, project, victim.id, %{grace_seconds: 2}) |> json_response(201)

      assert {:ok, _} = Auth.verify_token(old_raw)

      refute read_status(old_raw, ws, project) in @denials,
             "inside the grace window the old token must still authenticate"

      refute read_status(body["token"], ws, project) in @denials

      Process.sleep(3_000)

      verdict = Auth.verify_token(old_raw)

      assert verdict == {:error, :unauthorized},
             "after the window the old token must stop authenticating"

      assert read_status(old_raw, ws, project) in @denials
      # the successor is unaffected by the old token's window
      refute read_status(body["token"], ws, project) in @denials
    end

    test "default grace is 24h, and the retire job is scheduled for its end", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {old_raw, victim} = victim!(ws)

      rotate(admin_raw, ws, project, victim.id) |> json_response(201)

      old = Repo.get!(ApiToken, victim.id)
      assert secs_from_now(old.expires_at) in (86_400 - 5)..86_400
      assert is_nil(old.revoked_at)
      assert {:ok, _} = Auth.verify_token(old_raw)

      assert_enqueued(
        worker: RotationRetireWorker,
        args: %{"token_id" => victim.id},
        scheduled_at: {old.expires_at, delta: 5}
      )

      # run early (a manual drain): it waits, it does not revoke early
      assert {:snooze, wait} = perform_job(RotationRetireWorker, %{"token_id" => victim.id})
      assert wait > 86_000
      assert is_nil(Repo.get!(ApiToken, victim.id).revoked_at)
    end

    test "the retire job stamps revoked_at once the window has passed", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)

      rotate(admin_raw, ws, project, victim.id, %{grace_seconds: 60}) |> json_response(201)

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in ApiToken, where: t.id == ^victim.id), set: [expires_at: past])

      assert :ok = perform_job(RotationRetireWorker, %{"token_id" => victim.id})
      assert Repo.get!(ApiToken, victim.id).revoked_at

      assert Repo.exists?(
               from e in Barkpark.Audit.Event,
                 where: e.action == "token_revoked" and e.subject == ^victim.id
             )

      # idempotent
      assert :ok = perform_job(RotationRetireWorker, %{"token_id" => victim.id})
    end

    test "grace 0 stops the old token immediately", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {old_raw, victim} = victim!(ws)

      refute read_status(old_raw, ws, project) in @denials

      body = rotate(admin_raw, ws, project, victim.id, %{grace_seconds: 0}) |> json_response(201)

      assert {:error, :unauthorized} = Auth.verify_token(old_raw)
      assert read_status(old_raw, ws, project) in @denials
      assert Repo.get!(ApiToken, victim.id).revoked_at
      assert body["rotated_from"]["revoked_at"]
      refute read_status(body["token"], ws, project) in @denials
    end

    test "a revoked token cannot be rotated — 409, no successor", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)
      {:ok, _} = Auth.revoke_token(victim)

      assert rotate(admin_raw, ws, project, victim.id) |> json_response(409)
      assert tokens_labelled(victim.label) == 1
    end

    test "an expired token cannot be rotated — 409, no successor", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in ApiToken, where: t.id == ^victim.id), set: [expires_at: past])

      assert rotate(admin_raw, ws, project, victim.id) |> json_response(409)
      assert tokens_labelled(victim.label) == 1
    end

    test "a rotation never extends the old token's life", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)
      soon = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in ApiToken, where: t.id == ^victim.id), set: [expires_at: soon])

      rotate(admin_raw, ws, project, victim.id) |> json_response(201)

      assert Repo.get!(ApiToken, victim.id).expires_at == soon
    end

    test "grace outside 0..7d or not an integer is a 422 and mints nothing", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw} = ctx
      {_raw, victim} = victim!(ws)

      for bad <- [-1, Auth.rotation_max_grace() + 1, "abc", 1.5] do
        assert rotate(admin_raw, ws, project, victim.id, %{grace_seconds: bad})
               |> json_response(422)
      end

      assert tokens_labelled(victim.label) == 1
      assert is_nil(Repo.get!(ApiToken, victim.id).expires_at)
    end
  end

  # ── criterion 3 ─────────────────────────────────────────────────────────────

  describe "criterion 3 — revoke's authority, no widening, audited without secrets" do
    test "an admin of A cannot rotate B's token — 404, B untouched", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw, other_ws: other_ws} = ctx
      {_raw, b_token} = victim!(other_ws)

      assert rotate(admin_raw, ws, project, b_token.id) |> json_response(404)
      assert tokens_labelled(b_token.label) == 1
      assert is_nil(Repo.get!(ApiToken, b_token.id).expires_at)
    end

    test "a member (not admin) of the workspace cannot rotate — the revoke pipeline's 403",
         ctx do
      %{ws: ws, project: project} = ctx
      {member_raw, _} = victim!(ws, ["read", "write", "admin"], "member")
      {_raw, victim} = victim!(ws)

      conn = rotate(member_raw, ws, project, victim.id)
      assert conn.status == 403
      # and revoke answers the same for the same caller
      assert req(member_raw)
             |> delete("#{base(ws, project)}/tokens/#{victim.id}")
             |> Map.get(:status) ==
               403

      assert tokens_labelled(victim.label) == 1
    end

    test "a garbage id is a clean 404", %{ws: ws, project: project, admin_raw: admin_raw} do
      assert rotate(admin_raw, ws, project, "not-a-uuid") |> json_response(404)
    end

    test "cannot obtain a secret carrying a permission the actor's token lacks", ctx do
      %{ws: ws, project: project} = ctx
      weaker = workspace_with_admin("weak", ["read", "write"])
      # seat the weaker admin in THIS workspace too
      {:ok, _} = TenancyAuth.create_membership(ws.id, weaker.token.id, "admin", "api_token")
      {_raw, victim} = victim!(ws, ["read", "write", "admin"])

      assert rotate(weaker.raw, ws, project, victim.id) |> json_response(403)
      assert tokens_labelled(victim.label) == 1
      assert is_nil(Repo.get!(ApiToken, victim.id).expires_at)
    end

    test "cannot rotate a token also seated in a workspace the actor does not administer",
         ctx do
      %{ws: ws, project: project, admin_raw: admin_raw, other_ws: other_ws} = ctx
      {_raw, victim} = victim!(ws)
      {:ok, _} = TenancyAuth.create_membership(other_ws.id, victim.id, "member", "api_token")

      assert rotate(admin_raw, ws, project, victim.id) |> json_response(403)
      assert tokens_labelled(victim.label) == 1
    end

    test "request fields cannot widen the successor", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw, other_ws: other_ws} = ctx
      {_raw, victim} = victim!(ws, ["read"])

      body =
        rotate(admin_raw, ws, project, victim.id, %{
          permissions: ["read", "write", "admin"],
          workspace_id: other_ws.id,
          kind: "api",
          dataset: "other"
        })
        |> json_response(201)

      new = Repo.get!(ApiToken, body["id"])
      assert new.permissions == ["read"]
      assert new.dataset == @dataset
      assert seats(new.id) == [{ws.id, "member"}]
    end

    test "writes a token_rotated audit row with actor and both ids, and no secret", ctx do
      %{ws: ws, project: project, admin_raw: admin_raw, admin: admin} = ctx
      {old_raw, victim} = victim!(ws)

      body = rotate(admin_raw, ws, project, victim.id) |> json_response(201)
      new_raw = body["token"]

      event =
        Repo.one!(
          from e in Barkpark.Audit.Event,
            where: e.action == "token_rotated" and e.subject == ^victim.id
        )

      assert event.category == "token"
      assert event.actor_type == "api_token"
      assert event.actor_id == admin.id
      assert event.workspace_id == ws.id
      assert event.metadata["old_token_id"] == victim.id
      assert event.metadata["new_token_id"] == body["id"]

      dump = event |> Map.from_struct() |> Map.drop([:__meta__]) |> inspect(limit: :infinity)
      new = Repo.get!(ApiToken, body["id"])

      for secret <- [old_raw, new_raw, admin_raw, victim.token_hash, new.token_hash] do
        refute String.contains?(dump, secret), "audit row must not carry a secret or hash"
      end
    end
  end
end
