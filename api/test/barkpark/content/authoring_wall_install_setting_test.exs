defmodule Barkpark.Content.AuthoringWallInstallSettingTest do
  @moduledoc """
  task-8edd8e147c648a36 (ruling "8edd A"): the publish wall is an INSTALL
  setting, `config :barkpark, :authoring_wall`.

    * OFF (the library default; `@barkpark/engine` passes
      `BARKPARK_AUTHORING_WALL=off`): a fresh install publishes a paper with
      only a slug, a title and blocks — no description, no tag, nothing
      registered first.
    * ON (dev, test, prod `runtime.exs` unless the env var is falsy): the same
      request is refused by the wall exactly as before.

  Both arms drive the real ingest door, `POST /v1/plugins/bulldocs/papers`,
  on a dataset with no tag documents at all.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content.AuthoringWall

  @ingest_token "barkpark-test-ingest-token"

  setup do
    prev = Application.get_env(:barkpark, :authoring_wall)
    on_exit(fn -> Application.put_env(:barkpark, :authoring_wall, prev) end)
    :ok
  end

  defp bare_paper(slug) do
    %{
      slug: slug,
      title: "A bare paper #{slug}",
      blocks: [
        %{id: "h", type: "heading", level: 1, text: "A bare paper"},
        %{
          id: "p1",
          type: "paragraph",
          content: [%{type: "text", value: "Only a slug, a title and blocks."}]
        }
      ]
    }
  end

  defp ingest(body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> @ingest_token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers", Jason.encode!(body))
  end

  test "the test install runs the wall (as every instance we run does)" do
    assert AuthoringWall.enabled?()
  end

  test "OFF: a paper with only slug, title and blocks publishes, with no tag registered" do
    Application.put_env(:barkpark, :authoring_wall, false)
    refute AuthoringWall.enabled?()

    slug = "wall-off-#{System.unique_integer([:positive])}"
    resp = ingest(bare_paper(slug))

    assert resp.status in 200..201, resp.resp_body
    refute resp.resp_body =~ "label_spine"

    read = get(scoped_conn(), "/papers/#{slug}")
    assert read.status == 200
    assert read.resp_body =~ "Only a slug, a title and blocks."
  end

  test "ON: the same bare paper is refused by the wall, as before" do
    Application.put_env(:barkpark, :authoring_wall, true)

    resp = ingest(bare_paper("wall-on-#{System.unique_integer([:positive])}"))

    assert resp.status == 422, resp.resp_body
    assert resp.resp_body =~ "label_spine"
  end

  test "OFF: validate_all reports nothing and the dedup recheck is :ok" do
    Application.put_env(:barkpark, :authoring_wall, false)

    ref = %Barkpark.Content.Document{
      doc_id: "x",
      type: "paper",
      title: "x",
      content: %{"title" => "x"},
      dataset: "production"
    }

    assert AuthoringWall.validate_all(ref, "paper", "x", "production") == []
    assert AuthoringWall.recheck_dedup_under_scope_lock(ref, "paper", "x", "production") == :ok
  end

  test "ON: validate_all still names the label spine" do
    Application.put_env(:barkpark, :authoring_wall, true)

    ref = %Barkpark.Content.Document{
      doc_id: "x",
      type: "paper",
      title: "x",
      content: %{"title" => "x"},
      dataset: "production"
    }

    assert Enum.any?(AuthoringWall.validate_all(ref, "paper", "x", "production"), fn {code, _} ->
             code == :label_spine
           end)
  end

  test "/status.json reports the setting" do
    Application.put_env(:barkpark, :authoring_wall, true)
    assert %{"authoring_wall" => true} = json_response(get(scoped_conn(), "/status.json"), 200)

    Application.put_env(:barkpark, :authoring_wall, false)
    assert %{"authoring_wall" => false} = json_response(get(scoped_conn(), "/status.json"), 200)
  end
end
