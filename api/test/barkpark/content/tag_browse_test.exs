defmodule Barkpark.Content.TagBrowseTest do
  @moduledoc """
  `Content.Query.docs_with_tag/4` `order: :strength` — the tag-detail ranking
  (authoring-excellence ae-w10). Mutation-proven contracts:

    * STRENGTH ORDER — carriers rank by the ASKED tag's strength DESC. The
      fixture's title order ("A Weak" < "M Legacy" < "Z Strong") deliberately
      INVERTS the strength order, so removing the `order: :strength` arm
      (falling back to title order) REDS the ordering assertion.
    * NULLS LAST — a legacy flat-string carrier has NO weighted entry → NULL
      strength. Postgres `DESC` defaults NULLS FIRST, so mutating
      `desc_nulls_last` to `desc` ranks "M Legacy" FIRST and REDS the same
      assertion (both documented mutation runs in the task ledger).
    * DUAL-SHAPE membership — the legacy flat carrier IS in the result (the
      `e #>> '{}'` arm over `tags_meta`), ranked last, never dropped.
    * GUARDED CAST — a non-digit strength ("high") fails the digits regex
      instead of blowing up `::int`; the doc ranks with the NULL cohort.
    * MATCHED projection — `strength`/`rationale` are the ASKED tag's entry
      (never the doc's overall max), `title` is the COLUMN (content carries
      no title — the D69 trap), `main_tag_match` is case-insensitive.
    * `published_only: true` — draft-status and `drafts.`-prefixed rows are
      excluded; DEFAULT (absent) keeps the historical struct read untouched.

  Docs are inserted DIRECTLY (`Repo.insert!`) — the wall is a write-time
  concern; Postgres computes the `tags_meta` GENERATED column however the row
  arrived (the `Content.RelatedTest` precedent).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @ds "tag-browse-test"
  @tag_name "focus"

  defp insert_doc!(doc_id, title, content, opts \\ []) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: Keyword.get(opts, :type, "post"),
      dataset: Keyword.get(opts, :dataset, @ds),
      title: title,
      status: Keyword.get(opts, :status, "published"),
      content: content,
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id)
    })
  end

  defp weighted(pairs) do
    %{
      "tags" =>
        Enum.map(pairs, fn {tag, strength} ->
          %{"tag" => tag, "strength" => strength, "rationale" => "because #{tag}-#{strength}"}
        end)
    }
  end

  describe "docs_with_tag/4 order: :strength" do
    setup do
      # Title order (A, M, Z) INVERTS strength order (Z 90, A 10, M NULL) —
      # the mutation tripwire for both the order arm and NULLS LAST.
      insert_doc!("tb-weak", "A Weak", weighted([{@tag_name, 10}]))
      insert_doc!("tb-legacy", "M Legacy", %{"tags" => [@tag_name]})
      insert_doc!("tb-strong", "Z Strong", weighted([{@tag_name, 90}]))
      :ok
    end

    test "ranks by strength DESC with legacy (NULL) carriers LAST, never dropped" do
      docs = Content.docs_with_tag(@tag_name, "post", @ds, order: :strength)

      assert Enum.map(docs, & &1.doc_id) == ["tb-strong", "tb-weak", "tb-legacy"]

      # The dual-shape guarantee: the flat-string carrier is PRESENT with a
      # NULL strength/rationale (no weighted entry to match).
      legacy = List.last(docs)
      assert legacy.doc_id == "tb-legacy"
      assert legacy.strength == nil
      assert legacy.rationale == nil
    end

    test "projects the ASKED tag's matched entry, the title COLUMN, and main_tag_match" do
      # Overall-max decoy: "other" at 95 must NOT become the matched strength.
      insert_doc!(
        "tb-mixed",
        "Mixed Doc",
        weighted([{@tag_name, 20}, {"other", 95}]) |> Map.put("main_tag", "Focus")
      )

      docs = Content.docs_with_tag(@tag_name, "post", @ds, order: :strength)
      mixed = Enum.find(docs, &(&1.doc_id == "tb-mixed"))

      assert mixed.strength == 20
      assert mixed.rationale == "because #{@tag_name}-20"
      # The title COLUMN, not content->>'title' (which is absent).
      assert mixed.title == "Mixed Doc"
      assert mixed.type == "post"
      # main_tag "Focus" matches tag "focus" case-insensitively.
      assert mixed.main_tag_match == true

      strong = Enum.find(docs, &(&1.doc_id == "tb-strong"))
      assert strong.main_tag_match == false

      # Matched-strength ordering: 90 > 20 > 10 > NULL.
      assert Enum.map(docs, & &1.doc_id) == ["tb-strong", "tb-mixed", "tb-weak", "tb-legacy"]
    end

    test "guarded cast: a non-digit strength joins the NULL cohort instead of crashing" do
      insert_doc!("tb-bogus", "B Bogus", %{
        "tags" => [%{"tag" => @tag_name, "strength" => "high", "rationale" => "r"}]
      })

      docs = Content.docs_with_tag(@tag_name, "post", @ds, order: :strength)

      bogus = Enum.find(docs, &(&1.doc_id == "tb-bogus"))
      assert bogus.strength == nil
      # NULL cohort ranks after every real strength ("B Bogus" < "M Legacy" by title).
      assert Enum.map(docs, & &1.doc_id) == ["tb-strong", "tb-weak", "tb-bogus", "tb-legacy"]
    end

    test "published_only: true drops draft-status and drafts.-prefixed rows" do
      insert_doc!("tb-draft", "Draft Doc", weighted([{@tag_name, 99}]), status: "draft")

      insert_doc!("drafts.tb-twin", "Twin Draft", weighted([{@tag_name, 99}]))

      ids =
        Content.docs_with_tag(@tag_name, "post", @ds, order: :strength, published_only: true)
        |> Enum.map(& &1.doc_id)

      refute "tb-draft" in ids
      refute "drafts.tb-twin" in ids
      assert ids == ["tb-strong", "tb-weak", "tb-legacy"]
    end

    test "accepts a type LIST — one query, one strength order across types" do
      insert_doc!("tb-task", "Task Carrier", weighted([{@tag_name, 50}]), type: "task")

      ids =
        Content.docs_with_tag(@tag_name, ["post", "task"], @ds, order: :strength)
        |> Enum.map(& &1.doc_id)

      assert ids == ["tb-strong", "tb-task", "tb-weak", "tb-legacy"]
    end

    test "default order (no :strength) still returns title-ordered Document structs" do
      docs = Content.docs_with_tag(@tag_name, "post", @ds)

      assert Enum.map(docs, & &1.doc_id) == ["tb-weak", "tb-legacy", "tb-strong"]
      assert %Document{} = hd(docs)
    end
  end
end
