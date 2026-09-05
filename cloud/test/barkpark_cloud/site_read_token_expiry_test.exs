defmodule BarkparkCloud.SiteReadTokenExpiryTest do
  @moduledoc """
  task-b3e3ec0f433b217d — a site read token must have a LIFETIME of its own.

  ## The defect these tests pin

  ssw8 (PR #13875) gave the credential a DEATH: `delete_site/1` revokes it. It
  did not give it a lifetime. Measured on guerrilla 2026-09-01: 18 live
  `site-read-*` rows, `expires_at` set on ZERO, `revoked_at` set on ZERO in the
  fleet's whole history. Revoke-on-delete stops the population growing through
  the delete door; the twelve credentials belonging to sites that still exist
  are immortal, and the orphan sweep never even looks at them.

  ## What "a ceiling" had to mean here, and why it is not an `expires_at`

  The credential is a row in the INSTANCE's `api_tokens`. That table HAS an
  `expires_at` and the box's verify path honours it — but the mint route
  (`BarkparkWeb.TokenController.create/2`) reads only `label`, `permissions` and
  `dataset`, and `Barkpark.Auth.create_token/5` takes no expiry argument, so an
  `expires_at` in that body is silently dropped. Sending one would give the
  control plane a ceiling nothing enforces. So the ceiling is a control-plane
  policy over the box's own `inserted_at` (which `GET .../v1/tokens` already
  returns), and it is discharged by ROTATION, not by expiry — a hard box-side
  expiry on an unattended build credential is how a live site goes dark.

  The three obligations, all of them here:

    * ONE named ceiling, and the census draws the line the constant says.
    * A census that sees EVERY live credential, not just the orphans — with the
      "I could not compute a ceiling" case kept distinct from "inside it".
    * A rotate that mints BEFORE it revokes, with no instant at which the site
      row names a credential the box will refuse.

  ## What is faked and what is not

  The box is faked at the ONE transport seam (`:studio_link_http_client`), so
  what these tests prove is the control plane's half: which requests it makes,
  IN WHAT ORDER, and what it concludes from each answer. Same seam and same
  fixtures as `site_read_token_revoke_test.exs`.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @ws "acme"
  @proj "blog"
  @ds "production"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(%{
      url: "https://acme.barkpark.cloud",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    })
    |> Repo.update!()
  end

  defp bound_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: @ws,
          bootstrap_project: @proj,
          bootstrap_dataset: @ds,
          read_token: "bpt_read_#{n}"
        })
      )

    site
  end

  defp tokens_path, do: "/w/#{@ws}/p/#{@proj}/v1/tokens"

  # GET and POST share this path, so ONE body carries both shapes: the list read
  # takes `"tokens"`, the mint takes `"token"`. Each matcher is key-specific, so
  # neither can be served the other's answer.
  defp program_inventory(rows, opts \\ []) do
    body = %{"tokens" => rows, "token" => Keyword.get(opts, :minted, "bpt_read_rotated")}

    StudioLinkFakeHttpClient.program(
      Map.merge(
        %{
          tokens_path() => {:ok, %{status: 200, body: Jason.encode!(body)}},
          "/v1/webhooks/#{@ds}" => {:ok, %{status: 200, body: Jason.encode!(%{"webhooks" => []})}}
        },
        Keyword.get(opts, :extra, %{})
      )
    )
  end

  defp token_row(label, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, Ecto.UUID.generate()),
      "label" => label,
      "revoked_at" => Keyword.get(opts, :revoked_at),
      "inserted_at" => Keyword.get(opts, :inserted_at, iso_days_ago(1)),
      "expires_at" => Keyword.get(opts, :expires_at),
      "last_used_at" => Keyword.get(opts, :last_used_at)
    }
  end

  defp iso_days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second) |> DateTime.to_iso8601()
  end

  defp calls do
    StudioLinkFakeHttpClient.requests()
    |> Enum.map(fn %{method: m, url: url} -> {m, URI.parse(url).path} end)
    |> Enum.filter(fn {_m, path} -> String.contains?(path, "/v1/tokens") end)
  end

  describe "the ceiling is ONE named number" do
    test "site_read_token_max_age_days/0 is the only source of the line the census draws" do
      days = Registry.site_read_token_max_age_days()
      assert is_integer(days) and days > 0

      minted = DateTime.utc_now() |> DateTime.add(-3 * 24 * 3600, :second)

      {expires_at, :derived} =
        Registry.site_read_token_expires_at(%{
          "inserted_at" => DateTime.to_iso8601(minted)
        })

      # Not "some date in the future" — EXACTLY minted + the constant. A census
      # that drew its line from a second, hand-typed number would still be
      # "in the future" and would still pass a laxer assert.
      assert DateTime.diff(expires_at, minted, :second) == days * 24 * 3600
    end
  end

  describe "site_read_token_expires_at/1" do
    test "the BOX's own expires_at wins — it is the one the box actually enforces" do
      box_expiry = "2027-01-01T00:00:00Z"

      assert {at, :box} =
               Registry.site_read_token_expires_at(%{
                 "expires_at" => box_expiry,
                 "inserted_at" => iso_days_ago(500)
               })

      assert DateTime.to_iso8601(at) == box_expiry
    end

    test "no box expiry -> derived from inserted_at" do
      assert {%DateTime{}, :derived} =
               Registry.site_read_token_expires_at(%{"inserted_at" => iso_days_ago(2)})
    end

    test "neither stamp readable -> {nil, :unknown}, never a date nobody derived" do
      assert {nil, :unknown} = Registry.site_read_token_expires_at(%{})
      assert {nil, :unknown} = Registry.site_read_token_expires_at(%{"inserted_at" => nil})

      assert {nil, :unknown} =
               Registry.site_read_token_expires_at(%{"inserted_at" => "not a date"})

      assert {nil, :unknown} = Registry.site_read_token_expires_at(%{"inserted_at" => 1_700_000})
    end
  end

  describe "site_read_token_census/1" do
    setup do
      team = team_fixture()
      bp = live_bp(team)
      %{bp: bp}
    end

    test "a LIVE site's token past the ceiling is reported — the orphan sweep never sees it",
         %{bp: bp} do
      site = bound_site(bp)
      label = Registry.site_read_token_label(site)
      over = Registry.site_read_token_max_age_days() + 30

      program_inventory([token_row(label, inserted_at: iso_days_ago(over))])

      assert {:ok, [row]} = Registry.site_read_token_census(bp)
      assert row.label == label
      assert row.site_slug == site.slug
      assert row.expired?
      assert row.expiry_source == :derived
      refute row.orphan?

      # THE POINT OF THIS ROW: the orphan sweep is silent about it. A fix that
      # only revokes on delete leaves this credential live forever.
      assert {:ok, []} = Registry.orphan_site_read_tokens(bp)
    end

    test "a freshly minted token is inside the ceiling", %{bp: bp} do
      site = bound_site(bp)

      program_inventory([
        token_row(Registry.site_read_token_label(site), inserted_at: iso_days_ago(1))
      ])

      assert {:ok, [row]} = Registry.site_read_token_census(bp)
      refute row.expired?
      assert row.expiry_source == :derived
    end

    test "an uncomputable ceiling is :unknown and NOT expired — 'I could not tell' is not 'fine'",
         %{bp: bp} do
      site = bound_site(bp)

      program_inventory([
        token_row(Registry.site_read_token_label(site), inserted_at: nil)
      ])

      assert {:ok, [row]} = Registry.site_read_token_census(bp)
      assert row.expiry_source == :unknown
      assert row.expires_at == nil
      refute row.expired?
    end

    test "revoked rows and non-site labels are not in the census", %{bp: bp} do
      site = bound_site(bp)
      label = Registry.site_read_token_label(site)

      program_inventory([
        token_row(label, revoked_at: "2026-08-01T00:00:00Z"),
        token_row("ci-deploy-key"),
        token_row("prefixed-site-read-not-a-site")
      ])

      assert {:ok, []} = Registry.site_read_token_census(bp)
    end

    test "an unreadable inventory is :unreadable, never an empty census", %{bp: bp} do
      _site = bound_site(bp)
      StudioLinkFakeHttpClient.program(%{tokens_path() => {:error, :nxdomain}})

      assert {:error, :unreadable} = Registry.site_read_token_census(bp)
    end

    test "orphan_site_read_tokens/1 is this census filtered on orphan?", %{bp: bp} do
      site = bound_site(bp)
      over = Registry.site_read_token_max_age_days() + 5

      program_inventory([
        token_row(Registry.site_read_token_label(site), inserted_at: iso_days_ago(over)),
        token_row("site-read-deleted-site", inserted_at: iso_days_ago(over))
      ])

      assert {:ok, census} = Registry.site_read_token_census(bp)
      assert length(census) == 2

      assert {:ok, [orphan]} = Registry.orphan_site_read_tokens(bp)
      assert orphan.site_slug == "deleted-site"
      assert orphan.orphan?
      # The orphan row now carries a ceiling too, so the operator sweep can print
      # one verdict per row from one read.
      assert orphan.expired?
    end
  end

  describe "rotate_site_read_token/1 — the site NEVER goes dark" do
    setup do
      team = team_fixture()
      bp = live_bp(team)
      site = bound_site(bp)
      %{bp: bp, site: site, label: Registry.site_read_token_label(site)}
    end

    test "mints BEFORE it revokes, and revokes the INCUMBENT's id", ctx do
      old_id = Ecto.UUID.generate()

      program_inventory([token_row(ctx.label, id: old_id)],
        minted: "bpt_read_brand_new",
        extra: %{
          "#{tokens_path()}/#{old_id}" =>
            {:ok, %{status: 200, body: Jason.encode!(%{"revoked" => %{"id" => old_id}})}}
        }
      )

      assert {:ok, rotated, :ok} = Registry.rotate_site_read_token(ctx.site)

      # ORDER IS THE PROPERTY. A revoke-then-mint would show :delete before
      # :post, and between them the site would hold a credential the box refuses.
      assert [
               {:get, _},
               {:post, _},
               {:delete, delete_path}
             ] = calls()

      assert String.ends_with?(delete_path, "/v1/tokens/#{old_id}")

      # And the row really moved to the new secret.
      assert {:ok, "bpt_read_brand_new"} = Registry.reveal_site_read_token(rotated)
      assert {:ok, "bpt_read_brand_new"} = Registry.reveal_site_read_token(Repo.reload!(rotated))
    end

    test "an unreadable inventory aborts BEFORE anything is minted", ctx do
      StudioLinkFakeHttpClient.program(%{tokens_path() => {:error, :nxdomain}})

      assert {:error, :unreadable} = Registry.rotate_site_read_token(ctx.site)
      assert Enum.all?(calls(), fn {method, _} -> method == :get end)
      assert {:ok, token} = Registry.reveal_site_read_token(Repo.reload!(ctx.site))
      assert token != nil
    end

    test "no incumbent -> :none, and nothing is revoked", ctx do
      program_inventory([token_row("site-read-someone-else")], minted: "bpt_read_first")

      assert {:ok, rotated, :none} = Registry.rotate_site_read_token(ctx.site)
      refute Enum.any?(calls(), fn {method, _} -> method == :delete end)
      assert {:ok, "bpt_read_first"} = Registry.reveal_site_read_token(rotated)
    end

    test "a revoke the box will not confirm returns :error — with the NEW token already live",
         ctx do
      old_id = Ecto.UUID.generate()

      program_inventory([token_row(ctx.label, id: old_id)],
        minted: "bpt_read_new_but_old_lives",
        extra: %{"#{tokens_path()}/#{old_id}" => {:ok, %{status: 404, body: "{}"}}}
      )

      assert {:ok, rotated, :error} = Registry.rotate_site_read_token(ctx.site)

      # The site works — that is the non-negotiable half. The orphan left behind
      # is what `mix barkpark_cloud.site_read_tokens` exists to find.
      assert {:ok, "bpt_read_new_but_old_lives"} =
               Registry.reveal_site_read_token(Repo.reload!(rotated))
    end

    test "a mint the box refuses changes nothing", ctx do
      before = Registry.reveal_site_read_token(ctx.site)

      StudioLinkFakeHttpClient.program(%{
        tokens_path() =>
          {:ok, %{status: 200, body: Jason.encode!(%{"tokens" => [token_row(ctx.label)]})}}
      })

      assert {:error, {:mint_failed, _}} = Registry.rotate_site_read_token(ctx.site)
      assert before == Registry.reveal_site_read_token(Repo.reload!(ctx.site))
    end

    test "an unbound site is :noop — there is no credential to rotate", %{bp: bp} do
      n = System.unique_integer([:positive])

      {:ok, container} =
        Registry.create_site(bp, %{
          name: "App #{n}",
          slug: "app-#{n}",
          kind: "container",
          framework: "nextjs"
        })

      assert {:error, :noop} = Registry.rotate_site_read_token(container)
    end
  end

  describe "the operator surface reports the ceiling" do
    test "mix barkpark_cloud.site_read_tokens --census prints expires_at and flags the expired" do
      team = team_fixture()
      bp = live_bp(team)
      site = bound_site(bp)
      over = Registry.site_read_token_max_age_days() + 30

      program_inventory([
        token_row(Registry.site_read_token_label(site), inserted_at: iso_days_ago(over)),
        token_row("site-read-deleted-site", inserted_at: iso_days_ago(1))
      ])

      out =
        Mix.Tasks.BarkparkCloud.SiteReadTokens.census_boxes([bp.slug])
        |> Mix.Tasks.BarkparkCloud.SiteReadTokens.census_lines()
        |> Enum.join("\n")

      assert out =~ "2 live site-read token(s), 1 past the #{over - 30}-day ceiling"
      assert out =~ "*** EXPIRED ***"
      assert out =~ "— PAST THE CEILING"
      assert out =~ "expires       "
      assert out =~ "(derived)"
      assert out =~ "(ORPHAN — no such site)"
      assert out =~ "Nothing was rotated."
    end

    test "an instance whose inventory cannot be read is not printed as a clean bill of health" do
      team = team_fixture()
      bp = live_bp(team)
      _site = bound_site(bp)
      StudioLinkFakeHttpClient.program(%{tokens_path() => {:error, :nxdomain}})

      out =
        Mix.Tasks.BarkparkCloud.SiteReadTokens.census_boxes([bp.slug])
        |> Mix.Tasks.BarkparkCloud.SiteReadTokens.census_lines()
        |> Enum.join("\n")

      assert out =~ "UNREADABLE"
      assert out =~ "1 instance(s) could not be read"
      refute out =~ "no live site-read tokens"
    end
  end
end
