defmodule BarkparkWeb.LoginTicketTest do
  @moduledoc """
  dwb-7 "Studio one-click entry" — the signed one-time login handoff.

  Proves the security-relevant properties, not just the happy path:

    * mint requires a valid bearer (POST /v1/auth/login-tickets)
    * consume sets `session["api_token"]` to the RAW bound token + redirects
    * the minted session actually passes the LiveAuth `:admin` mount
    * single-use RACE: N concurrent consumes → EXACTLY ONE wins (no double-spend)
    * expiry is enforced
    * unknown / used / expired all return the SAME failure — no oracle
    * hardening headers on the one-time-link response (no-store, no-referrer)
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [where: 2]
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.LoginTicket
  alias Barkpark.Repo

  @admin_token "dwb7-admin-token-abcdef"
  @reader_token "dwb7-reader-token-123456"

  # SettingsLive moved to `/w/:ws/p/:proj/studio/settings` (sdl-w1-admin-canonical).
  @settings_path "/w/default/p/default/studio/settings"

  setup do
    # Default must exist before the admin token is minted so it auto-binds as a
    # Default member (the scoped settings route's LiveScope gate).
    ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@admin_token, "dwb7 admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@reader_token, "dwb7 reader", "production", ["read"])
    :ok
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "POST /v1/auth/login-tickets (mint)" do
    test "valid bearer mints a single-use ticket", %{conn: conn} do
      conn = conn |> bearer(@admin_token) |> post("/v1/auth/login-tickets")
      assert conn.status == 201
      body = json_response(conn, 201)
      assert is_binary(body["ticket"]) and body["ticket"] != ""
      assert body["expires_in"] == 60
      # The api_token itself must NEVER appear in the mint response.
      refute body["ticket"] == @admin_token
      refute conn.resp_body =~ @admin_token
    end

    test "no bearer → 401", %{conn: conn} do
      conn = post(conn, "/v1/auth/login-tickets")
      assert conn.status == 401
    end

    test "unknown bearer → 401 (RequireToken)", %{conn: conn} do
      conn = conn |> bearer("no-such-token") |> post("/v1/auth/login-tickets")
      assert conn.status == 401
    end
  end

  describe "GET /login/ticket/:ticket (consume)" do
    test "sets session api_token to the bound RAW token and redirects to /studio", %{conn: conn} do
      {:ok, ticket} = Auth.mint_login_ticket(@admin_token)

      conn = get(conn, "/login/ticket/#{ticket}")

      assert redirected_to(conn, 302) == "/studio"
      assert get_session(conn, "api_token") == @admin_token
      # One-time-link hardening headers.
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end

    test "the minted session passes the LiveAuth :admin mount (end-to-end)", %{conn: conn} do
      {:ok, ticket} = Auth.mint_login_ticket(@admin_token)

      conn = get(conn, "/login/ticket/#{ticket}")
      assert get_session(conn, "api_token") == @admin_token

      # Carry the freshly-set session cookie forward into a LiveView mount.
      conn = recycle(conn)
      assert {:ok, _view, _html} = live(conn, @settings_path)
    end

    test "a second consume of the same ticket fails (single-use)", %{conn: conn} do
      {:ok, ticket} = Auth.mint_login_ticket(@admin_token)

      first = get(conn, "/login/ticket/#{ticket}")
      assert get_session(first, "api_token") == @admin_token

      second = get(build_conn(), "/login/ticket/#{ticket}")
      assert redirected_to(second, 302) == "/login"
      assert get_session(second, "api_token") == nil
    end

    test "unknown / used / expired all redirect to /login with NO session (no oracle)", %{
      conn: conn
    } do
      # unknown
      unknown = get(conn, "/login/ticket/bplt_does-not-exist")

      # used
      {:ok, t_used} = Auth.mint_login_ticket(@admin_token)
      assert {:ok, _} = Auth.consume_login_ticket(t_used)
      used = get(build_conn(), "/login/ticket/#{t_used}")

      # expired (mint, then age the row past its TTL)
      {:ok, t_exp} = Auth.mint_login_ticket(@admin_token)
      expire_ticket(t_exp)
      expired = get(build_conn(), "/login/ticket/#{t_exp}")

      for c <- [unknown, used, expired] do
        assert redirected_to(c, 302) == "/login"
        assert get_session(c, "api_token") == nil
      end

      # Same flash text for every failure kind — no distinguishing oracle.
      assert Phoenix.Flash.get(unknown.assigns.flash, :error) ==
               Phoenix.Flash.get(used.assigns.flash, :error)

      assert Phoenix.Flash.get(used.assigns.flash, :error) ==
               Phoenix.Flash.get(expired.assigns.flash, :error)
    end
  end

  describe "Auth.consume_login_ticket/1 — single-use race" do
    test "N concurrent consumes of one ticket → exactly one winner" do
      {:ok, ticket} = Auth.mint_login_ticket(@admin_token)

      results =
        1..25
        |> Task.async_stream(fn _ -> Auth.consume_login_ticket(ticket) end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, :invalid}, &1))

      assert length(winners) == 1
      assert length(losers) == 24
      assert [{:ok, @admin_token}] = winners
    end

    test "expiry is enforced at the atomic claim" do
      {:ok, ticket} = Auth.mint_login_ticket(@admin_token)
      expire_ticket(ticket)
      assert {:error, :invalid} = Auth.consume_login_ticket(ticket)
    end

    test "sweep prunes spent and expired rows, keeps live ones" do
      {:ok, spent} = Auth.mint_login_ticket(@admin_token)
      {:ok, _} = Auth.consume_login_ticket(spent)

      {:ok, expired} = Auth.mint_login_ticket(@admin_token)
      expire_ticket(expired)

      {:ok, live} = Auth.mint_login_ticket(@admin_token)

      assert Auth.sweep_login_tickets() >= 2

      # Row-precise assertions (count-only would be vacuous under any
      # pre-existing rows): both dead rows gone, the live one kept.
      refute ticket_row(spent)
      refute ticket_row(expired)
      assert ticket_row(live)
    end
  end

  defp ticket_row(raw_ticket) do
    hash = Auth.hash_ticket(raw_ticket)
    LoginTicket |> where(ticket_hash: ^hash) |> Repo.one()
  end

  # Age a ticket row past its TTL by back-dating expires_at.
  defp expire_ticket(raw_ticket) do
    hash = Auth.hash_ticket(raw_ticket)
    past = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:microsecond)

    {1, _} =
      LoginTicket
      |> where(ticket_hash: ^hash)
      |> Repo.update_all(set: [expires_at: past])
  end
end
