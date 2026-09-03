defmodule BarkparkWeb.PdsW36RevokeAllReceiptTest do
  @moduledoc """
  PDS-D503 differential — "sign out everywhere" stops being an unread claim.

  `Accounts.revoke_all_user_sessions/1` used to discard `Repo.update_all`'s
  `{count, nil}` and return a literal `:ok`, so BOTH live receipts that depend
  on it were byte-identical whether the revoke stamped three rows or zero:

    * `POST /v1/auth/reset` printed `{"ok": true}`;
    * SCIM `PATCH /scim/v2/Users/:id` printed `"active": false` as a HARDCODED
      render argument.

  Every assertion below compares the RECEIPT against a DIRECT `Repo` read of
  `user_sessions` / `memberships` — never a second endpoint, which would only
  prove two surfaces agree on the same guess.

  MUTATION-PROVEN: narrowing the WHERE clause in
  `Accounts.revoke_all_user_sessions/1` so only ONE session is stamped reds the
  stored-row assertions in this file (see the task's mutation evidence).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Accounts.UserSession
  alias Barkpark.Tenancy.Membership

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  # DIRECT storage read — the only admissible oracle here.
  defp live_session_count(user_id) do
    Repo.aggregate(
      from(s in UserSession, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
      :count
    )
  end

  defp revoked_session_count(user_id) do
    Repo.aggregate(
      from(s in UserSession, where: s.user_id == ^user_id and not is_nil(s.revoked_at)),
      :count
    )
  end

  defp seed_sessions!(user, n) do
    for _ <- 1..n, do: elem(Accounts.create_user_session_token(user), 1)
  end

  describe "POST /v1/auth/reset — the count reaches the wire" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{
          email: "pds-w36-reset@example.com",
          password: @password
        })

      %{user: user}
    end

    test "the receipt's sessionsRevoked EQUALS the rows the revoke stamped", %{user: user} do
      seed_sessions!(user, 3)
      assert live_session_count(user.id) == 3
      assert revoked_session_count(user.id) == 0

      {:ok, raw} = Accounts.build_email_token(user, "reset")

      body =
        post_json(scoped_conn(), "/v1/auth/reset", %{
          token: raw,
          password: "a-brand-new-password"
        })
        |> json_response(200)

      # THE RECEIPT vs THE STORED ROWS.
      assert body["ok"] == true
      assert body["sessionsRevoked"] == 3
      assert body["sessionsRevoked"] == revoked_session_count(user.id)
      assert live_session_count(user.id) == 0
    end

    test "a reset with NOTHING to revoke says 0 — a different sentence", %{user: user} do
      assert live_session_count(user.id) == 0
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      body =
        post_json(scoped_conn(), "/v1/auth/reset", %{
          token: raw,
          password: "another-brand-new-password"
        })
        |> json_response(200)

      assert body["sessionsRevoked"] == 0
      assert body["sessionsRevoked"] == revoked_session_count(user.id)
    end
  end

  describe "SCIM /scim/v2/Users/:id — the receipt reads `active` back" do
    setup do
      {:ok, org} = Tenancy.create_organization(%{slug: "pdsw36", name: "pdsw36"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "pdsw36-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      {:ok, {token, _}} = Scim.mint_token(org.id, "pds-w36")

      conn =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")

      resp =
        conn
        |> post("/scim/v2/Users", Jason.encode!(%{"userName" => "leaver@pdsw36.com"}))
        |> json_response(201)

      user = Accounts.get_user_by_email("leaver@pdsw36.com")
      %{org: org, ws: ws, token: token, user: user, provisioned: resp}
    end

    test "PATCH active:false: the rendered `active` matches the STORED membership, and every seeded session is dead",
         %{token: token, org: org, ws: ws, user: user} do
      seed_sessions!(user, 3)
      assert live_session_count(user.id) == 3

      # THE ORACLE MUST BE ABLE TO SAY THE OTHER THING. Without this line the two
      # assertions below are both satisfied by a hardcoded `false` — exactly the
      # defect PDS-D503 filed — so the differential could not tell a read-back
      # from the literal it replaced. A provisioned member reads TRUE.
      assert Scim.org_user_active?(org, user) == true,
             "the active oracle answers false before any deprovision — it is not reading the rows"

      body =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> patch("/scim/v2/Users/#{user.id}", Jason.encode!(%{"active" => false}))
        |> json_response(200)

      # The receipt's `active` is a READ-BACK, not a literal: it equals what the
      # rows say, and what the rows say is "no membership in this org".
      assert body["active"] == Scim.org_user_active?(org, user)
      assert body["active"] == false

      refute Repo.exists?(
               from(m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^ws.id
               )
             )

      # THE POST-CONDITION THE RECEIPT IMPLIES, read directly from storage.
      assert live_session_count(user.id) == 0
      assert revoked_session_count(user.id) == 3
    end

    test "DELETE (hard, 204, no body): the sessions are gone from storage", %{
      token: token,
      user: user
    } do
      seed_sessions!(user, 3)
      assert live_session_count(user.id) == 3

      assert scoped_conn()
             |> put_req_header("authorization", "Bearer #{token}")
             |> delete("/scim/v2/Users/#{user.id}")
             |> response(204)

      # The 204 carries no sentence to correct — assert the post-condition
      # instead. NOTE (FK cascade): user_sessions.user_id is
      # `on_delete: :delete_all` (20260629150100_create_user_sessions.exs), so on
      # THIS path the rows vanish with the user row regardless of the revoke.
      # The soft PATCH path above is where the revoke is load-bearing.
      assert live_session_count(user.id) == 0
      assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^user.id), :count) == 0
    end
  end

  describe "Accounts.revoke_all_user_sessions/1 — the count itself" do
    test "returns {:ok, n} counting ONLY the rows it stamped" do
      {:ok, user} =
        Accounts.register_user(%{email: "pds-w36-count@example.com", password: @password})

      seed_sessions!(user, 3)
      assert {:ok, 3} = Accounts.revoke_all_user_sessions(user)
      # Idempotent: nothing live left to stamp, and the count SAYS so.
      assert {:ok, 0} = Accounts.revoke_all_user_sessions(user)
      assert live_session_count(user.id) == 0
    end
  end
end
