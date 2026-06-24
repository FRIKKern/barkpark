defmodule Barkpark.Sharing.StoredShareTest do
  @moduledoc """
  Pure changeset tests for `Barkpark.Sharing.StoredShare`.

  The `changeset/2` function is a structural guard only — it validates shape
  (all fields present, at least one surface) but does not verify whether surface
  or access tokens are semantically valid; that revalidation happens on read via
  `Sharing.list_stored/0`. No DB access is needed so the suite runs async.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sharing.StoredShare

  @valid_attrs %{
    workspace_slug: "gyldendal",
    project_slug: "books",
    dataset: "production",
    surfaces: ["papers", "docs"],
    access: "read"
  }

  describe "changeset/2 — valid inputs" do
    test "accepts all required fields and produces a valid changeset" do
      cs = StoredShare.changeset(%StoredShare{}, @valid_attrs)
      assert cs.valid?
      assert cs.changes.workspace_slug == "gyldendal"
      assert cs.changes.project_slug == "books"
      assert cs.changes.dataset == "production"
      assert cs.changes.surfaces == ["papers", "docs"]
      assert cs.changes.access == "read"
    end

    test "accepts a single-element surfaces list" do
      attrs = Map.put(@valid_attrs, :surfaces, ["media"])
      cs = StoredShare.changeset(%StoredShare{}, attrs)
      assert cs.valid?
    end

    test "accepts surfaces with unknown tokens — token revalidation is deferred to read" do
      attrs = Map.put(@valid_attrs, :surfaces, ["unknown_surface"])
      cs = StoredShare.changeset(%StoredShare{}, attrs)
      # The changeset is a structural guard; it does NOT reject unknown tokens.
      assert cs.valid?
    end
  end

  describe "changeset/2 — missing required fields" do
    test "is invalid when workspace_slug is missing" do
      cs = StoredShare.changeset(%StoredShare{}, Map.delete(@valid_attrs, :workspace_slug))
      refute cs.valid?
      assert :workspace_slug in Keyword.keys(cs.errors)
    end

    test "is invalid when project_slug is missing" do
      cs = StoredShare.changeset(%StoredShare{}, Map.delete(@valid_attrs, :project_slug))
      refute cs.valid?
      assert :project_slug in Keyword.keys(cs.errors)
    end

    test "is invalid when surfaces is missing" do
      cs = StoredShare.changeset(%StoredShare{}, Map.delete(@valid_attrs, :surfaces))
      refute cs.valid?
      assert :surfaces in Keyword.keys(cs.errors)
    end

    test "is invalid when access is missing" do
      cs = StoredShare.changeset(%StoredShare{}, Map.delete(@valid_attrs, :access))
      refute cs.valid?
      assert :access in Keyword.keys(cs.errors)
    end
  end

  describe "changeset/2 — edge: empty surfaces list" do
    test "is invalid when surfaces is an empty list" do
      cs = StoredShare.changeset(%StoredShare{}, Map.put(@valid_attrs, :surfaces, []))
      refute cs.valid?
      assert :surfaces in Keyword.keys(cs.errors)
    end
  end
end
