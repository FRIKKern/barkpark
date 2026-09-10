defmodule BarkparkCloud.Web.RouterAgentServingModeTest do
  @moduledoc """
  cf-agent-sites-tls-channel — THE CP→BOX TLS CHANNEL.

  `cf-box-render-internal-tls` (merged as 3a2252748) made the box render
  `tls internal` for a site whose `serving_mode` is `cf_proxied`, and left the
  producing half open: `runtime.go` decoded `InlineSite.ServingMode` from a key
  the control plane never sent, so on every real box the field was the zero
  value, every proxied site resolved to on-demand ACME, and an ACME challenge
  that cannot complete through the Cloudflare proxy is a live 526.

  The channel is the agent claim/pending site inline —
  `Router.deployment_with_site_json/1`, which serves BOTH
  `GET /v1/agent/pending` and `POST /v1/agent/deployments/claim`. These tests
  assert the `site` object on that wire.

  ## The mirror lock

  A value that lives on two surfaces (this serializer and the Go decoder in
  `internal/runtime`) needs ONE definition. Both suites read
  `internal/runtime/testdata/agent_claim_site_payload.json`: this file asserts
  the control plane EMITS those objects, and
  `internal/runtime/runtime_serving_mode_wire_test.go` serves the same objects
  as a raw claim body and asserts what the box renders from them. Drift on
  either side reds the other side's suite.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # The shared fixture, read from the repo root (cloud/test/barkpark_cloud/web
  # → four levels up). Read at runtime, not at compile time, so a stale
  # _build never hides a fixture edit.
  @fixture_path "../../../../internal/runtime/testdata/agent_claim_site_payload.json"

  defp fixture(key) do
    __DIR__
    |> Path.join(@fixture_path)
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!(key)
  end

  ## Fixtures

  # A fresh team per test — the sites unique index is (team_id, slug), so every
  # test may use the fixture's literal slug "shop" and still run async.
  defp agent_setup(site_attrs) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(
        bp,
        Map.merge(%{name: "Shop", slug: "shop", domains: ["shop.example.com"]}, site_attrs)
      )

    {:ok, token, _} = Registry.mint_agent_token(bp, "runtime")
    {token, site}
  end

  defp pushing_deployment(site) do
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, d} = Registry.create_deployment(site, %{git_ref: ref})
    {:ok, d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "site-x-1"})
    d
  end

  # The `site` inline exactly as the agent reads it off GET /v1/agent/pending.
  defp site_inline(token) do
    conn =
      :get
      |> conn("/v1/agent/pending")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    [dep] = Jason.decode!(conn.resp_body)["deployments"]
    dep["site"]
  end

  ## The wire

  describe "the agent claim/pending site inline carries serving_mode" do
    test "a cf_proxied site puts serving_mode=cf_proxied on the wire, byte-for-byte the fixture" do
      {token, site} = agent_setup(%{})
      {:ok, _} = Registry.set_cf_binding(site, %{serving_mode: "cf_proxied"})
      _d = pushing_deployment(site)

      # Full-object equality, not a key probe: the box decodes this whole
      # object, and the Go suite renders `tls internal` from this same JSON.
      assert site_inline(token) == fixture("cf_proxied")
    end

    test "a direct site puts serving_mode=direct on the wire, byte-for-byte the fixture" do
      {token, site} = agent_setup(%{})
      _d = pushing_deployment(site)

      assert site.serving_mode == "direct", "the schema default is the direct path"
      assert site_inline(token) == fixture("direct")
    end

    test "a record with NO serving_mode column degrades to direct — never a JSON null" do
      # A row read before the cf-edge-binding backfill has no such key at all.
      # `Map.get/2` (not struct access) is what makes that degrade to "direct"
      # instead of putting `null` on the wire, where the box would decode the
      # empty string and — correctly, but only by luck — fall back to on_demand.
      # This asserts the degrade is DESIGNED, not incidental.
      {token, site} = agent_setup(%{})
      legacy = Map.drop(Map.from_struct(site), [:serving_mode])
      refute Map.has_key?(legacy, :serving_mode)

      _d = pushing_deployment(site)

      # The serializer's own rule, applied to the legacy shape.
      assert Router.agent_serving_mode(legacy) == "direct"
      assert Router.agent_serving_mode(nil) == "direct"
      assert Router.agent_serving_mode(%{serving_mode: nil}) == "direct"

      # …and the live wire for the same site is the direct fixture.
      assert site_inline(token) == fixture("direct")
    end

    test "an unknown serving_mode fails safe to direct on the wire" do
      # The column is inclusion-validated, so this shape can only arise from a
      # future enum value the box does not yet speak. It must NEVER be forwarded
      # verbatim: the box's tlsModeForServing maps every unknown value to
      # on_demand, and a value the CP invents must not reach it as a surprise.
      assert Router.agent_serving_mode(%{serving_mode: "sideways"}) == "direct"
    end
  end

  ## The lock itself

  describe "the shared fixture" do
    test "pins the pre-change control-plane shape so the Go zero-value stays meaningful" do
      # `legacy_control_plane` is what a control plane WITHOUT this change emits.
      # If somebody adds serving_mode to it, the Go suite stops proving that an
      # old CP keeps rendering today's on_demand block.
      legacy = fixture("legacy_control_plane")
      refute Map.has_key?(legacy, "serving_mode")
      assert Map.has_key?(fixture("cf_proxied"), "serving_mode")
    end
  end
end
