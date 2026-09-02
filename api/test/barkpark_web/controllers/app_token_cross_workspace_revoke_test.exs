defmodule BarkparkWeb.AppTokenCrossWorkspaceRevokeTest do
  @moduledoc """
  `task-ea8cae3258ea4bd3` — the app-token revoke selectors must not reach
  another workspace's credentials.

  ## The failure mode, in concrete inputs

  `DELETE /v1/auth/app-tokens {"email": e}` selected on THREE predicates —
  `label == "app:" <> e`, `kind == "api"`, `is_nil(revoked_at)` — and none of
  them is tenancy. `DELETE /v1/auth/app-tokens/:id` read the row with a bare
  `Repo.get/2`. The only gate on either is `Auth.has_permission?(bearer,
  "admin")`, a flat membership test over `token.permissions` that reads no
  workspace at all. So an admin-permissioned token in workspace A, knowing
  only an email address (or an id, which `GET /v1/auth/app-tokens` hands out
  instance-wide), logged workspace B's users out of every phone session they
  held.

  Impact is denial of access, not disclosure — but it is repeatable and it
  costs the attacker nothing they did not already have.

  ## Why the fixture places the two principals in DIFFERENT workspaces

  A same-workspace fixture passes whether or not the boundary exists: the
  legacy suite mints everything into the seeded Default workspace, so a reader
  that forgot to thread scope returns the same rows either way. Every test
  below stands up TWO workspaces and asserts across the seam.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @dataset "production"
  @app_permissions ["read", "write", "chat"]

  setup :reset_rate_limiter!

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    admin_a = raw("adm-a")
    admin_b = raw("adm-b")

    # create_token/5 writes the principal's membership in the bound workspace,
    # role derived from permissions — so each of these is an ADMIN MEMBER of
    # exactly one workspace and a stranger to the other.
    {:ok, _} = Auth.create_token(admin_a, "adm-a", @dataset, ["read", "write", "admin"], ws_a.id)
    {:ok, _} = Auth.create_token(admin_b, "adm-b", @dataset, ["read", "write", "admin"], ws_b.id)

    %{ws_a: ws_a, ws_b: ws_b, admin_a: admin_a, admin_b: admin_b}
  end

  defp raw(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp email, do: "victim-#{System.unique_integer([:positive])}@example.com"

  # An app token as the mint would write it: `app:<email>` label, member-shaped
  # permission set, bound to one workspace.
  defp app_token_in!(workspace, mail) do
    secret = raw("bpapp")

    {:ok, token} =
      Auth.create_token(secret, "app:" <> mail, @dataset, @app_permissions, workspace.id)

    {secret, token}
  end

  defp json_conn(bearer) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  describe "revoke by EMAIL is confined to workspaces the caller administers" do
    test "an admin of A cannot log out a user whose app token lives in B",
         %{ws_b: ws_b, admin_a: admin_a} do
      mail = email()
      {victim, _row} = app_token_in!(ws_b, mail)

      assert {:ok, _} = Auth.verify_token(victim)

      body =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
        |> json_response(200)

      # No named workspace target, so the denial shape is "foreign rows simply
      # absent" (share_link_controller's denial-shape law), never a 403 that
      # would confirm the address exists somewhere on the instance.
      assert body["revoked_count"] == 0,
             "workspace A's admin revoked #{body["revoked_count"]} of workspace B's tokens"

      # `match?/2` rather than `assert {:ok, _} = ...`: the match form is a macro
      # that IGNORES the message, so this explanation could never have printed on
      # the one failure it exists for.
      assert match?({:ok, _}, Auth.verify_token(victim)),
             "workspace B's app token was revoked by an admin who is a stranger to B"
    end

    test "the split is per-row: A's copy dies, B's survives, in ONE call",
         %{ws_a: ws_a, ws_b: ws_b, admin_a: admin_a} do
      mail = email()
      {mine, _} = app_token_in!(ws_a, mail)
      {theirs, _} = app_token_in!(ws_b, mail)

      body =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
        |> json_response(200)

      assert body["revoked_count"] == 1
      assert {:error, _} = Auth.verify_token(mine)
      assert {:ok, _} = Auth.verify_token(theirs)
    end

    test "THE LEGITIMATE ARM: an admin still logs out its own workspace's user",
         %{ws_a: ws_a, admin_a: admin_a} do
      mail = email()
      {phone, _} = app_token_in!(ws_a, mail)
      {tablet, _} = app_token_in!(ws_a, mail)

      body =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
        |> json_response(200)

      assert body["revoked_count"] == 2
      assert {:error, _} = Auth.verify_token(phone)
      assert {:error, _} = Auth.verify_token(tablet)
    end

    test "the admin-permissioned exclusion is PRESERVED inside the caller's own workspace",
         %{ws_a: ws_a, admin_a: admin_a} do
      mail = email()
      custody = raw("bpapp")

      {:ok, _} =
        Auth.create_token(custody, "app:" <> mail, @dataset, ["read", "admin"], ws_a.id)

      body =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens", Jason.encode!(%{email: mail}))
        |> json_response(200)

      assert body["revoked_count"] == 0
      assert {:ok, _} = Auth.verify_token(custody)
    end
  end

  describe "revoke by ID is confined to workspaces the caller administers" do
    test "a foreign row id is a 404, byte-identical to a missing row",
         %{ws_b: ws_b, admin_a: admin_a} do
      mail = email()
      {victim, row} = app_token_in!(ws_b, mail)

      foreign =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens/#{row.id}")

      missing =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens/#{Ecto.UUID.generate()}")

      assert foreign.status == 404
      assert missing.status == 404

      # `Errors.stamp/2` puts a per-request `request_id` on every envelope, so
      # two responses are never byte-equal as strings. The discriminant that
      # matters is everything else: same code, same message, same status — the
      # single `ErrorResponse.emit(conn, {:error, :not_found})` call site.
      strip = fn conn ->
        conn.resp_body |> Jason.decode!() |> pop_in(["error", "request_id"]) |> elem(1)
      end

      assert strip.(foreign) == strip.(missing),
             "a foreign row id is distinguishable from a missing one — an existence oracle"

      # Guard the guard: if `request_id` were constant, stripping it would hide
      # nothing and the assertion above would pass for the wrong reason.
      refute Jason.decode!(foreign.resp_body)["error"]["request_id"] ==
               Jason.decode!(missing.resp_body)["error"]["request_id"]

      assert match?({:ok, _}, Auth.verify_token(victim)),
             "workspace B's app token was revoked by row id from workspace A"
    end

    test "THE LEGITIMATE ARM: by-id still works inside the caller's own workspace",
         %{ws_a: ws_a, admin_a: admin_a} do
      mail = email()
      {mine, row} = app_token_in!(ws_a, mail)

      body =
        json_conn(admin_a)
        |> delete("/v1/auth/app-tokens/#{row.id}")
        |> json_response(200)

      assert body["revoked"] == true
      assert body["id"] == row.id
      assert {:error, _} = Auth.verify_token(mine)
    end

    test "B's own admin can still revoke B's token — the row is not orphaned",
         %{ws_b: ws_b, admin_b: admin_b} do
      mail = email()
      {theirs, row} = app_token_in!(ws_b, mail)

      body =
        json_conn(admin_b)
        |> delete("/v1/auth/app-tokens/#{row.id}")
        |> json_response(200)

      assert body["revoked"] == true
      assert {:error, _} = Auth.verify_token(theirs)
    end
  end

  # ── The NULL-workspace arm of the SAME by-id check (arpss) ────────────────
  #
  # The block above proves the by-id confinement against rows that CARRY a
  # workspace. `Auth.administrable_by?/2` reads `%ApiToken{workspace_id: ws_id}`
  # straight into `TenancyAuth.workspace_admin?/2`, and `workspace_id` is
  # nullable — `Auth.create_token/4` predates workspace binding, so unbound app
  # rows are a real shape, not a hypothetical. Nothing tested what a nil does
  # there. It denies only because `membership/3`'s `is_binary(workspace_id)`
  # guard misses and the function lands on its terminal `nil`; that is three
  # modules away from this route and reads like an accident at every hop.
  #
  # If nil ever passed, an unbound app token would be revocable by ANY
  # admin-permissioned bearer on the instance — the same cross-tenant logout
  # this file exists to prevent, reached through the column instead of the seam.
  defp unbound_app_token!(mail) do
    secret = raw("bpapp-nullws")

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(secret),
        label: "app:" <> mail,
        dataset: @dataset,
        permissions: @app_permissions,
        workspace_id: nil
      })
      |> Barkpark.Repo.insert()

    {secret, token}
  end

  describe "revoke by ID: the NULL-workspace arm" do
    test "an app token with NO workspace binding is not revocable by id",
         %{admin_a: admin_a} do
      {victim, row} = unbound_app_token!(email())

      # Premise: the row is a genuine `kind: \"api\"` app token — the family
      # check inside `revoke_app_token_by_id/2` passes, so only the nil
      # workspace arm can produce the denial.
      assert row.kind == "api"
      assert is_nil(row.workspace_id)

      resp = json_conn(admin_a) |> delete("/v1/auth/app-tokens/#{row.id}")
      assert resp.status == 404

      # STATE: the credential is still alive.
      assert match?({:ok, _}, Auth.verify_token(victim)),
             "an unbound app token was revoked by row id — nil passed the workspace check"

      assert is_nil(Barkpark.Repo.get!(Barkpark.Auth.ApiToken, row.id).revoked_at)
    end

    test "B's admin cannot reach it either — nil is a denial, not a wildcard",
         %{admin_b: admin_b} do
      {victim, row} = unbound_app_token!(email())

      assert json_conn(admin_b) |> delete("/v1/auth/app-tokens/#{row.id}") |> Map.get(:status) ==
               404

      assert match?({:ok, _}, Auth.verify_token(victim))
    end
  end
end
