defmodule BarkparkWeb.BulldocsBpmlPushRevFenceTest do
  @moduledoc """
  A write that names a BPML push's starting rev as its `ifRev` is fenced by the
  three-way rule on the push's revision: it lands when every block (field batch,
  `fence: :blocks`) or field (patch, `"fence": "fields"`) it touches reads the
  same at that rev and now, and is refused with nothing written when one changed.

  Each Paper is pushed once before the push under test, so its starting rev is
  one that only a push wrote. The field-batch rows give the Paper schema a
  block-editor field, `aside`; the shipped Bulldocs schema has none.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.Document

  @ds "production"
  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp para(id, text), do: %{"id" => id, "type" => "paragraph", "content" => [t(text)]}

  defp paper!(extra) do
    slug = "bpml-push-rev-fence-#{System.unique_integer([:positive])}"
    blocks = [para("p1", "Plain.")]
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))

    content =
      paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html") |> Map.merge(extra)

    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp bpml_push!(slug, from, to) do
    resp = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")

    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{
      "bpml" => String.replace(response(resp, 200), from, to),
      "baseRev" => rev
    })
    |> json_response(200)
  end

  # The Paper pushed once, then pushed again: the second push's starting rev.
  defp start_rev!(slug) do
    bpml_push!(slug, "Plain.", "Plain, one.")
    start = rev(slug)
    bpml_push!(slug, "Plain, one.", "Plain, two.")
    start
  end

  defp rev(slug),
    do:
      Repo.one!(from d in Document, where: d.doc_id == ^slug and d.type == "paper", select: d.rev)

  # Every row of the Paper, drafts too, as stored.
  defp stored(slug),
    do:
      Repo.all(
        from d in Document,
          where: d.doc_id in [^slug, ^("drafts." <> slug)] and d.type == "paper",
          order_by: d.doc_id,
          select: {d.doc_id, d.rev, d.title, d.content}
      )

  defp draft(slug),
    do: Repo.one!(from d in Document, where: d.doc_id == ^"drafts.#{slug}" and d.type == "paper")

  defp texts(blocks), do: Enum.map(blocks, &hd(&1["content"])["value"])

  defp patch_block(id, text),
    do: %{"op" => "patch-block", "id" => id, "patch" => %{"content" => [t(text)]}}

  defp field_batch(doc_id, ops, opts),
    do: Content.apply_field_block_ops(doc_id, "paper", "aside", ops, @ds, opts)

  defp mutate(slug, set, extra \\ %{}),
    do:
      Content.apply_mutations(
        [%{"patch" => Map.merge(%{"id" => slug, "type" => "paper", "set" => set}, extra)}],
        @ds,
        []
      )

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  describe "a field batch from a push's starting rev" do
    setup do
      {:ok, schema} = Content.get_schema("paper", @ds)
      aside = %{"name" => "aside", "type" => "richText", "editor" => "blocks"}

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => schema.title,
            "visibility" => schema.visibility,
            "fields" => schema.fields ++ [aside]
          },
          @ds,
          []
        )

      slug = paper!(%{"aside" => %{"blocks" => [para("a1", "one"), para("a2", "two")]}})
      start = start_rev!(slug)
      # The change made since: a field batch writes `drafts.<slug>`, which the
      # batches below name and edit.
      {:ok, _} = field_batch(slug, [patch_block("a1", "one by them")], if_rev: rev(slug))
      {:ok, slug: slug, start: start}
    end

    test "is refused when a block it touches changed since, and nothing is written",
         %{slug: slug, start: start} do
      before = stored(slug)

      assert {:error, {:rev_mismatch, %{expected: ^start}}} =
               field_batch("drafts." <> slug, [patch_block("a1", "one by me")],
                 if_rev: start,
                 fence: :blocks
               )

      assert stored(slug) == before
    end

    test "lands when every block it touches is unchanged, and keeps the change made since",
         %{slug: slug, start: start} do
      paper_row = Enum.find(stored(slug), &(elem(&1, 0) == slug))

      assert {:ok, _} =
               field_batch("drafts." <> slug, [patch_block("a2", "two by me")],
                 if_rev: start,
                 fence: :blocks
               )

      saved = draft(slug)
      assert texts(saved.content["aside"]["blocks"]) == ["one by them", "two by me"]
      assert texts(saved.content["blocks"]) == ["Plain, two."]
      assert Enum.find(stored(slug), &(elem(&1, 0) == slug)) == paper_row
    end
  end

  describe "a fields-fenced patch from a push's starting rev" do
    setup do
      slug = paper!(%{})
      start = start_rev!(slug)
      {:ok, slug: slug, start: start}
    end

    test "is refused when its Paper's blocks or a field it sets changed since, and nothing is written",
         %{slug: slug, start: start} do
      fenced = %{"ifRevisionID" => start, "fence" => "fields"}

      # The push changed the blocks: every patch reads them.
      before = stored(slug)

      assert {:error, {:rev_mismatch, %{expected: ^start}}} =
               mutate(slug, %{"description" => "mine"}, fenced)

      assert stored(slug) == before

      # Blocks back as they stood at the starting rev; `source_doc` changed since.
      bpml_push!(slug, "Plain, two.", "Plain, one.")
      {:ok, _} = mutate(slug, %{"source_doc" => "theirs"})
      before = stored(slug)

      assert {:error, {:rev_mismatch, %{expected: ^start}}} =
               mutate(slug, %{"source_doc" => "mine"}, fenced)

      assert stored(slug) == before
    end

    test "lands when its Paper's blocks and every field it sets are unchanged, and keeps the change made since",
         %{slug: slug, start: start} do
      bpml_push!(slug, "Plain, two.", "Plain, one.")
      {:ok, _} = mutate(slug, %{"source_doc" => "theirs"})
      paper_row = Enum.find(stored(slug), &(elem(&1, 0) == slug))

      assert {:ok, _} =
               mutate(slug, %{"description" => "mine"}, %{
                 "ifRevisionID" => start,
                 "fence" => "fields"
               })

      saved = draft(slug)
      assert {saved.content["source_doc"], saved.content["description"]} == {"theirs", "mine"}
      assert texts(saved.content["blocks"]) == ["Plain, one."]
      assert Enum.find(stored(slug), &(elem(&1, 0) == slug)) == paper_row
    end
  end
end
