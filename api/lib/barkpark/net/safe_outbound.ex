defmodule Barkpark.Net.SafeOutbound do
  @moduledoc """
  SSRF guard for tenant-influenced outbound HTTP.

  Webhook URLs (and the media/CDN config-sourced siblings) are attacker-shaped
  input on the shared cloud hosts. Left unguarded, a tenant can point a webhook
  at `http://169.254.169.254/` (cloud metadata), loopback, or an RFC1918 host and
  read internal reachability out of the delivery status — blind SSRF + internal
  port-scan. This module resolves the target host and refuses any request whose
  DNS answer lands on a loopback / private / link-local / CGNAT / unspecified /
  multicast address (in either IPv4 or IPv6, including IPv4-mapped IPv6 forms),
  and drives every request with `redirect: false` so a 302-to-internal cannot
  smuggle the destination past the check.

  `check_url/1` is pure (`:ok | {:error, reason}`); `ip_allowed?/1` classifies a
  single `:inet.ip_address` tuple with no DNS so the ruleset is unit-testable.

  A config escape hatch `:allow_private_outbound` (default `false`) is set `true`
  in dev/test so Bypass-at-127.0.0.1 fixtures keep working; prod/runtime leaves
  it false.
  """

  import Bitwise

  @schemes ~w(http https)

  @doc """
  Validates `url` for outbound delivery. Returns `:ok`, or `{:error, reason}`
  where reason is one of `:invalid_url`, `:invalid_scheme`, `:missing_host`,
  `:userinfo_not_allowed`, `:unresolvable`, or `{:blocked_address, ip}`.

  Host resolution (and the address classification) is skipped when
  `:allow_private_outbound` is enabled; the scheme/host/userinfo checks always run.
  """
  @spec check_url(term()) :: :ok | {:error, term()}
  def check_url(url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         :ok <- validate_userinfo(uri) do
      validate_destination(uri.host)
    end
  end

  def check_url(_), do: {:error, :invalid_url}

  @doc """
  Runs `check_url/1`, then `Req.post/2` with `redirect: false` forced on.
  Returns `{:error, {:ssrf_blocked, reason}}` with NO network call when the
  URL is refused; otherwise returns whatever `Req.post/2` returns.
  """
  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post(url, opts \\ []) do
    case check_url(url) do
      :ok -> Req.post(url, Keyword.put(opts, :redirect, false))
      {:error, reason} -> {:error, {:ssrf_blocked, reason}}
    end
  end

  @doc """
  Classifies a resolved `:inet.ip_address` tuple. Returns `false` for any
  loopback / unspecified / private / link-local / CGNAT / multicast / reserved
  address (IPv4, IPv6, or an IPv4-mapped IPv6 `::ffff:a.b.c.d`), `true` for a
  routable public address.
  """
  @spec ip_allowed?(:inet.ip_address()) :: boolean()
  def ip_allowed?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not ipv4_blocked?(a, b)
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — unwrap the low 32 bits and re-check as IPv4.
  def ip_allowed?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    ip_allowed?({g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF})
  end

  def ip_allowed?({a, b, c, d, e, f, g, h} = addr)
      when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
             e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF do
    not ipv6_blocked?(addr)
  end

  def ip_allowed?(_), do: false

  # --- internals ---

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _} -> {:error, :invalid_url}
    end
  end

  defp validate_scheme(%URI{scheme: s}) when s in @schemes, do: :ok
  defp validate_scheme(_), do: {:error, :invalid_scheme}

  defp validate_host(%URI{host: h}) when is_binary(h) and h != "", do: :ok
  defp validate_host(_), do: {:error, :missing_host}

  defp validate_userinfo(%URI{userinfo: nil}), do: :ok
  defp validate_userinfo(_), do: {:error, :userinfo_not_allowed}

  defp validate_destination(host) do
    if allow_private_outbound?() do
      :ok
    else
      with {:ok, addrs} <- resolve(host) do
        check_addrs(addrs)
      end
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    addrs =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, list} -> list
          {:error, _} -> []
        end
      end)

    case addrs do
      [] -> {:error, :unresolvable}
      _ -> {:ok, addrs}
    end
  end

  defp check_addrs(addrs) do
    Enum.reduce_while(addrs, :ok, fn addr, _acc ->
      if ip_allowed?(addr) do
        {:cont, :ok}
      else
        {:halt, {:error, {:blocked_address, addr}}}
      end
    end)
  end

  # IPv4 classification keyed on the first two octets.
  defp ipv4_blocked?(a, b) do
    cond do
      # 0.0.0.0/8 unspecified / this-network
      a == 0 -> true
      # 127.0.0.0/8 loopback
      a == 127 -> true
      # 10.0.0.0/8 private
      a == 10 -> true
      # 172.16.0.0/12 private
      a == 172 and b in 16..31 -> true
      # 192.168.0.0/16 private
      a == 192 and b == 168 -> true
      # 169.254.0.0/16 link-local (incl. metadata IP)
      a == 169 and b == 254 -> true
      # 100.64.0.0/10 CGNAT
      a == 100 and b in 64..127 -> true
      # 224.0.0.0/4 multicast
      a in 224..239 -> true
      # 240.0.0.0/4 reserved + 255.255.255.255 broadcast
      a >= 240 -> true
      true -> false
    end
  end

  defp ipv6_blocked?({a, _, _, _, _, _, _, _} = addr) do
    cond do
      # :: unspecified
      addr == {0, 0, 0, 0, 0, 0, 0, 0} -> true
      # ::1 loopback
      addr == {0, 0, 0, 0, 0, 0, 0, 1} -> true
      # fc00::/7 unique-local
      (a &&& 0xFE00) == 0xFC00 -> true
      # fe80::/10 link-local
      (a &&& 0xFFC0) == 0xFE80 -> true
      # ff00::/8 multicast
      (a &&& 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end

  defp allow_private_outbound? do
    Application.get_env(:barkpark, :allow_private_outbound, false)
  end
end
