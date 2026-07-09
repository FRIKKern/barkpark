defmodule BarkparkCloud.DomainStatusOfflineGuard do
  @moduledoc """
  The fail-CLOSED default for `BarkparkCloud.DomainStatus`'s three outbound seams
  in the test env (wired in `config/test.exs`). If a test exercises the
  domain-status route without programming its own fakes, these return
  "unreachable" instead of the real transports touching the network — so no test
  can ever spend a DNS/TLS/HTTP call by accident (the Stripe-stub / azure
  fail-closed discipline). Tests that assert real behaviour inject their own
  seam fakes (per-call `opts` or `Application.put_env`), which take precedence.
  """

  @spec getaddrs(charlist(), :inet.address_family()) :: {:error, :offline_guard}
  def getaddrs(_host, _family), do: {:error, :offline_guard}

  @spec tls(String.t(), :inet.port_number()) :: {:error, :offline_guard}
  def tls(_host, _port), do: {:error, :offline_guard}

  @spec http(String.t()) :: {:error, :offline_guard}
  def http(_url), do: {:error, :offline_guard}
end
