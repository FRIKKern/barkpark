defmodule BarkparkCloud.ScrubBoundaryHttpTest do
  @moduledoc """
  dr-w22-s1 — THREE DISPLAY BOUNDARIES SHIPPED A COLOURISED CREDENTIAL BACK
  BYTE-IDENTICAL TO THE BYTES THE WORKER CAPTURED.

  `Web.Router.scrub_entry/2` folded every one of them through a BARE
  `FailureCopy.scrub/1` — no `strip_ansi` — and `scrub/1`'s key clause opens with
  `(?<![A-Za-z0-9])`. A CSI run parks an `m` immediately LEFT of the key, the
  clause never fires, and the value ships. The three call sites:

    * `merge_provision_steps/2`   → `provision_steps[].detail` on GET /v1/barkparks
    * `merge_provision_console/2` → `provision_console[].line` on the same payload
    * `deployment_json/1`         → `deployment.console[].line` on
      GET /v1/sites/:id/deployments/:id

  This file asserts on RENDERED HTTP BYTES through `Router.call/2` — not on
  `FailureCopy` in isolation, which is exactly how this hole stayed open while
  the unit tests were green. Each boundary is checked twice: the secret is GONE,
  and the rendered value is NOT byte-identical to the stored capture (a boundary
  that silently stopped folding would pass the first check on a fixture the
  scrub happens to miss; it cannot pass the second).

  ## THE FIXTURE DECIDES THE VERDICT (charter D387)

  `@capture` is a NON-PREFIXED 14-char secret with the CSI immediately LEFT of
  the key. Both of the obvious alternatives are GREEN OVER A LIVE HOLE:

    * a CSI in the VALUE position (`api_key=\\e[31m<secret>`) — the scrub's value
      class eats the escape, so it closes under BOTH orders, 0/2000;
    * a provider-PREFIXED token (`sk-…`, `bppat_…`) — the prefix clause matches
      the TOKEN itself, so it too closes under both orders.

  Either one would have this file passing against the unpatched router.

  ## Residual, and what is NOT claimed

  The OSC shape `"\\e]0;t\\ainapi_key=<secret>"` leaks under BOTH orders —
  stripping the OSC leaves the `n` flush against the key and re-blocks the same
  lookbehind. This slice does NOT close it; it is pinned as an open residual in
  `failure_copy_test.exs`. And no LIVE exploitation is claimed: a 154,931-line
  scan of real captured lines on cloud-db-1 found ZERO OSC sequences and exactly
  one line matching the key alphabet (instructional prose carrying a
  `<your-key>` placeholder). The boundary hole is proven; a live leak is not
  measured.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Sites}
  alias BarkparkCloud.Registry.{Deployment, ProvisionJob, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"

  # D387: NON-prefixed, 14 chars, CSI immediately LEFT of the key.
  @secret "Ab3xQ9zK1mP7vT"
  @capture "\e[31mapi_key=#{@secret}\e[0m fetching graph corpus"

  ## ---------------------------------------------------------------------------
  ## Fixtures
  ## ---------------------------------------------------------------------------

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    site
  end

  defp get_json(path, token) do
    conn =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  # The two assertions every boundary owes, stated once. `rendered` is what the
  # HTTP response carried; `stored` is the capture the worker wrote to the DB.
  defp assert_folded(rendered, stored, where) do
    refute rendered =~ @secret,
           "#{where} shipped a live credential: #{inspect(rendered)}"

    refute rendered == stored,
           "#{where} is byte-identical to input — the boundary is not folding at all"

    assert rendered =~ "[redacted]", "#{where} dropped the redaction marker"
  end

  ## ---------------------------------------------------------------------------
  ## GET /v1/barkparks — provision_steps[].detail and provision_console[].line
  ## ---------------------------------------------------------------------------

  describe "GET /v1/barkparks (the /new provision screen)" do
    setup do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)

      # Written through the SAME context functions the off-box Go provisioner's
      # worker endpoints call, so the escape bytes arrive the way a real capture
      # arrives — nothing in the ingest path strips them.
      {:ok, _} = Registry.append_provision_step(job.id, "create", "failed", @capture)
      {:ok, job} = Registry.append_provision_console(job.id, @capture)

      {:ok, token} = Accounts.create_user_session_token(user)
      %{bp: bp, job: job, token: token}
    end

    test "the DB keeps the raw capture — this is a display fold, not a data rewrite", %{job: job} do
      stored = Repo.get(ProvisionJob, job.id)

      assert hd(stored.steps)["detail"] == @capture
      assert hd(stored.console)["line"] == @capture
    end

    test "provision_steps[].detail is folded in the rendered bytes", %{bp: bp, token: token} do
      row = Enum.find(get_json("/v1/barkparks", token)["barkparks"], &(&1["id"] == bp.id))

      assert_folded(hd(row["provision_steps"])["detail"], @capture, "provision_steps[].detail")
    end

    test "provision_console[].line is folded in the rendered bytes", %{bp: bp, token: token} do
      row = Enum.find(get_json("/v1/barkparks", token)["barkparks"], &(&1["id"] == bp.id))

      assert_folded(hd(row["provision_console"])["line"], @capture, "provision_console[].line")
    end

    test "no 0x1B byte reaches the browser on either key", %{bp: bp, token: token} do
      row = Enum.find(get_json("/v1/barkparks", token)["barkparks"], &(&1["id"] == bp.id))

      refute hd(row["provision_steps"])["detail"] =~ "\e"
      refute hd(row["provision_console"])["line"] =~ "\e"
    end
  end

  ## ---------------------------------------------------------------------------
  ## GET /v1/sites/:id/deployments/:id — deployment.console[].line
  ## ---------------------------------------------------------------------------

  describe "GET /v1/sites/:id/deployments/:id (the build console)" do
    setup do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      d =
        d
        |> Ecto.Changeset.change(
          status: "failed",
          stage: "BUILD",
          failure_reason: @capture,
          console: [%{"stage" => "BUILD", "status" => "failed", "line" => @capture}]
        )
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)
      %{site: site, deployment: d, token: token}
    end

    test "console[].line is folded in the rendered bytes, and the DB row is untouched", %{
      site: site,
      deployment: d,
      token: token
    } do
      body = get_json("/v1/sites/#{site.id}/deployments/#{d.id}", token)
      entry = Enum.find(body["deployment"]["console"], &(&1["stage"] == "BUILD"))

      assert_folded(entry["line"], @capture, "deployment.console[].line")
      refute entry["line"] =~ "\e"

      # ops recovery still has the bytes
      assert hd(Repo.get(Deployment, d.id).console)["line"] == @capture
    end

    # REVIEW ADDITION (dr-w22-s1 review): the FOURTH boundary, in the SAME
    # payload as the third. `deployment_json/1` renders `failure_reason_raw`
    # through its own hand-written pipe, which shipped as `scrub |> strip_ansi`
    # — the leaky order, and the worst-rendering variant of it: the trailing
    # strip removes the escapes that blocked the scrub, so the credential
    # arrived in clean CLEARTEXT beside the `console[].line` that had just
    # redacted it. Sweeping only `scrub_entry/2` would have left it open.
    test "failure_reason_raw is folded in the rendered bytes", %{
      site: site,
      deployment: d,
      token: token
    } do
      body = get_json("/v1/sites/#{site.id}/deployments/#{d.id}", token)

      assert_folded(body["deployment"]["failure_reason_raw"], @capture, "failure_reason_raw")
      refute body["deployment"]["failure_reason_raw"] =~ "\e"

      # and the humanized twin beside it never carried it either
      refute body["deployment"]["failure_reason"] =~ @secret

      # the DB column is untouched — this is a display fold
      assert Repo.get(Deployment, d.id).failure_reason == @capture
    end
  end
end
