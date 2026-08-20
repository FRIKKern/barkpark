defmodule Barkpark.Sso.SsoHttpTimeoutTest do
  @moduledoc """
  Felix W10 — task-felix-sso-explicit-timeout (co-shipped with
  task-felix-outbound-pool-isolation).

  The 4 SSO outbound calls (OIDC token POST + JWKS GET, Social token POST +
  userinfo GET) now carry an EXPLICIT, tunable `receive_timeout: 10_000`. Named
  failure mode: a hung IdP/provider must never stall the login path
  indefinitely — the prior calls relied on Req/Finch's implicit default, so the
  bound was silent and untunable. The timeout is a top-level Req option, NEVER
  `connect_options` (Req raises ArgumentError if both `:finch` and
  `:connect_options` are set, and these calls also set `:finch`).

  Two guards:
    1. behavioral — each REAL `ReqClient` function reaches the network and comes
       back as a deterministic, bounded `{:error, reason}` (proves the outbound
       path is wired and non-vacuous — not merely a source grep);
    2. structural — the explicit `receive_timeout: 10_000` is present on each of
       the 4 SSO call sites (fail-before: absent on origin/main today).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sso.Oidc.HTTP.ReqClient, as: OidcClient
  alias Barkpark.Sso.Social.HTTP.ReqClient, as: SocialClient

  # 127.0.0.1:1 is never bound → immediate, deterministic econnrefused. Kept
  # fast (no sleeping stub) — connection refusal short-circuits before the 10s
  # receive_timeout, so the test is quick yet still exercises the real Req path
  # (through the dedicated Barkpark.Auth.Finch pool).
  @dead_url "http://127.0.0.1:1"
  @bounded_reasons [:timeout, :econnrefused, :ehostunreach, :enetunreach, :nxdomain, :closed]

  defp reason({:error, %{reason: r}}), do: r
  defp reason({:error, other}), do: other

  describe "behavioral — real SSO clients fail bounded, never hang or crash" do
    test "OIDC post_form/2 returns a bounded transport error" do
      result = OidcClient.post_form(@dead_url, %{"grant_type" => "authorization_code"})
      assert match?({:error, _}, result), "expected {:error, _}, got #{inspect(result)}"
      assert reason(result) in @bounded_reasons, "unexpected reason: #{inspect(reason(result))}"
    end

    test "OIDC get_json/1 (JWKS) returns a bounded transport error" do
      result = OidcClient.get_json(@dead_url)
      assert match?({:error, _}, result), "expected {:error, _}, got #{inspect(result)}"
      assert reason(result) in @bounded_reasons, "unexpected reason: #{inspect(reason(result))}"
    end

    test "Social post_form/2 returns a bounded transport error" do
      result = SocialClient.post_form(@dead_url, %{"grant_type" => "authorization_code"})
      assert match?({:error, _}, result), "expected {:error, _}, got #{inspect(result)}"
      assert reason(result) in @bounded_reasons, "unexpected reason: #{inspect(reason(result))}"
    end

    test "Social get_bearer/2 (userinfo) returns a bounded transport error" do
      result = SocialClient.get_bearer(@dead_url, "dummy-token")
      assert match?({:error, _}, result), "expected {:error, _}, got #{inspect(result)}"
      assert reason(result) in @bounded_reasons, "unexpected reason: #{inspect(reason(result))}"
    end
  end

  describe "structural — every SSO call site carries the explicit receive_timeout" do
    @sso_sources %{
      "lib/barkpark/sso/oidc/http.ex" => 2,
      "lib/barkpark/sso/social/http.ex" => 2
    }

    for {source, expected_count} <- @sso_sources do
      test "#{source} sets receive_timeout: 10_000 on all #{expected_count} outbound calls" do
        body = File.read!(unquote(source))
        count = body |> String.split("receive_timeout: 10_000") |> length() |> Kernel.-(1)

        assert count == unquote(expected_count),
               "#{unquote(source)}: expected #{unquote(expected_count)} explicit " <>
                 "`receive_timeout: 10_000`, found #{count}"

        # And no call may set the `connect_options:` key alongside `:finch`
        # (Req raises ArgumentError if both are present) — the explicit timeout
        # is threaded as a top-level `receive_timeout:` precisely to stay safe.
        refute body =~ "connect_options:",
               "#{unquote(source)} must NOT set connect_options: alongside :finch (Req raises)"
      end
    end
  end
end
