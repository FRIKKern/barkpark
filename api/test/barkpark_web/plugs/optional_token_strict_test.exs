defmodule BarkparkWeb.Plugs.OptionalTokenStrictTest do
  @moduledoc """
  Unit contract for `OptionalToken`'s opt-in `strict_on_presented: true` arm
  (task-46872cadcfc50c5f).

  Deliberately a SEPARATE file from `optional_token_test.exs`: that file pins
  the plug's fail-soft DEFAULT ("invalid Bearer → passes through, never
  halts") and must stay byte-identical, because the opt is opt-IN and changes
  nothing for a mount that does not pass it. The two files together are the
  proof that the narrowing is a narrowing and not a contract change — the
  `init([])` cases below are duplicated from the default's perspective on
  purpose, so a regression that makes the strict arm leak into the default
  reds HERE too.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.OptionalToken

  @raw_token "optional-token-strict-test-#{System.unique_integer([:positive])}"

  @strict OptionalToken.init(strict_on_presented: true)
  @lax OptionalToken.init([])

  setup do
    {:ok, token} =
      Auth.create_token(@raw_token, "optional-token-strict-test", "production", ["read"])

    %{token: token}
  end

  defp build_req, do: build_conn(:get, "/v1/data/query/production/anything")

  defp with_bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  # ── The one input the opt changes ─────────────────────────────────────────

  test "strict: a PRESENTED but unverifiable Bearer is refused 401 and halts" do
    conn = build_req() |> with_bearer("not-a-real-token") |> OptionalToken.call(@strict)

    assert conn.halted
    assert conn.status == 401
    refute Map.has_key?(conn.assigns, :api_token)
  end

  test "strict: a REVOKED bearer is refused with the SAME 401 as an unknown one — the " <>
         "revoked/expired/unknown fold stays indistinguishable",
       %{token: token} do
    {:ok, _} = Auth.revoke_token(token)

    revoked = build_req() |> with_bearer(@raw_token) |> OptionalToken.call(@strict)
    unknown = build_req() |> with_bearer("no-such-token") |> OptionalToken.call(@strict)

    assert revoked.status == 401
    assert revoked.status == unknown.status

    assert revoked.resp_body == unknown.resp_body,
           "a revoked bearer must be indistinguishable from an unknown one — " <>
             "existence-hiding in Auth.verify_token/1 is deliberate and this arm " <>
             "must not become an oracle (revoked=#{revoked.resp_body}, " <>
             "unknown=#{unknown.resp_body})"
  end

  # ── Everything the opt must NOT change ────────────────────────────────────

  test "strict: NO Authorization header still passes through untouched — the anonymous " <>
         "public read is not a blanket 401" do
    conn = build_req() |> OptionalToken.call(@strict)

    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end

  test "strict: a non-Bearer Authorization scheme still passes through" do
    conn =
      build_req()
      |> put_req_header("authorization", "Preview some-jwt")
      |> OptionalToken.call(@strict)

    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end

  test "strict: a VALID bearer is assigned exactly as before — a public-read token is a " <>
         "VALID token, so the shipped browser credentials are untouched" do
    conn = build_req() |> with_bearer(@raw_token) |> OptionalToken.call(@strict)

    refute conn.halted
    assert %Barkpark.Auth.ApiToken{} = conn.assigns[:api_token]
  end

  test "strict: no-ops when an earlier mount (`:api`) already assigned :api_token" do
    conn =
      build_req()
      |> with_bearer("not-a-real-token")
      |> assign(:api_token, %Barkpark.Auth.ApiToken{})
      |> OptionalToken.call(@strict)

    refute conn.halted
  end

  # ── The default arm, asserted from this file too ──────────────────────────

  test "default (no opt): the SAME unverifiable bearer still passes through, never halts" do
    conn = build_req() |> with_bearer("not-a-real-token") |> OptionalToken.call(@lax)

    refute conn.halted
    refute Map.has_key?(conn.assigns, :api_token)
  end
end
