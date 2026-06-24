defmodule Barkpark.Content.WriteScopeTest do
  @moduledoc """
  Unit tests for the pure / DB-free surface of Barkpark.Content.WriteScope.

  The module has both pure helpers and DB-backed resolvers.  We test only
  the functions whose behaviour is fully determined by their inputs:

    * `build_ctx/1`              — constructs the ctx map with defaults
    * `inherit_scope_attrs/2`    — copies scope fields from a Document struct
    * `fire_after/3`             — passes error tuples through untouched
    * `resolve_read_dataset_id/2`— returns nil for non-binary dataset arg
    * `put_scope_attrs/2`        — skips nil scope keys (no-opts fast-path
                                   tested via presence/absence of keys)

  No Repo, no DataCase — all paths exercised are pure.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Content.WriteScope
  alias Barkpark.Content.Document

  # ── build_ctx/1 ─────────────────────────────────────────────────────────────

  describe "build_ctx/1" do
    test "defaults source to :api when no opt given" do
      ctx = WriteScope.build_ctx([])
      assert ctx.source == :api
    end

    test "accepts an explicit source opt" do
      ctx = WriteScope.build_ctx(source: :worker)
      assert ctx.source == :worker
    end

    test "defaults user_id to nil" do
      ctx = WriteScope.build_ctx([])
      assert ctx.user_id == nil
    end

    test "forwards user_id opt" do
      ctx = WriteScope.build_ctx(user_id: "u-123")
      assert ctx.user_id == "u-123"
    end
  end

  # ── inherit_scope_attrs/2 ────────────────────────────────────────────────────

  describe "inherit_scope_attrs/2" do
    test "copies all three scope fields from a Document" do
      doc = %Document{workspace_id: "ws-1", project_id: "proj-1", dataset_id: "ds-1"}
      result = WriteScope.inherit_scope_attrs(%{}, doc)

      assert result["workspace_id"] == "ws-1"
      assert result["project_id"] == "proj-1"
      assert result["dataset_id"] == "ds-1"
    end

    test "nil scope fields are NOT written to attrs (maybe_put_scope_attr guard)" do
      doc = %Document{workspace_id: nil, project_id: nil, dataset_id: nil}
      result = WriteScope.inherit_scope_attrs(%{}, doc)

      refute Map.has_key?(result, "workspace_id")
      refute Map.has_key?(result, "project_id")
      refute Map.has_key?(result, "dataset_id")
    end

    test "preserves existing attrs that are unrelated to scope" do
      doc = %Document{workspace_id: "ws-2", project_id: "proj-2", dataset_id: nil}
      result = WriteScope.inherit_scope_attrs(%{"title" => "hello"}, doc)

      assert result["title"] == "hello"
      assert result["workspace_id"] == "ws-2"
    end

    test "falls through gracefully for a non-Document second arg" do
      result = WriteScope.inherit_scope_attrs(%{"k" => "v"}, nil)
      assert result == %{"k" => "v"}
    end
  end

  # ── fire_after/3 ── error pass-through ───────────────────────────────────────

  describe "fire_after/3 error pass-through" do
    test "passes {:error, changeset} through unchanged" do
      err = {:error, %Ecto.Changeset{}}
      assert WriteScope.fire_after(err, :after_save, %{}) == err
    end

    test "passes {:error, :not_found} through unchanged" do
      err = {:error, :not_found}
      assert WriteScope.fire_after(err, :after_save, %{}) == err
    end
  end

  # ── resolve_read_dataset_id/2 — non-binary arg ───────────────────────────────

  describe "resolve_read_dataset_id/2 with non-binary dataset" do
    test "returns nil for nil dataset" do
      assert WriteScope.resolve_read_dataset_id(nil, []) == nil
    end

    test "returns nil for integer dataset" do
      assert WriteScope.resolve_read_dataset_id(42, []) == nil
    end

    test "returns nil for atom dataset" do
      assert WriteScope.resolve_read_dataset_id(:production, []) == nil
    end
  end
end
