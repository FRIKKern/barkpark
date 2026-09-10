defmodule BarkparkCloud.SitesDeployArtifactReceiptTest do
  @moduledoc """
  dr-w12-bl-box-build-writes-no-digest (charter D188): A BOX-BUILD DEPLOYMENT
  RECORDS WHICH BYTES IT SERVED, AND A DISAGREEMENT IS DETECTABLE.

  ## The hole this closes

  `artifact_sha256` is the digest of the UPLOADED TARBALL and is stamped only by
  `Sites.Deploy.store_artifact/3` on the upload path. In prod that is 6 rows of
  30,633; the other 30,627 are `source = "box-build"` and carry NULL, including
  every live deployment that closed a superseded revision. `site-deploy.sh` wrote
  `.bp-prebuilt-sha256` only on the PREBUILT arm, so the box kept no receipt
  either. A wrong artifact could be served today and NO INSTRUMENT ANYWHERE would
  disagree with itself.

  ## What is under test

  The box now takes TWO independent digests of the release tree: one at STAGE
  over the tree it just copied in (`bp-build-sha256=`), one at SWITCH over
  whatever `current` resolves to once the flip committed (`bp-served-sha256=`).
  The control plane stamps the SERVED one on `deployments.build_sha256` and
  REFUSES to record the row live when the two both exist and DIFFER.

  ## The three sentences this file keeps apart

  A digest is a RECEIPT, never an identity key — one `content_rev` produced FOUR
  distinct artifacts on this fleet, so the build is not reproducible and nothing
  here is a content address. That makes the NEGATIVE arms as load-bearing as the
  positive one:

    * BOTH digests present and EQUAL — the ordinary correct deploy, recorded.
    * BOTH present and DIFFERENT — the bytes in front of users are not this
      build's. The row FAILS, naming both digests.
    * NEITHER present, or `none` — a box that predates the markers, or one with
      no sha256 tool. NOT a mismatch. A gate that read "missing" as "wrong" would
      fail every deploy on the fleet the day it shipped.
  """

  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay

  @instance_url "https://acme.barkpark.cloud"

  @staged String.duplicate("a1b2c3d4", 8)
  @served_other String.duplicate("f0e9d8c7", 8)

  defp live_barkpark do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Site #{n}",
        slug: "site-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    site
  end

  # A full six-stage box report whose STAGE and SWITCH details carry whatever
  # this box chose to narrate. The tokens ride the stage DETAIL — the same
  # channel the box already uses for every other stage caption — so a box that
  # predates them simply narrates the old text.
  defp succeeded(stage_detail, switch_detail) do
    stages =
      Enum.map(Deploy.stages(), fn name ->
        detail =
          case name do
            "STAGE" -> stage_detail
            "SWITCH" -> switch_detail
            _ -> "#{name} ok"
          end

        %{"name" => name, "status" => "done", "detail" => detail}
      end)

    {:ok, 200, %{"state" => "succeeded", "stages" => stages, "url" => nil}}
  end

  defp run_with(stage_detail, switch_detail) do
    bp = live_barkpark()
    site = static_site(bp)
    {:ok, d} = Deploy.enqueue(site, bp)
    FakeBoxRelay.program(polls: [succeeded(stage_detail, switch_detail)])
    result = Deploy.run(d.id)
    {result, Repo.get(Deployment, d.id), Registry.get_site(site.id)}
  end

  describe "the served digest reaches the row" do
    test "a box build records the SWITCH-time digest of the tree it served" do
      {result, final, site} =
        run_with(
          "dist/ -> releases/b1 (12K) bp-build-sha256=#{@staged}",
          "current -> releases/b1 bp-served-sha256=#{@staged}"
        )

      assert {:ok, :live} = result

      assert final.build_sha256 == @staged,
             "a box-build deployment that went live recorded NO receipt — which is the " <>
               "30,627-of-30,633 hole D188 names: the row cannot say which bytes it served"

      assert final.status == "live"
      assert site.current_deployment_id == final.id

      # The upload column is untouched. `Registry`'s prebuilt-upload reaper is
      # `source == "prebuilt" and is_nil(artifact_sha256)`; a box-build digest
      # landing there would silently redefine "minted but never uploaded".
      assert final.source == "box-build"
      assert is_nil(final.artifact_sha256)
    end

    test "the STAGE digest is not mistaken for the served one" do
      # Only STAGE narrates. The row must stay NULL rather than record a staged
      # digest as if it were a measurement of what went live.
      {result, final, _site} =
        run_with("dist/ -> releases/b1 (12K) bp-build-sha256=#{@staged}", "current -> releases/b1")

      assert {:ok, :live} = result
      assert is_nil(final.build_sha256)
    end
  end

  describe "a MISMATCH between the served artifact and the row's claim" do
    test "two different digests fail the deployment and NAME both" do
      {result, final, site} =
        run_with(
          "dist/ -> releases/b1 (12K) bp-build-sha256=#{@staged}",
          "current -> releases/b1 bp-served-sha256=#{@served_other}"
        )

      assert {:ok, :failed} = result

      assert final.status == "failed",
             "the box served a tree it did not stage and the row went LIVE anyway — this is " <>
               "exactly the disagreement no instrument could raise before D188"

      assert final.failure_reason =~ @staged
      assert final.failure_reason =~ @served_other
      assert final.failure_reason =~ "served a different release than the one it staged"

      refute site.current_deployment_id == final.id,
             "a refused deployment still moved the site's live pointer"
    end

    test "the failed row still carries what the box measured" do
      {_result, final, _site} =
        run_with(
          "dist/ -> releases/b1 (12K) bp-build-sha256=#{@staged}",
          "current -> releases/b1 bp-served-sha256=#{@served_other}"
        )

      assert final.build_sha256 == @served_other,
             "the row that FAILED on a mismatch is the row that most needs to name the bytes " <>
               "that were actually served"
    end
  end

  describe "silence is not a mismatch" do
    test "a box that narrates NO digest still goes live, with a NULL receipt" do
      {result, final, _site} =
        run_with("dist/ -> releases/b1 (12K)", "current -> releases/b1")

      assert {:ok, :live} = result,
             "a box predating the D188 markers was failed for not speaking — this arm is the " <>
               "difference between shipping and failing every deploy on the fleet"

      assert is_nil(final.build_sha256)
    end

    test "`none` (a box with no sha256 tool) is NOT a digest and NOT a mismatch" do
      {result, final, _site} =
        run_with(
          "dist/ -> releases/b1 (12K) bp-build-sha256=none",
          "current -> releases/b1 bp-served-sha256=none"
        )

      assert {:ok, :live} = result
      assert is_nil(final.build_sha256), "the literal string `none` was recorded as a digest"
    end

    test "a truncated or malformed digest is refused as a reading, not stored" do
      {result, final, _site} =
        run_with(
          "dist/ -> releases/b1 (12K) bp-build-sha256=deadbeef",
          "current -> releases/b1 bp-served-sha256=deadbeef"
        )

      assert {:ok, :live} = result
      assert is_nil(final.build_sha256)
    end
  end

  describe "the receipt is a MEASUREMENT, so a caller cannot declare it" do
    test "build_sha256 is not castable on create" do
      bp = live_barkpark()
      site = static_site(bp)

      {:ok, d} = Registry.create_deployment(site, %{build_sha256: @staged})

      assert is_nil(Repo.get(Deployment, d.id).build_sha256),
             "a deployment was born naming bytes nobody served"
    end

    test "build_sha256 IS castable on a transition (it is what the box observed)" do
      cs = Deployment.transition_changeset(%Deployment{}, %{build_sha256: @staged})
      assert Ecto.Changeset.get_change(cs, :build_sha256) == @staged
    end
  end
end
