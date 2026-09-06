defmodule Barkpark.PortableDoc.TableEditingTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.TableEditing

  @max_safe_integer 9_007_199_254_740_991

  describe "project/1" do
    test "projects rectangular direct and metadata-carrier storage without mutation" do
      table = mixed_table()

      assert {:ok, projection} = TableEditing.project(table)

      assert projection.head == [text("Head A"), strong("Head B")]

      assert projection.rows == [
               [text("A1"), strong("A2")],
               [link("B1"), [valueref("B2")]]
             ]

      assert projection.shape == %{
               "v" => 1,
               "head" => %{
                 "state" => "row",
                 "row" => %{
                   "kind" => "array",
                   "cells" => ["content-map", "inline-array"]
                 }
               },
               "rows" => [
                 %{"kind" => "array", "cells" => ["inline-array", "content-map"]},
                 %{"kind" => "cells-map", "cells" => ["content-map", "inline-array"]}
               ]
             }

      assert Jason.decode!(Jason.encode!(projection.shape)) == projection.shape
      assert table == mixed_table()
    end

    test "retains absent, null, and empty head states while projecting each as no header" do
      base = %{"id" => "table", "type" => "table", "rows" => [[text("cell")]]}

      for {table, state} <- [
            {base, "absent"},
            {Map.put(base, "head", nil), "null"},
            {Map.put(base, "head", []), "empty"}
          ] do
        assert {:ok, %{head: nil, shape: %{"head" => %{"state" => ^state}}}} =
                 TableEditing.project(table)

        assert {:ok, ^table} = TableEditing.merge_cells(table, shape(table), [])
      end
    end

    test "accepts only inline shapes that survive the shared Table converter exactly" do
      inline = [
        %{
          "type" => "link",
          "href" => "/target",
          "children" => [
            %{
              "type" => "wikilink",
              "target" => "doc",
              "alias" => "Alias",
              "docId" => "doc-id",
              "children" => [
                %{
                  "type" => "strong",
                  "children" => [
                    %{
                      "type" => "em",
                      "children" => [
                        %{
                          "type" => "underline",
                          "children" => [
                            %{
                              "type" => "strikethrough",
                              "children" => [%{"type" => "code", "value" => "marked"}]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        },
        %{"type" => "blockref", "target" => "doc", "anchor" => "section"},
        %{"type" => "tag", "name" => "table"},
        valueref("Value")
      ]

      table = %{"id" => "inline", "type" => "table", "rows" => [[inline]]}

      assert {:ok, %{rows: [[^inline]]}} = TableEditing.project(table)
      assert {:ok, ^table} = TableEditing.merge_cells(table, shape(table), [])
    end

    test "rejects unsupported reader dialects and lossy inline shapes without changing them" do
      base = %{"id" => "table", "type" => "table", "rows" => [[text("cell")]]}

      unsupported = [
        Map.put(base, "rows", [["scalar"]]),
        Map.put(base, "rows", [[42]]),
        Map.put(base, "rows", [[nil]]),
        Map.put(base, "rows", [%{"cells" => [text("cell")]}]),
        Map.put(base, "rows", [[%{"content" => text("cell")}]]),
        Map.put(base, "rows", [[%{"text" => "legacy"}]]),
        Map.put(base, "rows", [[[%{"type" => "paragraph", "content" => text("nested")}]]]),
        Map.put(base, "content", %{"rows" => base["rows"]}),
        Map.put(base, "header", nil),
        Map.put(base, "headers", []),
        Map.put(base, "columns", []),
        Map.put(base, "head", true),
        Map.put(base, "head", %{
          "cells" => [text("hidden")],
          "row-meta" => "reader-does-not-render-this-shape"
        }),
        Map.put(base, "rows", [%{"cells" => [text("cell")], "header" => true}]),
        Map.put(base, "rows", [[%{"content" => text("cell"), "header" => true}]]),
        Map.put(base, "rows", [
          [%{"content" => text("cell"), "type" => "tableHeader", "meta" => true}]
        ]),
        Map.put(base, "rows", [[text("a")], [text("b"), text("c")]]),
        Map.put(base, "rows", []),
        Map.put(base, "rows", [[]]),
        Map.put(base, "rows", [[[%{"type" => "unknown", "value" => "lost"}]]]),
        Map.put(base, "rows", [[[%{"type" => "text", "value" => "x", "meta" => true}]]]),
        Map.put(base, "rows", [[[%{"type" => "strong", "children" => []}]]]),
        Map.put(base, "rows", [
          [[%{"type" => "strong", "children" => [hd(strong("nested"))]}]]
        ]),
        Map.put(base, "rows", [[text("one") ++ text("two")]])
      ]

      for {table, index} <- Enum.with_index(unsupported) do
        before = :erlang.term_to_binary(table)

        assert TableEditing.project(table) == {:error, :read_only_shape},
               "unsupported fixture #{index} was accepted"

        assert :erlang.term_to_binary(table) == before
      end

      for bad_id <- [nil, "", " ", " padded "] do
        table = Map.put(base, "id", bad_id)
        assert TableEditing.project(table) == {:error, :read_only_shape}
      end
    end
  end

  describe "merge_cells/3" do
    test "updates only addressed authoritative carriers and preserves all other metadata" do
      table = mixed_table()
      shape = shape(table)

      changes = [
        %{"area" => "head", "row" => 0, "column" => 0, "content" => text("Head edited")},
        %{"area" => "body", "row" => 0, "column" => 1, "content" => [valueref("Edited")]}
      ]

      assert {:ok, updated} = TableEditing.merge_cells(table, shape, changes)

      assert get_in(updated, ["head", Access.at(0), "content"]) == text("Head edited")
      assert get_in(updated, ["head", Access.at(0), "cell-meta"]) == %{"keep" => true}

      assert get_in(updated, ["rows", Access.at(0), Access.at(1), "content"]) == [
               valueref("Edited")
             ]

      assert get_in(updated, ["rows", Access.at(0), Access.at(1), "cell-meta"]) == "keep"
      assert Enum.at(updated["rows"], 1) == Enum.at(table["rows"], 1)
      assert updated["table-meta"] == table["table-meta"]
    end

    test "rejects stale shapes, unsupported sources, malformed changes, and positional ambiguity" do
      table = mixed_table()
      shape = shape(table)
      valid = %{"area" => "body", "row" => 0, "column" => 0, "content" => text("Edited")}

      assert TableEditing.merge_cells(table, Map.put(shape, "v", 2), [valid]) ==
               {:error, :stale_shape}

      assert TableEditing.merge_cells(%{"type" => "table"}, shape, [valid]) ==
               {:error, :read_only_shape}

      invalid = [
        [%{"area" => "head", "row" => 1, "column" => 0, "content" => text("x")}],
        [%{"area" => "body", "row" => 9, "column" => 0, "content" => text("x")}],
        [%{"area" => "body", "row" => 0, "column" => 9, "content" => text("x")}],
        [%{"area" => "body", "row" => -1, "column" => 0, "content" => text("x")}],
        [
          %{
            "area" => "body",
            "row" => @max_safe_integer + 1,
            "column" => 0,
            "content" => text("x")
          }
        ],
        [Map.put(valid, "extra", true)],
        [Map.put(valid, "content", [%{"type" => "unknown"}])],
        [
          Map.put(valid, "content", [
            %{
              "type" => "valueref",
              "target" => "target",
              "field" => "title",
              "children" => [%{"type" => "text", "text" => "normalizer would rewrite this"}]
            }
          ])
        ],
        [valid, valid],
        [
          %{"area" => "body", "row" => 1, "column" => 0, "content" => text("later")},
          valid
        ],
        %{"not" => "a list"}
      ]

      for changes <- invalid do
        assert TableEditing.merge_cells(table, shape, changes) == {:error, :invalid_cells}
      end
    end
  end

  describe "apply_action/3" do
    test "row actions move or remove whole carriers and add canonical empty storage" do
      table = mixed_table()
      shape = shape(table)
      [row_a, row_b] = table["rows"]

      assert {:ok, added} = TableEditing.apply_action(table, shape, "add-row")
      assert added["rows"] == [row_a, row_b, [[], []]]

      assert {:ok, removed} =
               TableEditing.apply_action(table, shape, "remove-row:0")

      assert removed["rows"] == [row_b]

      assert {:ok, moved_up} =
               TableEditing.apply_action(table, shape, "up-row:1")

      assert moved_up["rows"] == [row_b, row_a]

      assert {:ok, moved_down} =
               TableEditing.apply_action(table, shape, "down-row:0")

      assert moved_down["rows"] == [row_b, row_a]
      assert moved_up["table-meta"] == table["table-meta"]
    end

    test "column actions preserve surviving cell and row metadata" do
      table = mixed_table()
      shape = shape(table)

      assert {:ok, added} = TableEditing.apply_action(table, shape, "add-column")
      assert Enum.map(project!(added).rows, &length/1) == [3, 3]
      assert Enum.all?(project!(added).rows, &(List.last(&1) == []))
      assert List.last(project!(added).head) == []

      for {kind, index, expected_first_row} <- [
            {"remove-column", 0, [strong("A2")]},
            {"left-column", 1, [strong("A2"), text("A1")]},
            {"right-column", 0, [strong("A2"), text("A1")]}
          ] do
        assert {:ok, updated} =
                 TableEditing.apply_action(table, shape, "#{kind}:#{index}")

        assert hd(project!(updated).rows) == expected_first_row
        assert get_in(updated, ["rows", Access.at(1), "row-meta"]) == %{"keep" => [1, 2]}
      end
    end

    test "header actions preserve exact no-op states and use canonical intentional shapes" do
      headless = %{"id" => "headless", "type" => "table", "rows" => [[text("a"), text("b")]]}

      for source <- [headless, Map.put(headless, "head", nil), Map.put(headless, "head", [])] do
        assert {:ok, added} =
                 TableEditing.apply_action(source, shape(source), "add-header")

        assert added["head"] == [[], []]
      end

      table = mixed_table()

      assert {:ok, removed} =
               TableEditing.apply_action(table, shape(table), "remove-header")

      assert removed["head"] == []
      assert removed["rows"] == table["rows"]
      assert removed["table-meta"] == table["table-meta"]
    end

    test "invalid actions and minimum geometry fail without mutation" do
      single = %{"id" => "single", "type" => "table", "rows" => [[text("only")]]}
      table = mixed_table()
      shape = shape(table)

      invalid = [
        "remove-row:9",
        "up-row:0",
        "down-row:1",
        "remove-column:9",
        "left-column:0",
        "right-column:1",
        "remove-row:-1",
        "remove-row:#{@max_safe_integer + 1}",
        "remove-row:01",
        "remove-row:+1",
        "add-row:0",
        "unknown",
        %{"kind" => "add-row"}
      ]

      for action <- invalid do
        assert TableEditing.apply_action(table, shape, action) == {:error, :invalid_action}
      end

      assert TableEditing.apply_action(single, shape(single), "remove-row:0") ==
               {:error, :invalid_action}

      assert TableEditing.apply_action(single, shape(single), "remove-column:0") ==
               {:error, :invalid_action}

      assert TableEditing.apply_action(table, Map.put(shape, "v", 2), "add-row") ==
               {:error, :stale_shape}
    end
  end

  defp shape(table), do: project!(table).shape

  defp project!(table) do
    assert {:ok, projection} = TableEditing.project(table)
    projection
  end

  defp mixed_table do
    %{
      "id" => "table-one",
      "type" => "table",
      "table-meta" => %{"keep" => true},
      "head" => [
        %{"content" => text("Head A"), "cell-meta" => %{"keep" => true}},
        strong("Head B")
      ],
      "rows" => [
        [
          text("A1"),
          %{"content" => strong("A2"), "cell-meta" => "keep"}
        ],
        %{
          "cells" => [
            %{"content" => link("B1"), "cell-meta" => ["keep"]},
            [valueref("B2")]
          ],
          "row-meta" => %{"keep" => [1, 2]}
        }
      ]
    }
  end

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp strong(value), do: [%{"type" => "strong", "children" => text(value)}]

  defp link(value) do
    [%{"type" => "link", "href" => "/#{String.downcase(value)}", "children" => text(value)}]
  end

  defp valueref(label) do
    %{
      "type" => "valueref",
      "target" => "target",
      "field" => "title",
      "label" => label,
      "children" => text("Fallback")
    }
  end
end
