defmodule Barkpark.Net.SafeOutboundTest do
  use ExUnit.Case, async: false

  alias Barkpark.Net.SafeOutbound

  describe "ip_allowed?/1 (pure classification, no DNS)" do
    test "rejects IPv4 loopback / private / link-local / CGNAT / unspecified" do
      refute SafeOutbound.ip_allowed?({127, 0, 0, 1})
      refute SafeOutbound.ip_allowed?({10, 0, 0, 1})
      refute SafeOutbound.ip_allowed?({172, 16, 0, 1})
      refute SafeOutbound.ip_allowed?({192, 168, 1, 1})
      refute SafeOutbound.ip_allowed?({169, 254, 169, 254})
      refute SafeOutbound.ip_allowed?({100, 64, 0, 1})
      refute SafeOutbound.ip_allowed?({0, 0, 0, 0})
    end

    test "allows routable public IPv4" do
      assert SafeOutbound.ip_allowed?({93, 184, 216, 34})
      assert SafeOutbound.ip_allowed?({1, 1, 1, 1})
      assert SafeOutbound.ip_allowed?({8, 8, 8, 8})
    end

    test "rejects IPv6 loopback / unspecified / ULA / link-local" do
      refute SafeOutbound.ip_allowed?({0, 0, 0, 0, 0, 0, 0, 1})
      refute SafeOutbound.ip_allowed?({0, 0, 0, 0, 0, 0, 0, 0})
      refute SafeOutbound.ip_allowed?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      refute SafeOutbound.ip_allowed?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      refute SafeOutbound.ip_allowed?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
    end

    test "unwraps IPv4-mapped IPv6 and re-checks the embedded IPv4" do
      # ::ffff:127.0.0.1
      refute SafeOutbound.ip_allowed?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      # ::ffff:169.254.169.254
      refute SafeOutbound.ip_allowed?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      # ::ffff:8.8.8.8 (public) is allowed
      assert SafeOutbound.ip_allowed?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "allows routable public IPv6" do
      assert SafeOutbound.ip_allowed?({0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25C8, 0x1946})
    end
  end

  describe "check_url/1 shape validation" do
    test "rejects a missing host" do
      assert {:error, :missing_host} = SafeOutbound.check_url("http:///")
      assert {:error, :missing_host} = SafeOutbound.check_url("http://:9000")
    end

    test "rejects userinfo" do
      assert {:error, :userinfo_not_allowed} =
               SafeOutbound.check_url("https://user:pw@host.example")
    end

    test "rejects a non-http scheme" do
      assert {:error, :invalid_scheme} = SafeOutbound.check_url("ftp://host.example")
      assert {:error, :invalid_scheme} = SafeOutbound.check_url("file:///etc/passwd")
    end

    test "rejects non-string input" do
      assert {:error, :invalid_url} = SafeOutbound.check_url(nil)
      assert {:error, :invalid_url} = SafeOutbound.check_url(123)
    end
  end

  describe "check_url/1 destination resolution (guard active)" do
    setup do
      prev = Application.get_env(:barkpark, :allow_private_outbound)
      Application.put_env(:barkpark, :allow_private_outbound, false)
      on_exit(fn -> restore(:allow_private_outbound, prev) end)
      :ok
    end

    test "refuses internal literal IPs" do
      assert {:error, {:blocked_address, {127, 0, 0, 1}}} =
               SafeOutbound.check_url("http://127.0.0.1:4000/hook")

      assert {:error, {:blocked_address, {169, 254, 169, 254}}} =
               SafeOutbound.check_url("http://169.254.169.254/latest/meta-data/")

      assert {:error, {:blocked_address, {10, 0, 0, 1}}} =
               SafeOutbound.check_url("http://10.0.0.1/")

      assert {:error, {:blocked_address, _}} =
               SafeOutbound.check_url("http://[::1]/")
    end

    test "allows a public literal IP" do
      assert :ok = SafeOutbound.check_url("https://8.8.8.8/")
    end
  end

  describe "check_url/1 with the escape hatch on" do
    setup do
      prev = Application.get_env(:barkpark, :allow_private_outbound)
      Application.put_env(:barkpark, :allow_private_outbound, true)
      on_exit(fn -> restore(:allow_private_outbound, prev) end)
      :ok
    end

    test "permits loopback (skips resolution) but still enforces shape" do
      assert :ok = SafeOutbound.check_url("http://127.0.0.1:4000/hook")
      assert {:error, :missing_host} = SafeOutbound.check_url("http:///")
      assert {:error, :userinfo_not_allowed} = SafeOutbound.check_url("http://u:p@127.0.0.1/")
    end
  end

  describe "post/2" do
    setup do
      prev = Application.get_env(:barkpark, :allow_private_outbound)
      Application.put_env(:barkpark, :allow_private_outbound, false)
      on_exit(fn -> restore(:allow_private_outbound, prev) end)
      :ok
    end

    test "refuses a blocked URL with {:ssrf_blocked, _} and makes NO network call" do
      assert {:error, {:ssrf_blocked, {:blocked_address, {127, 0, 0, 1}}}} =
               SafeOutbound.post("http://127.0.0.1:4000/hook", body: "{}")
    end
  end

  defp restore(k, nil), do: Application.delete_env(:barkpark, k)
  defp restore(k, v), do: Application.put_env(:barkpark, k, v)
end
