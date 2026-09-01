defmodule BarkparkCloud.Sites.AutodeployGapVisibilityTest do
  @moduledoc """
  dr-w11-bl-eight-sites-never-autodeploy — EIGHT sites never auto-deploy and
  NOTHING says so.

  `create_site/2` mints the per-site content-publish secret and lands its
  ciphertext on the row, then registers the webhook on the box and THROWS THE
  RESULT AWAY (`registry.ex` — `_ = maybe_register_content_webhook(...)`, whose
  own comment says "Best-effort by contract; the caller ignores the result").

  So when the box write does not take, the site row still carries
  `content_webhook_secret_encrypted` — every control-plane read believes the site
  is wired for auto-deploy — while the box holds no `site-autodeploy-<id>` row and
  no publish will ever be delivered. Registration re-runs ONLY on create and on
  explicit backfill, never on a schedule, so a site that missed its webhook stays
  missed forever, silently.

  The create-path comment justifies the discard with "a box that is not yet live
  (or refuses) just means auto-rebuild is wired on the next successful
  registration path". There is no next path. That sentence is the eight sites.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault

  @dataset "production"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://acme.barkpark.cloud",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp bound_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: @dataset,
        doc_type: "paper",
        read_token: "bpt_read_#{n}"
      })

    site
  end

  # The box is unreachable for BOTH the list GET and the create POST — the exact
  # shape that produces an unwired site: the CP mints and stores the secret, the
  # box write fails, the result is discarded.
  defp with_box_refusing(fun) do
    StudioLinkFakeHttpClient.program(%{
      "/v1/webhooks/#{@dataset}" => {:ok, %{status: 502, body: "box down"}}
    })

    fun.()
  end

  describe "the unwired site (the eight)" do
    # PREMISE — expected GREEN. Establishes that the defect is reachable and that
    # the fixture is not vacuous: the site really is created, and the control
    # plane really does hold the secret that makes it LOOK wired.
    test "a site whose box registration FAILED is still created carrying a content secret" do
      bp = team_fixture() |> live_bp()

      site = with_box_refusing(fn -> bound_site(bp) end)

      # The box write was attempted and refused...
      assert Enum.any?(StudioLinkFakeHttpClient.requests(), fn r ->
               r.method == :post and String.contains?(r.url, "/v1/webhooks/#{@dataset}")
             end),
             "the create path must have attempted the box registration"

      # ...yet the row carries the secret, so every CP-side read believes this
      # site is wired for auto-deploy. (Never assert on the plaintext.)
      site = Repo.reload!(site)
      assert is_binary(site.content_webhook_secret_encrypted),
             "the CP stores the secret regardless of whether the box write took"
    end

    # RED — the row's core claim: "nothing says so".
    test "the failed registration is RECORDED somewhere an operator can read it" do
      bp = team_fixture() |> live_bp()
      site = with_box_refusing(fn -> bound_site(bp) end)

      events = Registry.recent_events(bp, 50)

      assert Enum.any?(events, fn e ->
               is_map(e.payload) and
                 inspect(e.payload) =~ site.id
             end),
             """
             THE DEFECT: the box refused this site's content-publish registration and
             the control plane recorded NOTHING. The result is discarded at the call
             site, so the only trace is a Logger.warning that no operator surface
             reads. The site now looks wired (it holds a secret) and will never
             auto-deploy. Registration never re-runs on a schedule, so this is
             permanent and silent.
             """
    end
  end

  describe "the three-valued read: UNKNOWN is not ABSENT" do
    # RED — there is no read-only status surface at all today.
    #
    # This is the distinction that makes the surface trustworthy. Reporting
    # "this site has no publish trigger" for a read that could not be performed
    # turns a silent failure into a CONFIDENT WRONG ANSWER, and would send an
    # operator to re-register a webhook that already exists (`webhooks.name` has
    # no unique constraint on the box, so that POST duplicates the row).
    test "a box that ANSWERS and lacks the row reports the gap" do
      bp = team_fixture() |> live_bp()
      site = with_box_refusing(fn -> bound_site(bp) end)

      # The box is readable and genuinely does not have this site's row.
      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@dataset}" =>
          {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
      })

      assert Registry.content_webhook_status(bp, site) == :never_autodeploys
    end

    test "a box that CANNOT be read reports :unknown with a reason — never the gap" do
      bp = team_fixture() |> live_bp()
      site = with_box_refusing(fn -> bound_site(bp) end)

      # The list read fails. We did not learn that the row is missing; we learned
      # nothing at all.
      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@dataset}" => {:ok, %{status: 502, body: "box down"}}
      })

      status = Registry.content_webhook_status(bp, site)

      assert match?({:unknown, _reason}, status),
             "a read that could not be performed must report UNKNOWN, got: #{inspect(status)}"

      refute status == :never_autodeploys,
             "reporting the gap for a read we could not perform is a confident wrong answer"
    end

    test "a box carrying the row reports it wired" do
      bp = team_fixture() |> live_bp()
      site = with_box_refusing(fn -> bound_site(bp) end)
      hook_id = Ecto.UUID.generate()

      StudioLinkFakeHttpClient.program(%{
        "/v1/webhooks/#{@dataset}" =>
          {:ok,
           %{
             status: 200,
             body:
               Jason.encode!(%{
                 "webhooks" => [%{"id" => hook_id, "name" => "site-autodeploy-#{site.id}"}]
               })
           }}
      })

      assert Registry.content_webhook_status(bp, site) == {:wired, hook_id}
    end
  end
end
