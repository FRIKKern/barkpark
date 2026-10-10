defmodule BarkparkWeb.Search.SearchExactIdTest do
  @moduledoc """
  task-aa52fb0ec971417e: `/v1/data/search?q=drafts.sq-fox` missed the document
  whose id IS the query (ids were not searchable), and could return only a
  sibling whose content mentioned the id. A query equal to a document id, in
  draft or published spelling, now always returns it, ranked first.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @type_name "sxpost"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()
    raw = "sxid-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "sxid", @dataset, ["read", "write"], ws_id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    base = "sq#{System.unique_integer([:positive])}-fox"

    # Titles that share nothing with the ids, so only an id arm can match.
    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => base, "title" => "Quick"}, @dataset)

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => base <> "-rev", "title" => "Quick rev"},
        @dataset
      )

    %{raw: raw, base: base}
  end

  defp ids(raw, q, perspective \\ "drafts") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> get("/v1/data/search/#{@dataset}?q=#{URI.encode_www_form(q)}&perspective=#{perspective}")
    |> json_response(200)
    |> Map.fetch!("documents")
    |> Enum.map(& &1["_id"])
  end

  test "q = a draft id returns that draft first, and its -rev sibling", %{raw: raw, base: base} do
    assert ["drafts." <> ^base, "drafts." <> rev] = ids(raw, "drafts." <> base)
    assert rev == base <> "-rev"
  end

  test "q = the published spelling of the id returns the draft too", %{raw: raw, base: base} do
    assert hd(ids(raw, base)) == "drafts." <> base
  end

  test "an id term without a dot does not prefix-match other ids", %{raw: raw, base: base} do
    refute ("drafts." <> base <> "-rev") in ids(raw, base)
  end

  test "the published perspective still hides drafts", %{raw: raw, base: base} do
    assert ids(raw, "drafts." <> base, "published") == []
  end

  test "a text query unrelated to ids is unchanged (control)", %{raw: raw, base: base} do
    assert Enum.sort(ids(raw, "Quick")) ==
             Enum.sort(["drafts." <> base, "drafts." <> base <> "-rev"])
  end
end
