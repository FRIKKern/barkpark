defmodule Barkpark.Plugins.FrtExportTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Frt.Export

  # All assertions exercise the PURE helpers (build_types/1, canonical_iodata/1,
  # content_hash/1) — no DB, no app boot.

  describe "build_types/1" do
    test "puts the 7 singletons as single objects, not lists" do
      docs =
        for type <- ~w(coordinatorLoop gameClock player weapon runRuleset arena theme) do
          %{
            "doc_id" => type,
            "type" => type,
            "title" => "Title #{type}",
            "content" => %{"title" => "Title #{type}", "v" => "1"}
          }
        end

      types = Export.build_types(docs)

      for type <- ~w(coordinatorLoop gameClock player weapon runRuleset arena theme) do
        assert is_map(types[type]), "#{type} should be a single object"
        refute is_list(types[type])
        assert types[type]["_id"] == type
        assert types[type]["_title"] == "Title #{type}"
      end
    end

    test "non-singleton types become a list sorted by doc_id" do
      docs = [
        %{
          "doc_id" => "enemyType_runner",
          "type" => "enemyType",
          "title" => "Runner",
          "content" => %{}
        },
        %{
          "doc_id" => "enemyType_grunt",
          "type" => "enemyType",
          "title" => "Grunt",
          "content" => %{}
        },
        %{
          "doc_id" => "enemyType_elite",
          "type" => "enemyType",
          "title" => "Elite",
          "content" => %{}
        }
      ]

      types = Export.build_types(docs)

      assert is_list(types["enemyType"])

      assert Enum.map(types["enemyType"], & &1["_id"]) ==
               ~w(enemyType_elite enemyType_grunt enemyType_runner)
    end

    test "merges _id and _title and strips internal/tenancy fields" do
      docs = [
        %{
          "doc_id" => "enemyType_grunt",
          "type" => "enemyType",
          "title" => "Grunt",
          "content" => %{
            "title" => "Grunt",
            "baseHp" => "120",
            # internal/tenancy keys that may have leaked into content — must go
            "rev" => "deadbeef",
            "dataset_id" => "uuid",
            "workspace_id" => "uuid",
            "project_id" => "uuid",
            "id" => "uuid",
            "inserted_at" => "now",
            "updated_at" => "now",
            "status" => "published",
            "dataset" => "frt",
            "type" => "enemyType"
          }
        }
      ]

      [obj] = Export.build_types(docs)["enemyType"]

      assert obj["_id"] == "enemyType_grunt"
      assert obj["_title"] == "Grunt"
      assert obj["baseHp"] == "120"
      assert obj["title"] == "Grunt"

      for stripped <-
            ~w(rev dataset_id workspace_id project_id id inserted_at updated_at status dataset type) do
        refute Map.has_key?(obj, stripped), "#{stripped} should have been stripped"
      end
    end
  end

  describe "canonical_iodata/1" do
    test "sorts map keys recursively" do
      term = %{
        "zebra" => "1",
        "apple" => "2",
        "nested" => %{"yankee" => "y", "alpha" => "a"}
      }

      out = IO.iodata_to_binary(Export.canonical_iodata(term))

      assert out ==
               ~s({"apple":"2","nested":{"alpha":"a","yankee":"y"},"zebra":"1"})
    end

    test "encodes lists, strings, numbers, booleans and nil as JSON literals" do
      term = %{"list" => ["b", "a"], "n" => 3, "ok" => true, "no" => false, "nada" => nil}

      out = IO.iodata_to_binary(Export.canonical_iodata(term))

      assert out == ~s({"list":["b","a"],"n":3,"nada":null,"no":false,"ok":true})
    end
  end

  describe "content_hash/1" do
    test "is stable: differently-ordered input maps hash identically" do
      a = %{"weapon" => %{"_id" => "weapon", "z" => "1", "a" => "2"}}
      b = %{"weapon" => %{"a" => "2", "_id" => "weapon", "z" => "1"}}

      assert Export.content_hash(a) == Export.content_hash(b)
    end

    test "different content produces a different hash" do
      a = %{"weapon" => %{"_id" => "weapon", "baseDamage" => "4.0"}}
      b = %{"weapon" => %{"_id" => "weapon", "baseDamage" => "5.0"}}

      refute Export.content_hash(a) == Export.content_hash(b)
    end

    test "is a lowercase 64-char hex string" do
      hash = Export.content_hash(%{"x" => %{"_id" => "x"}})

      assert String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
    end
  end
end
