defmodule BarkparkCloud.Web.RouterBuilderAuthProseTest do
  @moduledoc """
  A PROSE↔CODE PIN over the `## Builder routes` section header in `router.ex`.

  That header once said builders "authenticate with a user session token for now
  (a dedicated builder-token type is a hardening follow-up)" and that "the build
  plane is fleet-wide". Both had been false since `jpf-w1-builder-identity` moved
  every `/v1/builder/*` route onto `Auth.require_agent/2` — the box's own hashed,
  revocable agent token, with the claim query narrowed by
  `Registry.claim_queued_deployment_for_barkpark/2`. The stale sentence was read
  as current and spawned a false cross-tenant security scare; `dwb-doc-lag-
  microfixes` rewrote it (PR #18475).

  A rewrite nothing checks rots again, and this is the file that stops it. The
  route-table TIER census in `router_moduledoc_table_test.exs` already pins the
  `agent` tier CELL for these five rows — what it does not read is the PARAGRAPH,
  and the paragraph is what the security reviewer actually read.

  Two arms, both parsed off the router SOURCE (no DB, no booted router):

    * RESURRECTION — the retired claim may not come back into the header block:
      no "user session token", no "fleet-wide" unqualified by a negation, no
      "hardening follow-up".
    * AGREEMENT — the gate the header NAMES for `/v1/builder/*` must be the gate
      every `/v1/builder/*` route body actually composes, resolved through the
      shared `RouterTierLens` rather than a private regex.

  ANTI-VACUITY: both arms first assert that the header block was located and is
  non-empty, and that the `/v1/builder/*` route population is non-empty. A moved
  header or a renamed prefix fails here instead of passing by finding nothing.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.RouterTierLens, as: Lens

  # The `## Builder routes` header: consecutive `##` comment lines starting at the
  # section title, ending at the first line that is not one.
  @header_start ~r/^\s*##\s+Builder routes\b/
  @header_line ~r/^\s*##(\s|$)/

  @builder_prefix "/v1/builder/"

  # The gate the header attributes to the builder routes, and the one gate every
  # builder route body is expected to compose.
  @expected_gate "require_agent"

  defp header_block do
    Lens.source()
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(@header_start, &1)))
    |> Enum.take_while(&Regex.match?(@header_line, &1))
    |> Enum.join("\n")
  end

  defp builder_routes do
    Lens.route_keys()
    |> Enum.filter(fn {_method, path} -> String.starts_with?(path, @builder_prefix) end)
    |> Enum.sort()
  end

  describe "anti-vacuity" do
    test "the builder-routes header block is located and non-empty" do
      block = header_block()

      assert String.length(block) > 200,
             "the `## Builder routes` section header was not found in router.ex (or shrank to " <>
               "#{String.length(block)} chars). This census reads that paragraph; if the header " <>
               "moved or was renamed, re-point @header_start rather than deleting the pin."
    end

    test "the /v1/builder/* route population is non-empty" do
      routes = builder_routes()

      refute routes == [],
             "no `#{@builder_prefix}*` routes were parsed out of router.ex — the agreement arm " <>
               "below would be green over an empty set. Check the prefix before trusting a pass."
    end
  end

  describe "resurrection" do
    test "the retired user-session claim cannot come back into the header" do
      block = header_block()
      assert String.length(block) > 200

      refute block =~ ~r/user[- ]session token/i,
             "the builder-routes header claims a USER-SESSION credential again. Every " <>
               "`#{@builder_prefix}*` route gates on `Auth.#{@expected_gate}/2` (the box's own " <>
               "agent token). This exact sentence spawned a false cross-tenant security scare " <>
               "once; see dwb-doc-lag-microfixes."

      refute block =~ ~r/hardening follow-up/i,
             "the builder-routes header promises a dedicated builder-token type as a future " <>
               "hardening follow-up. It already shipped: `Auth.#{@expected_gate}/2`."
    end

    test "the header does not call the build plane fleet-wide without negating it" do
      block = header_block()
      assert String.length(block) > 200

      # `NOT fleet-wide` / `never fleet-wide` is the CURRENT, true sentence. A bare
      # `is fleet-wide` is the retired one: the claim query is box-scoped through
      # `Registry.claim_queued_deployment_for_barkpark/2`.
      fleet_wide_claims =
        block
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/fleet-wide/i))
        |> Enum.reject(&(&1 =~ ~r/\b(not|never|no longer)\b/i))

      assert fleet_wide_claims == [],
             "the builder-routes header calls the build plane fleet-wide without negating it: " <>
               "#{inspect(fleet_wide_claims)}. The claim is box-scoped through " <>
               "`Registry.claim_queued_deployment_for_barkpark/2`."
    end
  end

  describe "agreement" do
    test "the header names the gate the builder routes actually compose" do
      block = header_block()
      assert String.length(block) > 200

      assert block =~ "Auth.#{@expected_gate}/2",
             "the builder-routes header no longer names `Auth.#{@expected_gate}/2`, which is " <>
               "the gate every `#{@builder_prefix}*` route body composes. Prose that does not " <>
               "name the gate is the state this census exists to refuse."
    end

    test "every /v1/builder/* route body composes that gate" do
      routes = builder_routes()
      refute routes == []

      actual =
        Map.new(routes, fn {method, path} ->
          {{method, path}, Lens.base_guard(Lens.raw_route_guard(method, path))}
        end)

      wrong = for {key, guard} <- actual, guard != @expected_gate, do: {key, guard}

      assert wrong == [],
             "these `#{@builder_prefix}*` routes do not gate on `Auth.#{@expected_gate}/2`, so " <>
               "the section header above them is now false: #{inspect(wrong)}. Either restore " <>
               "the gate or rewrite the header AND this pin together."
    end
  end
end
