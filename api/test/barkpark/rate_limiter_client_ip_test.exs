defmodule Barkpark.RateLimiterClientIpTest do
  @moduledoc """
  The TRUST BOUNDARY for `x-forwarded-for` on every IP-keyed rate bucket
  (`Barkpark.RateLimiter.client_ip/1`).

  A per-IP bucket is only a limit if the client cannot choose its own key. The
  inherited idiom — read the FIRST `x-forwarded-for` hop, else the peer — failed
  that: Caddy APPENDS to whatever the caller sent, so a request reaching the box
  directly with `x-forwarded-for: 9.9.9.9` keyed on `9.9.9.9` and could rotate
  that per request. The header became load-bearing when the Cloud control plane
  started relaying the caller's address on the revoke DELETE (#6224), which is
  why the boundary is drawn once, here, for every bucket.

  PROTECTIVE, not vacuous — the mutation that flips this suite RED, in the exact
  words of the code it replaced:

      defp client_ip(conn) do
        case get_req_header(conn, "x-forwarded-for") do
          [forwarded | _] -> forwarded |> String.split(",") |> hd() |> String.trim()
          [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
        end
      end

  Substitute that first-hop read for `client_ip/1` and every "spoof" test below
  fails: "a spoofed chain from an untrusted peer is IGNORED" starts returning the
  forged address, and "two forged headers from one untrusted peer share ONE
  bucket" starts handing out a fresh bucket per forgery (`:ok`, not
  `:rate_limited`). Weakening only the peer guard (trust the chain from anyone)
  fails the same tests; weakening only the chain walk (leftmost instead of
  rightmost) fails "a caller-supplied PREFIX behind our own front is discarded".

  `async: false`: the suite moves the global `:trusted_proxies` config and shares
  the process-global `RateLimiter` ETS table (bucket keys below are made unique
  per test, so no sibling file can race a verdict).
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  import Plug.Test, only: [conn: 3]

  alias Barkpark.RateLimiter

  # A public, routable address standing in for a caller that reached the box
  # directly — NOT loopback, NOT in the allowlist, so its header carries no
  # authority whatsoever.
  @direct_peer {203, 0, 113, 66}

  # The Barkpark Cloud control plane's egress address in the fixtures below: the
  # one non-loopback front an operator would list in BARKPARK_TRUSTED_PROXIES.
  @relay_ip "198.51.100.55"
  @relay_tuple {198, 51, 100, 55}

  setup do
    original = Application.get_env(:barkpark, :trusted_proxies)
    on_exit(fn -> Application.put_env(:barkpark, :trusted_proxies, original || []) end)
    :ok
  end

  defp trust!(addresses), do: Application.put_env(:barkpark, :trusted_proxies, addresses)

  defp request(peer, forwarded_values) do
    Enum.reduce(forwarded_values, %{conn(:get, "/", nil) | remote_ip: peer}, fn value, acc ->
      Plug.Conn.put_req_header(acc, "x-forwarded-for", value)
    end)
  end

  # put_req_header REPLACES, so a genuinely repeated header (legal in HTTP, and
  # what a chain of proxies that each add their own line produces) is built here.
  defp request_with_repeated_header(peer, values) do
    %{conn(:get, "/", nil) | remote_ip: peer}
    |> Map.update!(:req_headers, fn headers ->
      headers ++ Enum.map(values, &{"x-forwarded-for", &1})
    end)
  end

  # capacity: 1 → the first check consumes the bucket, so a SECOND :ok proves a
  # DIFFERENT key was used and a :rate_limited proves the SAME one. refill 0.0
  # freezes the bucket for the life of the test.
  defp spend(client, tag), do: RateLimiter.check({tag, client}, capacity: 1, refill_per_sec: 0.0)

  describe "an untrusted peer's header carries no authority" do
    test "a spoofed chain from an untrusted peer is IGNORED — the peer is the key" do
      assert RateLimiter.client_ip(request(@direct_peer, ["9.9.9.9"])) == "203.0.113.66"
    end

    test "no chain length or shape lets an untrusted peer move its own key" do
      for forged <- [
            ["9.9.9.9"],
            ["9.9.9.9, 8.8.8.8"],
            ["2001:db8::99"],
            # its own address, then a forgery appended to the right
            ["203.0.113.66, 9.9.9.9"],
            # a loopback prefix, betting the resolver skips trusted hops blindly
            ["127.0.0.1, 9.9.9.9"],
            # nothing but trusted-looking hops, betting on a fall-through
            ["127.0.0.1, ::1"]
          ] do
        assert RateLimiter.client_ip(request(@direct_peer, forged)) == "203.0.113.66",
               "an untrusted peer moved its bucket key with #{inspect(forged)}"
      end
    end

    test "a repeated x-forwarded-for header from an untrusted peer is ignored too" do
      conn = request_with_repeated_header(@direct_peer, ["9.9.9.9", "8.8.8.8"])
      assert RateLimiter.client_ip(conn) == "203.0.113.66"
    end
  end

  describe "behind our own front (loopback peer — Caddy dials localhost)" do
    test "the relayed caller IP is the key" do
      assert RateLimiter.client_ip(request({127, 0, 0, 1}, ["203.0.113.7"])) == "203.0.113.7"
    end

    test "a caller-supplied PREFIX behind our own front is discarded — Caddy appends" do
      # The direct attacker's real address is what Caddy appended at the RIGHT
      # end; the forged left-hand hop is exactly what must not win.
      conn = request({127, 0, 0, 1}, ["9.9.9.9, 203.0.113.66"])
      assert RateLimiter.client_ip(conn) == "203.0.113.66"
    end

    test "no header at all → the peer" do
      assert RateLimiter.client_ip(request({127, 0, 0, 1}, [])) == "127.0.0.1"
      assert RateLimiter.client_ip(request({0, 0, 0, 0, 0, 0, 0, 1}, [])) == "::1"
    end

    test "an IPv4-mapped loopback peer (dual-stack listener) is still our front" do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
      assert RateLimiter.client_ip(request(mapped, [])) == "127.0.0.1"
      assert RateLimiter.client_ip(request(mapped, ["203.0.113.7"])) == "203.0.113.7"
    end
  end

  describe "the allowlist (BARKPARK_TRUSTED_PROXIES)" do
    test "an appended chain from a LISTED relay still keys on the ORIGINAL first hop" do
      trust!([@relay_tuple])

      # The shape of every cloud-proxied revoke: the control plane relays the
      # phone's address, our Caddy appends the control plane's egress.
      conn = request({127, 0, 0, 1}, ["203.0.113.7, #{@relay_ip}"])
      assert RateLimiter.client_ip(conn) == "203.0.113.7"
    end

    test "a LISTED relay is also trusted as the immediate PEER" do
      trust!([@relay_tuple])
      assert RateLimiter.client_ip(request(@relay_tuple, ["203.0.113.7"])) == "203.0.113.7"
    end

    test "an UNLISTED relay is disbelieved: its own address becomes the key" do
      # Not a regression but the honest cost of the boundary — the pre-relay
      # collapse (one bucket for the whole team) until the operator lists the
      # egress address. Never a forgery.
      conn = request({127, 0, 0, 1}, ["203.0.113.7, #{@relay_ip}"])
      assert RateLimiter.client_ip(conn) == @relay_ip
    end

    test "an UNLISTED peer stays untrusted even when the same address is a chain hop" do
      conn = request(@relay_tuple, ["203.0.113.7, #{@relay_ip}"])
      assert RateLimiter.client_ip(conn) == @relay_ip
    end
  end

  describe "canonical keys (one address must never buy two budgets)" do
    test "alternate spellings of one hop collapse to ONE key" do
      for spelling <- [
            "2001:0db8:0000:0000:0000:0000:0000:0001",
            "2001:db8::1",
            "[2001:db8::1]"
          ] do
        assert RateLimiter.client_ip(request({127, 0, 0, 1}, [spelling])) == "2001:db8::1",
               "spelling #{spelling} keyed its own bucket"
      end
    end

    test "a short-form IPv4 hop is normalised, so loopback-in-short-form is still skipped" do
      assert RateLimiter.client_ip(request({127, 0, 0, 1}, ["127.1"])) == "127.0.0.1"
      assert RateLimiter.client_ip(request({127, 0, 0, 1}, ["9.9.9.9, 127.1"])) == "9.9.9.9"
    end

    test "an IPv4-mapped hop keys the same bucket as its plain v4 form" do
      a = RateLimiter.client_ip(request({127, 0, 0, 1}, ["::ffff:203.0.113.7"]))
      b = RateLimiter.client_ip(request({127, 0, 0, 1}, ["203.0.113.7"]))
      assert a == "203.0.113.7"
      assert a == b
    end
  end

  describe "malformed chains fail closed onto the verified peer" do
    test "a hop that is not an address at all falls back to the peer" do
      for junk <- ["unknown", "not-an-ip", "203.0.113.7:9999", "", "   "] do
        conn = request({127, 0, 0, 1}, ["9.9.9.9, #{junk}"])

        assert RateLimiter.client_ip(conn) in ["127.0.0.1", "9.9.9.9"],
               "junk hop #{inspect(junk)} produced an unexpected key"
      end

      # Specifically: a rightmost hop we cannot verify never lets the forged
      # left-hand hop through.
      assert RateLimiter.client_ip(request({127, 0, 0, 1}, ["9.9.9.9, not-an-ip"])) == "127.0.0.1"
    end

    test "an obfuscated (RFC 7239 style) token is not mistaken for an address" do
      conn = request({127, 0, 0, 1}, ["9.9.9.9, _hidden"])
      assert RateLimiter.client_ip(conn) == "127.0.0.1"
    end
  end

  describe "the bucket itself (the boundary in the limiter's own currency)" do
    setup do
      %{tag: {:client_ip_boundary_test, System.unique_integer([:positive])}}
    end

    test "two forged headers from ONE untrusted peer share ONE bucket", %{tag: tag} do
      first = RateLimiter.client_ip(request(@direct_peer, ["9.9.9.9"]))
      second = RateLimiter.client_ip(request(@direct_peer, ["8.8.8.8"]))

      assert first == second
      assert spend(first, tag) == :ok
      # Under the first-hop read this was a fresh bucket per forgery, i.e. no
      # limit at all — the whole point of the boundary.
      assert spend(second, tag) == :rate_limited
    end

    test "an untrusted peer cannot escape the bucket it already spent", %{tag: tag} do
      assert spend(RateLimiter.client_ip(request(@direct_peer, [])), tag) == :ok

      for forged <- ["9.9.9.9", "8.8.8.8", "203.0.113.1, 9.9.9.9", "127.0.0.1"] do
        client = RateLimiter.client_ip(request(@direct_peer, [forged]))

        assert spend(client, tag) == :rate_limited,
               "forging #{forged} bought a fresh bucket"
      end
    end

    test "two genuine callers behind a LISTED relay keep SEPARATE buckets", %{tag: tag} do
      trust!([@relay_tuple])

      phone_a = RateLimiter.client_ip(request({127, 0, 0, 1}, ["203.0.113.7, #{@relay_ip}"]))
      phone_b = RateLimiter.client_ip(request({127, 0, 0, 1}, ["198.51.100.9, #{@relay_ip}"]))

      assert phone_a != phone_b
      assert spend(phone_a, tag) == :ok
      assert spend(phone_a, tag) == :rate_limited
      # Phone A exhausting its allowance leaves its teammate untouched — the
      # per-phone bucketing #6224 bought must survive the boundary.
      assert spend(phone_b, tag) == :ok
    end
  end
end
