defmodule BarkparkWeb.Plugs.OptionalSessionTokenPrecedenceTest do
  @moduledoc """
  The full 3x2 credential-precedence matrix for `OptionalSessionToken`:
  {valid bearer, invalid bearer, no bearer} x {session cookie present, absent}.

  WHY THIS FILE EXISTS. The plug's moduledoc used to claim, flatly:

      "The Bearer header wins when both are present."

  That is true of a VALID bearer only. Asserting the claim LITERALLY for the
  invalid-bearer case produced this RED against the unmodified plug:

      1) test 3x2 credential precedence matrix 3. INVALID bearer + session
         cookie -> moduledoc says BEARER WINS
         moduledoc says the Bearer header wins when both are present, but the
         session cookie decided the principal: "SESSION-TOKEN"
         code: refute label(out) == "SESSION-TOKEN"

      6 tests, 1 failure

  The other five cases passed unchanged, so the matrix exercises the plug for
  real rather than agreeing with it vacuously. Only the DOC was wrong; the
  behaviour (fall through to the cookie when the bearer does not verify) is
  deliberate and is left exactly as it was. The corrected moduledoc now states
  all six outcomes and points back here.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.OptionalSessionToken

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    bearer_raw = "precedence-bearer-#{n}"
    session_raw = "precedence-session-#{n}"

    {:ok, _} = Auth.create_token(bearer_raw, "BEARER-TOKEN", "production", ["read"])
    {:ok, _} = Auth.create_token(session_raw, "SESSION-TOKEN", "production", ["read"])

    {:ok, conn: conn, bearer_raw: bearer_raw, session_raw: session_raw}
  end

  defp run(conn, bearer, session) do
    conn =
      case bearer do
        nil -> conn
        raw -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw)
      end

    session_map = if session, do: %{"api_token" => session}, else: %{}

    conn
    |> init_test_session(session_map)
    |> OptionalSessionToken.call([])
  end

  defp label(conn), do: conn.assigns[:api_token] && conn.assigns[:api_token].label

  describe "3x2 credential precedence matrix" do
    test "1. valid bearer + session cookie -> bearer wins", ctx do
      out = run(ctx.conn, ctx.bearer_raw, ctx.session_raw)
      assert label(out) == "BEARER-TOKEN"
    end

    test "2. valid bearer + no cookie -> bearer", ctx do
      out = run(ctx.conn, ctx.bearer_raw, nil)
      assert label(out) == "BEARER-TOKEN"
    end

    test "3. INVALID bearer + session cookie -> the SESSION wins, not the bearer", ctx do
      out = run(ctx.conn, "garbage-not-a-token", ctx.session_raw)

      # THE CASE THE OLD MODULEDOC GOT WRONG. It claimed "the Bearer header
      # wins when both are present", which holds for a VALID bearer only:
      # `token_from_bearer/1` returns nil when the credential does not verify,
      # so `||` falls straight through to the cookie and the SESSION decides
      # the principal.
      assert label(out) == "SESSION-TOKEN"
    end

    test "4. INVALID bearer + no cookie -> anonymous", ctx do
      out = run(ctx.conn, "garbage-not-a-token", nil)
      refute out.halted
      assert label(out) == nil
    end

    test "5. no bearer + session cookie -> session", ctx do
      out = run(ctx.conn, nil, ctx.session_raw)
      assert label(out) == "SESSION-TOKEN"
    end

    test "6. no bearer + no cookie -> anonymous, never halts", ctx do
      out = run(ctx.conn, nil, nil)
      refute out.halted
      assert label(out) == nil
    end
  end
end
