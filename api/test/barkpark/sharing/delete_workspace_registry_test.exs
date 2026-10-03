defmodule Barkpark.Sharing.DeleteWorkspaceRegistryTest do
  @moduledoc """
  Deleting a workspace removes its `shares` rows with raw SQL. The live share
  registry (`Application` env `:shares`) is rebuilt from those rows only by
  `Sharing.refresh/0`, so without a refresh the deleted workspace's share
  stayed live in memory: a new workspace created under the freed slug was
  anonymously readable until the next share change or restart.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.SharingFixtures

  alias Barkpark.{Sharing, Tenancy}

  test "a deleted workspace's share leaves the live registry" do
    ws = create_workspace!()
    proj = create_project!(ws)

    plant_shares!("#{ws.slug}/#{proj.slug}/production:docs:read")
    assert Sharing.shared?(ws.slug, proj.slug, "production", :docs)

    assert {:ok, _} = Tenancy.delete_workspace(ws)

    refute Sharing.shared?(ws.slug, proj.slug, "production", :docs)
  end

  test "another workspace's share survives the delete" do
    ws = create_workspace!()
    proj = create_project!(ws)
    other = create_workspace!()
    other_proj = create_project!(other)

    plant_shares!(
      "#{ws.slug}/#{proj.slug}/production:docs:read;" <>
        "#{other.slug}/#{other_proj.slug}/production:docs:read"
    )

    assert {:ok, _} = Tenancy.delete_workspace(ws)

    assert Sharing.shared?(other.slug, other_proj.slug, "production", :docs)
  end
end
