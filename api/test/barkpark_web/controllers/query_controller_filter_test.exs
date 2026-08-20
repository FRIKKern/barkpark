defmodule BarkparkWeb.QueryControllerFilterTest do
  # Pure unit test for the fail-CLOSED filter guard — no ConnCase/DB needed.
  use ExUnit.Case, async: true

  alias BarkparkWeb.QueryController

  defp invalid(m), do: QueryController.invalid_filter_op_for_test(m)

  describe "invalid_filter_op/1 — is value validation" do
    test "an out-of-range is value is a CLAUSE refusal that says what `is` takes" do
      # It used to return {field, "is"}, rendered as `unknown filter operator
      # "is"` by a message that then listed `is` among the valid operators.
      assert {:clause, message, details} = invalid(%{"status" => %{"is" => "x"}})
      assert details == %{field: "status", op: "is"}
      assert message =~ ~s(filter[status][is] takes "null" or "notnull")
      refute message =~ "unknown filter operator"
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
      test "malformed value #{inspect(bad)} is refused by a message that names the GRAMMAR" do
        # Gyldendal: this used to render as `unknown filter operator "hasStrong"`
        # — inside a message that listed hasStrong as a valid operator. The
        # operator was never the problem; the VALUE was.
        assert {:clause, message, details} =
                 invalid(%{"tags" => %{"hasStrong" => unquote(bad)}})

        assert details == %{field: "tags", op: "hasStrong"}
        assert message =~ ~s(filter[tags][hasStrong] takes "<tag>:<min_strength>")
        refute message =~ "unknown filter operator"
      end
    end
  end

  describe "invalid_filter_op/1 — scalar-value guard, now for EVERY non-list op" do
    # The guard used to cover gt/gte/lt/lte only, so `?filter[title][eq][]=a`
    # reached Ecto and raised a CastError — surfaced to the caller as a 400
    # `internal_error` reading "unknown error (Ecto.Query.CastError)" with a
    # "Retry shortly" hint: a permanently-malformed request dressed as a
    # transient server fault. in/nin are the only list-binding ops.
    for op <- ~w(gt gte lt lte eq neq contains startsWith endsWith has) do
      test "#{op} with a LIST value (array-bracket syntax) is rejected" do
        assert {:clause, message, details} =
                 invalid(%{"price" => %{unquote(op) => ["1"]}})

        assert details == %{field: "price", op: unquote(op)}
        assert message =~ "takes a single value, not a list or object"
      end

      test "#{op} with a scalar value is accepted" do
        assert invalid(%{"price" => %{unquote(op) => "1"}}) == nil
      end
    end

    test "a nested-map value for a range op is also rejected" do
      assert {:clause, _msg, %{field: "price", op: "gt"}} =
               invalid(%{"price" => %{"gt" => %{"x" => 1}}})
    end

    test "in/nin still take their LIST value (the widened guard didn't over-reject)" do
      assert invalid(%{"title" => %{"in" => ["a", "b"]}}) == nil
      assert invalid(%{"title" => %{"nin" => ["a"]}}) == nil
    end

    test "in with a nested OBJECT value is refused instead of silently no-opping" do
      # apply_field_op/4's in-clause is is_list-guarded, so a map value would
      # skip straight past it and return every row.
      assert {:clause, message, %{field: "title", op: "in"}} =
               invalid(%{"title" => %{"in" => %{"k" => "v"}}})

      assert message =~ "takes a comma list"
    end

    test "a bare LIST value (filter[title][]=a) is refused, not cast into eq" do
      assert {:clause, message, %{field: "title"}} = invalid(%{"title" => ["a"]})
      assert message =~ "filter[title] takes a single value"
    end
  end

  describe "invalid_filter_op/1 — boolean groups ($or) name the real problem" do
    test "$or is refused as an unsupported GROUP, never with its index as an operator" do
      # Gyldendal: `filter[$or][0][title][eq]=x` reported `unknown filter
      # operator "0" on field "$or"` — the caller was told to fix an operator
      # that was never one.
      assert {:clause, message, details} =
               invalid(%{"$or" => %{"0" => %{"title" => %{"eq" => "x"}}}})

      assert details == %{field: "$or"}
      assert message =~ "boolean filter groups are not supported"
      refute message =~ ~s(operator "0")
    end

    test "$and is refused the same way, whatever its value shape" do
      assert {:clause, _msg, %{field: "$and"}} = invalid(%{"$and" => ["a=1"]})
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

      assert {:clause, _msg, %{field: "tags", op: "hasStrong"}} =
               invalid(%{"tags" => %{"hasStrong" => "wired"}})
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

  describe "normalize_filter_map/1 — a REPEATED filter param AND-composes (Gyldendal #16)" do
    # `?filter[]=a&filter[]=b` reaches Plug as a LIST. It used to hit the `%{}`
    # catch-all and mean NO FILTER AT ALL: the one HTTP shape that still
    # answered 200 with the unfiltered set, and invisible to the fail-closed
    # op guard, which inspects an empty map and finds nothing wrong with it.
    test "two clauses on DIFFERENT fields compose into one AND-ed map" do
      assert normalize(["status=published", "title=Alpha"]) ==
               %{"status" => "published", "title" => "Alpha"}
    end

    test "two clauses on the SAME field with different ops merge into one op map" do
      assert normalize(["price>10", "price<20"]) ==
               %{"price" => %{"gt" => "10", "lt" => "20"}}
    end

    test "a bare eq-sugar clause is promoted when it has to merge" do
      assert normalize(["title=Alpha", "title*=lph"]) ==
               %{"title" => %{"eq" => "Alpha", "contains" => "lph"}}
    end

    test "the SAME field+op twice is REFUSED — under AND no row satisfies both" do
      assert {:error, {:invalid_filter_clause, message, details}} =
               normalize(["title=Alpha", "title=Beta"])

      assert details == %{field: "title", op: "eq"}
      assert message =~ "cannot carry two"
      assert message =~ "in a,b"
    end

    test "ONE unparseable element fails the WHOLE request — half a filter is the defect" do
      assert {:error, {:invalid_flat_filter, "total garbage!!!"}} =
               normalize(["status=published", "total garbage!!!"])
    end

    test "a single-element list behaves exactly like the lone param" do
      assert normalize(["status=published"]) == %{"status" => "published"}
    end

    test "an empty list is a no-filter no-op, like an absent param" do
      assert normalize([]) == %{}
    end
  end

  describe "normalize_filter_map/1 — the catch-all is SEALED" do
    test "an unrecognised shape is an error sentinel, never the empty (no-filter) map" do
      # MUTATION PROOF: restore `defp normalize_filter_map(_), do: %{}` and this
      # reds — and, over HTTP, the request answers 200 with every row.
      assert {:error, {:invalid_filter_clause, message, _details}} = normalize(42)
      assert message =~ "unsupported filter param shape"
      assert message =~ "filter[]="
    end
  end
end
