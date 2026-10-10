defmodule BarkparkWeb.PatMintExpiryTest do
  @moduledoc """
  task-9d2cdfae246cc486 — the PAT self-mint (`POST /v1/auth/tokens`) accepts
  an optional, CAPPED `ttl_seconds` or `expires_at`, reports `expires_at`, and
  an expired token answers the same 401 a revoked one does.

  The cap/refusal/report machinery is `Barkpark.Auth.TokenExpiry` — already
  proven generically (and against five OTHER mint routes) by
  `BarkparkWeb.TokenExpiryMintTest`. This file exercises it specifically
  through the PAT door, which `TokenExpiryMintTest` deliberately pins to its
  OWN fixed 30-day horizon with no client override
  ("PAT and share-edit keep their built-in horizons") — that pin is exactly
  the gap this task closes, so this file's regression test for the
  no-params case is a second, independent proof the omit-vs-nil distinction
  in `mint_pat/4` did not disturb it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @day 86_400

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp bearer(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp session_raw! do
    ws = create_workspace!()
    user = register_user("#{uniq("pat")}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")

    {:ok, session_raw} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    session_raw
  end

  # `current_password` satisfies the step-up re-auth every PAT self-mint
  # needs (owner ruling #13, task-f4cfc3e2ab4bd6b8): a session alone cannot
  # mint a standing credential. Matches the convention in
  # `TokenExpiryMintTest.mint_pat/0` and `PatSelfMintAdminCapTest`.
  defp mint(session_raw, body) do
    base = %{"name" => uniq("cli"), "current_password" => "correct-horse-battery"}

    bearer(session_raw) |> post("/v1/auth/tokens", Jason.encode!(Map.merge(base, body)))
  end

  defp row!(raw), do: Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw))
  defp token_count, do: Repo.aggregate(ApiToken, :count)

  defp days_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second) / @day

  describe "ttl_seconds / expires_at accepted, within the cap" do
    test "ttl_seconds mints a token expiring that many seconds from now, and the response reports it" do
      conn = mint(session_raw!(), %{"ttl_seconds" => 3600})
      body = json_response(conn, 201)

      assert body["personal_access_token"]["expires_at"]
      {:ok, reported, _} = DateTime.from_iso8601(body["personal_access_token"]["expires_at"])

      row = row!(body["token"])
      assert DateTime.compare(row.expires_at, reported) == :eq
      assert_in_delta DateTime.diff(row.expires_at, DateTime.utc_now(), :second), 3600, 2
    end

    test "expires_at (ISO-8601) mints a token expiring at exactly that instant" do
      at = DateTime.utc_now() |> DateTime.add(29 * @day) |> DateTime.truncate(:second)
      conn = mint(session_raw!(), %{"expires_at" => DateTime.to_iso8601(at)})

      row = row!(json_response(conn, 201)["token"])
      assert row.expires_at == at
    end

    test "no ttl_seconds or expires_at keeps the existing 30-day default (regression pin)" do
      conn = mint(session_raw!(), %{})
      row = row!(json_response(conn, 201)["token"])
      assert_in_delta days_from_now(row.expires_at), 30, 0.01
    end
  end

  describe "over the cap: refused 422, no row written" do
    test "ttl_seconds over 365 days is 422 naming the max" do
      count = token_count()
      conn = mint(session_raw!(), %{"ttl_seconds" => 366 * @day})
      body = json_response(conn, 422)

      assert body["error"]["message"] =~ "max age of 365 days"
      assert token_count() == count
    end

    test "expires_at over 365 days is 422 naming the max" do
      count = token_count()
      at = DateTime.utc_now() |> DateTime.add(366 * @day) |> DateTime.to_iso8601()
      conn = mint(session_raw!(), %{"expires_at" => at})
      body = json_response(conn, 422)

      assert body["error"]["message"] =~ "max age of 365 days"
      assert token_count() == count
    end

    test "exactly 365 days is accepted (boundary)" do
      conn = mint(session_raw!(), %{"ttl_seconds" => 365 * @day})
      row = row!(json_response(conn, 201)["token"])
      assert_in_delta days_from_now(row.expires_at), 365, 0.01
    end

    test "a past expires_at is 422, no row written" do
      count = token_count()
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      conn = mint(session_raw!(), %{"expires_at" => past})

      assert json_response(conn, 422)
      assert token_count() == count
    end

    test "sending BOTH ttl_seconds and expires_at is 422, no row written" do
      count = token_count()
      at = DateTime.utc_now() |> DateTime.add(@day) |> DateTime.to_iso8601()
      conn = mint(session_raw!(), %{"ttl_seconds" => 3600, "expires_at" => at})

      assert json_response(conn, 422)
      assert token_count() == count
    end

    test "a non-positive or malformed ttl_seconds is 422, no row written" do
      count = token_count()

      for bad <- [0, -1, "soon"] do
        conn = mint(session_raw!(), %{"ttl_seconds" => bad})
        assert json_response(conn, 422)
      end

      assert token_count() == count
    end
  end

  describe "an expired PAT answers the same 401 a revoked one does" do
    test "a PAT minted with a short ttl_seconds, once past its expiry, is rejected exactly like a revoked token" do
      conn = mint(session_raw!(), %{"ttl_seconds" => 60})
      raw = json_response(conn, 201)["token"]

      assert {:ok, _} = Auth.verify_token(raw)

      row!(raw)
      |> Ecto.Changeset.change(
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert Auth.verify_token(raw) == {:error, :unauthorized}

      # The control: a revoked (never-expired) token fails the SAME way.
      other_conn = mint(session_raw!(), %{})
      other_raw = json_response(other_conn, 201)["token"]
      {:ok, _} = Auth.revoke_token(row!(other_raw))
      assert Auth.verify_token(other_raw) == {:error, :unauthorized}
    end
  end
end
