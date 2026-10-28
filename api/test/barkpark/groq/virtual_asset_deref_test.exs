defmodule Barkpark.Groq.VirtualAssetDerefTest do
  @moduledoc """
  task-63d414ef90e9f409: `image.asset->` on the ref the studio stores,
  `asset-<file id>`, answers Sanity's asset document in the published
  perspective, where the file's `mediaAsset` document (a draft) is not
  visible, and adds Sanity's keys to the `mediaAsset` in drafts. Nothing is
  stored. A caller who may not read every type gets null, as before.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Groq, TenancyFixtures}
  alias Barkpark.Content.CallerContext

  import Barkpark.SanityImageFixtures

  @projection ~s({"a": {"_ref": $ref}}.a->{_id, _type, url, path, assetId, extension, mimeType, size, metadata{dimensions, lqip}})

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    token = scope ++ [caller_context: %CallerContext{principal_type: :api_token, token_id: "t"}]
    %{scope: scope, token: token, media: upload!(scope)}
  end

  defp deref(ref, perspective, scope_opts) do
    {:ok, %{result_json: json}} =
      Groq.query(@projection, %{"ref" => ref},
        dataset: "production",
        perspective: perspective,
        scope_opts: scope_opts
      )

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  test "published: asset-<id> answers a Sanity image asset", %{media: file, token: token} do
    out = deref("asset-" <> file.id, :published, token)

    assert out["_id"] == "image-#{file.sha1}-3x2-png"
    assert out["_type"] == "sanity.imageAsset"
    assert out["assetId"] == file.sha1
    assert out["extension"] == "png"
    assert out["mimeType"] == "image/png"
    assert out["size"] == byte_size(png())
    assert out["path"] =~ ~r"\Aimages/[^/]+/production/#{file.sha1}-3x2\.png\z"
    assert out["url"] =~ ~r"\Ahttps?://.+/w/[^/]+/p/[^/]+/#{out["path"]}\z"
    assert %{"width" => 3, "height" => 2, "aspectRatio" => 1.5} = out["metadata"]["dimensions"]

    # The Sanity id resolves to the same document; another size names nothing.
    assert deref(out["_id"], :published, token) == out
    assert deref("image-#{file.sha1}-4x2-png", :published, token) == nil
  end

  test "drafts: the mediaAsset keeps its keys and gains url", %{media: file, token: token} do
    out = deref("asset-" <> file.id, :drafts, token)

    assert out["_id"] == "asset-" <> file.id
    assert out["_type"] == "mediaAsset"
    assert out["url"] =~ "/#{file.sha1}-3x2.png"
    assert out["metadata"]["dimensions"]["width"] == 3
  end

  test "no virtual asset without a full-read token or outside the workspace", %{
    media: file,
    scope: scope
  } do
    assert deref("asset-" <> file.id, :published, scope) == nil

    other = TenancyFixtures.create_workspace!()
    other_project = TenancyFixtures.create_project!(other)

    assert deref("asset-" <> file.id, :published,
             workspace_id: other.id,
             project_id: other_project.id,
             caller_context: %CallerContext{principal_type: :api_token, token_id: "t"}
           ) == nil
  end
end
