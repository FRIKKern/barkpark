defmodule BarkparkWeb.Plugs.RateLimitPrincipalCoverageTest do
  @moduledoc """
  THE TRIPWIRE FOR THE MISTAKE THAT ALREADY HAPPENED ONCE.

  `RateLimit` runs BEFORE the credential plug in every pipeline that mounts
  both, so it cannot ask "who is this?" — it has to resolve the bearer itself,
  through `@principal_resolvers`. That list knew about `ApiToken` and not about
  `Barkpark.Scim.Token`, so `pipeline :scim` metered an entire IdP's
  provisioning traffic as anonymous per-IP traffic and CI went 18 tests red with
  HTTP 429. The defect was not in the resolver; it was that NOTHING connected
  the router's credential plugs to the limiter's resolver list.

  This test is that connection. It reads the router, finds every pipeline that
  mounts `RateLimit`, and refuses any credential-bearing plug in those pipelines
  that is not accounted for below. Adding a metered pipeline with a new
  credential kind reds here, at the mount, rather than in someone else's suite.

  It is a COVERAGE assertion, not a behaviour one: it says a human decided how
  each credential kind is keyed. `rate_limit_test.exs` proves the keying.
  """
  use ExUnit.Case, async: true

  @router Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)

  # Every credential-ish plug that may appear in a pipeline mounting RateLimit,
  # and HOW its callers get a bucket. Keep the rationales; the reason to touch
  # this map is a new credential kind, and the next reader needs to know which
  # of these three answers applies to it.
  #
  #   :resolved      — a bearer this plug accepts is resolved by an entry in
  #                    RateLimit's @principal_resolvers, so it keys on its own
  #                    verified token id.
  #   :not_a_bearer  — the plug reads a DIFFERENT Authorization scheme, so the
  #                    limiter's "Bearer " clause never matches it and it keys
  #                    on IP. True before this fix and after it.
  #   :not_a_resolver — the plug resolves no credential at all (it derives scope
  #                    or gates on an already-resolved one).
  @accounted %{
    "OptionalToken" => {:resolved, "api_token via Auth.verify_token_id/1"},
    "RequireToken" => {:resolved, "api_token via Auth.verify_token_id/1"},
    "OptionalSessionToken" => {:resolved, "bearer branch is Auth.verify_token/1; the cookie branch carries no bearer and keys on IP"},
    "RequireBearerOrSessionToken" => {:resolved, "bearer branch is Auth.verify_token/1; cookie branch as above"},
    "RequireShareEditToken" => {:resolved, "a share-edit token IS an api_token (kind \"api\", share_scope set)"},
    "RequireScimToken" => {:resolved, "scim token via Scim.resolve_token_id/1 — the kind whose absence caused the 429s"},
    "PreviewToken" => {:not_a_bearer, "reads `Authorization: Preview <jwt>`"},
    "RequireChatHost" => {:not_a_bearer, "reads `Authorization: Host <cred>`"},
    "DeriveWorkspaceFromToken" => {:not_a_resolver, "derives scope from an already-assigned token"},
    # Local function plugs in the router itself, same rules.
    "scoped_api_optional_credential" =>
      {:resolved, "delegates to OptionalSessionToken + OptionalToken — api_token either way"}
  }

  defp metered_pipelines do
    src = File.read!(@router)

    Regex.scan(~r/\n  pipeline (:\w+) do\n(.*?)\n  end\n/s, src)
    |> Enum.map(fn [_, name, body] -> {name, body} end)
    |> Enum.filter(fn {_name, body} -> String.contains?(body, "Plugs.RateLimit)") end)
  end

  test "the router still has metered pipelines to check (the parse is not silently empty)" do
    pipelines = metered_pipelines()

    # A regex that stops matching would make every assertion below vacuous, and
    # a vacuous green here is precisely the failure this file exists to prevent.
    assert length(pipelines) >= 10,
           "only #{length(pipelines)} pipelines mounting RateLimit were parsed out of the " <>
             "router — the block regex has probably drifted, so this file is measuring nothing"

    names = Enum.map(pipelines, &elem(&1, 0))
    assert ":scim" in names
    assert ":api" in names
  end

  # POSITIVE CONTROL for the test below. Its verdict is "the unaccounted list is
  # EMPTY", and a regex that matched nothing would produce that verdict too —
  # the same shape of vacuous green that let the SCIM gap ship. So first prove
  # the scan can SEE the credential plugs, including the one that caused the
  # incident and the local function-plug spelling a module-only scan would miss.
  test "the credential-plug scan actually finds plugs (not a vacuous empty set)" do
    found =
      for {_pipeline, body} <- metered_pipelines(),
          [_, plug] <- Regex.scan(~r/plug\((?:BarkparkWeb\.Plugs\.)?:?(\w+)[\),]/, body),
          Regex.match?(~r/Token|token|Credential|credential|Host|Auth/, plug),
          do: plug

    assert "RequireScimToken" in found
    assert "OptionalToken" in found
    assert "scoped_api_optional_credential" in found
    assert length(Enum.uniq(found)) >= 6
  end

  test "every credential plug in a metered pipeline has a declared bucket story" do
    # Both spellings: a module plug `plug(BarkparkWeb.Plugs.X)` and a LOCAL
    # function plug `plug(:x)` defined in the router (`:scoped_api` resolves its
    # credential that way, so a module-only scan would have a blind spot the
    # size of the whole scoped surface).
    unaccounted =
      for {pipeline, body} <- metered_pipelines(),
          [_, plug] <- Regex.scan(~r/plug\((?:BarkparkWeb\.Plugs\.)?:?(\w+)[\),]/, body),
          Regex.match?(~r/Token|token|Credential|credential|Host|Auth/, plug),
          not Map.has_key?(@accounted, plug),
          do: {pipeline, plug}

    assert unaccounted == [],
           """
           A pipeline that mounts BarkparkWeb.Plugs.RateLimit also mounts a
           credential plug this test does not know how to bucket:

             #{Enum.map_join(unaccounted, "\n  ", fn {p, plug} -> "#{p} -> #{plug}" end)}

           RateLimit runs BEFORE that plug, so it resolves the bearer itself. If
           this credential is a Bearer of a NEW kind, add a resolver to
           @principal_resolvers in lib/barkpark_web/plugs/rate_limit.ex and a
           test to rate_limit_test.exs — otherwise every caller holding one is
           metered as anonymous and shares the per-IP budget with strangers.
           That exact omission (SCIM) shipped once and reddened 18 tests.

           If it is NOT a bearer, or resolves no credential, record it in
           @accounted here with the reason.
           """
  end

  test "the accounted plugs that claim :resolved name a kind RateLimit actually resolves" do
    src = File.read!(Path.expand("../../../lib/barkpark_web/plugs/rate_limit.ex", __DIR__))

    # The registry is the code's own statement of which kinds it can verify.
    assert src =~ "{\"api\", {Barkpark.Auth, :verify_token_id}}"
    assert src =~ "{\"scim\", {Barkpark.Scim, :resolve_token_id}}"

    # And both of those functions exist with the arity the registry applies.
    # `ensure_loaded?` first: in :test the modules are lazily loaded, and
    # `function_exported?` on an unloaded module answers FALSE — a red that
    # would look exactly like a deleted function.
    assert Code.ensure_loaded?(Barkpark.Auth)
    assert Code.ensure_loaded?(Barkpark.Scim)
    assert function_exported?(Barkpark.Auth, :verify_token_id, 1)
    assert function_exported?(Barkpark.Scim, :resolve_token_id, 1)
  end
end
