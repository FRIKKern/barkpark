defmodule BarkparkCloud.CredentialEgressManifestTest do
  @moduledoc """
  cchi-w58 — THE CREDENTIAL-EGRESS REGISTER.

  Every place this control plane decrypts a stored secret and puts it on the
  wire, keyed on the question nobody was asking:

      (site) -> (what secret is sent,
                 what determines the destination,
                 what was verified about that destination FIRST,
                 what refusal exists,
                 is it non-admin reachable?)

  The third column is the point. For every row-derived site in this tree the
  honest answer today is NOTHING — not the destination's scheme, not its
  certificate, not that it is the box we provisioned. That is an assertion about
  OUR code, it is falsifiable, and the sweep below PROVES it by driving every
  site against a `bp.url` of `http://untrusted.egress.example` (plaintext,
  attacker-shaped) and observing that the decrypted admin bearer leaves anyway.
  If a scheme check ever ships, this file goes red and the column gets rewritten.

  ## A SIBLING, NEVER AN EXTENSION

  A NEW file beside `terminal_act_residue_manifest_test.exs` (charter D607/D636),
  whose ADD/STALE shape it copies and whose extractor it deliberately does not
  share. It is NOT the shape in `sold_capability_manifest_test.exs`, whose ADD arm
  iterates whatever the reader happens to emit and passes vacuously at zero
  iterations (D564/D666).

  ## THE POPULATION IS A UNION OF TWO MECHANISMS, AND THEY ARE NOT EQUAL (D665)

    * (a) THE ROW-DERIVED SITES ARE READ BY RUNNING. Every one of the sites in
      `@egress_sites` is DRIVEN: its thunk calls the real public function against
      a real `barkparks` row in this BEAM, the swappable
      `:studio_link_http_client` / `:verify_http_client` seams record what
      actually went on the wire, and the covered set is built from the requests
      that were OBSERVED — never from a hand-typed literal. A run is the strongest
      operand available here: it survives a refactor that keeps the bytes and
      changes the value, which a scan does not.

    * (b) THE VENDOR-CONSTANT CLASS IS READ BY SCANNING. The ~10 third-party
      destinations (Hetzner, Stripe, GitHub, Vercel, Cloudflare, Azure, the OAuth
      providers, the archive store, notifications) are SAFE BY CONSTRUCTION: a
      compile-time destination cannot be influenced by a row, so no row of ours
      can ever redirect the secret. They are a DECLARED-EMPTY class, not an
      omission — `@vendor_constant_class` names each one and the scan asserts the
      module attribute that pins its base URL to a literal still exists. A SCAN IS
      WEAKER THAN A RUN and the way it is weaker is exact: it catches the literal
      being DELETED or made dynamic; it does not vouch for what the module then
      does with it.

  Neither half vouches for the other. The union is the population, and the
  register accounts for it in exactly those two ways.

  ## THE ADD ARM DELIBERATELY DOES NOT COPY D673's

  `web/instance_api_proxy_test.exs` has a catalog-drift arm whose covered set is a
  HAND-TYPED literal sitting beside the list that drives the calls. Deleting a
  name from the literal reds; deleting the DRIVEN call it is supposed to vouch for
  leaves the file green, because both operands are in-file text and the run is not
  an operand at all — while its own failure message promises a driven row.

  Here there is ONE `@driven` list of `{site, thunk}` pairs. It feeds BOTH the
  sweep AND the covered set, so deleting a driven row SHRINKS the covered set and
  the pinned side reds by name. That is mutation-proved in this file's PR.

  ## WHAT THIS REGISTER'S GREEN IS WORTH

    1. It knows which sites SEND a secret and where the destination comes from.
       It does not audit what the box does with the secret afterwards.
    2. `non_admin_reachable?` is a DECLARED column read off the route's auth
       plug, not a driven one — except for the console proxy row, which is driven
       through the real router. Do not quote it as a proved authorization matrix;
       `web/router_ability_matrix_test.exs` owns that axis.
    3. The refusal column is driven: each shipped refusal is a POSITIVE CONTROL
       with its own test asserting ZERO requests reached the wire.
  """

  # async: false — the verify row swaps the GLOBAL `:verify_http_client` app env,
  # so this module must not race a parallel test reading it.
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo, Usage, Verify}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @admin_token "instance-admin-token-plaintext-EGRESS-REGISTER"
  @caller_bearer "caller-supplied-bearer-NOT-FROM-THE-ROW"

  # THE DESTINATION IS PLAINTEXT HTTP ON PURPOSE. Every driven site below sends
  # the decrypted admin bearer here. Nothing in this tree looks at that scheme —
  # which is exactly what the "verified first" column claims, driven rather than
  # asserted in prose.
  @instance_url "http://untrusted.egress.example"

  @bootstrap_workspace "acme"
  @bootstrap_project "web"
  @bootstrap_dataset "production"

  ## ── THE REGISTER ─────────────────────────────────────────────────────────
  #
  # One row per EGRESS SITE — keyed on where the REQUEST IS BUILT, not on who
  # calls it. `Sites.BoxRelay.HTTP` and `Sites.Deploy` are therefore not rows:
  # they are callers of `relay_admin/4`, whose request build IS the `:relay_admin`
  # row, and giving each caller its own row would count the same send twice.
  #
  # Keys, all five required of every row:
  #   :secret               — what credential travels
  #   :destination          — what determines where it goes
  #   :verified_first       — what was checked about that destination BEFORE the
  #                           send (the column that is the point)
  #   :refusal              — the shipped refusal that can stop this send, or
  #                           :none when nothing refuses
  #   :non_admin_reachable  — can a non-team-admin actor cause this send?
  #
  # Plus the two the sweep uses to find the site's request in what was recorded:
  #   :method / :marker     — the wire signature, and :seam (which transport)
  @egress_sites [
    %{
      site: :studio_link_mint,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:suspended, "Registry.mint_studio_link/2 leading clause"},
      non_admin_reachable: true,
      seam: :instance,
      method: :post,
      marker: "/v1/auth/login-tickets"
    },
    %{
      site: :app_token_mint,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:suspended, "Registry.mint_app_token/2 leading clause"},
      non_admin_reachable: true,
      seam: :instance,
      method: :post,
      marker: "/v1/auth/app-tokens"
    },
    %{
      site: :app_token_revoke,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: true,
      seam: :instance,
      method: :delete,
      marker: "/v1/auth/app-tokens"
    },
    %{
      site: :update_status_probe,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: false,
      seam: :instance,
      method: :get,
      marker: "/v1/admin/self-update"
    },
    %{
      site: :self_update_trigger,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:identity_refused, "Registry.relay_admin_post/3 leading clause"},
      non_admin_reachable: false,
      seam: :instance,
      method: :post,
      marker: "/v1/admin/self-update"
    },
    %{
      site: :rollback_trigger,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:identity_refused, "Registry.relay_admin_post/3 leading clause"},
      non_admin_reachable: false,
      seam: :instance,
      method: :post,
      marker: "/v1/admin/rollback"
    },
    %{
      site: :relay_admin,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: false,
      seam: :instance,
      method: :get,
      marker: "/v1/capabilities"
    },
    %{
      site: :relay_as,
      secret: :caller_supplied_bearer,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: false,
      seam: :instance,
      method: :get,
      marker: "/v1/ping"
    },
    %{
      site: :public_read_token_mint,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: false,
      seam: :instance,
      method: :post,
      marker: "/v1/tokens"
    },
    %{
      site: :site_url_webhook_list,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:suspended, "Registry.wire_site_url/2 leading clause"},
      non_admin_reachable: false,
      seam: :instance,
      method: :get,
      marker: "/v1/webhooks/#{@bootstrap_dataset}"
    },
    %{
      site: :site_url_webhook_put,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:suspended, "Registry.wire_site_url/2 leading clause"},
      non_admin_reachable: false,
      seam: :instance,
      method: :put,
      marker: "/v1/webhooks/#{@bootstrap_dataset}/wh_revalidation"
    },
    %{
      site: :usage_datasets,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: true,
      seam: :instance,
      method: :get,
      marker: "/api/workspaces/default/projects/default/datasets"
    },
    %{
      site: :usage_documents,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: true,
      seam: :instance,
      method: :get,
      marker: "/v1/data/analytics/"
    },
    %{
      site: :usage_webhooks,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: true,
      seam: :instance,
      method: :get,
      marker: "/v1/webhooks/"
    },
    %{
      site: :verify_api_probe,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: :none,
      non_admin_reachable: false,
      seam: :verify,
      method: :get,
      marker: "/v1/capabilities"
    },
    %{
      site: :console_instance_api_proxy,
      secret: :stored_admin_token,
      destination: {:row_column, :url},
      verified_first: :nothing,
      refusal: {:suspended_mutate_tier, "Router.dispatch_instance_api/4 cond clause"},
      non_admin_reachable: true,
      seam: :instance,
      method: :get,
      marker: "/v1/webhooks/"
    }
  ]

  @required_keys [:secret, :destination, :verified_first, :refusal, :non_admin_reachable]

  # PINNED HERE, and by NEITHER operand of the drift arm. That is not style — it
  # is the only reason the STALE direction can lose.
  @registered MapSet.new(@egress_sites, & &1.site)

  ## ── THE DECLARED-EMPTY CLASS ─────────────────────────────────────────────
  #
  # Third-party destinations whose address is a COMPILE-TIME LITERAL. No
  # `barkparks` row can influence where these secrets go, so they carry no
  # row-derived egress risk and get no driven row. Declared, with the reason, so a
  # reader can tell "accounted for and empty" from "forgotten".
  #
  # SCRIPT-LOCATION (D607(4)): the repo-root anchor is a STRING-LITERAL
  # `Path.expand("../..", __DIR__)` so the cloud path-escape ratchet's grep can
  # see it. The list form is invisible to that grep.
  @cloud_root Path.expand("../..", __DIR__)

  @vendor_constant_class %{
    reason:
      "a compile-time destination cannot be influenced by a row: the base URL is a " <>
        "module attribute bound to a string literal, so no tenant-controlled value " <>
        "can redirect the credential",
    secret: :vendor_api_key,
    destination: {:compile_time_literal, :module_attribute},
    verified_first: :the_literal_itself,
    refusal: :not_applicable,
    non_admin_reachable: false,
    members: [
      {:hetzner, "lib/barkpark_cloud/web/router.ex", "@hetzner_api_base \"https://"},
      {:stripe, "lib/barkpark_cloud/billing/stripe_gateway.ex", "@api_base \"https://"},
      {:github, "lib/barkpark_cloud/github/real.ex", "@api_base \"https://"},
      {:github_commit_distance, "lib/barkpark_cloud/github/commit_distance.ex",
       "@api_base \"https://"},
      {:vercel, "lib/barkpark_cloud/vercel/real.ex", "@api_base \"https://"},
      {:cloudflare, "lib/barkpark_cloud/cloudflare/real.ex", "@api_base \"https://"},
      {:azure_arm, "lib/barkpark_cloud/azure/client.ex", "@arm_base \"https://"},
      {:azure_pricing, "lib/barkpark_cloud/azure/pricing.ex", "@base \"https://"},
      {:oauth_github, "lib/barkpark_cloud/oauth/github.ex", "@token_url \"https://"},
      {:oauth_google, "lib/barkpark_cloud/oauth/google.ex", "@token_url \"https://"},
      {:notifications_pushover, "lib/barkpark_cloud/notifications/channels/pushover.ex",
       "@endpoint \"https://"}
    ]
  }

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  # A LIVE instance, bootstrapped: url + host + stored admin token + the
  # bootstrap outputs `wire_site_url/2` needs. The url is PLAINTEXT HTTP.
  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@admin_token),
      bootstrap_workspace: @bootstrap_workspace,
      bootstrap_project: @bootstrap_project,
      bootstrap_dataset: @bootstrap_dataset,
      bootstrap_read_token_encrypted: Vault.encrypt("bootstrap-read-token")
    )
    |> Repo.update!()
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token) do
    method
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  ## ── The verify seam's recorder (a sibling, never a parameterisation) ──────
  #
  # `Verify` reads `:verify_http_client`, a DIFFERENT seam from the instance
  # relay's. It gets its own recorder rather than a shared one, so a change to
  # one transport double can never silently retune the other half's population.
  defmodule VerifyRecorder do
    def reset, do: Process.put(:egress_verify_log, [])
    def requests, do: Enum.reverse(Process.get(:egress_verify_log, []))

    def request(req) do
      Process.put(:egress_verify_log, [req | Process.get(:egress_verify_log, [])])
      {:ok, %{status: 200, body: "{}", headers: []}}
    end
  end

  setup do
    prev = Application.get_env(:barkpark_cloud, :verify_http_client)
    Application.put_env(:barkpark_cloud, :verify_http_client, VerifyRecorder)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark_cloud, :verify_http_client, prev),
        else: Application.delete_env(:barkpark_cloud, :verify_http_client)
    end)

    {user, team} = user_with_team("owner")
    bp = live_barkpark(team)
    :ok
    {:ok, user: user, team: team, bp: bp, token: session_token(user)}
  end

  # The upstream this register drives against. PATH-KEYED (never consumed), so a
  # thunk that makes several calls gets the right body for each regardless of
  # order — the shape the usage fan-out's Task children need.
  defp program_upstream do
    scoped = "/w/#{@bootstrap_workspace}/p/#{@bootstrap_project}"

    Fake.program(%{
      "/v1/auth/login-tickets" => ok(201, ~s({"ticket":"bplt_egress","expires_in":60})),
      "/v1/auth/app-tokens" =>
        ok(201, ~s({"token":"apptok_x","revoked":true,"revoked_count":1})),
      "/v1/admin/self-update" => ok(200, ~s({"check":{"state":"current"},"apply_enabled":true})),
      "/v1/admin/rollback" => ok(202, "{}"),
      "/v1/capabilities" => ok(200, "{}"),
      "/v1/ping" => ok(200, "{}"),
      "#{scoped}/v1/tokens" => ok(200, ~s({"token":"prt_public_read"})),
      "#{scoped}/v1/webhooks/#{@bootstrap_dataset}" =>
        ok(
          200,
          ~s({"webhooks":[{"id":"wh_revalidation","name":"bootstrap-revalidation"}]})
        ),
      "#{scoped}/v1/webhooks/#{@bootstrap_dataset}/wh_revalidation" => ok(200, "{}"),
      "/api/workspaces/default/projects/default/datasets" =>
        ok(200, ~s({"datasets":[{"slug":"#{@bootstrap_dataset}"}]})),
      "/v1/data/analytics/#{@bootstrap_dataset}" => ok(200, ~s({"total_documents":7})),
      "/v1/webhooks/#{@bootstrap_dataset}" => ok(200, ~s({"webhooks":[]}))
    })
  end

  defp ok(status, body), do: {:ok, %{status: status, body: body}}

  ## ── THE ONE DRIVEN LIST ──────────────────────────────────────────────────
  #
  # THIS list is the register's population AND its sweep. The covered set below
  # is derived from RUNNING these thunks — deleting a row here removes a site
  # from the covered set and reds the drift arm by name. That is precisely the
  # arm D673's catalog check does not have.
  defp driven(ctx) do
    [
      {:studio_link_mint, fn -> Registry.mint_studio_link(ctx.bp) end},
      {:app_token_mint, fn -> Registry.mint_app_token(ctx.bp, "member@example.com") end},
      {:app_token_revoke,
       fn -> Registry.revoke_app_token(ctx.bp, {:email, "member@example.com"}) end},
      {:update_status_probe, fn -> Registry.refresh_update_status(ctx.bp) end},
      {:self_update_trigger, fn -> Registry.trigger_self_update(ctx.bp) end},
      {:rollback_trigger, fn -> Registry.trigger_rollback(ctx.bp) end},
      {:relay_admin, fn -> Registry.relay_admin(ctx.bp, :get, "/v1/capabilities", nil) end},
      {:relay_as, fn -> Registry.relay_as(ctx.bp, :get, "/v1/ping", @caller_bearer) end},
      {:public_read_token_mint,
       fn ->
         Registry.mint_public_read_token(
           ctx.bp,
           @bootstrap_workspace,
           @bootstrap_project,
           @bootstrap_dataset,
           "site-read"
         )
       end},
      {:site_url_webhook_list, fn -> Registry.wire_site_url(ctx.bp, "https://site.example") end},
      {:site_url_webhook_put, fn -> Registry.wire_site_url(ctx.bp, "https://site.example") end},
      {:usage_datasets, fn -> Usage.gather(ctx.bp) end},
      {:usage_documents, fn -> Usage.gather(ctx.bp) end},
      {:usage_webhooks, fn -> Usage.gather(ctx.bp) end},
      {:verify_api_probe, fn -> Verify.run(ctx.bp) end},
      {:console_instance_api_proxy,
       fn -> call(:get, "/v1/barkparks/#{ctx.bp.id}/api/webhooks", ctx.token) end}
    ]
  end

  defp row!(site), do: Enum.find(@egress_sites, &(&1.site == site))

  # Run ONE driven entry in isolation and hand back the requests it caused on the
  # seam its row names. Isolation per thunk is what lets two sites share a wire
  # path without their markers colliding.
  defp record(site, thunk) do
    row = row!(site)
    program_upstream()
    VerifyRecorder.reset()
    thunk.()

    case row do
      %{seam: :verify} -> VerifyRecorder.requests()
      _ -> Fake.requests()
    end
  end

  defp find_request(row, requests) do
    Enum.find(requests, &(&1.method == row.method and String.contains?(&1.url, row.marker)))
  end

  defp auth_header(req), do: List.keyfind(req.headers, "Authorization", 0)

  ## ── POPULATION: the drift arm ────────────────────────────────────────────

  test "POPULATION (read by RUNNING): every registered egress site is DRIVEN, and the pin loses in BOTH directions",
       ctx do
    list = driven(ctx)

    # ANTI-VACUITY, arm 1: a sweep that drove nothing cannot vouch for anything.
    driven_count = length(list)

    assert driven_count > 0,
           "the driven list is empty — a register with nothing to sweep is not a reading"

    covered =
      for {site, thunk} <- list, reduce: MapSet.new() do
        acc ->
          row = row!(site)

          # A driven site with no row cannot be checked at all — say so loudly
          # rather than silently dropping it from the covered set (which would
          # read as STALE and blame the wrong side).
          assert row, "#{inspect(site)} is DRIVEN but carries no register row"

          case find_request(row, record(site, thunk)) do
            nil -> acc
            _req -> MapSet.put(acc, site)
          end
      end

    # ANTI-VACUITY, arm 2: an empty covered set must never read as "nothing to
    # register". This is the assertion that would otherwise pass silently if
    # every thunk stopped egressing at once.
    refute MapSet.size(covered) == 0,
           "NO driven site put anything on the wire — an unreadable population is a red, not a pass"

    added = MapSet.difference(covered, @registered)
    stale = MapSet.difference(@registered, covered)

    assert MapSet.equal?(covered, @registered),
           "the credential-egress population drifted from this register.\n" <>
             "  observed on the wire but unregistered (ADD):   #{inspect(MapSet.to_list(added))}\n" <>
             "  registered but never observed (STALE):         #{inspect(MapSet.to_list(stale))}\n" <>
             "A new egress site needs a row here saying WHAT SECRET it sends, WHAT DETERMINES the " <>
             "destination, WHAT WAS VERIFIED about that destination first, WHAT REFUSAL exists and " <>
             "whether a non-admin can reach it. A site that no longer sends needs its row deleted " <>
             "in the same commit, deliberately. A STALE name here also means the SWEEP stopped " <>
             "driving that row — which is the failure D673's catalog arm cannot see."
  end

  test "every register row carries all five keys, and no row is a duplicate" do
    for row <- @egress_sites, key <- @required_keys do
      assert Map.has_key?(row, key),
             "#{inspect(row.site)} is missing the #{inspect(key)} column — an egress row that " <>
               "does not answer all five questions is not a register entry"

      refute is_nil(Map.fetch!(row, key)),
             "#{inspect(row.site)}'s #{inspect(key)} is nil — say NOTHING explicitly, never by omission"
    end

    assert MapSet.size(@registered) == length(@egress_sites),
           "two register rows share a site key — one of them can never be reached"
  end

  ## ── THE COLUMN THAT IS THE POINT ─────────────────────────────────────────

  test "WHAT WAS VERIFIED FIRST: every row-derived site sends its secret to a PLAINTEXT HTTP address without one check",
       ctx do
    for {site, thunk} <- driven(ctx) do
      row = row!(site)
      requests = record(site, thunk)
      req = find_request(row, requests)

      assert req,
             "#{inspect(site)} put nothing matching #{row.method} #{row.marker} on the wire"

      # DESTINATION: determined by the ROW's `url` column, nothing else.
      assert String.starts_with?(req.url, @instance_url),
             "#{inspect(site)} sent to #{req.url}, which is not derived from the row's url column"

      # VERIFIED FIRST: NOTHING. The address is plaintext http:// and the send
      # happened anyway. When a scheme/pin check ships, THIS is the line that
      # reds and the column gets rewritten.
      assert String.starts_with?(req.url, "http://"),
             "#{inspect(site)} no longer sends over plaintext http — something now verifies the " <>
               "destination, and this row's :verified_first column must stop saying :nothing"

      assert row.verified_first == :nothing,
             "#{inspect(site)} claims something is verified about its destination first; the drive " <>
               "above shows a plaintext send with no check"
    end
  end

  test "WHAT SECRET: every stored_admin_token row carries the DECRYPTED row credential, and the caller-bearer row carries the caller's",
       ctx do
    for {site, thunk} <- driven(ctx) do
      row = row!(site)
      req = find_request(row, record(site, thunk))
      assert req, "#{inspect(site)} put nothing on the wire"

      expected =
        case row.secret do
          :stored_admin_token -> @admin_token
          :caller_supplied_bearer -> @caller_bearer
        end

      assert {"Authorization", "Bearer " <> ^expected} = auth_header(req),
             "#{inspect(site)}'s Authorization header does not carry the secret its row names " <>
               "(#{inspect(row.secret)})"
    end
  end

  ## ── THE DECLARED-EMPTY CLASS (read by SCANNING) ──────────────────────────

  test "the vendor-constant class is DECLARED empty of row-derived egress, with its reason, and every member's destination is still a compile-time literal" do
    assert @vendor_constant_class.reason =~ "compile-time destination cannot be influenced by a row"

    for key <- @required_keys do
      assert Map.has_key?(@vendor_constant_class, key),
             "the declared-empty class is missing the #{inspect(key)} column — a class row answers " <>
               "the same five questions or it is an omission wearing a costume"
    end

    members = @vendor_constant_class.members

    # ANTI-VACUITY: a class with no members is an omission, not a declaration.
    assert length(members) >= 10,
           "the vendor-constant class shrank below the ~10 sites it was enumerated from — either " <>
             "a vendor destination became row-derived (it needs a DRIVEN row above) or the class " <>
             "stopped being read"

    for {name, rel_path, literal_prefix} <- members do
      path = Path.join(@cloud_root, rel_path)

      assert File.exists?(path),
             "#{inspect(name)}'s module moved: #{path} does not exist, so this class member is no " <>
               "longer read at all"

      source = File.read!(path)

      assert String.contains?(source, literal_prefix),
             "#{inspect(name)} no longer pins its destination to a string literal " <>
               "(#{literal_prefix}…) in #{rel_path}. If that address became dynamic, it is no " <>
               "longer safe by construction and needs a DRIVEN row in @egress_sites."
    end

    # And none of them is quietly also a driven row — the two halves are disjoint.
    member_names = MapSet.new(members, fn {name, _, _} -> name end)

    assert MapSet.disjoint?(member_names, @registered),
           "a name is in BOTH the declared-empty class and the driven population: " <>
             inspect(MapSet.to_list(MapSet.intersection(member_names, @registered)))
  end

  ## ── POSITIVE CONTROLS: the refusals this wave shipped ─────────────────────

  # cch-w54-bl (PR #11106). The refusal is a sibling `cond` clause ABOVE the
  # relay, so the ciphertext is never decrypted and NOTHING reaches the wire.
  test "POSITIVE CONTROL (cch-w54-bl): a suspended box refuses self-update and rollback with ZERO requests on the wire",
       ctx do
    suspended =
      ctx.bp
      |> Ecto.Changeset.change(suspended: true, suspended_reason: "billing_lapsed")
      |> Repo.update!()

    for path <- ["self-update", "rollback"] do
      program_upstream()

      conn = call(:post, "/v1/barkparks/#{suspended.id}/#{path}", ctx.token)

      assert conn.status == 409,
             "POST /#{path} on a SUSPENDED box answered #{conn.status}, not 409 — cch-w54-bl's " <>
               "refusal is gone and the stored admin credential is being spent on a box the " <>
               "console says it has stopped managing"

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "suspended"

      assert Fake.requests() == [],
             "the refused /#{path} STILL reached the wire — the refusal is a leg inside the relay " <>
               "rather than a clause above it, so the credential was decrypted anyway"
    end
  end

  # cch-w58-s1 (PR #11102). "unknown" collapsed five worlds; the WHY is now
  # persisted on the row.
  test "POSITIVE CONTROL (cch-w58-s1): the box's identity verdict is PERSISTED, not discarded",
       ctx do
    Fake.program([ok(401, "")])

    {:error, :identity_refused} = Registry.refresh_update_status(ctx.bp)

    reloaded = Repo.get!(BarkparkCloud.Registry.Barkpark, ctx.bp.id)

    assert reloaded.update_unavailable_reason == "identity_refused",
           "a 401 from the box's own admin route left update_unavailable_reason as " <>
             "#{inspect(reloaded.update_unavailable_reason)} — cch-w58-s1's persisted verdict is " <>
             "gone and 'unknown' is unreadable again"
  end

  # cch-w58-s3 (PR #11104). A box that ANSWERED and said no is not "unreachable".
  test "POSITIVE CONTROL (cch-w58-s3): refused and unreachable are DIFFERENT persisted verdicts",
       ctx do
    Fake.program([ok(401, "")])
    {:error, :identity_refused} = Registry.refresh_update_status(ctx.bp)
    refused = Repo.get!(BarkparkCloud.Registry.Barkpark, ctx.bp.id).update_unavailable_reason

    Fake.program([{:error, :nxdomain}])
    {:error, :unreachable} = Registry.refresh_update_status(ctx.bp)
    unreachable = Repo.get!(BarkparkCloud.Registry.Barkpark, ctx.bp.id).update_unavailable_reason

    assert refused != unreachable,
           "a box that ANSWERED 401 and a box that never answered persist the SAME verdict " <>
             "(#{inspect(refused)}) — cch-w58-s3's split has collapsed"

    assert refused == "identity_refused"
    assert unreachable == "unreachable"
  end

  # cch-w60-s4's refusal on the shared admin POST seam, which the register's
  # :self_update_trigger / :rollback_trigger rows both name.
  test "POSITIVE CONTROL: a box that already refused our identity is not asked to EXECUTE — zero requests on the wire",
       ctx do
    refuted =
      ctx.bp
      |> Ecto.Changeset.change(update_unavailable_reason: "identity_refused")
      |> Repo.update!()

    for {label, thunk} <- [
          {"self_update", fn -> Registry.trigger_self_update(refuted) end},
          {"rollback", fn -> Registry.trigger_rollback(refuted) end}
        ] do
      program_upstream()

      assert {:error, :identity_refused} = thunk.(),
             "#{label} on an identity-refuted box no longer refuses"

      assert Fake.requests() == [],
             "#{label} STILL spent the decrypted credential at an address that already told us " <>
               "the credential is wrong"
    end
  end
end
