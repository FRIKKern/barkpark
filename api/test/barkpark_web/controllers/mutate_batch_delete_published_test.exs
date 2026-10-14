defmodule BarkparkWeb.MutateBatchDeletePublishedTest do
  @moduledoc """
  task-d374f21e76ea166f: a mutate batch with two or more deletes answered 500
  `internal_error` on gyl (workspace `gyldendal-no`, two and fourteen `tag`
  deletes), while the same deletes sent one per request succeeded.

  These tests replay that request shape on PUBLISHED documents of a schema
  shaped like the gyl `tag` schema: a `reference` field, an array of
  references, and documents in the batch that reference each other.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Content.ReferenceIntegrity
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "mbdp-ws-#{suffix}", name: "Batch delete"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "tag",
          "title" => "Tag",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "mainTag", "type" => "reference", "refType" => "tag"},
            %{
              "name" => "parentTags",
              "type" => "arrayOf",
              "of" => [%{"type" => "reference", "refType" => "tag"}]
            }
          ]
        },
        @dataset,
        scope
      )

    raw = "mbdp-token-#{suffix}"
    {:ok, token} = Auth.create_token(raw, "mbdp writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    {:ok, slug: ws.slug, raw: raw, scope: scope}
  end

  defp mutate(conn, slug, raw, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{slug}/p/default/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => mutations})
    )
  end

  # A create followed by a publish of the same id leaves only the published
  # row, the state the gyl import left its tags in.
  defp put_tag(id, attrs \\ %{}) do
    [
      %{"createOrReplace" => Map.merge(%{"_type" => "tag", "_id" => id, "title" => id}, attrs)},
      %{"publish" => %{"id" => id, "type" => "tag"}}
    ]
  end

  defp delete_tag(id), do: %{"delete" => %{"id" => id, "type" => "tag"}}

  defp seed!(conn, slug, raw, tags) do
    tags
    |> Enum.concat()
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      resp = mutate(conn, slug, raw, chunk)
      assert resp.status == 200, "seeding failed: #{resp.status} #{resp.resp_body}"
    end)
  end

  defp gone?(id, scope) do
    Content.get_document(id, "tag", @dataset, scope) == {:error, :not_found} and
      Content.get_document("drafts." <> id, "tag", @dataset, scope) == {:error, :not_found}
  end

  test "the gyl repro: a batch of two published tag deletes succeeds", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    seed!(conn, slug, raw, [put_tag("evidence"), put_tag("refactor")])
    assert {:ok, %{doc_id: "evidence"}} = Content.get_document("evidence", "tag", @dataset, scope)

    resp = mutate(conn, slug, raw, [delete_tag("evidence"), delete_tag("refactor")])

    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
    assert length(Jason.decode!(resp.resp_body)["results"]) == 2
    assert gone?("evidence", scope)
    assert gone?("refactor", scope)
  end

  test "a batch of 500 published tag deletes succeeds, references inside the batch included", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    ids = for i <- 1..500, do: "mbdp-tag-#{i}"

    # Every tag after the first points at its predecessor through both
    # reference shapes, so the batch deletes referenced documents whose
    # referrers are in the same batch.
    tags =
      ids
      |> Enum.with_index()
      |> Enum.map(fn
        {id, 0} ->
          put_tag(id)

        {id, i} ->
          prev = Enum.at(ids, i - 1)

          put_tag(id, %{
            "mainTag" => %{"_type" => "reference", "_ref" => prev},
            "parentTags" => [%{"_key" => "k#{i}", "_type" => "reference", "_ref" => prev}]
          })
      end)

    seed!(conn, slug, raw, tags)

    resp = mutate(conn, slug, raw, Enum.map(ids, &delete_tag/1))

    assert resp.status == 200, "#{resp.status} #{String.slice(resp.resp_body, 0, 500)}"
    assert length(Jason.decode!(resp.resp_body)["results"]) == 500
    assert Enum.all?(ids, &gone?(&1, scope))
  end

  test "an outside referrer still blocks a batch with 409, not 500", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    seed!(conn, slug, raw, [
      put_tag("mbdp-a"),
      put_tag("mbdp-b"),
      put_tag("mbdp-holder", %{
        "parentTags" => [%{"_key" => "k", "_type" => "reference", "_ref" => "mbdp-b"}]
      })
    ])

    resp = mutate(conn, slug, raw, [delete_tag("mbdp-a"), delete_tag("mbdp-b")])

    assert resp.status == 409, "#{resp.status} #{resp.resp_body}"
    err = Jason.decode!(resp.resp_body)["error"]
    assert err["code"] == "document_referenced"
    assert err["details"]["id"] == "mbdp-b"
    assert err["details"]["referrers"] == [%{"id" => "mbdp-holder", "type" => "tag"}]
  end

  test "a weak reference does not block a batch, a strong one beside it does", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    seed!(conn, slug, raw, [
      put_tag("mbdp-w1"),
      put_tag("mbdp-w2"),
      put_tag("mbdp-w3"),
      put_tag("mbdp-weak-holder", %{
        "parentTags" => [
          %{"_key" => "a", "_type" => "reference", "_ref" => "mbdp-w1", "_weak" => true},
          %{"_key" => "b", "_type" => "reference", "_ref" => "mbdp-w2"}
        ]
      })
    ])

    resp = mutate(conn, slug, raw, [delete_tag("mbdp-w1"), delete_tag("mbdp-w2")])

    assert resp.status == 409, "#{resp.status} #{resp.resp_body}"
    assert Jason.decode!(resp.resp_body)["error"]["details"]["id"] == "mbdp-w2"

    ok = mutate(conn, slug, raw, [delete_tag("mbdp-w1"), delete_tag("mbdp-w3")])
    assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
  end

  test "the structural reference scan is one statement whose SQL does not grow with the run",
       %{conn: conn, slug: slug, raw: raw, scope: scope} do
    ids = for i <- 1..20, do: "mbdp-scan-#{i}"
    seed!(conn, slug, raw, Enum.map(ids, &put_tag/1))

    # Before the fix the scan OR-ed one `jsonb_path_exists` per id, so
    # Postgres walked every document's content once per deleted id. Now the
    # id list is one array parameter and each document is walked once.
    two = jsonpath_statements(Enum.take(ids, 2), scope)
    twenty = jsonpath_statements(ids, scope)

    assert length(twenty) == 1, "expected one jsonpath scan, got: #{inspect(twenty)}"
    assert two == twenty, "the scan SQL changed with the run length"

    [sql] = twenty
    assert length(String.split(sql, "jsonb_path_")) == 2, "expected one jsonpath call: #{sql}"
  end

  defp jsonpath_statements(ids, scope) do
    {_, events} =
      Barkpark.QueryCounter.capture(fn ->
        ReferenceIntegrity.referrers_for_ids(ids, @dataset, scope)
      end)

    events |> Enum.map(& &1.query) |> Enum.filter(&String.contains?(&1, "jsonb_path_"))
  end
end
