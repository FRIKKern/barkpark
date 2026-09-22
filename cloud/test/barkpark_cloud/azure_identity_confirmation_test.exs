defmodule BarkparkCloud.AzureIdentityConfirmationTest do
  @moduledoc """
  The two mechanical arms behind charter **D898** — "a SERVER-CONFIRMED azure
  account identity is DECLINED for now, and cannot be smuggled in later".

  D898 is a written ruling, and a written finding does not fire by itself. These
  are its triggers:

    * **The ARM request-builder surface is exactly the four D898 priced.** A
      FIFTH builder — a `GET /subscriptions/{id}` fetching the subscription
      `displayName` is the one the row asked for — reds this test and routes its
      author back to the ruling, where the latency and failure-mode cost are
      stated. The assertion is keyed on the `_request` SHAPE, not on a list of
      four names, so a builder added under any name is caught.
    * **`FakeClient.verify/1` and `RealClient.verify/1` emit the SAME meta
      keys.** This is the "widened together" invariant: a key the fake emits and
      the real client does not is green in the whole suite and `nil` in prod.
      The shapes had ALREADY drifted when this landed (the fake carried a
      `resource_count: 1` that no caller anywhere read and the real client never
      produced); D898 converged them and this holds the line.

  `async: false` — the parity test drives `RealClient.verify/1` through a STUB
  transport, which it installs in the global `BarkparkCloud.Azure` config and
  restores on exit. No byte reaches `management.azure.com`: the stub answers
  both legs from memory and asserts the URLs it was handed.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Azure.{FakeClient, RealClient}

  @blob %{
    "tenant_id" => "tenant-abc",
    "client_id" => "client-xyz",
    "client_secret" => "s3cr3t",
    "subscription_id" => "sub-123"
  }

  describe "D898: the ARM request-builder surface is frozen at four" do
    test "a fifth request builder reds this test — read charter D898 before adding one" do
      assert request_builders() == [
               {:locations_request, 2},
               {:resource_groups_request, 2},
               {:token_request, 1},
               {:vm_sizes_request, 2}
             ]
    end

    # CONTROL — the tripwire is keyed on the request-builder shape, not on "the
    # module changed". RealClient's non-builder exports (the two behaviour
    # callbacks) are public too, and must not be swept into the frozen set;
    # if they were, this test's own subject would be unfalsifiable noise.
    test "control: the behaviour callbacks are public and are NOT counted as builders" do
      exports = RealClient.__info__(:functions)

      assert {:verify, 1} in exports
      assert {:list_catalog, 1} in exports

      refute {:verify, 1} in request_builders()
      refute {:list_catalog, 1} in request_builders()
    end
  end

  describe "D898: the fake and the real client emit ONE verify/1 meta shape" do
    setup do
      prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Azure)

      Application.put_env(:barkpark_cloud, BarkparkCloud.Azure,
        http_client: &__MODULE__.stub_transport/1
      )

      on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Azure, prev) end)
      :ok
    end

    test "their meta key sets are identical — neither widens without the other" do
      assert {:ok, fake_meta} = FakeClient.verify(@blob)
      assert {:ok, real_meta} = RealClient.verify(@blob)

      assert Map.keys(fake_meta) |> Enum.sort() == Map.keys(real_meta) |> Enum.sort(),
             """
             The fake and real Azure verify/1 metas have diverged.
             fake: #{inspect(Map.keys(fake_meta))}
             real: #{inspect(Map.keys(real_meta))}
             Widen BOTH clients in one commit (charter D898), or neither.
             """
    end

    test "and both still carry the echoed subscription id the console renders" do
      assert {:ok, %{subscription_id: "sub-123"}} = FakeClient.verify(@blob)
      assert {:ok, %{subscription_id: "sub-123"}} = RealClient.verify(@blob)
    end

    # CONTROL — the parity above is measured on a REAL drive of RealClient's
    # success path, not on a fail-closed stub that would make both sides equally
    # empty. Without a transport RealClient cannot answer at all, so a parity
    # test that forgot its stub would be vacuous.
    test "control: with no transport RealClient.verify cannot reach its meta at all" do
      Application.put_env(:barkpark_cloud, BarkparkCloud.Azure, http_client: nil)

      assert {:error, :http_client_not_configured} = RealClient.verify(@blob)
    end
  end

  @doc false
  # Answers the two legs verify/1 makes, asserting the shape of each: the OAuth2
  # token exchange, then the capped resource-group list. The list body is the
  # EMPTY page a fresh zero-resource-group subscription returns — the shape
  # D898 records as the reason that body cannot yield an account identity.
  def stub_transport(%{method: :post, url: url, body: body}) do
    assert url =~ "login.microsoftonline.com/tenant-abc/oauth2/v2.0/token"
    assert body =~ "grant_type=client_credentials"
    {:ok, %{status: 200, body: ~s({"access_token":"stub-token"})}}
  end

  def stub_transport(%{method: :get, url: url, headers: headers}) do
    assert url =~ "management.azure.com/subscriptions/sub-123/resourcegroups"
    assert {"Authorization", "Bearer stub-token"} in headers
    {:ok, %{status: 200, body: ~s({"value":[]})}}
  end

  # Every PUBLIC arity-N function on RealClient whose name ends in `_request`.
  # A predicate, not an enumeration: it describes what a request builder IS, so
  # it catches one added under a name nobody listed here.
  defp request_builders do
    RealClient.__info__(:functions)
    |> Enum.filter(fn {name, _arity} -> String.ends_with?(Atom.to_string(name), "_request") end)
    |> Enum.sort()
  end
end
