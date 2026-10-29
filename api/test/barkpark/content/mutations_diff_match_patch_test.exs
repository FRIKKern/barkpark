defmodule Barkpark.Content.MutationsDiffMatchPatchTest do
  @moduledoc """
  task-88240409d3fc3c51: the mutate route takes Sanity's `diffMatchPatch` op,
  so two editors typing in one Portable Text span both keep their text. The
  patch strings and expected results below were made with
  @sanity/diff-match-patch 3.2.1 (`makePatches(base, mine)`, then
  `applyPatches` on the text another editor had changed meanwhile).
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

    test "ifRevisionID fences the patch", %{scope: scope, rev: rev} do
      patch = %{"diffMatchPatch" => %{@span => "@@ -12,8 +12,14 @@\n rown fox\n+ jumps\n"}}

      assert {:ok, _} = mutate(Map.put(patch, "ifRevisionID", rev), scope)
      assert span_text(scope) == "The quick brown fox jumps"

      assert {:error, {:rev_mismatch, _}} = mutate(Map.put(patch, "ifRevisionID", rev), scope)
      assert span_text(scope) == "The quick brown fox jumps"
    end
  end
end
