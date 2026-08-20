defmodule Barkpark.Plugins.ContentProbeTest do
  @moduledoc """
  `ContentProbe.content_get/2` must read a value nested under a doc's `content`
  map across EVERY doc shape Studio hands a resolver — and it must NEVER raise,
  least of all the `Document does not implement the Access behaviour` crash that
  a bare string-key `get_in` throws against a real `%Document{}` struct. Pure —
  no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.ContentProbe

  describe "content_get/2 — the struct raise this module exists to kill" do
    test "reads through a real %Document{} struct with string-keyed content (no raise)" do
      doc = %Document{content: %{"github" => %{"state" => "intake"}}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == "intake"
    end

    test "returns nil (not a raise) for a %Document{} whose content lacks the key" do
      doc = %Document{content: %{"lifecycle_status" => "open"}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == nil
    end

    test "returns nil for a %Document{} with the default empty content map" do
      assert ContentProbe.content_get(%Document{}, ["github", "state"]) == nil
    end

    test "returns nil for a %Document{} whose content was explicitly nil" do
      assert ContentProbe.content_get(%Document{content: nil}, ["github", "state"]) == nil
    end
  end

  describe "content_get/2 — plain-map shapes" do
    test "reads string 'content' key with string-keyed inner map" do
      doc = %{"content" => %{"github" => %{"state" => "intake"}}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == "intake"
    end

    test "reads atom :content key with fully atom-keyed inner map" do
      doc = %{content: %{github: %{state: "intake"}}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == "intake"
    end

    test "mixed: atom :content, string-keyed inner map" do
      doc = %{content: %{"github" => %{"state" => "adopted"}}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == "adopted"
    end

    test "returns nil when a mid-path key is missing" do
      assert ContentProbe.content_get(%{"content" => %{"github" => %{}}}, ["github", "state"]) ==
               nil
    end

    test "returns nil when content is absent entirely" do
      assert ContentProbe.content_get(%{"title" => "x"}, ["github", "state"]) == nil
    end

    test "returns nil when a mid-path value is not a map" do
      doc = %{"content" => %{"github" => "not-a-map"}}
      assert ContentProbe.content_get(doc, ["github", "state"]) == nil
    end

    test "single-key path returns the whole nested value" do
      doc = %{"content" => %{"github" => %{"state" => "intake"}}}
      assert ContentProbe.content_get(doc, ["github"]) == %{"state" => "intake"}
    end
  end

  describe "content_get/2 — non-map / never-raise edge cases" do
    test "returns nil for a non-map doc" do
      assert ContentProbe.content_get(nil, ["github", "state"]) == nil
      assert ContentProbe.content_get("string", ["github", "state"]) == nil
      assert ContentProbe.content_get(42, ["github", "state"]) == nil
    end

    test "does not raise nor mint a new atom for a key that has no existing atom twin" do
      # A random key whose atom was never created must read blank, not blow up
      # String.to_existing_atom — and content_get must never MINT the key's atom.
      #
      # This invariant is KEY-SCOPED, not a whole-VM :atom_count delta. This
      # module is async:true, so `:erlang.system_info(:atom_count) == before`
      # was a false flake: any co-scheduled async test that mints an unrelated
      # atom in the window breaks the global count with zero bug in content_get
      # (this reddened rebased merge-train Test runs — felix wave-8). The real,
      # local claim is proved directly: after the read, the key's atom STILL does
      # not exist, so its existing-atom lookup raises. That reads blank whatever
      # the rest of the VM does.
      key = "zzz_no_such_atom_#{System.unique_integer([:positive])}"
      assert ContentProbe.content_get(%{"content" => %{}}, [key]) == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end
end
