defmodule BarkparkWeb.Contract.FederatedMediaTierClampTest do
  @moduledoc """
  The flat federated `GET /v1/search/:dataset` MEDIA leg, two holes left after
  task-0fcec595765a7b00 (r2-lane-c authz sweep, 2026-10-01):

    1. It decided "may see non-public assets?" by token PRESENCE, so a
       `public-read` site token — a real token, but a public-tier caller, the
       credential that ships in public site builds — received PRIVATE assets,
       URLs included. The V1 media controller keys the same question on the
       tier-aware `Media.Storage.Access.authenticated?/1`.
    2. The clamp ran AFTER the query: private files were dropped from `hits`,
       but the query's `highlights` (built over every page file) still carried
       an entry keyed by the private file's id with its marked-up name.

  Now the tier-aware answer drives `visibility_clamp: :public` in the query, so
  a private asset never enters the page, its highlights or `total`. Controls: a
  read-tier token still sees both assets; a public asset stays visible to the
  public tier.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "fed_media_tier_ds"
  @asset_type "mediaAsset"

  defp media!(stem) do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    suffix = System.unique_integer([:positive])

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: "#{stem}-#{suffix}.png",
        original_name: "#{stem}-#{suffix}.png",
        path: "fixtures/tier-#{suffix}.png",
        mime_type: "image/png",
        size: 1,
        dataset: @dataset,
        workspace_id: ws.id,
        project_id: project.id
      })
      |> Repo.insert()

    file
  end

  defp asset!(file, title, visibility) do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    content = %{"mediaFileId" => file.id, "tags" => [], "bp_visibility" => visibility}

    {:ok, _} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "tier-asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: content,
        workspace_id: ws.id,
        project_id: project.id
      })
      |> Repo.insert()

    :ok
  end

  defp search(conn, raw) do
    conn = if raw, do: put_req_header(conn, "authorization", "Bearer " <> raw), else: conn

    conn
    |> get("/v1/search/#{@dataset}?q=heron&surfaces=media")
    |> json_response(200)
    |> get_in(["results", "media"])
  end

  defp token!(perms) do
    raw = "fedtier-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "fed tier", @dataset, perms)
    raw
  end

  setup do
    priv = media!("heron-private")
    :ok = asset!(priv, "Heron Private Dossier", "private")
    pub = media!("heron-public")
    :ok = asset!(pub, "Heron Public Snapshot", "public")
    %{priv: priv, pub: pub}
  end

  test "a public-read site token does not receive the private asset", ctx do
    media = search(scoped_conn(), token!(["public-read"]))
    ids = Enum.map(media["hits"], & &1["id"])

    refute ctx.priv.id in ids,
           "LEAK: a public-read token received a PRIVATE asset from federated search"

    assert ctx.pub.id in ids
    refute Jason.encode!(media) =~ ctx.priv.filename
  end

  test "an anonymous caller gets no highlight entry for the private asset", ctx do
    media = search(scoped_conn(), nil)

    refute Map.has_key?(media["highlights"] || %{}, ctx.priv.id),
           "LEAK: highlights carried the private asset's marked-up name"

    assert media["total"] == length(media["hits"])
  end

  test "CONTROL: a read-tier token still sees both assets", ctx do
    ids = scoped_conn() |> search(token!(["read"])) |> Map.fetch!("hits") |> Enum.map(& &1["id"])
    assert ctx.priv.id in ids
    assert ctx.pub.id in ids
  end
end
