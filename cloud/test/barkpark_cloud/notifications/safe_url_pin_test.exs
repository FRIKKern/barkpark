defmodule BarkparkCloud.Notifications.SafeUrlPinTest do
  @moduledoc """
  task-b771deef208d93e0: team notification webhooks (discord / slack / webhook)
  were checked by resolving the name, then handed to `:httpc` BY NAME, which
  resolved it again at connect time. A short-TTL name could answer a public
  address to the check and 169.254.169.254 to the connect (DNS rebinding).

  `SafeUrl.pin/2` resolves ONCE and returns the approved IP literal, the Host
  header and the TLS server name; `Billing.HttpClient` turns `:server_name` into
  ssl `server_name_indication`, which ssl also uses for the certificate hostname
  check. The private-range list also gained the ranges the api side's
  SafeOutbound already refuses.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Billing.HttpClient
  alias BarkparkCloud.Notifications.SafeUrl

  # A rebinding resolver: the FIRST lookup per family answers a public address,
  # every later one answers the cloud-metadata address.
  defp rebinding_resolver do
    counter = :counters.new(1, [])

    fn _host, family ->
      :counters.add(counter, 1, 1)

      cond do
        family == :inet6 -> {:error, :nxdomain}
        :counters.get(counter, 1) <= 2 -> {:ok, [{203, 0, 113, 9}]}
        true -> {:ok, [{169, 254, 169, 254}]}
      end
    end
  end

  describe "pin/2" do
    test "connects to the address the check approved, even when the name rebinds" do
      assert {:ok, pinned} =
               SafeUrl.pin("https://hooks.example.test/api/x?wait=true",
                 resolver: rebinding_resolver()
               )

      assert pinned.url == "https://203.0.113.9/api/x?wait=true"
      assert pinned.host == "hooks.example.test"
      assert pinned.server_name == "hooks.example.test"
    end

    test "a non-default port rides in the Host header" do
      resolver = fn
        _h, :inet -> {:ok, [{203, 0, 113, 9}]}
        _h, :inet6 -> {:error, :nxdomain}
      end

      assert {:ok, pinned} = SafeUrl.pin("https://hooks.example.test:8443/x", resolver: resolver)
      assert pinned.url == "https://203.0.113.9:8443/x"
      assert pinned.host == "hooks.example.test:8443"
    end

    test "an IPv6-only name pins to a bracketed literal" do
      resolver = fn
        _h, :inet -> {:error, :nxdomain}
        _h, :inet6 -> {:ok, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}]}
      end

      assert {:ok, pinned} = SafeUrl.pin("https://v6.example.test/x", resolver: resolver)
      assert pinned.url == "https://[2001:db8::9]/x"
    end

    test "an IP literal comes back unchanged and unpinned" do
      assert {:ok, %{url: "https://203.0.113.11/x", host: nil, server_name: nil}} =
               SafeUrl.pin("https://203.0.113.11/x")
    end

    test "a name resolving to a private address is refused" do
      resolver = fn
        _h, :inet -> {:ok, [{10, 0, 0, 5}]}
        _h, :inet6 -> {:error, :nxdomain}
      end

      assert {:error, :ssrf_blocked} =
               SafeUrl.pin("https://evil.example.test/x", resolver: resolver)
    end
  end

  describe "private_address?/1 — the ranges SafeOutbound already refuses" do
    test "NAT64, IPv4-compatible and 6to4 unwrap to the embedded v4 address" do
      # 64:ff9b::a9fe:a9fe = NAT64 of 169.254.169.254
      assert SafeUrl.private_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE})
      # ::10.0.0.1 (IPv4-compatible)
      assert SafeUrl.private_address?({0, 0, 0, 0, 0, 0, 0x0A00, 0x0001})
      # 2002:7f00:0001:: = 6to4 of 127.0.0.1
      assert SafeUrl.private_address?({0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0})
      # NAT64 of a public address stays public
      refute SafeUrl.private_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0xCB00, 0x7109})
    end

    test "benchmarking, protocol-assignment, multicast and reserved v4 ranges" do
      assert SafeUrl.private_address?({198, 18, 0, 1})
      assert SafeUrl.private_address?({198, 19, 255, 254})
      assert SafeUrl.private_address?({192, 0, 0, 170})
      assert SafeUrl.private_address?({224, 0, 0, 1})
      assert SafeUrl.private_address?({240, 0, 0, 1})
      assert SafeUrl.private_address?({255, 255, 255, 255})
      assert SafeUrl.private_address?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
      refute SafeUrl.private_address?({198, 20, 0, 1})
      refute SafeUrl.private_address?({192, 0, 2, 1})
    end

    test "a save-time check refuses a NAT64 literal of the metadata address" do
      assert {:error, :ssrf_blocked} = SafeUrl.check("https://[64:ff9b::a9fe:a9fe]/x")
    end
  end

  describe "HttpClient carries the pin to TLS" do
    test ":server_name becomes ssl server_name_indication" do
      req = %{
        method: :post,
        url: "https://203.0.113.9/x",
        headers: [{"Host", "hooks.example.test"}, {"Content-Type", "application/json"}],
        body: "{}",
        server_name: "hooks.example.test"
      }

      {{url, headers, _ct, _body}, http_opts, _opts} = HttpClient.to_httpc(req)
      assert url == ~c"https://203.0.113.9/x"
      assert {~c"Host", ~c"hooks.example.test"} in headers
      assert Keyword.fetch!(http_opts, :ssl)[:server_name_indication] == ~c"hooks.example.test"
      assert Keyword.fetch!(http_opts, :ssl)[:verify] == :verify_peer
    end

    test "an unpinned request sets no SNI override" do
      req = %{method: :post, url: "https://api.stripe.com/v1/x", headers: [], body: ""}
      {_arg, http_opts, _opts} = HttpClient.to_httpc(req)
      refute Keyword.has_key?(Keyword.fetch!(http_opts, :ssl), :server_name_indication)
    end
  end
end
