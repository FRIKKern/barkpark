defmodule BarkparkWeb.BulldocsBpmlWriteWallTest do
  @moduledoc """
  A BPML push may not change what its pull did not show. Each case pulls a
  Paper through the public source route, pushes the bytes back (edited or
  not) and reads the stored row.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, LabelFixtures, Repo, Tenancy}

  @ds "production"
  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp t(v), do: %{"type" => "text", "value" => v}

  defp slug(name), do: "bpml-write-wall-#{name}-#{System.unique_integer([:positive])}"

  defp paper!(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
  end

  defp paper_schema!(fields) do
    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope
      )
  end

  defp pull(slug) do
    resp = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")
    {response(resp, 200), rev}
  end

  defp sync(slug, bpml, rev) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "an unedited push of a Paper whose pull redacts a nested block field keeps the stored field" do
    paper_schema!([
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [
          %{
            "type" => "object",
            "fields" => [%{"name" => "text", "type" => "string", "private" => true}]
          }
        ]
      }
    ])

    slug = slug("redacted")
    heading = %{"id" => "h", "type" => "heading", "level" => 2, "text" => "PRIVATE_HEADING"}
    paper!(slug, [heading, %{"id" => "p", "type" => "paragraph", "content" => [t("Visible.")]}])

    {bpml, rev} = pull(slug)
    assert bpml =~ ~s(<h2 id="h"></h2>)

    sync(slug, bpml, rev)

    assert [^heading, _] = stored_blocks(slug)
  end
end
