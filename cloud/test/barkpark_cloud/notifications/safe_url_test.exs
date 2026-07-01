defmodule BarkparkCloud.Notifications.SafeUrlTest do
  use ExUnit.Case, async: true

  alias BarkparkCloud.Notifications.SafeUrl

  describe "check/1 blocks SSRF targets" do
    test "literal internal hosts" do
      for url <- [
            "http://localhost/hook",
            "http://localhost:9000/hook",
            "http://foo.internal/hook",
            "http://db.local/hook",
            "http://0.0.0.0/hook"
          ] do
        assert SafeUrl.check(url) == {:error, :ssrf_blocked}, "expected #{url} blocked"
      end
    end

    test "private / loopback / link-local IPv4 literals" do
      for url <- [
            "http://127.0.0.1/hook",
            "http://10.0.0.5/hook",
            "http://172.16.3.4/hook",
            "http://192.168.1.1/hook",
            # 169.254.169.254 — the cloud metadata endpoint.
            "http://169.254.169.254/latest/meta-data"
          ] do
        assert SafeUrl.check(url) == {:error, :ssrf_blocked}, "expected #{url} blocked"
      end
    end

    test "IPv6 loopback and link-local literals" do
      assert SafeUrl.check("http://[::1]/hook") == {:error, :ssrf_blocked}
      assert SafeUrl.check("http://[fe80::1]/hook") == {:error, :ssrf_blocked}
      assert SafeUrl.check("http://[fc00::1]/hook") == {:error, :ssrf_blocked}
    end

    test "non-http schemes and malformed URLs are rejected" do
      assert SafeUrl.check("ftp://example.com") == {:error, :bad_url}
      assert SafeUrl.check("file:///etc/passwd") == {:error, :bad_url}
      assert SafeUrl.check("not a url") == {:error, :bad_url}
      assert SafeUrl.check(nil) == {:error, :bad_url}
    end
  end

  describe "check/1 allows legitimate public provider URLs" do
    test "public hostnames resolve to public IPs and pass" do
      # These resolve to real public addresses; the resolve-then-check passes.
      assert SafeUrl.check("https://discord.com/api/webhooks/1/x") == :ok
      assert SafeUrl.check("https://hooks.slack.com/services/T/B/X") == :ok
    end

    test "a public IPv4 literal passes" do
      assert SafeUrl.check("https://1.1.1.1/hook") == :ok
    end
  end

  describe "private_address?/1 (the resolve-then-check core)" do
    test "classifies IPv4 ranges" do
      assert SafeUrl.private_address?({127, 0, 0, 1})
      assert SafeUrl.private_address?({10, 1, 2, 3})
      assert SafeUrl.private_address?({172, 16, 0, 1})
      assert SafeUrl.private_address?({172, 31, 255, 255})
      assert SafeUrl.private_address?({192, 168, 0, 1})
      assert SafeUrl.private_address?({169, 254, 169, 254})
      refute SafeUrl.private_address?({1, 1, 1, 1})
      refute SafeUrl.private_address?({8, 8, 8, 8})
      # 172.32 is OUTSIDE the 172.16/12 private block.
      refute SafeUrl.private_address?({172, 32, 0, 1})
    end

    test "classifies IPv6 ranges, including IPv4-mapped" do
      assert SafeUrl.private_address?({0, 0, 0, 0, 0, 0, 0, 1})
      assert SafeUrl.private_address?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert SafeUrl.private_address?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      # ::ffff:127.0.0.1 — IPv4-mapped loopback must be unwrapped and blocked.
      assert SafeUrl.private_address?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      refute SafeUrl.private_address?({0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888})
    end
  end
end
