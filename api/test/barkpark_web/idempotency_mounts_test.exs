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
end
