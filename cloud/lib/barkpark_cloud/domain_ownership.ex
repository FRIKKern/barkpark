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

  @doc """
  Is the PLATFORM-zone `host` free for this box (task-6f85554a4e0cbc4c)?

  We own the platform zone, and the attach job's DNS upsert creates OR REPLACES
  the record. So before a platform host is persisted, the name must either not
  resolve at all (NXDOMAIN on both families: nobody's record) or resolve only
  to `box_ip` (a re-attach of this box's own record). Anything else is somebody
  else's record, possibly the control plane's own. Answers `:ok` or
  `{:error, observed}`.

  FAIL-CLOSED: a resolver answer other than an address list or `:nxdomain` (a
  timeout, SERVFAIL, a raise) is `{:error, [:unresolved]}`. Replacing a record
  we could not read is the one outcome this check exists to prevent.

  Its own seam (`opts[:dns]` or the `:platform_label_dns` application env),
  separate from the external-FQDN moat's `:attach_domain_dns`. In test it
  defaults to an offline NXDOMAIN answer, so no test touches real DNS.
  """
  @spec platform_label_free?(String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, [String.t() | :unresolved]}
  def platform_label_free?(host, box_ip, opts \\ []) when is_binary(host) do
    dns =
      opts[:dns] || Application.get_env(:barkpark_cloud, :platform_label_dns, &default_getaddrs/2)

    charlist = to_charlist(host)

    answers =
      for family <- [:inet, :inet6] do
        case safe_call(fn -> dns.(charlist, family) end) do
          {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &ip_to_string/1)}
          {:error, :nxdomain} -> {:ok, []}
          _ -> :unresolved
        end
      end

    if :unresolved in answers do
      {:error, [:unresolved]}
    else
      observed = answers |> Enum.flat_map(fn {:ok, l} -> l end) |> Enum.uniq()

      if Enum.all?(observed, &(&1 == box_ip)), do: :ok, else: {:error, observed}
    end
  end

  # Resolve a host over inet + inet6 (the DomainStatus.resolve_all idiom) and
  # return de-duplicated address STRINGS. A resolver error/raise on either
  # family is an empty contribution, never a crash.
  @doc """
  Owner ruling #29 (2026-10-03): does `domain` carry the site-domain proof —
  a TXT record at `_barkpark-verify.<domain>` whose value is exactly
  `expected_value`? Returns `:ok` or `{:error, observed}` with the TXT values
  actually seen at that name.

  FAIL-CLOSED: a resolver error, timeout, raise or NXDOMAIN is `{:error, []}`.
  The proof reads its own name, so it holds whether the domain's traffic points
  at a Barkpark box or at Cloudflare.

  Seam: `opts[:txt_dns]`, else a per-process override
  (`put_txt_dns/1`, async-test safe), else the `:domain_txt_dns` application
  env, else `:inet_res`. The fun takes the record name (a charlist) and answers
  `{:ok, [value :: String.t()]}` or `{:error, reason}`. Test config defaults to
  an offline empty answer, so no test touches real DNS.
  """
  @spec txt_proven?(String.t(), String.t(), keyword()) :: :ok | {:error, [String.t()]}
  def txt_proven?(domain, expected_value, opts \\ [])
      when is_binary(domain) and is_binary(expected_value) do
    name = BarkparkCloud.Registry.DomainVerification.record_name(domain)

    observed =
      case safe_call(fn -> txt_fun(opts).(to_charlist(name)) end) do
        {:ok, values} when is_list(values) -> Enum.map(values, &to_string/1)
        _ -> []
      end

    if expected_value in observed, do: :ok, else: {:error, observed}
  end

  @doc "TEST-ONLY: answer TXT lookups in THIS process with `fun` (nil clears)."
  def put_txt_dns(fun) when is_function(fun, 1) or is_nil(fun),
    do: Process.put({__MODULE__, :txt_dns}, fun)

  defp txt_fun(opts) do
    opts[:txt_dns] || Process.get({__MODULE__, :txt_dns}) ||
      Application.get_env(:barkpark_cloud, :domain_txt_dns, &default_txt/1)
  end

  # :inet_res answers each TXT record as a list of charlist chunks (a long
  # record is split at 255 bytes); join each record's chunks into one value.
  defp default_txt(name) do
    case :inet_res.lookup(name, :in, :txt, [], 5_000) do
      records when is_list(records) ->
        {:ok, Enum.map(records, fn chunks -> chunks |> Enum.map(&to_string/1) |> Enum.join() end)}
    end
  end

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
