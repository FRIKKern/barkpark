defmodule BarkparkCloud.Notifications.SafeUrl do
  @moduledoc """
  SSRF guard for EVERY url-bearing channel — a port of Coolify's
  `app/Rules/SafeWebhookUrl.php`. `discord`, `slack` and `webhook` all carry the
  same `%{"url" => …}` credential, and a Slack/Discord incoming-webhook URL is
  pasted by the operator exactly as a generic webhook URL is, so all three are
  gated at BOTH validation time (`Notifications.put_channel/4`) and send time
  (defense in depth, the way Coolify re-checks inside `SendWebhookJob`). Both
  fences key on the credential SHAPE, so a url-bearing type added later is gated
  the day it lands. Telegram and Pushover carry no URL credential and are not
  gated here — their endpoints are constants in their shapers.

  ## What it blocks — and the one improvement over Coolify

  1. Scheme must be `http`/`https` and a host must be present.
  2. The literal host is rejected if it is an obvious internal name
     (`localhost`, `*.internal`, `0.0.0.0`, `::`, `[::1]`, …).
  3. The host is RESOLVED (`:inet.getaddrs/2` over inet + inet6) and EVERY
     returned address is checked against the private / loopback / link-local /
     ULA / cloud-metadata ranges. Coolify's rule is regex-on-the-string only;
     resolving-then-checking the actual address is what closes the DNS-rebinding
     hole where `evil.example.com` resolves to `169.254.169.254`. No dependency —
     pure `:inet` + integer/mask math.

  Returns `:ok` or `{:error, :ssrf_blocked}` (plus `{:error, :bad_url}` /
  `{:error, :unresolvable}` for malformed / undiscoverable hosts).

  ## The resolver seam

  `check/2` takes an optional `:resolver` — anything with the shape of
  `:inet.getaddrs/2`, which is the default. Production never passes it. It exists
  so the hostname path (resolve-then-check, the only path an IP literal cannot
  exercise) is testable WITHOUT asking a third party's DNS whether the suite may
  pass: a merge-blocking CI context must not depend on a host this repo does not
  own.
  """

  @type result :: :ok | {:error, :ssrf_blocked | :bad_url | :unresolvable}
  @type resolver ::
          (charlist(), :inet | :inet6 -> {:ok, [:inet.ip_address()]} | {:error, term()})

  # Hostnames we reject before even resolving — the obvious internal labels.
  @blocked_hosts ~w(localhost ip6-localhost ip6-loopback 0.0.0.0 0 ::1 ::)
  # Any host ending in one of these suffixes is internal by convention.
  @blocked_suffixes ~w(.localhost .internal .local)

  @doc """
  A BARE host (no scheme — an SMTP relay, say) that is internal WITHOUT any DNS
  lookup: a blocked internal name (`localhost`, `*.internal`, `*.local`, …) or an
  IP literal in a private/loopback/link-local/metadata range. Offline and
  deterministic, so it can gate a save. A public-looking NAME that resolves to a
  private address is not caught here (that needs `check/2`'s resolution).
  """
  @spec literal_internal_host?(term()) :: boolean()
  def literal_internal_host?(host) when is_binary(host) do
    normalized =
      host |> String.trim() |> String.downcase() |> String.trim_trailing(".") |> strip_brackets()

    blocked_name?(normalized) or
      case :inet.parse_address(to_charlist(normalized)) do
        {:ok, addr} -> private_address?(addr)
        {:error, _} -> false
      end
  end

  def literal_internal_host?(_), do: false

  @doc "Convenience boolean wrapper over `check/1`."
  @spec safe?(String.t()) :: boolean()
  def safe?(url), do: check(url) == :ok

  @doc """
  Validate `url` for SSRF safety. See the moduledoc for the full ruleset.

  Options:

    * `:resolver` — an `:inet.getaddrs/2`-shaped function. Defaults to
      `&:inet.getaddrs/2`; see the moduledoc's "resolver seam".
  """
  @spec check(String.t(), keyword()) :: result()
  def check(url, opts \\ [])

  def check(url, opts) when is_binary(url) and is_list(opts) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        check_host(host, Keyword.get(opts, :resolver, &:inet.getaddrs/2))

      _ ->
        {:error, :bad_url}
    end
  end

  def check(_, _), do: {:error, :bad_url}

  defp check_host(host, resolver) do
    normalized = host |> String.downcase() |> String.trim_trailing(".") |> strip_brackets()

    if blocked_name?(normalized),
      do: {:error, :ssrf_blocked},
      else: check_resolved(normalized, resolver)
  end

  defp blocked_name?(normalized) do
    normalized in @blocked_hosts or
      Enum.any?(@blocked_suffixes, &String.ends_with?(normalized, &1))
  end

  # IPv6 literals arrive bracketed in a URL host; strip so :inet can parse them.
  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  # If the host is itself an IP literal, check it directly; otherwise resolve over
  # both families and reject if ANY returned address is private/loopback/etc.
  defp check_resolved(host, resolver) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, addr} ->
        if private_address?(addr), do: {:error, :ssrf_blocked}, else: :ok

      {:error, _} ->
        resolve_and_check(host, resolver)
    end
  end

  defp resolve_and_check(host, resolver) do
    case resolve_public(host, resolver) do
      {:ok, _addrs} -> :ok
      {:error, _} = error -> error
    end
  end

  # Resolve over both families (v4 first) and return EVERY address, or refuse
  # if any one is private. `pin/2` connects to the head of this list.
  defp resolve_public(host, resolver) do
    charlist = to_charlist(host)

    addrs =
      Enum.flat_map([:inet, :inet6], fn family ->
        case resolver.(charlist, family) do
          {:ok, list} -> list
          {:error, _} -> []
        end
      end)

    cond do
      addrs == [] -> {:error, :unresolvable}
      Enum.any?(addrs, &private_address?/1) -> {:error, :ssrf_blocked}
      true -> {:ok, addrs}
    end
  end

  @doc """
  Check `url` like `check/2`, then PIN it: return request coordinates that
  connect to the exact address the check approved (task-b771deef208d93e0).

  `check/2` alone resolves, approves, and hands the NAME to the HTTP client,
  which resolves it AGAIN at connect time. A short-TTL name can answer a public
  address to the check and `169.254.169.254` to the connect (DNS rebinding).
  `pin/2` closes that window: `:url` carries the approved IP literal, `:host` is
  the original `Host` header value, and `:server_name` is the TLS SNI and
  certificate-hostname reference, so the receiver still sees (and TLS still
  verifies) the name the operator saved.

  An IP-literal host needs no pin: it comes back unchanged with `:host` and
  `:server_name` nil.
  """
  @spec pin(String.t(), keyword()) ::
          {:ok, %{url: String.t(), host: String.t() | nil, server_name: String.t() | nil}}
          | {:error, :ssrf_blocked | :bad_url | :unresolvable}
  def pin(url, opts \\ [])

  def pin(url, opts) when is_binary(url) and is_list(opts) do
    resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)

    # ONE resolution: the addresses checked are the addresses connected to.
    # Everything `check/2` refuses before resolving is refused here too.
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        normalized = host |> String.downcase() |> String.trim_trailing(".") |> strip_brackets()

        cond do
          blocked_name?(normalized) ->
            {:error, :ssrf_blocked}

          match?({:ok, _}, :inet.parse_address(to_charlist(normalized))) ->
            with :ok <- check_resolved(normalized, resolver),
                 do: {:ok, %{url: url, host: nil, server_name: nil}}

          true ->
            with {:ok, [addr | _]} <- resolve_public(normalized, resolver) do
              {:ok,
               %{
                 url: URI.to_string(%URI{uri | host: ip_host(addr)}),
                 host: host_header(uri),
                 server_name: normalized
               }}
            end
        end

      _ ->
        {:error, :bad_url}
    end
  end

  def pin(_, _), do: {:error, :bad_url}

  # URI.to_string/1 brackets an IPv6 host itself.
  defp ip_host(addr), do: addr |> :inet.ntoa() |> to_string()

  defp host_header(%URI{scheme: scheme, host: host, port: port}) do
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  @doc """
  True when `addr` (an `:inet.ip_address` tuple) is in a private, loopback,
  link-local, ULA, unspecified, or cloud-metadata range — i.e. NOT a safe public
  destination. Public function so it is directly unit-testable.
  """
  @spec private_address?(:inet.ip_address()) :: boolean()
  def private_address?({a, b, c, _d}) do
    cond do
      a == 127 -> true
      a == 10 -> true
      a == 0 -> true
      a == 172 and b in 16..31 -> true
      a == 192 and b == 168 -> true
      # 169.254.0.0/16 link-local — includes 169.254.169.254 cloud metadata.
      a == 169 and b == 254 -> true
      # 100.64.0.0/10 carrier-grade NAT.
      a == 100 and b in 64..127 -> true
      # 192.0.0.0/24 IETF protocol assignments; 198.18.0.0/15 benchmarking.
      # Both are routed inside some provider networks (task-b771deef208d93e0).
      a == 192 and b == 0 and c == 0 -> true
      a == 198 and b in 18..19 -> true
      # 224.0.0.0/4 multicast, 240.0.0.0/4 reserved and broadcast.
      a >= 224 -> true
      true -> false
    end
  end

  def private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # ::1 loopback
  def private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # ::ffff:a.b.c.d — IPv4-mapped IPv6; unwrap and re-check the v4 address.
  def private_address?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    private_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # ::a.b.c.d — deprecated IPv4-compatible IPv6. Unwrap it like the mapped form.
  def private_address?({0, 0, 0, 0, 0, 0, g, h}) do
    private_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # 64:ff9b::/96 NAT64. A DNS64 resolver hands this out for an IPv4-only name,
  # and the gateway connects to the embedded v4 address. Unwrap it.
  def private_address?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}) do
    private_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # 2002::/16 6to4. The v4 address rides in the next 32 bits. Unwrap it.
  def private_address?({0x2002, g, h, _, _, _, _, _}) do
    private_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  # 64:ff9b:1::/48 local-use NAT64 (RFC 8215). It is internal to the local
  # translator and never a public destination (task-a30c403aea77a679; the api's
  # SafeOutbound refuses it too).
  def private_address?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true

  def private_address?({first, _, _, _, _, _, _, _}) do
    cond do
      # ff00::/8 multicast
      Bitwise.band(first, 0xFF00) == 0xFF00 -> true
      # fc00::/7 unique-local
      Bitwise.band(first, 0xFE00) == 0xFC00 -> true
      # fe80::/10 link-local
      Bitwise.band(first, 0xFFC0) == 0xFE80 -> true
      true -> false
    end
  end

  def private_address?(_), do: false
end
