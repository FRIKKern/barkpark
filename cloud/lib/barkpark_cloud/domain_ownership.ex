defmodule BarkparkCloud.DomainOwnership do
  @moduledoc """
  Attach-domain V2 ownership proof — the moat for arbitrary customer domains:
  **you can only attach a domain you already pointed at your own box.**

  Before the control plane persists an EXTERNAL custom host (anything outside
  the platform zone) it resolves the FQDN's A/AAAA records via the system
  resolver and requires the instance's box IP among the answers. No match →
  the attach is refused with the observed addresses, and nothing is written.
  Platform-zone hosts never come here — we own that zone, so pointing it IS
  the attach.

  FAIL-CLOSED by construction: a resolver error, timeout, raise, or empty
  answer all count as "not pointed". The Go worker re-runs the same check
  box-side before touching the machine (defense in depth — the worker cannot
  trust the control plane).

  The resolver seam follows `BarkparkCloud.DomainStatus`'s dns seam exactly —
  a `(charlist, family)` getaddrs fun, injectable per call via `opts[:dns]` or
  globally via the `:attach_domain_dns` application env — so tests drive every
  outcome offline.
  """

  @doc """
  Does `host` (a normalized FQDN) currently resolve to `expected_ip` (the
  instance's box, the Barkpark row's `host`)? Returns `:ok` or
  `{:error, observed}` with the de-duplicated address strings actually seen
  (empty on any resolver failure — fail closed). A nil `expected_ip` (an
  instance without a provisioned box) is `{:error, []}` without consulting the
  resolver: nothing can legitimately point at a box that does not exist.
  """
  @spec pointed_at?(String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, [String.t()]}
  def pointed_at?(host, expected_ip, opts \\ [])

  def pointed_at?(_host, nil, _opts), do: {:error, []}

  def pointed_at?(host, expected_ip, opts)
      when is_binary(host) and is_binary(expected_ip) do
    observed = resolve_all(host, dns_fun(opts))

    if expected_ip in observed, do: :ok, else: {:error, observed}
  end

  # Resolve a host over inet + inet6 (the DomainStatus.resolve_all idiom) and
  # return de-duplicated address STRINGS. A resolver error/raise on either
  # family is an empty contribution, never a crash.
  defp resolve_all(host, dns_fun) do
    charlist = to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case safe_call(fn -> dns_fun.(charlist, family) end) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end
    end)
    |> Enum.map(&ip_to_string/1)
    |> Enum.uniq()
  end

  defp ip_to_string(addr) when is_tuple(addr), do: addr |> :inet.ntoa() |> to_string()
  defp ip_to_string(addr) when is_binary(addr), do: addr
  defp ip_to_string(addr), do: to_string(addr)

  # Never let a seam raise escape — total-over-failure: a raise or exit becomes
  # the non-ok path, which counts as "not pointed".
  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp dns_fun(opts) do
    opts[:dns] ||
      Application.get_env(:barkpark_cloud, :attach_domain_dns, &default_getaddrs/2)
  end

  defp default_getaddrs(charlist, family), do: :inet.getaddrs(charlist, family)
end
