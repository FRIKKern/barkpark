defmodule BarkparkWeb.MediaDeleteRefusalSameIdTest do
  @moduledoc """
  task-29ef6d1ab344a01b, the two ways round a filter by `doc_id` alone.

  The media delete refusal names only documents the caller can read. A hidden
  document can share a readable one's `doc_id` (another project of the same
  workspace, same dataset name), so the refusal matches the stored ROW, not
  the id. And a dataset-bound token cannot read the project's other datasets,
  so the refusal it gets names none of their documents.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Tenancy}
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @ds "rs-prod"
  @ds2 "rs-stage"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    ws = create_workspace!("rs-ws-#{System.unique_integer([:positive])}")
    pa = create_project!(ws, "rs-a-#{System.unique_integer([:positive])}")
    pb = create_project!(ws, "rs-b-#{System.unique_integer([:positive])}")
    {:ok, da} = Tenancy.get_or_create_dataset(pa, @ds)
    {:ok, da2} = Tenancy.get_or_create_dataset(pa, @ds2)
    {:ok, db} = Tenancy.get_or_create_dataset(pb, @ds)

    member = "rs-member-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(member, "member", @ds, ["read", "write"], ws.id)
    bound = "rs-bound-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(bound, "bound", @ds, ["read", "write"], ws.id, dataset_bound: true)

    %{ws: ws, pa: pa, da: da, da2: da2, pb: pb, db: db, member: member, bound: bound}
  end

  defp bearer(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("x-requested-with", "bp-media-picker")
  end

  defp base(ctx), do: "/w/#{ctx.ws.slug}/p/#{ctx.pa.slug}/v1/media/#{@ds}"

  defp upload!(ctx, raw) do
    tmp = Path.join(System.tmp_dir!(), "rs-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    upload = %Plug.Upload{path: tmp, filename: "logo.png", content_type: "image/png"}
    resp = post(bearer(raw), base(ctx) <> "/upload", %{"file" => upload})
    assert resp.status in [200, 201], resp.resp_body
    result = Jason.decode!(resp.resp_body)["result"]
    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), result["path"])) end)
    Repo.get!(MediaFile, result["id"])
  end

  defp doc!(file, attrs) do
    defaults = %{
      type: "post",
      dataset: @ds,
      status: "published",
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{"blocks" => [%{"type" => "image", "src" => "/media/files/#{file.path}"}]}
    }

    Repo.insert!(struct(Document, Map.merge(defaults, attrs)))
  end

  test "a hidden document with a readable one's doc_id is not named", ctx do
    file = upload!(ctx, ctx.member)
    own = %{workspace_id: ctx.ws.id, project_id: ctx.pa.id, dataset_id: ctx.da.id}
    other = %{workspace_id: ctx.ws.id, project_id: ctx.pb.id, dataset_id: ctx.db.id}
    doc!(file, Map.merge(own, %{doc_id: "rs-same", title: "Own visible"}))
    doc!(file, Map.merge(other, %{doc_id: "rs-same", title: "Other project same id secret"}))

    body =
      bearer(ctx.member) |> delete(base(ctx) <> "/#{file.id}") |> json_response(409)

    assert [%{"doc_id" => "rs-same", "title" => "Own visible"}] =
             body["error"]["details"]["referencedBy"]

    refute Jason.encode!(body) =~ "Other project same id secret"
    assert Repo.get(MediaFile, file.id)
  end

  test "a dataset-bound token is not told about documents in another dataset", ctx do
    file = upload!(ctx, ctx.bound)
    scope = %{workspace_id: ctx.ws.id, project_id: ctx.pa.id}
    doc!(file, Map.merge(scope, %{doc_id: "rs-own", title: "Bound own", dataset_id: ctx.da.id}))

    doc!(
      file,
      Map.merge(scope, %{
        doc_id: "rs-stage-doc",
        title: "Stage secret",
        dataset: @ds2,
        dataset_id: ctx.da2.id
      })
    )

    body = bearer(ctx.bound) |> delete(base(ctx) <> "/#{file.id}") |> json_response(409)

    assert Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"]) == ["rs-own"]
    refute Jason.encode!(body) =~ "rs-stage-doc"
    refute Jason.encode!(body) =~ "Stage secret"

    # The member token, which may read both datasets, is told about both.
    member_body =
      bearer(ctx.member) |> delete(base(ctx) <> "/#{file.id}") |> json_response(409)

    assert member_body["error"]["details"]["referencedBy"]
           |> Enum.map(& &1["doc_id"])
           |> Enum.sort() == ["rs-own", "rs-stage-doc"]
  end
end
