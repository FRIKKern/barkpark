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

    cond do
      normalized in @blocked_hosts ->
        {:error, :ssrf_blocked}

      Enum.any?(@blocked_suffixes, &String.ends_with?(normalized, &1)) ->
        {:error, :ssrf_blocked}

      true ->
        check_resolved(normalized, resolver)
    end
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
      true -> :ok
    end
  end

  @doc """
  True when `addr` (an `:inet.ip_address` tuple) is in a private, loopback,
  link-local, ULA, unspecified, or cloud-metadata range — i.e. NOT a safe public
  destination. Public function so it is directly unit-testable.
  """
  @spec private_address?(:inet.ip_address()) :: boolean()
  def private_address?({a, b, _c, _d}) do
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

  def private_address?({first, _, _, _, _, _, _, _}) do
    cond do
      # fc00::/7 unique-local
      Bitwise.band(first, 0xFE00) == 0xFC00 -> true
      # fe80::/10 link-local
      Bitwise.band(first, 0xFFC0) == 0xFE80 -> true
      true -> false
    end
  end

  def private_address?(_), do: false
end
