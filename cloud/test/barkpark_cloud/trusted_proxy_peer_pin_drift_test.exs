defmodule BarkparkCloud.TrustedProxyPeerPinDriftTest do
  @moduledoc """
  The DRIFT TRIPWIRE for the docker-bridge-gateway pin (cch-w1-peer-ip-pin,
  charter D6). The trusted-peer guard in `BarkparkCloud.Web.Router.trusted_peer?/1`
  is only a real guard when THREE hand-typed values, in TWO files, agree:

    * `cloud/config/config.exs`     — `:trusted_proxy_peers` default `{172,18,0,1}`
    * `cloud/docker-compose.yml`    — `TRUSTED_PROXY_PEERS=${TRUSTED_PROXY_PEERS:-172.18.0.1}`
    * `cloud/docker-compose.yml`    — the `networks.default.ipam` pinned `subnet:`

  Nothing wires these together at compile or run time (`config.exs` cannot read
  a sibling YAML file, and compose does not read `config.exs`), so the ONLY
  thing standing between "an operator repins the subnet" and "the trust guard
  silently degrades into a permanent no-op" is a human remembering the comment
  on each site that says "these two values MUST move together" / "in the SAME
  commit". Both docker-compose.yml and router_test.exs say a bare hardcoded
  peer would "rot into a silent no-op... with a test still asserting it
  works" — this test is the thing that stops being true.

  This is a TEST-TIME file read only (`File.read!` inside a test, never a
  module attribute / `@external_resource` / compile-time read), so it costs
  nothing at compile time and cannot brick the cloud image build — the
  `cloud/Dockerfile` COPYs `lib/ priv/ config/` but never `test/` or
  `docker-compose.yml`.

  Re-pin by editing all three sites in the SAME commit; there is no `make`
  target because there is nothing to copy — only a fact to keep in agreement.
  """
  use ExUnit.Case, async: true

  @compose_path Path.expand("../../docker-compose.yml", __DIR__)
  @config_path Path.expand("../../config/config.exs", __DIR__)

  defp compose_text, do: File.read!(@compose_path)
  defp config_text, do: File.read!(@config_path)

  # The .1 gateway Docker allocates for a byte-aligned CIDR block: the network
  # address with the host bits zeroed, plus 1. Works for any prefix length, not
  # just /16 — so a future re-pin to a differently-sized subnet is still checked.
  defp gateway_of_cidr!(cidr) do
    [ip_str, prefix_str] = String.split(cidr, "/", parts: 2)
    {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(ip_str))
    prefix = String.to_integer(prefix_str)

    ip_int = a * 16_777_216 + b * 65_536 + c * 256 + d
    host_bits = 32 - prefix
    block = round(:math.pow(2, host_bits))
    network_int = div(ip_int, block) * block
    gateway_int = network_int + 1

    <<ga, gb, gc, gd>> = <<gateway_int::32>>
    "#{ga}.#{gb}.#{gc}.#{gd}"
  end

  test "docker-compose's TRUSTED_PROXY_PEERS default is the .1 gateway of its OWN pinned subnet" do
    text = compose_text()

    [_, subnet] =
      Regex.run(~r/subnet:\s*([\d.]+\/\d+)/, text) ||
        flunk("cloud/docker-compose.yml: no `subnet:` found under networks.default.ipam.config")

    [_, compose_default] =
      Regex.run(~r/TRUSTED_PROXY_PEERS=\$\{TRUSTED_PROXY_PEERS:-([\d.]+)\}/, text) ||
        flunk("cloud/docker-compose.yml: no TRUSTED_PROXY_PEERS default found")

    gateway = gateway_of_cidr!(subnet)

    assert compose_default == gateway,
           "cloud/docker-compose.yml pins TRUSTED_PROXY_PEERS default #{compose_default} but " <>
             "the networks.default subnet #{subnet}'s gateway is #{gateway} — the bridge was " <>
             "repinned in only ONE of the two docker-compose.yml sites; move them together " <>
             "(see the cch-w1-peer-ip-pin comment above `networks:`)"
  end

  test "config.exs's compiled-in trusted_proxy_peers default agrees with docker-compose.yml" do
    compose = compose_text()
    config = config_text()

    [_, compose_default] =
      Regex.run(~r/TRUSTED_PROXY_PEERS=\$\{TRUSTED_PROXY_PEERS:-([\d.]+)\}/, compose) ||
        flunk("cloud/docker-compose.yml: no TRUSTED_PROXY_PEERS default found")

    [_, a, b, c, d] =
      Regex.run(
        ~r/config\s+:barkpark_cloud,\s*:trusted_proxy_peers,\s*\[\{(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\}\]/,
        config
      ) ||
        flunk("cloud/config/config.exs: no `:trusted_proxy_peers` default tuple found")

    config_default = "#{a}.#{b}.#{c}.#{d}"

    assert config_default == compose_default,
           "cloud/config/config.exs pins :trusted_proxy_peers default #{config_default} but " <>
             "cloud/docker-compose.yml pins TRUSTED_PROXY_PEERS default #{compose_default} — " <>
             "the bridge gateway was repinned in only ONE of the two files; move them together " <>
             "(cch-w1-peer-ip-pin, charter D6)"
  end

  test "the live Application env default (unless a shell TRUSTED_PROXY_PEERS is set) matches the pinned files" do
    # A belt-and-suspenders check against the ACTUAL compiled config, not just
    # the source text — catches a config.exs edit that parses fine as Elixir
    # but produces a tuple the regex above didn't anticipate (e.g. reordered
    # keyword args). Skipped gracefully if this shell has TRUSTED_PROXY_PEERS
    # set, since runtime.exs would then legitimately override the file default.
    case System.get_env("TRUSTED_PROXY_PEERS") do
      nil ->
        [_, subnet] = Regex.run(~r/subnet:\s*([\d.]+\/\d+)/, compose_text())
        gateway = gateway_of_cidr!(subnet)
        {:ok, gateway_tuple} = :inet.parse_address(String.to_charlist(gateway))

        assert Application.get_env(:barkpark_cloud, :trusted_proxy_peers) == [gateway_tuple],
               "the compiled :trusted_proxy_peers default does not match the gateway of the " <>
                 "pinned docker-compose.yml subnet (#{gateway}) — re-check cloud/config/config.exs"

      _ ->
        :ok
    end
  end
end
