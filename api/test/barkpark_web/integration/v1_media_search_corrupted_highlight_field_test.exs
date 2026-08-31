defmodule BarkparkWeb.Integration.V1MediaSearchCorruptedHighlightFieldTest do
  @moduledoc """
  task-5cf80a99ecd52bf2: a `search_surface_config` row whose `highlight_fields`
  carries a name `Barkpark.Search.Highlighter.media_field_text/3` has no
  clause for is a STORED denial of service. The write that produced it may
  predate the write-time validation fix (`SurfaceConfig.changeset/2`) — an
  already-corrupted row keeps crashing every `GET /v1/media/:dataset/search`
  until someone manually reverts it.

  This test seeds that corrupted row DIRECTLY at the Repo, bypassing
  `SurfaceConfig.changeset/2` on purpose (mirrors how the row could exist:
  written before the write-time gate landed, or by any future path that
  skips the changeset). It then proves the full HTTP read path degrades
  instead of 500ing — the read-side catch-all in `media_field_text/3` is
  what makes that true.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo
  alias Barkpark.Search.SurfaceConfig
  alias Barkpark.Search.SurfaceConfigs

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
  @scope "production"

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-media-search-corrupted-highlight-field-test",
      ["read", "write", "admin"]
    )

    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp png_upload(name) do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "corrupt-hf-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)
    %Plug.Upload{path: tmp_path, filename: name, content_type: "image/png"}
  end

  defp upload(conn, filename) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => png_upload(filename)})
    |> json_response(201)
    |> Map.fetch!("result")
  end

  defp cleanup(%{"id" => id, "path" => path}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  # Bypasses SurfaceConfig.changeset/2's cast+validation entirely
  # (Ecto.Changeset.change/2, same seam seed_defaults!/0 uses) — the write-time
  # fix in this same task cannot stop this row from existing; only the
  # read-side catch-all can save the request that finds it.
  defp corrupt_media_highlight_fields! do
    # Ecto forbids `workspace_id: nil` in a keyword get_by (it compiles to
    # `== nil`, always false) — same `is_nil/1` requirement SurfaceConfigs'
    # own `get_row/3` documents.
    query =
      from(c in SurfaceConfig,
        where: c.surface == "media" and c.scope == @scope and is_nil(c.workspace_id)
      )

    case Repo.one(query) do
      nil ->
        %SurfaceConfig{}
        |> Ecto.Changeset.change(%{
          surface: "media",
          scope: @scope,
          workspace_id: nil,
          highlight_fields: ["cliverbs-media-marker"]
        })
        |> Repo.insert!()

      row ->
        row
        |> Ecto.Changeset.change(%{highlight_fields: ["cliverbs-media-marker"]})
        |> Repo.update!()
    end

    SurfaceConfigs.__reset_cache_for_test__()
  end

  test "a corrupted highlightFields row degrades the search response instead of 500ing", %{
    conn: conn
  } do
    hero = upload(conn, "corrupted-hf-hero.png")

    corrupt_media_highlight_fields!()

    resp =
      conn
      |> recycle()
      |> authed()
      |> get(~p"/v1/media/production/search?q=corrupted-hf-hero")
      |> json_response(200)

    assert resp["result"]["total"] >= 1
    hit = Enum.find(resp["result"]["hits"], &(&1["id"] == hero["id"]))
    assert hit, "the corrupted config must not stop the hit from coming back"

    cleanup(hero)
  end
end
