defmodule Barkpark.Validation.CrossCodelistTest do
  use ExUnit.Case, async: true

  alias Barkpark.Validation.CrossCodelist

  describe "consistent?/2 with :in predicate" do
    @mapping %{
      # ONIX-style: ProductFormCode 'BB' Hardback ⇒ PageCount > 0
      "BB" => {:gt, 0},
      "EA" => :any,
      "DG" => {:in, [0]}
    }

    test "driver match + predicate satisfied → true" do
      doc = %{"product" => %{"formCode" => "BB", "pageCount" => 240}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: "product.formCode",
               dependent_field: "product.pageCount",
               mapping: @mapping
             })
    end

    test "driver match + predicate violated → false" do
      doc = %{"product" => %{"formCode" => "BB", "pageCount" => 0}}

      refute CrossCodelist.consistent?(doc, %{
               driver_field: "product.formCode",
               dependent_field: "product.pageCount",
               mapping: @mapping
             })
    end

    test ":any predicate accepts everything" do
      doc = %{"product" => %{"formCode" => "EA", "pageCount" => 0}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: "product.formCode",
               dependent_field: "product.pageCount",
               mapping: @mapping
             })
    end

    test "driver value absent from mapping → unconstrained (true)" do
      doc = %{"product" => %{"formCode" => "ZZ", "pageCount" => 0}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: "product.formCode",
               dependent_field: "product.pageCount",
               mapping: @mapping
             })
    end

    test "missing driver field → true (presence enforced elsewhere)" do
      doc = %{"product" => %{"pageCount" => 240}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: "product.formCode",
               dependent_field: "product.pageCount",
               mapping: @mapping
             })
    end
  end

  describe "predicate flavours" do
    test "{:in, …}" do
      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => "yes"},
               %{
                 driver_field: "a",
                 dependent_field: "b",
                 mapping: %{"x" => {:in, ["yes", "maybe"]}}
               }
             )

      refute CrossCodelist.consistent?(
               %{"a" => "x", "b" => "no"},
               %{
                 driver_field: "a",
                 dependent_field: "b",
                 mapping: %{"x" => {:in, ["yes", "maybe"]}}
               }
             )
    end

    test "{:not_in, …}" do
      mapping = %{"x" => {:not_in, ["forbidden"]}}

      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => "ok"},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )

      refute CrossCodelist.consistent?(
               %{"a" => "x", "b" => "forbidden"},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )
    end

    test "{:gte, n} numeric guard" do
      mapping = %{"x" => {:gte, 1}}

      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => 1},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )

      refute CrossCodelist.consistent?(
               %{"a" => "x", "b" => 0},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )
    end

    test "{:any, [preds]} — any-of" do
      mapping = %{"x" => {:any, [{:in, ["A"]}, {:gt, 100}]}}

      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => "A"},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )

      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => 200},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )

      refute CrossCodelist.consistent?(
               %{"a" => "x", "b" => "Z"},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )
    end

    test "{:all, [preds]} — all-of" do
      mapping = %{"x" => {:all, [{:gt, 0}, {:lt, 100}]}}

      assert CrossCodelist.consistent?(
               %{"a" => "x", "b" => 50},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )

      refute CrossCodelist.consistent?(
               %{"a" => "x", "b" => 100},
               %{driver_field: "a", dependent_field: "b", mapping: mapping}
             )
    end
  end

  describe "field path resolution" do
    test "string path traverses dot-separated keys" do
      doc = %{"a" => %{"b" => %{"c" => "value"}}}
      mapping = %{"value" => {:in, ["ok"]}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: "a.b.c",
               dependent_field: "a.b.d",
               mapping: mapping
             })
    end

    test "list path is accepted directly" do
      doc = %{"a" => %{"b" => "x"}}

      assert CrossCodelist.consistent?(doc, %{
               driver_field: ["a", "b"],
               dependent_field: ["a", "missing"],
               mapping: %{"x" => :any}
             })
    end
  end
end
