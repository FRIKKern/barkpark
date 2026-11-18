defmodule Barkpark.Test.IdempotencyMountsTest do
  @moduledoc """
  The forms `Barkpark.Test.IdempotencyMounts` must see (task-ccf7bc7003c505c9).
  The two Idempotency tripwires read through it; a form missing here is a
  controller or a streaming call those tripwires pass over.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Test.IdempotencyMounts

  defp mounts(source), do: source |> Code.string_to_quoted!() |> IdempotencyMounts.mounts()
  defp streams?(source), do: source |> Code.string_to_quoted!() |> IdempotencyMounts.streams?()

  defp controller(body), do: "defmodule BarkparkWeb.XController do\n#{body}\nend"

  describe "mounts/1" do
    test "a full-name mount with options and a guard" do
      assert [%{opts: [scope: "s"], guard: {:==, _, _}}] =
               mounts(
                 controller(
                   ~s|plug(BarkparkWeb.Plugs.Idempotency, [scope: "s"] when action == :x)|
                 )
               )
    end

    test "a full-name mount with no options, guarded or not" do
      assert [%{opts: nil, guard: {:==, _, _}}] =
               mounts(controller("plug BarkparkWeb.Plugs.Idempotency when action == :x"))

      assert [%{opts: nil, guard: nil}] = mounts(controller("plug BarkparkWeb.Plugs.Idempotency"))
    end

    test "a mount through an alias, an `as:` alias, or a multi-alias" do
      for body <- [
            "alias BarkparkWeb.Plugs.Idempotency\nplug Idempotency",
            "alias BarkparkWeb.Plugs.Idempotency, as: Idem\nplug(Idem, scope: \"s\")",
            "alias BarkparkWeb.Plugs.{Idempotency, RequireToken}\nplug Idempotency when action in [:x]",
            "alias BarkparkWeb.Plugs\nplug Plugs.Idempotency"
          ] do
        found = mounts(controller(body))
        assert length(found) == 1, "not seen: #{body}"
      end
    end

    test "another plug, or another module named Idempotency, is not a mount" do
      for body <- [
            "plug BarkparkWeb.Plugs.RequireToken",
            "plug Other.Plugs.Idempotency",
            "plug Idempotency",
            "plug :fetch_session"
          ] do
        assert mounts(controller(body)) == [], "wrongly seen: #{body}"
      end
    end
  end

  describe "streams?/1" do
    test "send_chunked or send_file bare, piped, qualified, aliased or captured" do
      for body <- [
            "send_chunked(conn, 200)",
            "conn |> send_chunked(200)",
            "Plug.Conn.send_chunked(conn, 200)",
            "conn |> Plug.Conn.send_file(200, path)",
            "Conn.send_chunked(conn, 200)",
            "Enum.map(conns, &Plug.Conn.send_chunked(&1, 200))",
            "f = &send_file/3"
          ] do
        assert streams?(body), "not seen: #{body}"
      end
    end

    test "send_resp is not streaming" do
      refute streams?("conn |> Plug.Conn.send_resp(200, body)")
    end
  end

  # task-13f09b2af9408e48: a `:*` route is asked as a POST, because a POST is
  # what the plug sees. Asked as "*", no POST route can shadow it, so a forward
  # an earlier POST route hides would read as resolved, and its pipelines would
  # be read for a request that never reaches it.
  describe "route_info/2" do
    setup do
      n = System.unique_integer([:positive])
      plug = Module.concat(Barkpark.Test, "ShadowPlug#{n}")
      router = Module.concat(Barkpark.Test, "ShadowRouter#{n}")

      Code.compile_string("""
      defmodule #{inspect(plug)} do
        def init(opts), do: opts
        def call(conn, _opts), do: conn
      end

      defmodule #{inspect(router)} do
        use Phoenix.Router

        scope "/v1/plugins" do
          post "/fwd", #{inspect(plug)}, :create
          forward "/fwd", #{inspect(plug)}
        end
      end
      """)

      %{router: router}
    end

    test "a forward a POST route shadows is unresolved", %{router: router} do
      [post] = for route <- router.__routes__(), route.verb == :post, do: route
      [forward] = for route <- router.__routes__(), route.verb == :*, do: route

      assert %{route: "/v1/plugins/fwd"} = IdempotencyMounts.route_info(router, post)

      as_any = Phoenix.Router.route_info(router, "*", "/v1/plugins/fwd", "localhost")

      assert is_map(as_any) and not is_atom(as_any.plug_opts),
             "CONTROL: asked as \"*\", the forward resolves, so the fixture tells the two " <>
               "apart. Got: #{inspect(as_any)}"

      assert IdempotencyMounts.route_info(router, forward) == nil,
             "the forward was asked as \"*\": a POST to its path reaches the POST route"
    end
  end

  describe "module/2" do
    test "a name through an alias, or by full name" do
      aliases = IdempotencyMounts.aliases(Code.string_to_quoted!("alias Barkpark.Media"))
      assert IdempotencyMounts.module([:Media, :Blob], aliases) == Barkpark.Media.Blob
      assert IdempotencyMounts.module([:Plug, :Conn], aliases) == Plug.Conn
    end

    # A crash here reds every PR whose controller writes `alias __MODULE__.X`.
    test "an alias built from __MODULE__ resolves to nil, not a crash" do
      aliases = IdempotencyMounts.aliases(quote(do: alias(__MODULE__.Inner)))
      assert IdempotencyMounts.module([:Inner], aliases) == nil
      assert IdempotencyMounts.module([{:__MODULE__, [], nil}, :Inner], %{}) == nil
    end
  end
end
