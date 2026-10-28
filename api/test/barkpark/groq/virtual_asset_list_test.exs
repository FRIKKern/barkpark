defmodule Barkpark.Groq.VirtualAssetListTest do
  @moduledoc """
  task-a6372a4ce0216c6c: `*[_type == "sanity.imageAsset"]` and
  `sanity.fileAsset` list the workspace's media files as the virtual asset
  documents `->` answers. Untyped `*` lists none of them, and a caller who
  may not read every type gets none.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Groq, Media, TenancyFixtures}
  alias Barkpark.Content.CallerContext

  import Barkpark.SanityImageFixtures

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    token = scope ++ [caller_context: %CallerContext{principal_type: :api_token, token_id: "t"}]
    image = upload!(scope)

    path = Barkpark.TestTmp.path("notes.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "virtual asset list")

    {:ok, text} =
      Media.upload(
        %Plug.Upload{path: path, filename: "notes.txt", content_type: "text/plain"},
        "production",
        scope
      )

    %{scope: scope, token: token, image: image, text: text}
  end

  defp groq(query, perspective, scope_opts) do
    {:ok, %{result_json: json}} =
      Groq.query(query, %{},
        dataset: "production",
        perspective: perspective,
        scope_opts: scope_opts
      )

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  test "a typed query lists images and files", %{image: image, text: text, token: token} do
    image_id = "image-#{image.sha1}-3x2-png"
    file_id = "file-#{text.sha1}-txt"

    for perspective <- [:published, :drafts] do
      assert groq(~s<*[_type == "sanity.imageAsset"]._id>, perspective, token) == [image_id]
      assert groq(~s<count(*[_type == "sanity.imageAsset"])>, perspective, token) == 1
      assert groq(~s<*[_type == "sanity.fileAsset"]._id>, perspective, token) == [file_id]
    end

    assert %{"url" => url, "metadata" => %{"dimensions" => %{"width" => 3}}} =
             groq(
               ~s<*[_type == "sanity.imageAsset" && _id == "#{image_id}"][0]>,
               :published,
               token
             )

    assert url =~ "/#{image.sha1}-3x2.png"

    assert groq(~s<*[_type == "sanity.fileAsset"][0].url>, :published, token) =~
             "/files/"

    assert groq(
             ~s<*[_type in ["sanity.imageAsset", "sanity.fileAsset"]] | order(_id)[0]._id>,
             :published,
             token
           ) ==
             file_id
  end

  test "untyped * and callers without a full-read token see none", %{
    image: image,
    token: token,
    scope: scope
  } do
    assert groq(~s<*[_id == "image-#{image.sha1}-3x2-png"]>, :published, token) == []
    assert groq(~s<count(*[_type == "sanity.imageAsset"])>, :published, scope) == 0
  end
end
