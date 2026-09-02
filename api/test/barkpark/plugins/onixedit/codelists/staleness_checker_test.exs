defmodule Barkpark.Plugins.OnixEdit.Codelists.StalenessCheckerTest do
  @moduledoc """
  Phase 8 WI4 — pure-data tests for the StalenessChecker module. No DB,
  no IO; every fixture is a plain map. Tests cover detect_stale/2 and
  revalidate/2 across the four status outcomes plus acknowledgement.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker

  defp doc_with_refs(refs, extras \\ %{}) when is_map(refs) do
    %{content: Map.merge(refs, extras)}
  end

  describe "detect_stale/2 — status classification" do
    test "returns :current when ref_issue matches the registry" do
      doc =
        doc_with_refs(%{
          "notificationType" => %{
            "codelistId" => "onixedit:notification_type",
            "issue_version" => "73"
          }
        })

      assert [%{status: :current, codelist: "onixedit:notification_type", ref_issue: "73"}] =
               StalenessChecker.detect_stale(doc, "73")
    end

    test "returns :stale when ref_issue is numerically lower than the registry" do
      doc =
        doc_with_refs(%{
          "notificationType" => %{
            "codelistId" => "onixedit:notification_type",
            "issue_version" => "73"
          }
        })

      assert [%{status: :stale, ref_issue: "73", current_issue: "74"}] =
               StalenessChecker.detect_stale(doc, "74")
    end

    test "returns :deprecated when the ref carries the deprecated flag" do
      doc =
        doc_with_refs(%{
          "deprecatedField" => %{
            "codelistId" => "onixedit:legacy_id",
            "issue_version" => "70",
            "deprecated" => true
          }
        })

      assert [%{status: :deprecated, codelist: "onixedit:legacy_id"}] =
               StalenessChecker.detect_stale(doc, "74")
    end

    test "treats refs in acknowledged docs as :acknowledged when they would be stale" do
      doc =
        doc_with_refs(
          %{
            "notificationType" => %{
              "codelistId" => "onixedit:notification_type",
              "issue_version" => "73"
            }
          },
          %{"staleness_acknowledged" => true}
        )

      assert [%{status: :acknowledged}] = StalenessChecker.detect_stale(doc, "74")
    end

    test "leaves :current refs unchanged even when the doc is acknowledged" do
      doc =
        doc_with_refs(
          %{
            "notificationType" => %{
              "codelistId" => "onixedit:notification_type",
              "issue_version" => "74"
            }
          },
          %{"staleness_acknowledged" => true}
        )

      assert [%{status: :current}] = StalenessChecker.detect_stale(doc, "74")
    end
  end

  describe "detect_stale/2 — path tracking" do
    test "surfaces nested refs inside composites with dotted paths" do
      doc =
        doc_with_refs(%{
          "recordSourceIdentifier" => %{
            "recordSourceIdentifierType" => %{
              "codelistId" => "onixedit:name_id_type",
              "issue_version" => "73"
            }
          }
        })

      [ref] = StalenessChecker.detect_stale(doc, "74")
      assert ref.path == "recordSourceIdentifier.recordSourceIdentifierType"
      assert ref.status == :stale
    end

    test "surfaces refs nested in arrays with index segments" do
      doc =
        doc_with_refs(%{
          "contributors" => [
            %{
              "role" => %{
                "codelistId" => "onixedit:contributor_role",
                "issue_version" => "73"
              }
            },
            %{
              "role" => %{
                "codelistId" => "onixedit:contributor_role",
                "issue_version" => "74"
              }
            }
          ]
        })

      refs = StalenessChecker.detect_stale(doc, "74")
      assert length(refs) == 2
      paths = Enum.map(refs, & &1.path)
      assert "contributors.0.role" in paths
      assert "contributors.1.role" in paths

      stale = Enum.find(refs, &(&1.path == "contributors.0.role"))
      current = Enum.find(refs, &(&1.path == "contributors.1.role"))
      assert stale.status == :stale
      assert current.status == :current
    end

    test "ignores plain scalar values (no codelist ref shape)" do
      doc =
        doc_with_refs(%{
          "title" => "My Book",
          "isbn" => "9781234567890"
        })

      assert [] = StalenessChecker.detect_stale(doc, "74")
    end
  end

  describe "revalidate/2" do
    test "returns :changed entries when ref issue diverges from registry" do
      doc =
        doc_with_refs(%{
          "notificationType" => %{
            "codelistId" => "onixedit:notification_type",
            "issue_version" => "73"
          }
        })

      registry = %{
        "onixedit:notification_type" => %{issue_version: "74", codes: :any}
      }

      assert %{changed: [%{from: "73", to: "74", codelist: "onixedit:notification_type"}]} =
               StalenessChecker.revalidate(doc, registry)
    end

    test "returns :removed entries when ref code is no longer in the current registry" do
      doc =
        doc_with_refs(%{
          "productForm" => %{
            "codelistId" => "onixedit:product_form",
            "issue_version" => "74",
            "code" => "OBSOLETE"
          }
        })

      registry = %{
        "onixedit:product_form" => %{issue_version: "74", codes: ["BA", "BB", "BC"]}
      }

      assert %{
               removed: [
                 %{path: "productForm", codelist: "onixedit:product_form", code: "OBSOLETE"}
               ]
             } = StalenessChecker.revalidate(doc, registry)
    end

    test "returns :added entries for codelists in the registry but not in the doc" do
      doc = doc_with_refs(%{"title" => "no codelists"})

      registry = %{
        "onixedit:contributor_role" => %{issue_version: "74", codes: :any},
        "onixedit:product_form" => %{issue_version: "74", codes: :any}
      }

      diff = StalenessChecker.revalidate(doc, registry)
      assert length(diff.added) == 2
      assert Enum.all?(diff.added, &Map.has_key?(&1, :codelist))
      assert Enum.all?(diff.added, &(&1.issue_version == "74"))
    end

    test "acknowledged docs return an empty diff" do
      doc =
        doc_with_refs(
          %{
            "notificationType" => %{
              "codelistId" => "onixedit:notification_type",
              "issue_version" => "73"
            }
          },
          %{"staleness_acknowledged" => true}
        )

      registry = %{
        "onixedit:notification_type" => %{issue_version: "74", codes: :any}
      }

      assert %{added: [], removed: [], changed: []} = StalenessChecker.revalidate(doc, registry)
    end
  end

  describe "corpus_coverage/1 — non-vacuity" do
    # THE POINT OF THIS BLOCK. Every fixture above hand-builds a map carrying
    # BOTH "codelistId" and "issue_version" — a shape a real `book` document
    # cannot hold, because `Barkpark.Content.Validation` rejects any `codelist`
    # field whose value is not a plain string. So the green tests above prove
    # the classifier's arithmetic and nothing about whether it ever SEES a ref
    # in production. `corpus_coverage/1` is the assertion that closes that gap:
    # it lets a caller distinguish "no drift" from "recognized nothing".

    test "an empty corpus is :empty, not :blind" do
      assert StalenessChecker.corpus_coverage([]) == :empty
    end

    test "a corpus where every document yields zero refs is :blind" do
      assert StalenessChecker.corpus_coverage([[], [], []]) == :blind
    end

    test "one recognized ref anywhere makes the corpus :instrumented" do
      doc =
        doc_with_refs(%{
          "notificationType" => %{
            "codelistId" => "onixedit:notification_type",
            "issue_version" => "73"
          }
        })

      refs = StalenessChecker.detect_stale(doc, "73")
      assert refs != []
      assert StalenessChecker.corpus_coverage([[], refs, []]) == :instrumented
    end

    test "PRODUCTION-SHAPED content reads as :blind — a plain-string codelist value" do
      # This is what a real book carries: `codelist` field values are plain
      # strings (Content.Validation: "codelist value must be a string"), never
      # a nested ref map. detect_stale/2 therefore recognizes nothing, and the
      # corpus must report :blind rather than letting a caller conclude
      # "all current".
      book = %{
        content: %{
          "notificationType" => "03",
          "productForm" => "BB",
          "subjects" => [%{"scheme" => "thema", "code" => "FBA"}]
        }
      }

      refs = StalenessChecker.detect_stale(book, "74")

      assert refs == []
      assert StalenessChecker.corpus_coverage([refs]) == :blind
    end
  end
end
