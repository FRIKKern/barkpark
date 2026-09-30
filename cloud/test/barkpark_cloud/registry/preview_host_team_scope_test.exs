defmodule BarkparkCloud.Registry.PreviewHostTeamScopeTest do
  @moduledoc """
  task-f98ea12880b32251: a branch preview's host is unique per SITE, not per
  site slug.

  Site slugs are unique per TEAM only (sites_team_slug_unique_idx), and the
  preview label used to hash the branch alone. So every team with a site
  called `blog` previewing `dev` minted the SAME `blog--dev-<hash>` host, and
  `domain_registered?/1` certified it for whichever box asked.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}

  defp blog_site do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Blog", slug: "blog"})
    site
  end

  test "two teams' sites named `blog` previewing `dev` get DIFFERENT hosts" do
    a = blog_site()
    b = blog_site()
    assert a.slug == b.slug

    {:ok, da} = Registry.create_preview_deployment(a, "dev", String.duplicate("a", 40))
    {:ok, db} = Registry.create_preview_deployment(b, "dev", String.duplicate("b", 40))

    refute da.preview_host == db.preview_host
    assert String.starts_with?(da.preview_host, "blog--dev-")
    assert String.starts_with?(db.preview_host, "blog--dev-")
  end

  test "CONTROL: the same site's branch keeps a stable host across pushes" do
    site = blog_site()

    {:ok, first} = Registry.create_preview_deployment(site, "dev", String.duplicate("c", 40))
    {:ok, _} = Registry.transition_deployment(first, %{status: "failed"})
    {:ok, second} = Registry.create_preview_deployment(site, "dev", String.duplicate("d", 40))

    assert first.preview_host == second.preview_host
  end
end
