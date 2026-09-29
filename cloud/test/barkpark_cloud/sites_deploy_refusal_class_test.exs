defmodule BarkparkCloud.SitesDeployRefusalClassTest do
  @moduledoc """
  THE FOUR NEW REFUSAL CLASSES, PROVED OFF THE PRODUCER — never off a hand-typed
  string.

  `DeployLedger.classify/2` reads a PROSE column, so a fixture typed by hand
  proves only that the classifier agrees with the test author. Every row below is
  written by `Sites.Deploy` itself: a programmed box answers with the envelope the
  real instance sends, the driver composes `failure_reason` through its own
  private `box_refusal/3`, the row lands in Postgres, and the class is read back
  off THAT row. A reword of the producer's template reds here at edit time.

  WHY A FILE OF ITS OWN. `deploy_ledger_test.exs`'s label gauge scrapes the box's
  wire vocabulary out of `sites_deploy_test.exs` with a lowercase-`snake_case`
  regex over `"code" => "…"`. Putting a `unauthorized` envelope in that file would
  enrol a new cause word into a matrix that never probes a 401, and the gauge
  would demand a naming decision for a probe it does not run. The producer proof
  belongs beside the producer either way; this file keeps the two instruments from
  colliding.

  FIXTURE-DRIVEN, AND SAID SO. The census that named these shapes was taken on the
  live control plane on 2026-09-06; this worker had no production database. The
  counts in the comments come from the filing row, the strings from the producer.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, DeployLedger, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay

  @instance_url "https://acme.barkpark.cloud"
  @read_token "bpt_public_read_xyz"

  # The same live-instance + static-site fixture `sites_deploy_test.exs` uses: a
  # url and an encrypted admin token, which is what the provision-succeed path
  # writes and what the driver needs to reach a box at all.
  defp setup_site do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp =
      bp
      |> Ecto.Changeset.change(
        url: @instance_url,
        git_commit: "abc123",
        admin_token_encrypted: Vault.encrypt("instance-admin-token")
      )
      |> BarkparkCloud.Repo.update!()

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: @read_token
      })

    {bp, site}
  end

  # Drive one start refusal all the way onto a row, and hand back the row.
  defp refused_row(status, body) do
    {bp, site} = setup_site()
    {:ok, d} = Deploy.enqueue(site, bp)
    FakeBoxRelay.program(start: {:ok, status, body})
    assert {:ok, :failed} = Deploy.run(d.id)
    BarkparkCloud.Repo.get(Deployment, d.id)
  end

  describe "the box's typed 400 — the archive was refused before a byte was staged" do
    # 3 rows in the 2026-09-06 census, the largest single shape in the batch.
    test "E_TOTAL_TOO_LARGE is the SITE's payload, and says so" do
      row =
        refused_row(400, %{
          "error" => %{
            "code" => "E_TOTAL_TOO_LARGE",
            "message" => "the archive's entries declare more than the 67108864 byte total cap",
            "request_id" => "F9-too-large"
          }
        })

      # The producer really wrote the shape the classifier reads — asserted here
      # so a template reword cannot leave the class assertion below vacuous.
      assert row.failure_reason =~ "the instance refused the deploy (HTTP 400)"
      assert row.failure_reason =~ "E_TOTAL_TOO_LARGE"

      assert DeployLedger.classify(row) == "ARCHIVE_TOO_LARGE_400"
      assert DeployLedger.agency("ARCHIVE_TOO_LARGE_400") == :site

      # The label must not send an operator to check a box's health for a payload
      # they can fix.
      refute DeployLedger.label("ARCHIVE_TOO_LARGE_400") =~ "unavailable"
      assert DeployLedger.label("ARCHIVE_TOO_LARGE_400") =~ "cap"
    end

    # 1 row.
    test "E_UNKNOWN_TYPE is its own class, and its agency is honestly :ambiguous" do
      row =
        refused_row(400, %{
          "error" => %{
            "code" => "E_UNKNOWN_TYPE",
            "message" => "unsupported tar entry type \"x\""
          }
        })

      assert DeployLedger.classify(row) == "ARCHIVE_UNSUPPORTED_ENTRY_400"

      # NOT :site. `internal/cli/sites_tarball.go:249` records that a box which
      # predates the extractor's pax arm answers this for bytes every current box
      # stages — BOX-LAGS-CLI is a supported product state — so one shape carries
      # a site cause and a box cause and the string cannot tell them apart.
      assert DeployLedger.agency("ARCHIVE_UNSUPPORTED_ENTRY_400") == :ambiguous
    end

    # NO CATCH-ALL. A 400 whose code the ledger has not seen must rise.
    test "a 400 with an unnamed E_ code is UNCLASSIFIED, not absorbed by either archive class" do
      row =
        refused_row(400, %{
          "error" => %{
            "code" => "E_SYMLINK",
            "message" => "entry \"public/link\" is a symlink — refused"
          }
        })

      # The row is a real, well-formed typed 400 — the control that makes the
      # verdict below a decision and not a parse failure.
      assert row.failure_reason =~ "E_SYMLINK"
      assert DeployLedger.classify(row) == "UNCLASSIFIED"
    end
  end

  describe "the statuses whose cause IS the status" do
    # 1 row: "…(HTTP 401): unauthorized — missing or invalid token [box request_id: …]".
    test "a 401 is the box refusing the CREDENTIAL, and the class is :box" do
      row =
        refused_row(401, %{
          "error" => %{
            "code" => "unauthorized",
            "message" => "missing or invalid token",
            "request_id" => "F9tPXq2A"
          }
        })

      # Including the request-id stamp the producer appends AFTER the detail —
      # the shape that once ate the code word on the 409 arm.
      assert row.failure_reason =~ "[box request_id: F9tPXq2A]"

      assert DeployLedger.classify(row) == "BOX_UNAUTHORIZED_401"
      assert DeployLedger.agency("BOX_UNAUTHORIZED_401") == :box
      assert DeployLedger.label("BOX_UNAUTHORIZED_401") =~ "credential"
    end

    # 2 rows, BARE — no detail at all, which is why this arm reads no detail.
    test "a bare 404 is a box that does not have the deploy route" do
      row = refused_row(404, %{})

      assert row.failure_reason == "the instance refused the deploy (HTTP 404)"
      assert DeployLedger.classify(row) == "BOX_ROUTE_UNKNOWN_404"
      assert DeployLedger.agency("BOX_ROUTE_UNKNOWN_404") == :box
      assert DeployLedger.label("BOX_ROUTE_UNKNOWN_404") =~ "skew"
    end

    # THE TAIL STILL WORKS, proved on a status the ledger has never been sent.
    # Without this, "we named four statuses" and "we named every status" are
    # indistinguishable from the outside.
    test "a status the ledger has never seen is still UNCLASSIFIED" do
      row = refused_row(402, %{})

      assert row.failure_reason =~ "(HTTP 402)"
      assert DeployLedger.classify(row) == "UNCLASSIFIED"
    end
  end
end
