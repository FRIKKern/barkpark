defmodule BarkparkWeb.Plugs.PaperReaderCspTest do
  @moduledoc """
  Unit locks for the layer-2 paper-reader CSP plug. Pure conn plumbing (no DB):
  proves the SELF-GATING that keeps the shared `:public_root` bucket safe —
  the policy hits the paper reader paths and NOTHING else (sheets/quiz/share/
  the /email sub-route), which is the whole risk of shipping this backstop.
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias BarkparkWeb.Plugs.PaperReaderCsp

  defp run(path_info) do
    %Plug.Conn{}
    |> Map.put(:path_info, path_info)
    |> PaperReaderCsp.call([])
  end

  defp csp(conn), do: get_resp_header(conn, "content-security-policy")

  describe "emits the policy ONLY on paper reader paths" do
    test "flat /papers/:slug" do
      conn = run(["papers", "my-paper"])
      assert [policy] = csp(conn)
      assert policy =~ "script-src 'self' 'nonce-"
      assert policy =~ "'wasm-unsafe-eval'"
      assert policy =~ "'unsafe-eval'"
      assert policy =~ "https://cdn.jsdelivr.net"
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"
      # crucially NOT unsafe-inline — that would re-open inline injection.
      refute policy =~ "'unsafe-inline'"
      # the nonce is assigned for the layout to stamp on its inline scripts.
      assert is_binary(conn.assigns.csp_nonce)
      assert policy =~ "'nonce-#{conn.assigns.csp_nonce}'"
    end

    test "dataset-prefixed /d/:dataset/papers/:slug" do
      conn = run(["d", "production", "papers", "my-paper"])
      assert [_policy] = csp(conn)
      assert is_binary(conn.assigns.csp_nonce)
    end

    test "workspace/project-scoped /w/:ws/p/:proj/papers/:slug" do
      conn = run(["w", "default", "p", "default", "papers", "my-paper"])
      assert [_policy] = csp(conn)
      assert is_binary(conn.assigns.csp_nonce)
    end
  end

  describe "is a pure no-op on the shared-bucket siblings + sub-routes" do
    test "the /email sub-route (own layout, no inline reader scripts)" do
      conn = run(["papers", "my-paper", "email"])
      assert csp(conn) == []
      refute Map.has_key?(conn.assigns, :csp_nonce)
    end

    test "the sheets reader /sheets/:slug" do
      conn = run(["sheets", "my-sheet"])
      assert csp(conn) == []
      refute Map.has_key?(conn.assigns, :csp_nonce)
    end

    test "the quiz readers /quiz/host/:pin and /quiz/play/:pin" do
      assert run(["quiz", "host", "1234"]) |> csp() == []
      assert run(["quiz", "play", "1234"]) |> csp() == []
    end

    test "the share reader /s/:token" do
      conn = run(["s", "sometoken"])
      assert csp(conn) == []
    end

    test "the bare root /" do
      conn = run([])
      assert csp(conn) == []
    end
  end

  describe "nonce" do
    test "is freshly generated per request (not reused)" do
      n1 = run(["papers", "a"]).assigns.csp_nonce
      n2 = run(["papers", "b"]).assigns.csp_nonce
      assert n1 != n2
    end

    test "policy/1 renders the exact directive order for a given nonce" do
      assert PaperReaderCsp.policy("ABC123") ==
               "script-src 'self' 'nonce-ABC123' 'wasm-unsafe-eval' 'unsafe-eval' " <>
                 "https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; " <>
                 "frame-ancestors 'self'"
    end
  end
end
