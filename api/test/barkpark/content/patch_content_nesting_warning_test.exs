defmodule Barkpark.Content.PatchContentNestingWarningTest do
  @moduledoc """
  Option-1 (make-it-loud) coverage for the patch double-nest trap.

  A `patch.set` map is merged INTO the document's `content`, so a `set` field
  literally named `content` lands the caller's data at `content.content.*` — the
  `--set 'content:={"blocks":…}'` footgun that silently no-ops the real blocks.
  The approved fix does NOT change the merge (semantics stay byte-identical); it
  only emits a non-blocking `Warnings` advisory. These tests pin that the
  advisory fires for the map-valued `content` shape and stays quiet otherwise.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Warnings

  @dataset "patch_nest_test"
  @code "patch.content_nested"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp seed(id) do
    {:ok, {_tx, [_result]}} =
      Content.apply_mutations(
        [
          %{
            "create" => %{
              "_id" => id,
              "_type" => "post",
              "title" => "T",
              "content" => %{"blocks" => []}
            }
          }
        ],
        @dataset,
        []
      )

    :ok
  end

  # Mirror the controller: open the queue (reset), apply, drain the advisories.
  defp patch_warnings(id, set_fields) do
    Warnings.reset()

    {:ok, {_tx, _results}} =
      Content.apply_mutations(
        [%{"patch" => %{"id" => id, "type" => "post", "set" => set_fields}}],
        @dataset,
        []
      )

    Warnings.drain()
  end

  test "a patch `set` with a MAP-valued `content` field emits the double-nest advisory" do
    seed("p-nest")

    warnings =
      patch_warnings("p-nest", %{
        "content" => %{"blocks" => [%{"type" => "paragraph", "text" => "hi"}]}
      })

    entry = Enum.find(warnings, &(&1.code == @code))
    assert entry, "expected a #{@code} advisory, got: #{inspect(warnings)}"
    assert entry.severity == "advisory"
    assert entry.message =~ "nested `content.content`"
    assert entry.message =~ "blocks:="
  end

  test "a normal patch `set` (blocks + title, no map content) emits NO double-nest advisory" do
    seed("p-plain")

    warnings =
      patch_warnings("p-plain", %{
        "blocks" => [%{"type" => "paragraph", "text" => "hi"}],
        "title" => "New title"
      })

    refute Enum.any?(warnings, &(&1.code == @code)),
           "a well-formed patch must not warn, got: #{inspect(warnings)}"
  end

  test "a SCALAR `content` field (a legit content-level string) stays quiet — only the map shape warns" do
    seed("p-scalar")

    warnings = patch_warnings("p-scalar", %{"content" => "just a string"})

    refute Enum.any?(warnings, &(&1.code == @code)),
           "a scalar content field is not the double-nest shape and must not warn, got: #{inspect(warnings)}"
  end
end
