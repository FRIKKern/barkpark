defmodule BarkparkCloud.Notifications.FleetDigestSiteOwningAudienceTest do
  @moduledoc """
  dr-w33-bl — THE DIGEST'S AUDIENCE WAS KEYED ON THE WRONG NOUN.

  ## The defect

  `Notifications.deliver_fleet_digest/1` derived WHO gets mailed from
  `Enum.group_by(barkparks, & &1.team_id)` — i.e. from BARKPARK INSTANCE
  ownership. Sites entered only afterwards, through `team_site_ids/1`, as the
  SCOPE of a reading taken for a team the instance list had already elected.

  So the email whose headline payload is deploy health (dr-w28-s5) was addressed
  by a fact that has nothing to do with deploys. A team that owns SITES but no
  instance is measured by nobody and mailed by nobody: its sites deploy, they
  fail, and no digest is ever built for the team that owns them. Nothing reports
  that gap either — the accounting counts recipients and covered INSTANCES, and
  a team absent from the audience contributes zero to both, so the run looks
  complete.

  ## How a team ends up owning sites and no instance

  `sites.barkpark_id` cascades on delete, so deleting a box takes its sites with
  it — that is NOT the path. The path is tenancy drift: `Registry.create_site/2`
  stamps `team_id` from the box AT CREATE TIME (registry.ex, `create_site/2`) and never
  again, so moving a box to another team leaves its sites' `team_id` pointing at
  the old one. The old team then owns rows in `sites` and no row in `barkparks`.
  §1 builds exactly that state and drives the real rail over
  `Registry.all_barkparks/0`, which is what `DailyDigestWorker` passes.

  ## What this file does NOT claim

  It does not claim the drifted state is common — the row that filed this
  measured the live control plane and found the failing population EMPTY (three
  instance-owning teams, one site-owning team, and the one is a subset of the
  three). This is a latent correctness defect in the carrier, proven on a state
  the schema permits, not an incident replay.

  §2 is the other half and the one that keeps the fix honest: widening an
  audience must not narrow it. A team that owns instances and no sites is still
  mailed, and still gets the `no_sites: true` sentence rather than a false
  UNMEASURED.
  """
  use BarkparkCloud.DataCase, async: true

  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}

  defp user_team(prefix) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "#{prefix}-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "#{prefix} #{n}", slug: "#{prefix}-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The `n` emails the Swoosh Test adapter accepted, in delivery order. Taken as
  # a SET by the caller: nothing here asserts which team is mailed first.
  defp delivered(n) do
    for _ <- 1..n do
      assert_received {:email, email}
      email
    end
  end

  ## 1. THE GAP. A team with sites and no instance is in the audience.

  test "a team that owns sites but no instance receives a digest" do
    {site_owner, site_team} = user_team("sites")
    {box_owner, box_team} = user_team("boxes")

    # The box is registered to `site_team`, so the site it spawns is stamped with
    # `site_team`'s id — and then the box moves. `sites.team_id` does not follow.
    {:ok, bp} = Registry.register_barkpark(site_team, %{name: "Prod", slug: slug("prod")})
    {:ok, site} = Registry.create_site(bp, %{name: "Marketing", slug: slug("marketing")})

    _moved = bp |> Ecto.Changeset.change(team_id: box_team.id) |> Repo.update!()

    # The state under test, asserted rather than assumed: one team owns the site
    # and no box, the other owns the box and no site.
    assert site.team_id == site_team.id
    assert Registry.all_barkparks() |> Enum.map(& &1.team_id) == [box_team.id]
    assert site_team.id |> Registry.list_sites_for_team() |> Enum.map(& &1.id) == [site.id]
    assert Registry.list_sites_for_team(box_team.id) == []

    assert {:ok, %{sent: 2, recipients: recipients}} =
             Notifications.deliver_fleet_digest(Registry.all_barkparks())

    assert Enum.sort(recipients) == Enum.sort([site_owner.email, box_owner.email])

    # THE DELIVERED BYTES. The site-owning team's mail carries a REAL deploy
    # reading over its own site — not the no-sites sentence, which is what it
    # would say if the audience had been widened without the scope following.
    #
    # Picked out of BOTH sends by recipient rather than through
    # `assert_email_sent/1`, which pops the FIRST `{:email, _}` message only: the
    # audience is a map, so which of the two teams is mailed first is iteration
    # order and not a property of this fix. A matcher that depends on it is a
    # coin flip, and it flipped once while this file was being written.
    body_for = fn emails, address ->
      email =
        Enum.find(emails, fn e ->
          Enum.any?(e.to, fn {_name, to} -> to == address end)
        end)

      assert email, "no digest was delivered to #{address}"
      email.text_body
    end

    emails = delivered(2)

    site_body = body_for.(emails, site_owner.email)
    assert site_body =~ "Fleet: 0 instances."
    assert site_body =~ "Deploy health for this team's sites"
    refute site_body =~ "this team owns no sites"

    # And the team that kept the box is untouched by the widening: still mailed,
    # still told it owns no sites — the site it used to own moved teams, not
    # inboxes.
    box_body = body_for.(emails, box_owner.email)
    assert box_body =~ "Fleet: 1 instance"
    assert box_body =~ "Deploy health: this team owns no sites, so it ran no deploys"
  end

  ## 2. NOBODY IS DROPPED. The instance-only team still gets its digest, with the
  ##    no-sites line intact.

  test "a team that owns instances but no sites still receives its digest with the no-sites line" do
    {owner, team} = user_team("instances")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Prod", slug: slug("prod")})

    assert Registry.list_sites_for_team(team.id) == []

    assert {:ok, %{sent: 1, recipients: [recipient]}} =
             Notifications.deliver_fleet_digest([bp])

    assert recipient == owner.email

    assert_email_sent(fn email ->
      assert Enum.any?(email.to, fn {_name, address} -> address == owner.email end)
      assert email.text_body =~ "Fleet: 1 instance"

      assert email.text_body =~
               "Deploy health: this team owns no sites, so it ran no deploys"
    end)
  end
end
