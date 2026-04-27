defmodule Barkpark.Codelists.EDItEURTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Codelists.EDItEUR
  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.{Codelist, Translation, Value}

  @fixture Path.expand("../../fixtures/codelists/synthetic.xml", __DIR__)

  describe "parse_xml/2" do
    test "parses every CodeList in the fixture" do
      assert {:ok, lists} = EDItEUR.parse_xml(@fixture)
      ids = lists |> Enum.map(& &1.list_id) |> Enum.sort()

      assert ids == [
               "onixedit:list_1",
               "onixedit:list_17",
               "onixedit:list_64",
               "onixedit:list_7"
             ]

      # Synthetic IssueNumber is on the root element only (matching the real
      # EDItEUR shape), so per-list issue is nil and the caller must supply
      # one via `--issue` / `seed/2` opts.
      assert Enum.all?(lists, &is_nil(&1.issue))
    end

    test "extracts multi-language Description elements when present" do
      {:ok, lists} = EDItEUR.parse_xml(@fixture)
      list_17 = Enum.find(lists, &(&1.list_id == "onixedit:list_17"))
      a01 = Enum.find(list_17.values, &(&1.code == "A01"))

      langs = a01.translations |> Enum.map(& &1.language) |> Enum.sort()
      assert langs == ["eng", "nob"]
    end

    test "falls back to <CodeDescription> as eng when no <Description> present" do
      {:ok, lists} = EDItEUR.parse_xml(@fixture)
      list_17 = Enum.find(lists, &(&1.list_id == "onixedit:list_17"))
      b01 = Enum.find(list_17.values, &(&1.code == "B01"))

      assert [%{language: "eng", label: "Edited by"}] = b01.translations
    end

    test "returns :file_not_found for a missing path" do
      assert {:error, {:file_not_found, _}} = EDItEUR.parse_xml("/nope/missing.xml")
    end
  end

  describe "seed/2 — round-trip" do
    test "parsed fixture lands in the registry with codes + labels" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      assert {:ok, _ids} = EDItEUR.seed(parsed, issue: "73")

      # list 1 — flat, eng-only
      assert %{value: "01", label: "Early notification"} =
               Codelists.lookup("onixedit", "onixedit:list_1", "01")

      # list 17 — multi-language, contributor role 'A01'
      assert %{value: "A01", label: "Forfatter"} =
               Codelists.lookup("onixedit", "onixedit:list_17", "A01", languages: ["nob", "eng"])

      assert %{value: "A01", label: "By (author)"} =
               Codelists.lookup("onixedit", "onixedit:list_17", "A01", languages: ["eng"])
    end
  end

  describe "seed/2 — hierarchical (list 64)" do
    test "parent_id self-references resolve through Codelists.lookup/3" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      {:ok, _} = EDItEUR.seed(parsed, issue: "73")

      # ABA → AB → A
      assert %{value: "ABA", parent_code: "AB"} =
               Codelists.lookup("onixedit", "onixedit:list_64", "ABA")

      assert %{value: "AB", parent_code: "A"} =
               Codelists.lookup("onixedit", "onixedit:list_64", "AB")

      assert %{value: "A", parent_code: nil} =
               Codelists.lookup("onixedit", "onixedit:list_64", "A")
    end

    test "Codelists.tree/2 reconstructs the synthetic Thema tree" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      {:ok, _} = EDItEUR.seed(parsed, issue: "73")

      tree = Codelists.tree("onixedit", "onixedit:list_64")
      roots = tree |> Enum.map(& &1.value) |> Enum.sort()
      assert roots == ["A", "B"]

      a = Enum.find(tree, &(&1.value == "A"))
      assert [%{value: "AB", children: [%{value: "ABA"}]}] = a.children

      b = Enum.find(tree, &(&1.value == "B"))
      assert [%{value: "BG", children: []}] = b.children
    end
  end

  describe "seed/2 — multi-language label resolution" do
    test "respects an explicit language preference list" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      {:ok, _} = EDItEUR.seed(parsed, issue: "73")

      assert %{label: "Digital nedlasting"} =
               Codelists.lookup("onixedit", "onixedit:list_7", "EB", languages: ["nob", "eng"])

      assert %{label: "Digital download"} =
               Codelists.lookup("onixedit", "onixedit:list_7", "EB", languages: ["eng"])
    end
  end

  describe "seed/2 — idempotency" do
    test "re-seeding the same fixture twice keeps row counts stable" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      {:ok, _} = EDItEUR.seed(parsed, issue: "73")

      counts_after_first = registry_counts("onixedit", "73")

      {:ok, _} = EDItEUR.seed(parsed, issue: "73")
      counts_after_second = registry_counts("onixedit", "73")

      assert counts_after_first == counts_after_second
    end
  end

  describe "seed/2 — issue versioning" do
    test "issue 73 and 74 of the same list_id coexist" do
      {:ok, parsed} = EDItEUR.parse_xml(@fixture)
      assert {:ok, _} = EDItEUR.seed(parsed, issue: "73")
      assert {:ok, _} = EDItEUR.seed(parsed, issue: "74")

      issues =
        Codelist
        |> where([c], c.plugin_name == "onixedit" and c.list_id == "onixedit:list_17")
        |> Repo.all()
        |> Enum.map(& &1.issue)
        |> Enum.sort()

      assert issues == ["73", "74"]
    end
  end

  describe "resolve_source/1" do
    test "argument wins over env wins over plugin settings" do
      System.put_env("BARKPARK_ONIX_CODELIST_PATH", "/from/env.xml")

      try do
        assert {:ok, "/explicit.xml"} = EDItEUR.resolve_source(source: "/explicit.xml")

        assert {:ok, "/from/env.xml"} = EDItEUR.resolve_source([])
      after
        System.delete_env("BARKPARK_ONIX_CODELIST_PATH")
      end
    end

    test "returns :not_found when nothing is configured" do
      System.delete_env("BARKPARK_ONIX_CODELIST_PATH")
      assert {:error, :not_found} = EDItEUR.resolve_source([])
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp registry_counts(plugin, issue) do
    codelists =
      Codelist
      |> where([c], c.plugin_name == ^plugin and c.issue == ^issue)
      |> Repo.all()

    codelist_ids = Enum.map(codelists, & &1.id)

    value_count =
      Repo.aggregate(
        from(v in Value, where: v.codelist_id in ^codelist_ids),
        :count
      )

    value_ids = Repo.all(from v in Value, where: v.codelist_id in ^codelist_ids, select: v.id)

    translation_count =
      Repo.aggregate(
        from(t in Translation, where: t.codelist_value_id in ^value_ids),
        :count
      )

    %{
      codelists: length(codelists),
      values: value_count,
      translations: translation_count
    }
  end
end
