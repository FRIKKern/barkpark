defmodule Barkpark.Content.CodelistsTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.{Codelist, Translation, Value}

  describe "register/3 + lookup/3 — flat list" do
    test "round-trips a small flat codelist with English-only labels" do
      values = [
        %{code: "A01", translations: [%{language: "eng", label: "By (author)"}]},
        %{code: "A02", translations: [%{language: "eng", label: "With"}]},
        %{code: "B01", translations: [%{language: "eng", label: "Edited by"}]}
      ]

      assert {:ok, %Codelist{}} =
               Codelists.register("onixedit", "onixedit:contributor_role", %{
                 issue: "73",
                 name: "ONIX Contributor Role 73",
                 values: values
               })

      assert %{value: "A01", label: "By (author)", parent_code: nil} =
               Codelists.lookup("onixedit", "onixedit:contributor_role", "A01")

      assert %{value: "B01", label: "Edited by"} =
               Codelists.lookup("onixedit", "onixedit:contributor_role", "B01")

      assert is_nil(Codelists.lookup("onixedit", "onixedit:contributor_role", "ZZ99"))
      assert is_nil(Codelists.lookup("onixedit", "missing-list", "A01"))
    end
  end

  describe "lookup/3 — multi-language fallback" do
    setup do
      {:ok, _} =
        Codelists.register("onixedit", "onixedit:language", %{
          issue: "1",
          values: [
            %{
              code: "nob",
              translations: [
                %{language: "eng", label: "Norwegian Bokmål"},
                %{language: "nob", label: "Norsk bokmål"}
              ]
            },
            %{
              code: "eng",
              translations: [
                %{language: "eng", label: "English"}
              ]
            },
            %{
              code: "fra",
              translations: [
                %{language: "fra", label: "Français"}
              ]
            }
          ]
        })

      :ok
    end

    test "default fallback prefers nob, then eng" do
      # nob entry has both translations; default chain hits nob first
      assert %{label: "Norsk bokmål"} =
               Codelists.lookup("onixedit", "onixedit:language", "nob")

      # eng entry has only eng; chain falls through to eng
      assert %{label: "English"} =
               Codelists.lookup("onixedit", "onixedit:language", "eng")
    end

    test "explicit chain overrides defaults" do
      assert %{label: "Norwegian Bokmål"} =
               Codelists.lookup("onixedit", "onixedit:language", "nob", languages: ["eng", "nob"])
    end

    test "no preferred language match falls back to any translation" do
      # fra is the only translation; default chain (nob, eng) misses
      assert %{label: "Français"} =
               Codelists.lookup("onixedit", "onixedit:language", "fra")
    end
  end

  describe "tree/2 — hierarchical lookup" do
    test "returns nested roots and children with depth preserved" do
      {:ok, _} =
        Codelists.register("onixedit", "onixedit:thema-mini", %{
          issue: "1.5",
          values: [
            %{
              code: "A",
              translations: [%{language: "eng", label: "The arts"}],
              children: [
                %{
                  code: "AB",
                  translations: [%{language: "eng", label: "The arts: general"}],
                  children: [
                    %{
                      code: "ABA",
                      translations: [%{language: "eng", label: "Theory of art"}]
                    }
                  ]
                }
              ]
            },
            %{
              code: "B",
              translations: [%{language: "eng", label: "Biography"}],
              children: [
                %{code: "B1", translations: [%{language: "eng", label: "Biography: general"}]}
              ]
            }
          ]
        })

      assert [a_root, b_root] = Codelists.tree("onixedit", "onixedit:thema-mini")

      assert %{value: "A", label: "The arts", children: [ab]} = a_root
      assert %{value: "AB", label: "The arts: general", children: [aba]} = ab
      assert %{value: "ABA", label: "Theory of art", children: []} = aba

      assert %{value: "B", label: "Biography", children: [b1]} = b_root
      assert %{value: "B1", children: []} = b1
    end

    test "lookup/3 surfaces parent_code for hierarchical entries" do
      {:ok, _} =
        Codelists.register("onixedit", "onixedit:hier", %{
          issue: "1",
          values: [
            %{
              code: "ROOT",
              translations: [%{language: "eng", label: "Root"}],
              children: [
                %{code: "CHILD", translations: [%{language: "eng", label: "Child"}]}
              ]
            }
          ]
        })

      assert %{value: "CHILD", label: "Child", parent_code: "ROOT"} =
               Codelists.lookup("onixedit", "onixedit:hier", "CHILD")

      assert %{value: "ROOT", parent_code: nil} =
               Codelists.lookup("onixedit", "onixedit:hier", "ROOT")
    end
  end

  describe "idempotent re-registration" do
    test "re-registering with the same (plugin, list, issue) is stable" do
      payload = %{
        issue: "1",
        name: "v1",
        values: [
          %{code: "A", translations: [%{language: "eng", label: "Alpha"}]},
          %{code: "B", translations: [%{language: "eng", label: "Beta"}]}
        ]
      }

      assert {:ok, %Codelist{id: id_1}} =
               Codelists.register("onixedit", "onixedit:idem", payload)

      assert {:ok, %Codelist{id: id_2}} =
               Codelists.register("onixedit", "onixedit:idem", payload)

      assert id_1 == id_2,
             "re-registration should upsert the codelist row, not duplicate it"

      # Row counts stable: 1 codelist, 2 values, 2 translations.
      assert Repo.aggregate(
               from(c in Codelist,
                 where: c.plugin_name == "onixedit" and c.list_id == "onixedit:idem"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(v in Value, where: v.codelist_id == ^id_1),
               :count
             ) == 2

      value_ids =
        Repo.all(from v in Value, where: v.codelist_id == ^id_1, select: v.id)

      assert Repo.aggregate(
               from(t in Translation, where: t.codelist_value_id in ^value_ids),
               :count
             ) == 2
    end

    test "re-registration replaces values and translations" do
      list_id = "onixedit:idem-replace"

      assert {:ok, %Codelist{id: id_1}} =
               Codelists.register("onixedit", list_id, %{
                 issue: "1",
                 values: [
                   %{code: "A", translations: [%{language: "eng", label: "Alpha"}]},
                   %{code: "B", translations: [%{language: "eng", label: "Beta"}]}
                 ]
               })

      assert {:ok, %Codelist{id: id_2}} =
               Codelists.register("onixedit", list_id, %{
                 issue: "1",
                 values: [
                   %{code: "C", translations: [%{language: "eng", label: "Gamma"}]}
                 ]
               })

      assert id_1 == id_2

      assert is_nil(Codelists.lookup("onixedit", list_id, "A"))
      assert is_nil(Codelists.lookup("onixedit", list_id, "B"))
      assert %{value: "C", label: "Gamma"} = Codelists.lookup("onixedit", list_id, "C")
    end
  end

  describe "plugin discriminator isolation" do
    test "two plugins may register the same list_id and code without bleed" do
      {:ok, _} =
        Codelists.register("onixedit", "language", %{
          issue: "1",
          values: [
            %{code: "x", translations: [%{language: "eng", label: "Onix-X"}]}
          ]
        })

      {:ok, _} =
        Codelists.register("commerce", "language", %{
          issue: "1",
          values: [
            %{code: "x", translations: [%{language: "eng", label: "Commerce-X"}]}
          ]
        })

      assert %{label: "Onix-X"} = Codelists.lookup("onixedit", "language", "x")
      assert %{label: "Commerce-X"} = Codelists.lookup("commerce", "language", "x")
    end
  end

  describe "list/1" do
    test "returns codelists registered under a plugin" do
      {:ok, _} =
        Codelists.register("plugin-a", "plugin-a:one", %{issue: "1", values: []})

      {:ok, _} =
        Codelists.register("plugin-a", "plugin-a:two", %{issue: "1", values: []})

      {:ok, _} =
        Codelists.register("plugin-b", "plugin-b:one", %{issue: "1", values: []})

      ids =
        "plugin-a"
        |> Codelists.list()
        |> Enum.map(& &1.list_id)
        |> Enum.sort()

      assert ids == ["plugin-a:one", "plugin-a:two"]
    end
  end
end
