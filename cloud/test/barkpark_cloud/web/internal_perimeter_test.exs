defmodule BarkparkCloud.Web.InternalPerimeterTest do
  @moduledoc """
  dr-w24-bl-internal-write-route-is-publicly-reachable — the BOOT-TIME half.

  `router_internal_perimeter_test.exs` drives the plug through the router. This
  file drives the two decisions that happen before any request exists:

    * `load!/2` — what a prod release does when nobody declared
      `INTERNAL_ALLOWED_CIDRS`. The answer must be "refuse to boot", not "let
      everybody in". This rule lives in a module, and not inline in
      `config/runtime.exs`, precisely so it can be RUN here instead of read.
    * `allowed?/2` — the membership rule, including every way it can be handed
      something it did not expect.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Web.InternalPerimeter

  describe "load!/2 — the prod declaration is mandatory" do
    test "an unset variable REFUSES TO BOOT a prod release" do
      assert_raise RuntimeError, ~r/INTERNAL_ALLOWED_CIDRS is missing/, fn ->
        InternalPerimeter.load!(nil, :prod)
      end
    end

    test "the refusal names the opt-out, so nobody has to guess how to proceed" do
      error = assert_raise(RuntimeError, fn -> InternalPerimeter.load!(nil, :prod) end)
      message = error.message

      assert message =~ "INTERNAL_ALLOWED_CIDRS=any"
      assert message =~ "203.0.113.7/32"
    end

    test "unset OUTSIDE prod is :any — dev and test behave exactly as before" do
      assert InternalPerimeter.load!(nil, :dev) == :any
      assert InternalPerimeter.load!(nil, :test) == :any
    end

    test "prod may decline the network factor, but only BY NAME" do
      assert InternalPerimeter.load!("any", :prod) == :any
      assert InternalPerimeter.load!("  any  ", :prod) == :any
    end

    test "an empty string is NOT the opt-out — it raises rather than guessing" do
      assert_raise RuntimeError, ~r/set but empty/, fn ->
        InternalPerimeter.load!("", :prod)
      end

      assert_raise RuntimeError, ~r/set but empty/, fn ->
        InternalPerimeter.load!("   ", :dev)
      end
    end

    test "a value of only separators raises rather than parsing to an empty list" do
      # An empty list would be a working config that admits NOBODY: a silent,
      # total outage of the fleet-ops surface from a stray comma.
      assert_raise RuntimeError, ~r/no entries/, fn ->
        InternalPerimeter.load!(", ,", :prod)
      end
    end
  end

  describe "load!/2 — parsing" do
    test "a comma-separated list of ranges" do
      assert InternalPerimeter.load!("203.0.113.7/32, 10.20.0.0/16", :prod) == [
               {{203, 0, 113, 7}, 32},
               {{10, 20, 0, 0}, 16}
             ]
    end

    test "a bare address is its own /32, and a bare v6 address its own /128" do
      assert InternalPerimeter.load!("203.0.113.7", :prod) == [{{203, 0, 113, 7}, 32}]

      assert InternalPerimeter.load!("2001:db8::1", :prod) == [
               {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 128}
             ]
    end

    test "a malformed address raises at BOOT — never a silently smaller fence" do
      assert_raise RuntimeError, ~r/not a valid IP address/, fn ->
        InternalPerimeter.load!("203.0.113.7/32,not-an-ip/24", :prod)
      end
    end

    test "a prefix length out of range for the family raises" do
      assert_raise RuntimeError, ~r/invalid prefix\s+length/, fn ->
        InternalPerimeter.load!("203.0.113.0/33", :prod)
      end

      assert_raise RuntimeError, ~r/invalid prefix\s+length/, fn ->
        InternalPerimeter.load!("2001:db8::/129", :prod)
      end
    end

    test "a non-numeric prefix length raises" do
      assert_raise RuntimeError, ~r/invalid prefix\s+length/, fn ->
        InternalPerimeter.load!("203.0.113.0/twenty-four", :prod)
      end
    end

    test "a v6 prefix beyond 32 is accepted — the family bound is 128, not 32" do
      assert InternalPerimeter.load!("2001:db8::/64", :prod) == [
               {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 64}
             ]
    end
  end

  describe "allowed?/2 — fail closed on everything unexpected" do
    @cidrs [{{203, 0, 113, 0}, 24}]

    test ":any admits anyone, including a malformed remote_ip" do
      assert InternalPerimeter.allowed?(:any, {198, 51, 100, 9})
      assert InternalPerimeter.allowed?(:any, nil)
    end

    test "nil config — a deleted key — admits NOBODY" do
      refute InternalPerimeter.allowed?(nil, {203, 0, 113, 7})
    end

    test "a config of the wrong shape admits nobody" do
      refute InternalPerimeter.allowed?("203.0.113.0/24", {203, 0, 113, 7})
      refute InternalPerimeter.allowed?(:everyone, {203, 0, 113, 7})
      refute InternalPerimeter.allowed?(%{}, {203, 0, 113, 7})
    end

    test "an empty list admits nobody" do
      refute InternalPerimeter.allowed?([], {203, 0, 113, 7})
    end

    test "a nil or malformed remote_ip admits nobody" do
      refute InternalPerimeter.allowed?(@cidrs, nil)
      refute InternalPerimeter.allowed?(@cidrs, "203.0.113.7")
    end
  end

  describe "allowed?/2 — prefix arithmetic" do
    test "the boundaries of a /24" do
      cidrs = [{{203, 0, 113, 0}, 24}]

      assert InternalPerimeter.allowed?(cidrs, {203, 0, 113, 0})
      assert InternalPerimeter.allowed?(cidrs, {203, 0, 113, 255})
      refute InternalPerimeter.allowed?(cidrs, {203, 0, 112, 255})
      refute InternalPerimeter.allowed?(cidrs, {203, 0, 114, 0})
    end

    test "a /32 admits exactly one address" do
      cidrs = [{{203, 0, 113, 7}, 32}]

      assert InternalPerimeter.allowed?(cidrs, {203, 0, 113, 7})
      refute InternalPerimeter.allowed?(cidrs, {203, 0, 113, 8})
    end

    test "a /0 admits the whole family — and still only that family" do
      cidrs = [{{0, 0, 0, 0}, 0}]

      assert InternalPerimeter.allowed?(cidrs, {198, 51, 100, 9})
      refute InternalPerimeter.allowed?(cidrs, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "any of several ranges is enough" do
      cidrs = [{{203, 0, 113, 0}, 24}, {{10, 20, 0, 0}, 16}]

      assert InternalPerimeter.allowed?(cidrs, {10, 20, 33, 44})
      assert InternalPerimeter.allowed?(cidrs, {203, 0, 113, 7})
      refute InternalPerimeter.allowed?(cidrs, {10, 21, 0, 1})
    end

    test "families never cross — a v4-mapped v6 probe is not inside a v4 range" do
      cidrs = [{{203, 0, 113, 0}, 24}]

      # ::ffff:203.0.113.7 — the same numbers, a different family.
      refute InternalPerimeter.allowed?(cidrs, {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107})
    end

    test "a v6 range works on v6 addresses" do
      cidrs = [{{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}]

      assert InternalPerimeter.allowed?(cidrs, {0x2001, 0xDB8, 0xDEAD, 0, 0, 0, 0, 1})
      refute InternalPerimeter.allowed?(cidrs, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
      refute InternalPerimeter.allowed?(cidrs, {203, 0, 113, 7})
    end

    test "a prefix length outside the family's bound matches nothing" do
      # Unreachable through load!/2, which raises on these — this pins the
      # matcher's own behaviour if a value is ever set from elsewhere.
      refute InternalPerimeter.allowed?([{{203, 0, 113, 0}, 33}], {203, 0, 113, 7})
      refute InternalPerimeter.allowed?([{{203, 0, 113, 0}, -1}], {203, 0, 113, 7})
    end
  end
end
