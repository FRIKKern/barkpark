defmodule BarkparkWeb.DatasetDeleteRefusalVisibleTest do
  @moduledoc """
  A dataset delete refused because documents outside it embed its media names
  only the documents the caller can read (task-4c1169363b1c3436). The count
  stays the gate's, and the dataset stays.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Media.WhereUsed
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @prod "rv-prod"
  @stage "rv-stage"
  @hidden ["NULL-WORKSPACE", "rv-null", "OTHER-PROJECT", "rv-other"]

  setup do
    ws = create_workspace!()
    pa = create_project!(ws)
    pb = create_project!(ws)
    {:ok, prod} = Tenancy.get_or_create_dataset(pa, @prod)
    {:ok, _stage} = Tenancy.get_or_create_dataset(pa, @stage)
    {:ok, other} = Tenancy.get_or_create_dataset(pb, @prod)

    {:ok, file} = create_media_file_in!(ws, pa, %{}, @stage)
    url = WhereUsed.delivery_path(file)

    doc = fn attrs ->
      Repo.insert!(
        struct(
          Document,
          Map.merge(
            %{
              type: "post",
              dataset: @prod,
              status: "published",
              rev: "rv-#{System.unique_integer([:positive])}",
              content: %{"body" => url}
            },
            attrs
          )
        )
      )
    end

    doc.(%{
      doc_id: "rv-visible",
      title: "VISIBLE-PROD",
      workspace_id: ws.id,
      project_id: pa.id,
      dataset_id: prod.id
    })

    doc.(%{doc_id: "rv-null", title: "NULL-WORKSPACE", workspace_id: nil, project_id: nil})

    doc.(%{
      doc_id: "rv-other",
      title: "OTHER-PROJECT",
      workspace_id: ws.id,
      project_id: pb.id,
      dataset_id: other.id
    })

    %{ws: ws, pa: pa}
  end

  defp owner!(ws, dataset, bound?) do
    raw = "rv-owner-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "rv-owner", dataset, ~w(read write admin))
    if bound?, do: token |> Ecto.Changeset.change(dataset_bound: true) |> Repo.update!()
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner", "api_token")
    raw
  end

  defp delete_stage(raw, %{ws: ws, pa: pa}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> delete("/w/#{ws.slug}/p/#{pa.slug}/v1/datasets/#{@stage}")
  end

  defp refusal!(conn) do
    assert %{"error" => %{"code" => "dataset_media_referenced", "details" => details}} =
             json_response(conn, 409)

    refute conn.resp_body =~ "row_id"
    Enum.each(@hidden, &refute(conn.resp_body =~ &1, "names hidden #{&1}"))
    [file] = details["media"]
    file
  end

  test "an owner is told about its own project's document, never another project's or the NULL layer",
       ctx do
    file = refusal!(delete_stage(owner!(ctx.ws, "production", false), ctx))

    assert [%{"doc_id" => "rv-visible", "title" => "VISIBLE-PROD"}] = file["sample"]
    assert file["count"] == 3
    assert Tenancy.get_dataset(ctx.pa, @stage)
  end

  test "a token bound to the dataset is told about no document in another dataset", ctx do
    file = refusal!(delete_stage(owner!(ctx.ws, @stage, true), ctx))

    assert file["sample"] == []
    refute Jason.encode!(file) =~ "VISIBLE-PROD"
    assert Tenancy.get_dataset(ctx.pa, @stage)
  end
end
