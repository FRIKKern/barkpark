defmodule BarkparkWeb.MediaDatasetBindingTest do
  @moduledoc """
  task-9d76210585fa665b — the media half of the `dataset_bound` fence
  (task-4418b517649a58ce).

  The by-id media reads (`/media/:id/meta`, `/media/files/*path`, and their
  `/w/:ws/p/:proj/media` mirrors) name no dataset, so the request-level fence
  had nothing to compare; and an upload naming no dataset landed in
  `"production"`. A token minted with an explicit dataset could therefore read
  any dataset's media by id and upload outside its binding.

  Now: a bound token reads only its own dataset's rows by id (another
  dataset's row answers 404, the same as a miss), an upload with no `dataset`
  lands in the bound dataset, and an upload naming another dataset is refused
  403 `dataset_not_bound`. Unbound tokens keep today's behaviour.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Media, Repo}
  alias Barkpark.Media.Storage.MediaFile

  @own "e2e-local"
  @other "e2e-sanity-builder"

  # 1x1 transparent PNG (mirrors media_test.exs).
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup :reset_rate_limiter!

  setup do
    bound = "mdsb-bound-#{System.unique_integer([:positive])}"
    unbound = "mdsb-unbound-#{System.unique_integer([:positive])}"
    ws = default_workspace_id!()

    {:ok, _} =
      Auth.create_token(bound, "mdsb-bound", @own, ["read", "write"], ws, dataset_bound: true)

    {:ok, _} = Auth.create_token(unbound, "mdsb-unbound", @own, ["read", "write"], ws)

    %{bound: bound, unbound: unbound}
  end

  defp as(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp png_upload do
    tmp = Path.join(System.tmp_dir!(), "mdsb-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}
  end

  defp upload(raw, extra \\ %{}),
    do: as(raw) |> post("/media/upload", Map.merge(%{"file" => png_upload()}, extra))

  defp uploaded!(conn) do
    body = json_response(conn, 201)
    on_exit(fn -> rm_uploaded(body) end)
    Repo.get!(MediaFile, body["id"])
  end

  defp rm_uploaded(%{"url" => "/media/files/" <> relative}),
    do: File.rm(Path.join(Media.upload_dir(), relative))

  defp rm_uploaded(_), do: :ok

  defp assert_dataset_refusal(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["error"]["reason"] == "dataset_not_bound", conn.resp_body
  end

  describe "upload" do
    test "a bound token's upload with no dataset lands in its bound dataset", %{bound: bound} do
      assert %MediaFile{dataset: @own} = uploaded!(upload(bound))
    end

    test "a bound token's upload naming another dataset is refused, and nothing is stored",
         %{bound: bound} do
      before = Repo.aggregate(MediaFile, :count)
      assert_dataset_refusal(upload(bound, %{"dataset" => @other}))
      assert Repo.aggregate(MediaFile, :count) == before
    end

    test "an unbound token's upload with no dataset still lands in production",
         %{unbound: unbound} do
      assert %MediaFile{dataset: "production"} = uploaded!(upload(unbound))
    end
  end

  describe "reads by id (flat /media)" do
    setup %{bound: bound, unbound: unbound} do
      %{
        own: uploaded!(upload(bound)),
        other: uploaded!(upload(unbound, %{"dataset" => @other}))
      }
    end

    test "meta: own dataset 200, another dataset 404", %{bound: bound, own: own, other: other} do
      assert (as(bound) |> get("/media/#{own.id}/meta")).status == 200
      assert (as(bound) |> get("/media/#{other.id}/meta")).status == 404
    end

    test "files: own dataset 200, another dataset 404", %{bound: bound, own: own, other: other} do
      assert (as(bound) |> get("/media/files/#{own.path}")).status == 200
      assert (as(bound) |> get("/media/files/#{other.path}")).status == 404
    end

    test "an unbound token still reads another dataset's file by id",
         %{unbound: unbound, other: other} do
      assert (as(unbound) |> get("/media/#{other.id}/meta")).status == 200
      assert (as(unbound) |> get("/media/files/#{other.path}")).status == 200
    end
  end

  describe "reads by id (scoped /w/:ws/p/:proj/media)" do
    test "meta: own dataset 200, another dataset 404" do
      ws = create_workspace!()
      proj = create_project!(ws)
      raw = "mdsb-scoped-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "mdsb-scoped", @own, ["read"], ws.id, dataset_bound: true)

      {:ok, own} = create_media_file_in!(ws, proj, %{}, @own)
      {:ok, other} = create_media_file_in!(ws, proj, %{}, @other)
      base = "/w/#{ws.slug}/p/#{proj.slug}/media"

      assert (as(raw) |> get("#{base}/#{own.id}/meta")).status == 200
      assert (as(raw) |> get("#{base}/#{other.id}/meta")).status == 404
    end
  end
end
