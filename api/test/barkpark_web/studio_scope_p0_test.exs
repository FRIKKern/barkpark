defmodule BarkparkWeb.StudioScopeP0Test do
  @moduledoc """
  P0 of the Scoped-by-URL arc (tsk-url-p0) — tenant-boundary correctness
  fixes that need no URL change:

    1. Presence topics are workspace-keyed and `on_doc/3` is
       dataset-aware — no cross-tenant avatars, no same-doc_id
       co-presence across datasets.
    2. The flat rendition serve is scope-bounded: another workspace's
       rendition id 404s on the Default-pinned flat URL (it used to
       serve ANY workspace's file — the documented cross-scope leak).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias BarkparkWeb.Studio.PresenceState

  import Barkpark.TenancyFixtures

  @dataset "production"

  describe "PresenceState.topic/1 (ws-keyed)" do
    test "a resolved workspace keys its own topic" do
      assert PresenceState.topic("ws-123") == "studio:presence:ws:ws-123"
    end

    test "nil workspace falls back to the legacy global topic" do
      assert PresenceState.topic(nil) == "studio:presence"
    end

    test "two workspaces never share a topic" do
      refute PresenceState.topic("ws-a") == PresenceState.topic("ws-b")
    end
  end

  describe "PresenceState.on_doc/3 (dataset-aware)" do
    @meta %{user_id: "u1", doc_id: "p1", dataset: "production", color: "#fff"}

    test "matches doc_id + dataset" do
      assert [_] = PresenceState.on_doc([@meta], "p1", "production")
    end

    test "same doc_id in another dataset is NOT co-presence" do
      assert [] = PresenceState.on_doc([@meta], "p1", "test")
    end

    test "legacy metas without a dataset stamp fail quiet (no false positive)" do
      legacy = Map.delete(@meta, :dataset)
      assert [] = PresenceState.on_doc([legacy], "p1", "production")
    end
  end

  describe "flat rendition serve is scope-bounded (Default-pinned)" do
    setup do
      ws_b = create_workspace!("rendition-leak-b")
      proj_b = create_project!(ws_b, "rendition-leak-pb")

      # A real on-disk file owned by workspace B (NOT Default).
      name = "leak-#{System.unique_integer([:positive])}.png"
      rel = "uploads/p0-rendition-test/#{name}"
      full = Media.file_path(rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "BYTES-FROM-B")
      on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

      file_b =
        %MediaFile{}
        |> MediaFile.changeset(%{
          filename: name,
          original_name: name,
          path: rel,
          mime_type: "image/png",
          size: 12,
          dataset: @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        })
        |> Repo.insert!()

      %{file_b: file_b}
    end

    test "another workspace's rendition id 404s on the flat URL", %{
      conn: conn,
      file_b: file_b
    } do
      # Pre-fix this resolved the file via an UNSCOPED get_file/1 and
      # proceeded into Renditions.ensure — any workspace's bytes were
      # one guessed id away on the public flat route.
      conn = get(conn, "/media/renditions/#{file_b.id}/thumb")
      assert conn.status == 404
    end
  end
end
