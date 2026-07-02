defmodule BarkparkWeb.QueryControllerFilterTest do
  # Pure unit test for the fail-CLOSED filter guard — no ConnCase/DB needed.
  use ExUnit.Case, async: true

  alias BarkparkWeb.QueryController

  defp invalid(m), do: QueryController.invalid_filter_op_for_test(m)

  describe "invalid_filter_op/1 — is value validation" do
    test "an out-of-range is value is reported as {field, \"is\"}" do
      assert invalid(%{"status" => %{"is" => "x"}}) == {"status", "is"}
    end

    test "is=null is accepted" do
      assert invalid(%{"status" => %{"is" => "null"}}) == nil
    end

    test "is=notnull is accepted" do
      assert invalid(%{"status" => %{"is" => "notnull"}}) == nil
    end

    test "a bare scalar filter carries no op and stays nil" do
      assert invalid(%{"status" => "published"}) == nil
    end

    test "an unknown op still fail-closes ahead of the is check" do
      assert invalid(%{"status" => %{"bogus" => "x"}}) == {"status", "bogus"}
    end
  end
end
