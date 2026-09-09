defmodule BarkparkCloud.Web.PromoteIdentityGuardTest do
  @moduledoc """
  deploy-reliability W12 — THE CONJUNCTION GUARD for the promote path's content
  identity.

  Promote (`POST /v1/sites/:id/deployments/:dep_id/promote`) is the documented
  ROLLBACK primitive for a container site: promoting an OLDER artifact IS the
  rollback. `Registry.Deployment.promotion_attrs/1` builds the attrs for the
  fresh row, and it used to copy EXACTLY `%{git_ref, artifact_url}` — dropping
  `content_rev` AND `artifact_sha256` on the one path where "which bytes" is the
  entire question.

  THE CONJUNCTION THIS FILE GUARDS. The drop was never a live defect, because
  two facts had to hold at once and only ever one did:

    1. the promote route 422s `not_promotable` for `site.kind in ["static",
       "node"]` BEFORE `promotion_attrs/1` is reached — so only a CONTAINER site
       can reach it; and
    2. a digest only exists on a row whose site opted into off-box builds
       (`sites.prebuilt_enabled`, the gate on `POST /deploy {"source":
       "prebuilt"}`) — and no container site had the flag on.

    A SINGLE `update sites set prebuilt_enabled = true` on a container site
    satisfies both. That row is what `container_site_accepting_prebuilt/1`
    builds, so this file measures the ARMED world, not today's fenced one — and
    it fails the moment `promotion_attrs/1` stops carrying identity.

  The control below is the other half of the conjunction: it proves the STATIC
  fence still stands, so a green here is never mistaken for "the fence was
  removed".
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  @git_ref "v1-sha"
  @artifact_url "file:///tmp/v1.tar.gz"
  @content_rev "content-rev-abc123"
  @artifact_sha256 "3b1f9c0d5e8a47b2c6d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9"

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # THE ARMED SITE: a container site (so promote is not fenced) whose owner has
  # switched on off-box builds (so its deployments carry a digest). One UPDATE
  # apart from the production shape at filing time.
  defp container_site_accepting_prebuilt(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})

    {:ok, site} =
      site |> Ecto.Changeset.change(prebuilt_enabled: true) |> Repo.update()

    # The precondition, asserted rather than assumed: if `create_site/2`'s
    # default kind ever stops being "container", this file would silently be
    # measuring a 422 instead of the mint.
    assert site.kind == "container"
    assert site.prebuilt_enabled

    site
  end

  # A settled production source carrying the FULL identity an uploaded artifact
  # gets: where the bytes are, what they hash to, and what content they were
  # built from.
  defp live_prebuilt_source(site) do
    {:ok, d} =
      Registry.create_deployment(site, %{
        git_ref: @git_ref,
        artifact_url: @artifact_url,
        content_rev: @content_rev,
        artifact_sha256: @artifact_sha256,
        source: "prebuilt"
      })

    {:ok, d} = Registry.transition_deployment(d, %{status: "live"})
    d
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp post_promote(site, source, token) do
    conn(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", Jason.encode!(%{}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  describe "promotion_attrs/1 — content identity on the rollback path" do
    test "carries content_rev and artifact_sha256, not only the artifact location" do
      source = %Deployment{
        git_ref: @git_ref,
        artifact_url: @artifact_url,
        content_rev: @content_rev,
        artifact_sha256: @artifact_sha256
      }

      # An EXACT map, not a subset assertion: a promote must not silently grow a
      # field either (`delivery_id` in particular must stay absent — a promote is
      # an operator action, not a GitHub redelivery).
      assert Deployment.promotion_attrs(source) == %{
               git_ref: @git_ref,
               artifact_url: @artifact_url,
               content_rev: @content_rev,
               artifact_sha256: @artifact_sha256
             }
    end

    test "a nil-identity source promotes to nil identity — it copies, it never invents" do
      source = %Deployment{git_ref: @git_ref, artifact_url: @artifact_url}

      assert Deployment.promotion_attrs(source) == %{
               git_ref: @git_ref,
               artifact_url: @artifact_url,
               content_rev: nil,
               artifact_sha256: nil
             }
    end
  end

  describe "THE CONJUNCTION: a container site with prebuilt_enabled reaches promote" do
    test "the minted row names the bytes it was promoted from" do
      {user, team} = user_team()
      site = container_site_accepting_prebuilt(team)
      source = live_prebuilt_source(site)

      conn = post_promote(site, source, login_token(user))

      # Arm 1 of the conjunction: promote was REACHED (not 422 not_promotable).
      assert conn.status == 201
      minted_id = Jason.decode!(conn.resp_body)["deployment"]["id"]
      minted = Registry.get_deployment(minted_id)

      # A genuinely new row, not a pointer flip.
      refute minted.id == source.id

      # Arm 2: identity travelled. THIS is the assertion that fails when
      # `promotion_attrs/1` drops content_rev / artifact_sha256.
      assert minted.git_ref == @git_ref
      assert minted.artifact_url == @artifact_url
      assert minted.content_rev == @content_rev
      assert minted.artifact_sha256 == @artifact_sha256

      # `source` is NOT carried, on purpose: it is pipeline provenance, not
      # identity. A promoted row minted `prebuilt` would be prebuilt?/1-true with
      # no artifact bytes of its own (nothing uploads on a promote) and would sit
      # queued forever. Pinned so the reasoning cannot be quietly reversed.
      refute Deployment.prebuilt?(minted)
    end

    test "CONTROL — a STATIC site is still fenced out of promote entirely" do
      {user, team} = user_team()
      site = container_site_accepting_prebuilt(team)
      {:ok, site} = site |> Ecto.Changeset.change(kind: "static") |> Repo.update()
      source = live_prebuilt_source(site)

      conn = post_promote(site, source, login_token(user))

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "not_promotable"
    end
  end
end
