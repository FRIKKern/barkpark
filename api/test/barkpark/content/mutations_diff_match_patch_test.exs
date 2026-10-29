defmodule Barkpark.Content.MutationsDiffMatchPatchTest do
  @moduledoc """
  task-81fdb9df6eb27d97: the mutate route takes Sanity's `diffMatchPatch` op,
  so two editors typing in one Portable Text span both keep their text. The
  patch strings and expected results here, and in
  `test/fixtures/diff_match_patch/sanity_vectors.json` (115 cases: fuzzy
  placement, failed hunks, emoji, pastes and long deletions), were made with
  @sanity/diff-match-patch 3.2.1: `makePatches(base, mine)`, then
  `applyPatches` on the text another editor had changed meanwhile.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, TenancyFixtures}
  alias Barkpark.Content.DiffMatchPatch

  @golden [
    {"typing at the end", "@@ -4,8 +4,9 @@\n lo world\n+!\n", "Hello world", "Hello world!",
     [true]},
    {"two editors, one span", "@@ -12,8 +12,14 @@\n rown fox\n+ jumps\n",
     "The very quick brown fox", "The very quick brown fox jumps", [true]},
    {"delete while the other types", "@@ -1,14 +1,8 @@\n The \n-quick \n brow\n",
     "The quick brown fox jumps high", "The brown fox jumps high", [true]},
    {"multi-byte", "@@ -3,16 +3,24 @@\n %C3%A5b%C3%A6r og \n+laks og \n %C3%B8rret\n",
     "blåbær, og ørret", "blåbær, og laks og ørret", [true]},
    {"emoji", "@@ -1,15 +1,19 @@\n smile %F0%9F%98%80\n+%F0%9F%98%80\n  here\n",
     "smile 😀 here now", "smile 😀😀 here now", [true]},
    {"context gone", "@@ -1,8 +1,9 @@\n abcd\n+X\n efgh\n", "zzzzzzzzzzzzzzzz",
     "zzzzzzzzzzzzzzzz", [false]},
    {"two hunks after a deletion",
     "@@ -1,12 +1,8 @@\n one \n-two \n thre\n@@ -51,8 +51,9 @@\n n twelve\n+!\n",
     "one two three four five six seven eight nine ten eleven twelve",
     "one three four five six seven eight nine ten eleven twelve!", [true, true]}
  ]

  test "applies patches as @sanity/diff-match-patch does" do
    for {name, patch, current, result, applied} <- @golden do
      assert DiffMatchPatch.apply(patch, current) == {:ok, result, applied}, name
    end

    assert DiffMatchPatch.apply("not a patch", "text") == :error
  end

  test "matches @sanity/diff-match-patch on every pinned vector" do
    vectors =
      "test/fixtures/diff_match_patch/sanity_vectors.json" |> File.read!() |> Jason.decode!()

    assert length(vectors) > 100

    for %{"patch" => patch, "current" => current, "result" => result, "applied" => applied} <-
          vectors do
      assert DiffMatchPatch.apply(patch, current) == {:ok, result, applied},
             "patch #{inspect(patch)} on #{inspect(current)}"
    end
  end

  test "work past the limits is refused, not done" do
    %{patch_bytes: bytes, hunks: hunks, text_units: units, fuzzy_units: fuzzy} =
      DiffMatchPatch.limits()

    long = String.duplicate("ab", div(units, 2) + 1)
    assert {:error, :limit, _} = DiffMatchPatch.apply("@@ -1,2 +1,3 @@\n ab\n+c\n", long)

    big_patch = "@@ -1,2 +1,3 @@\n ab\n+" <> String.duplicate("c", bytes) <> "\n"
    assert {:error, :limit, _} = DiffMatchPatch.apply(big_patch, "ab")

    many = Enum.map_join(1..(hunks + 1), fn _ -> "@@ -1,2 +1,3 @@\n ab\n+c\n" end)
    assert {:error, :limit, _} = DiffMatchPatch.apply(many, "ab")

    # A long deletion whose text changed meanwhile: its diff is over budget.
    base = for i <- 1..(fuzzy + 200), into: "", do: <<?a + rem(i * 7, 26)>>

    changed =
      base
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map_join(fn {c, i} -> if rem(i, 9) == 0, do: "Z", else: c end)

    patch = "@@ -1,#{byte_size(base)} +1,0 @@\n-" <> base <> "\n"
    assert {:error, :limit, message} = DiffMatchPatch.apply(patch, changed)
    assert message =~ "units of diff"
  end

  describe "the mutate route" do
    @ds "dmp"
    @span ~s|body[_key=="b1"].children[_key=="s1"].text|

    setup do
      {ws, project} = TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "visibility" => "public",
            "fields" => [%{"name" => "body", "type" => "json"}]
          },
          @ds,
          scope
        )

      body = [
        %{
          "_key" => "b1",
          "_type" => "block",
          "children" => [%{"_key" => "s1", "_type" => "span", "text" => "The quick brown fox"}]
        }
      ]

      {:ok, doc} =
        Content.create_document(
          "post",
          %{"doc_id" => "p1", "content" => %{"body" => body}},
          @ds,
          scope
        )

      %{scope: scope, rev: doc.rev}
    end

    defp mutate(patch, scope),
      do: Content.apply_mutations([%{"patch" => Map.put(patch, "id", "drafts.p1")}], @ds, scope)

    defp span_text(scope) do
      {:ok, doc} = Content.get_document("drafts.p1", "post", @ds, scope)
      [%{"children" => [%{"text" => text}]}] = doc.content["body"]
      text
    end

    test "two editors typing in one span both keep their text", %{scope: scope} do
      # Editor A typed "very " (as a set); editor B's patch was made before that.
      assert {:ok, _} = mutate(%{"set" => %{@span => "The very quick brown fox"}}, scope)

      assert {:ok, _} =
               mutate(
                 %{"diffMatchPatch" => %{@span => "@@ -12,8 +12,14 @@\n rown fox\n+ jumps\n"}},
                 scope
               )

      assert span_text(scope) == "The very quick brown fox jumps"
    end

    test "a hunk that no longer matches leaves the text as it is", %{scope: scope} do
      assert {:ok, _} =
               mutate(
                 %{"diffMatchPatch" => %{@span => "@@ -1,8 +1,9 @@\n abcd\n+X\n efgh\n"}},
                 scope
               )

      assert span_text(scope) == "The quick brown fox"

      # A path that holds no string is left alone too.
      assert {:ok, _} =
               mutate(
                 %{"diffMatchPatch" => %{~s|body[_key=="b1"].children| => "@@ -1 +1 @@\n-a\n"}},
                 scope
               )

      assert span_text(scope) == "The quick brown fox"
    end

    test "past a limit the batch answers 422 and the text stays", %{scope: scope} do
      too_many = Enum.map_join(1..101, fn _ -> "@@ -1,2 +1,3 @@\n Th\n+X\n" end)

      assert {:error, {:validation_failed, "diffMatchPatch", %{"diffMatchPatch" => [message]}, _}} =
               mutate(%{"diffMatchPatch" => %{@span => too_many}}, scope)

      assert message =~ "over 100 hunks"
      assert span_text(scope) == "The quick brown fox"

      assert {:error, {:validation_failed, "diffMatchPatch", _, _}} =
               mutate(%{"diffMatchPatch" => %{@span => "not a patch"}}, scope)
    end

    test "with fence: fields a stale ifRevisionID still merges a diffMatchPatch-only patch",
         %{scope: scope, rev: rev} do
      assert {:ok, _} = mutate(%{"set" => %{@span => "The very quick brown fox"}}, scope)
      patch = %{"diffMatchPatch" => %{@span => "@@ -12,8 +12,14 @@\n rown fox\n+ jumps\n"}}

      assert {:error, {:rev_mismatch, _}} = mutate(Map.put(patch, "ifRevisionID", rev), scope)

      assert {:ok, _} =
               mutate(patch |> Map.put("ifRevisionID", rev) |> Map.put("fence", "fields"), scope)

      assert span_text(scope) == "The very quick brown fox jumps"
    end

    test "ifRevisionID fences the patch", %{scope: scope, rev: rev} do
      patch = %{"diffMatchPatch" => %{@span => "@@ -12,8 +12,14 @@\n rown fox\n+ jumps\n"}}

      assert {:ok, _} = mutate(Map.put(patch, "ifRevisionID", rev), scope)
      assert span_text(scope) == "The quick brown fox jumps"

      assert {:error, {:rev_mismatch, _}} = mutate(Map.put(patch, "ifRevisionID", rev), scope)
      assert span_text(scope) == "The quick brown fox jumps"
    end
  end
end
