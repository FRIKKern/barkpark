defmodule BarkparkCloud.BillingTestModeConsoleMirrorTest do
  @moduledoc """
  cch-w50-bl — THE DISCLOSURE, END TO END, IN ONE MUTATION.

  The defect this file guards was measured on the LIVE control plane
  (`cloud-control_plane_green-1`, read-only `docker exec … printenv`, re-derived
  2026-09-02): `STRIPE_SECRET_KEY` begins `sk_test_` while `STRIPE_PRICE_SUPPORTER`
  (`price_1TnEHC…`) and `STRIPE_WEBHOOK_SECRET` (`whsec_…`) are both wired. So
  `Billing.configured?/0` was true, `checkout/2` resolved a price, and the money
  screen's Subscribe opened a REAL hosted Checkout Session that no real card can
  pay — while the console said nothing about it (`grep -in 'test mode|sk_test'`
  over the bytes production serves: zero hits).

  ## WHY THIS TEST IS CROSS-LAYER AND NOT TWO TESTS

  The remedy has two halves in two languages: `checkout_capability/0` must
  DISTINGUISH `:test_mode`, and the console must RENDER that distinction as a
  disabled, labelled affordance. An Elixir-only test proves the server declares
  it; a node-only test proves the console renders it when told. Neither sees the
  case that actually shipped the defect — the server declaring `:available` on a
  test key, with a console that renders whatever it is told.

  So this guard drives ONE path: the capability value the SERVER puts on the
  wire (`GET /v1/subscription` → `billing_capability.checkout`) is fed into the
  CONSOLE's real renderer (`__preview__/__tier_card_dump.mjs`, which evaluates
  the shipped `app.js` in a node:vm sandbox and calls `tierCardHtml`). Collapse
  `:test_mode` into `:available` in `billing.ex` and the wire says "available",
  the console renders a live `data-plan="supporter"` Subscribe, and the rendered
  assertion below reds — from a mutation in another language.

  NO SOURCE-TEXT SCAN. Both sides are read by RUNNING: `Router.call/2` for the
  wire, `System.cmd/3` over the dump script for the render. A regex over `app.js`
  is not a pin (it passes a refactor that keeps the bytes and changes the value,
  and fails a reformat that changes nothing) — the same rule
  `billing_client_mirror_test.exs` states for the ceiling mirror.

  `async: false`: the config states are driven with `Application.put_env` over
  the gateway / prices / webhook-secret / secret-key quadruple.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing}
  alias BarkparkCloud.Billing.StripeGateway
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Production's shape, with only the key varying. Neither key is a credential:
  # both are refused by Stripe on sight, and nothing here reaches the network.
  @prices %{"supporter" => "price_supporter"}
  @webhook_secret "whsec_test"
  @test_key "sk_test_never_used"
  @live_key "sk_live_never_used"

  setup do
    billing_env = Application.get_env(:barkpark_cloud, Billing)
    stripe_env = Application.get_env(:barkpark_cloud, StripeGateway)

    on_exit(fn ->
      restore(Billing, billing_env)
      restore(StripeGateway, stripe_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark_cloud, key)
  defp restore(key, env), do: Application.put_env(:barkpark_cloud, key, env)

  defp put_key(secret_key) do
    base = Application.get_env(:barkpark_cloud, Billing, [])

    Application.put_env(
      :barkpark_cloud,
      Billing,
      base |> Keyword.put(:gateway, StripeGateway) |> Keyword.put(:prices, @prices)
    )

    Application.put_env(:barkpark_cloud, StripeGateway,
      secret_key: secret_key,
      webhook_secret: @webhook_secret
    )
  end

  defp owner_token do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "owner-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # SIDE A — what the plane DECLARES, taken off a real response.
  defp declared_capability(secret_key) do
    token = owner_token()
    put_key(secret_key)

    conn =
      conn(:get, "/v1/subscription")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert is_map(body["billing_capability"]),
           "the declaration is missing from the wire — there is nothing to drive the console with"

    body["billing_capability"]["checkout"]
  end

  # SIDE B — what the CONSOLE renders when told that. Read by running the
  # shipped app.js, never by scanning it.
  defp rendered_tier!(capability) do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip.
    assert node,
           "node is not on PATH — the cross-layer disclosure guard cannot read the console side"

    script =
      [__DIR__, "..", "..", "priv", "static", "__preview__", "__tier_card_dump.mjs"]
      |> Path.join()
      |> Path.expand()

    assert File.exists?(script),
           "the client dump script is missing at #{script} — the console side cannot be read"

    {out, status} = System.cmd(node, [script, capability], stderr_to_stdout: true)

    assert status == 0,
           "the console render failed (exit #{status}): #{out}"

    refute out == "", "an empty render must never read as agreement"
    out
  end

  describe "the plane's declaration reaches the money screen" do
    test "a test-keyed plane renders a DISABLED Subscribe carrying the disclosure" do
      capability = declared_capability(@test_key)

      assert capability == "test_mode",
             "the wire declared #{inspect(capability)} on a sk_test_ key — the console has nothing to disclose"

      html = rendered_tier!(capability)

      assert html =~ "disabled",
             "the Subscribe affordance is still live on a plane that can only refuse: #{html}"

      refute html =~ ~s(data-plan="supporter"),
             "the card still carries the checkout wire, so a click still POSTs: #{html}"

      assert html =~ Billing.test_mode_disclosure(),
             "the rendered card does not state the server's own reason: #{html}"
    end

    test "a live-keyed plane renders the ordinary Subscribe — the disclosure is not permanent" do
      # The other direction, so a renderer that disabled the button always
      # could not pass this file. It is also the state the deploy reaches the
      # day a live key is wired: no code change, the button comes back.
      capability = declared_capability(@live_key)
      assert capability == "available"

      html = rendered_tier!(capability)

      assert html =~ ~s(data-plan="supporter"),
             "a live-keyed plane must still offer checkout: #{html}"

      refute html =~ Billing.test_mode_disclosure(),
             "the disclosure rendered on a plane that is not in test mode: #{html}"
    end

    test "an ABSENT declaration renders what it always rendered — the server stays the gate" do
      # An older payload or a failed read leaves the console's cache empty. It
      # must not invent a disclosure it was not told, and it must not silently
      # disable the money screen: POST checkout refuses :test_mode on its own.
      html = rendered_tier!("")

      assert html =~ ~s(data-plan="supporter")
      refute html =~ Billing.test_mode_disclosure()
    end
  end
end
