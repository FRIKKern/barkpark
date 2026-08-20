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

  describe "invalid_filter_op/1 — hasStrong value validation (D20)" do
    test "a well-formed tag:min value is accepted" do
      assert invalid(%{"tags" => %{"hasStrong" => "epic:50"}}) == nil
    end

    test "a colon-carrying tag name splits at the LAST colon and is accepted" do
      assert invalid(%{"tags" => %{"hasStrong" => "ns:sub:50"}}) == nil
    end

    for bad <- ["epic", "epic:", ":50", "epic:high", ""] do
      test "malformed value #{inspect(bad)} is rejected as {field, \"hasStrong\"}" do
        assert invalid(%{"tags" => %{"hasStrong" => unquote(bad)}}) == {"tags", "hasStrong"}
      end
    end
  end

  describe "invalid_filter_op/1 — scalar-value guard for range ops" do
    for op <- ~w(gt gte lt lte) do
      test "#{op} with a LIST value (array-bracket syntax) is rejected" do
        assert invalid(%{"price" => %{unquote(op) => ["1"]}}) == {"price", unquote(op)}
      end

      test "#{op} with a scalar value is accepted" do
        assert invalid(%{"price" => %{unquote(op) => "1"}}) == nil
      end
    end

    test "a nested-map value for a range op is also rejected" do
      assert invalid(%{"price" => %{"gt" => %{"x" => 1}}}) == {"price", "gt"}
    end
  end

  defp normalize(s), do: QueryController.normalize_filter_map_for_test(s)

  describe "normalize_filter_map/1 — flat hasStrong grammar (D75)" do
    test "field hasStrong tag:min parses to the canonical nested op" do
      assert normalize("tags hasStrong epic:50") == %{"tags" => %{"hasStrong" => "epic:50"}}
    end

    test "the keyword is case-insensitive; the emitted op stays canonical" do
      assert normalize("tags hasstrong epic:50") == %{"tags" => %{"hasStrong" => "epic:50"}}
    end

    test "one pair of surrounding quotes is stripped from the value" do
      assert normalize(~s(tags hasStrong "epic:50")) == %{"tags" => %{"hasStrong" => "epic:50"}}
    end

    test "a colon-carrying tag rides through intact to the shared last-colon value parser" do
      assert normalize("tags hasStrong ns:sub:50") == %{"tags" => %{"hasStrong" => "ns:sub:50"}}
    end

    test "a malformed hasStrong VALUE still parses to the op the fail-closed guard rejects" do
      # Grammar and value validation are separate layers: the flat parser emits
      # the canonical op; invalid_filter_op/1 (via parse_has_strong) rejects it.
      assert normalize("tags hasStrong wired") == %{"tags" => %{"hasStrong" => "wired"}}
      assert invalid(%{"tags" => %{"hasStrong" => "wired"}}) == {"tags", "hasStrong"}
    end
  end

  describe "normalize_filter_map/1 — sealed empty-map passthrough (D75)" do
    test "an unparseable non-empty string is an error sentinel, NEVER %{}" do
      # Mutation-proof: revert the seal (`|| %{}` fall-through) and this reds.
      assert normalize("total garbage!!!") ==
               {:error, {:invalid_flat_filter, "total garbage!!!"}}
    end

    test "a value-less hasStrong is an error sentinel too" do
      assert normalize("tags hasStrong") == {:error, {:invalid_flat_filter, "tags hasStrong"}}
    end

    test "empty / whitespace-only stays a no-filter no-op, like an absent param" do
      assert normalize("") == %{}
      assert normalize("   ") == %{}
    end

    test "the existing grammars still parse (the seal didn't over-reject)" do
      assert normalize("status=published") == %{"status" => "published"}
      assert normalize("title in a,b") == %{"title" => %{"in" => ["a", "b"]}}
      assert normalize("category is null") == %{"category" => %{"is" => "null"}}
      assert normalize("price>=10") == %{"price" => %{"gte" => "10"}}
    end
  end
end
