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
      # crucially NOT unsafe-inline IN script-src — that would re-open inline
      # injection. Scoped to the script-src directive because `style-src` DOES
      # carry 'unsafe-inline' (unavoidable: the renderer stamps `style=`
      # attributes — see the plug's @moduledoc), and a whole-header refute
      # would silently conflate the two.
      refute policy =~ ~r/script-src[^;]*'unsafe-inline'/
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
               "default-src 'self'; " <>
                 "script-src 'self' 'nonce-ABC123' 'wasm-unsafe-eval' 'unsafe-eval' " <>
                 "https://cdn.jsdelivr.net; " <>
                 "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " <>
                 "img-src 'self' data: blob: https: http:; " <>
                 "media-src 'self' data: blob: https: http:; " <>
                 "font-src 'self' data:; " <>
                 "connect-src 'self' https: ws: wss:; " <>
                 "frame-src 'self'; object-src 'none'; base-uri 'self'; " <>
                 "form-action 'self'; frame-ancestors 'self'"
    end
  end

  describe "non-script directives (the markup-injection floor)" do
    setup do
      %{policy: PaperReaderCsp.policy("N")}
    end

    # The three directives the task names, each one an INDEPENDENT assertion so
    # a mutation that drops exactly one reds exactly one test.
    test "form-action 'self' — the reader emits zero <form>, so this is free", %{policy: p} do
      assert p =~ "form-action 'self'"
    end

    test "frame-src 'self' — the only frame is the same-origin /email view", %{policy: p} do
      assert p =~ "frame-src 'self'"
    end

    test "default-src 'self' — the floor for the unnamed fetch directives", %{policy: p} do
      assert p =~ "default-src 'self'"
    end

    test "font-src is pinned to self (+ data:), the genuine tightening", %{policy: p} do
      assert p =~ "font-src 'self' data:;"
      refute p =~ ~r/font-src[^;]*https:/
    end

    # These two are DELIBERATELY permissive and the lock says so, so a later
    # "tighten it" edit has to argue with a named test instead of a comment.
    test "img-src/media-src keep remote hosts — paper blocks carry any https URL", %{policy: p} do
      assert p =~ "img-src 'self' data: blob: https: http:"
      assert p =~ "media-src 'self' data: blob: https: http:"
    end

    test "connect-src keeps https: — asciicast srcs come from paper content", %{policy: p} do
      assert p =~ "connect-src 'self' https: ws: wss:"
    end

    test "style-src carries 'unsafe-inline' — inline style= attrs cannot be nonced", %{
      policy: p
    } do
      assert p =~ "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net"
    end

    test "every directive appears exactly once (no duplicate/shadowed directive)", %{policy: p} do
      names =
        p
        |> String.split(";")
        |> Enum.map(&(&1 |> String.trim() |> String.split(" ") |> List.first()))
        |> Enum.reject(&(&1 in [nil, ""]))

      assert length(names) == length(Enum.uniq(names))

      assert Enum.sort(names) ==
               Enum.sort(~w(
                 default-src script-src style-src img-src media-src font-src
                 connect-src frame-src object-src base-uri form-action frame-ancestors
               ))
    end
  end
end
