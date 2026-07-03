defmodule BarkparkCloud.Web.HetznerProxyTest do
  @moduledoc """
  The Hetzner read-only control-plane proxy (charter decision 3) — the
  dashboard's server-side path into a team's Hetzner account. Proves:

    * `GET /v1/hetzner/overview` emits EXACTLY the charter envelope: ok /
      fetched_at / provider{kind,label} / all nine resources keys / matching
      counts, rows carrying at least id/name/status ("n/a" where the kind has
      none)
    * the vault-stored token is decrypted SERVER-SIDE (the upstream sees the
      Bearer) and NEVER appears in any response body
    * no connected hetzner provider → 404 no_provider (and the upstream is
      never called); teamless users get the same 404
    * one upstream kind failing degrades PER KIND (that kind null, count 0,
      an errors map entry) — the envelope never 500s over one bad upstream
    * tampered ciphertext fails closed (500 decrypt_failed, no upstream call)
    * `GET /v1/hetzner/catalog` serializes resource/verb/tier/params ONLY —
      no upstream paths, no upstream host
    * both routes are authed: no token → 401

  It also closes two wave-1 debts (charter decisions 4 & 11):

    * **Overview contract reconciliation Go↔Elixir** — the proxy's serialized
      envelope DEEP-EQUALS the committed golden fixture
      (`priv/static/__fixtures__/hetzner_overview.json`) that the Go
      `bp cloud hetzner overview -o json` test asserts byte-for-byte. Deep TERM
      equality (key order is a serializer artifact, not contract), fed a canned
      upstream that mirrors the fixture's estate. This proves the rows now carry
      the SAME kind-specific fields the Go reference does — the wave-1 proxy
      emitted bare `{id,name,status}`.
    * **Destroy-tier settlement** — a tripwire proving NO proxy execution path
      ever resolves a `:destroy` catalog entry (the 9 destroy entries stay inert
      data for the dashboard's danger-tier grammar).
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.HetznerFakeHttpClient
  alias BarkparkCloud.Registry.HetznerCatalog
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @hetzner_token "hetzner-api-token-plaintext-XYZ"

  @overview_keys ~w(servers volumes networks firewalls load_balancers floating_ips primary_ips dns_zones backups)

  ## Fixtures (mirror RouterStudioLinkTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp connect_hetzner(team, label \\ "prod account") do
    {:ok, provider} = Registry.connect_provider(team, "hetzner", @hetzner_token, label: label)
    provider
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # Canned 200s for all nine upstream reads — realistic Hetzner shapes:
  # networks/firewalls carry no status; backups are name-less images whose
  # description is the human handle.
  defp program_happy_upstream do
    HetznerFakeHttpClient.program(%{
      "/v1/servers" => ok_json(~s({"servers":[
          {"id":42,"name":"guerrilla","status":"running"},
          {"id":43,"name":"barkpark-cp","status":"running"}
        ]})),
      "/v1/volumes" => ok_json(~s({"volumes":[{"id":7,"name":"data","status":"available"}]})),
      "/v1/networks" => ok_json(~s({"networks":[{"id":1,"name":"internal"}]})),
      "/v1/firewalls" => ok_json(~s({"firewalls":[{"id":2,"name":"web"}]})),
      "/v1/load_balancers" => ok_json(~s({"load_balancers":[]})),
      "/v1/floating_ips" => ok_json(~s({"floating_ips":[{"id":9,"name":"fip-1"}]})),
      "/v1/primary_ips" => ok_json(~s({"primary_ips":[{"id":11,"name":"pip-1"}]})),
      "/v1/zones" => ok_json(~s({"zones":[{"id":"z1","name":"barkpark.cloud","status":"ok"}]})),
      "/v1/images" =>
        ok_json(
          ~s({"images":[{"id":100,"name":null,"description":"nightly backup","status":"available"}]})
        )
    })
  end

  defp ok_json(body), do: {:ok, %{status: 200, body: body}}

  describe "GET /v1/hetzner/overview" do
    test "happy path → the exact charter envelope: nine kinds, matching counts, id/name/status rows" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      # The charter-frozen top level.
      assert body["ok"] == true
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(body["fetched_at"])
      assert body["provider"] == %{"kind" => "hetzner", "label" => "prod account"}
      refute Map.has_key?(body, "errors")

      # All nine resources keys, nothing extra; counts mirror row lengths.
      assert body["resources"] |> Map.keys() |> Enum.sort() == Enum.sort(@overview_keys)
      assert body["counts"] |> Map.keys() |> Enum.sort() == Enum.sort(@overview_keys)

      for key <- @overview_keys do
        assert body["counts"][key] == length(body["resources"][key])
      end

      assert body["counts"]["servers"] == 2
      assert body["counts"]["load_balancers"] == 0

      # Rows carry at least id/name/status; "n/a" where the kind has none.
      assert %{"id" => 42, "name" => "guerrilla", "status" => "running"} in body["resources"][
               "servers"
             ]

      # Rows now carry the SAME kind-specific fields the Go reference does
      # (wave-1 debt closed): networks carry an array-derived server_count
      # (0 here), always present even with no attached servers.
      assert [%{"id" => 1, "name" => "internal", "status" => "n/a", "server_count" => 0}] =
               body["resources"]["networks"]

      # The OTHER half of the reconciliation contract: an optional the upstream
      # omitted is ABSENT, never present-as-null (router.ex's second emission
      # rule). This network carried no ip_range/created, so the row is EXACTLY
      # id/name/status/server_count — a nil-leaking merge would add null keys
      # here. The golden deep-equal can't guard this (its rows carry every
      # field), so this exact key-set assertion is the only tripwire for it.
      [network_row] = body["resources"]["networks"]
      assert Enum.sort(Map.keys(network_row)) == ~w(id name server_count status)

      # A name-less backup image falls back to its description, never null; and
      # with no created/created_from upstream, those optionals are dropped too.
      assert [%{"id" => 100, "name" => "nightly backup", "status" => "available"}] =
               body["resources"]["backups"]

      [backup_row] = body["resources"]["backups"]
      assert Enum.sort(Map.keys(backup_row)) == ~w(id name status)

      assert [%{"id" => "z1", "name" => "barkpark.cloud", "status" => "ok"}] =
               body["resources"]["dns_zones"]
    end

    test "the token is decrypted server-side for the upstream and NEVER appears in the response" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))
      assert conn.status == 200

      # Nine upstream calls, each authenticated with the DECRYPTED token —
      # proof the vault round-trip happened on the server.
      requests = HetznerFakeHttpClient.requests()
      assert length(requests) == 9

      for req <- requests do
        assert {"Authorization", "Bearer " <> @hetzner_token} =
                 List.keyfind(req.headers, "Authorization", 0)
      end

      # Backups ride the catalog's allowed type=backup query, and every read
      # asks for the 50-row page max (counts must be estate truth).
      assert Enum.any?(requests, &(&1.url =~ "/v1/images?type=backup&"))
      assert Enum.all?(requests, &(&1.url =~ "per_page=50"))

      # The raw token must never reach the browser.
      refute conn.resp_body =~ @hetzner_token
    end

    test "no connected hetzner provider → 404 no_provider, upstream never called" do
      {user, _team} = user_with_team()
      HetznerFakeHttpClient.program(%{})

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
      assert HetznerFakeHttpClient.requests() == []
    end

    test "teamless user → the same 404 no_provider" do
      user = user_fixture()
      HetznerFakeHttpClient.program(%{})

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
    end

    test "one upstream kind failing → envelope still ok, that kind null + counted 0 + named in errors" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # Volumes 500s; servers is healthy; the other seven ride the fake's
      # empty-200 default.
      HetznerFakeHttpClient.program(%{
        "/v1/servers" =>
          ok_json(~s({"servers":[{"id":42,"name":"guerrilla","status":"running"}]})),
        "/v1/volumes" => {:ok, %{status: 500, body: ~s({"error":{"code":"unavailable"}})}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      assert body["ok"] == true
      assert body["resources"]["volumes"] == nil
      assert body["counts"]["volumes"] == 0
      assert body["errors"] == %{"volumes" => "http_500"}

      # The healthy kinds are untouched.
      assert body["counts"]["servers"] == 1
      assert is_list(body["resources"]["networks"])
      refute conn.resp_body =~ @hetzner_token
    end

    test "a transport-level failure degrades the same way, with a SAFE reason" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      HetznerFakeHttpClient.program(%{
        "/v1/servers" => {:error, {:http_client, :timeout}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert body["resources"]["servers"] == nil
      assert body["errors"]["servers"] == "unreachable"
      refute conn.resp_body =~ @hetzner_token
    end

    test "a paginated estate is walked to the last page — counts are estate truth, not first-page truth" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # Hetzner pages at 25 by default (50 max) — the proxy must follow
      # meta.pagination.next_page or a 60-server fleet reads as 50.
      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"},{"id":2,"name":"b","status":"running"}],"meta":{"pagination":{"page":1,"next_page":2}}})
          ),
        "/v1/servers?per_page=50&page=2" =>
          ok_json(
            ~s({"servers":[{"id":3,"name":"c","status":"running"}],"meta":{"pagination":{"page":2,"next_page":null}}})
          )
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      assert body["counts"]["servers"] == 3
      assert Enum.map(body["resources"]["servers"], & &1["id"]) == [1, 2, 3]

      server_urls =
        HetznerFakeHttpClient.requests()
        |> Enum.map(& &1.url)
        |> Enum.filter(&(&1 =~ "/v1/servers"))

      assert length(server_urls) == 2
    end

    test "a failure on a LATER page degrades the whole kind — partial rows never lie about counts" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"}],"meta":{"pagination":{"page":1,"next_page":2}}})
          ),
        "/v1/servers?per_page=50&page=2" => {:ok, %{status: 502, body: ""}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)
      assert body["resources"]["servers"] == nil
      assert body["counts"]["servers"] == 0
      assert body["errors"]["servers"] == "http_502"
    end

    test "a next_page pointing at or behind the current page cannot loop the walk" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # A hostile/buggy upstream that points back at page 1 forever.
      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"}],"meta":{"pagination":{"page":1,"next_page":1}}})
          )
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      assert json_body(conn)["counts"]["servers"] == 1

      server_urls =
        HetznerFakeHttpClient.requests()
        |> Enum.map(& &1.url)
        |> Enum.filter(&(&1 =~ "/v1/servers"))

      assert length(server_urls) == 1
    end

    test "with several connected hetzner accounts the NEWEST is the one proxied" do
      {user, team} = user_with_team()

      older = connect_hetzner(team, "old account")

      older
      |> Ecto.Changeset.change(inserted_at: DateTime.add(older.inserted_at, -3600, :second))
      |> Repo.update!()

      connect_hetzner(team, "new account")
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      assert json_body(conn)["provider"]["label"] == "new account"
    end

    test "tampered ciphertext fails closed: 500 decrypt_failed, upstream never called" do
      {user, team} = user_with_team()
      provider = connect_hetzner(team)

      provider
      |> Ecto.Changeset.change(encrypted_token: Base.encode64("not-real-ciphertext-material"))
      |> Repo.update!()

      HetznerFakeHttpClient.program(%{})
      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 500
      assert json_body(conn) == %{"error" => "decrypt_failed"}
      assert HetznerFakeHttpClient.requests() == []
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/hetzner/overview")
      assert conn.status == 401
    end
  end

  describe "GET /v1/hetzner/catalog" do
    test "serializes resource/verb/tier/params ONLY — no upstream paths or host" do
      {user, _team} = user_with_team()

      conn = call(:get, "/v1/hetzner/catalog", session_token(user))

      assert conn.status == 200
      %{"catalog" => entries} = json_body(conn)
      assert entries != []

      for entry <- entries do
        assert Map.keys(entry) |> Enum.sort() == ["params", "resource", "tier", "verb"]
        assert entry["tier"] in ["read", "mutate", "destroy"]
      end

      # The nine reads are all listed; mutations are declared with their tier
      # so the dashboard can render the confirm grammar before wave 3 routes them.
      reads = Enum.filter(entries, &(&1["tier"] == "read"))
      assert Enum.map(reads, & &1["resource"]) |> Enum.sort() == Enum.sort(@overview_keys)

      assert Enum.any?(entries, &(&1["resource"] == "servers" and &1["verb"] == "reboot"))

      destroys = Enum.filter(entries, &(&1["tier"] == "destroy"))
      assert destroys != []
      assert Enum.all?(destroys, &("confirm" in &1["params"]))

      # Upstream internals never leave the server.
      refute conn.resp_body =~ "api.hetzner.cloud"
      refute conn.resp_body =~ "/v1/servers"
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/hetzner/catalog")
      assert conn.status == 401
    end
  end

  # ── Wave-1 debt: overview contract reconciliation Go↔Elixir ──
  #
  # The Go `bp cloud hetzner overview -o json` test asserts its output
  # byte-for-byte against the committed golden fixture. This proves the Elixir
  # proxy, fed a canned upstream mirroring the fixture's estate, emits the SAME
  # envelope — DEEP-EQUAL (term equality; JSON key order is a serializer
  # artifact, never the contract). fetched_at (a live clock) and provider.label
  # (the connected account's label, pinned to the fixture's here) are the only
  # values that legitimately vary.
  @fixture_path Path.expand(
                  "../../../priv/static/__fixtures__/hetzner_overview.json",
                  __DIR__
                )

  # The per-kind field set the golden fixture pins — the SAME contract the Go
  # test byte-asserts. Every fixture row must carry EXACTLY these keys, and the
  # proxy (below) must reproduce them from raw upstream JSON.
  @kind_fields %{
    "servers" => ~w(id name status type location ipv4 created),
    "volumes" => ~w(id name status size_gb server_id location created),
    "networks" => ~w(id name status ip_range server_count created),
    "firewalls" => ~w(id name status rule_count applied_to_count created),
    "load_balancers" => ~w(id name status type location ipv4 service_count target_count created),
    "floating_ips" => ~w(id name status ip type server_id created),
    "primary_ips" => ~w(id name status ip type assignee_id created),
    "dns_zones" => ~w(id name status mode record_count created),
    "backups" => ~w(id name status created_from created)
  }

  # A canned upstream that reproduces the golden fixture's one-per-kind estate.
  # These are RAW Hetzner Cloud API shapes (nested server_type/datacenter/
  # public_net, `servers`/`rules`/`services` arrays, images with a null name +
  # description handle) — the proxy must normalize them into the fixture rows.
  defp program_golden_upstream do
    HetznerFakeHttpClient.program(%{
      "/v1/servers" => ok_json(~s({"servers":[{"id":42,"name":"guerrilla","status":"running",
          "server_type":{"id":1,"name":"cax21"},
          "datacenter":{"id":4,"name":"hel1-dc2","location":{"id":3,"name":"hel1"}},
          "public_net":{"ipv4":{"ip":"192.0.2.10"}},
          "created":"2026-05-01T10:00:00Z"}]})),
      "/v1/volumes" =>
        ok_json(~s({"volumes":[{"id":7,"name":"pg-data","status":"available","size":50,
          "server":42,"location":{"id":3,"name":"hel1"},"created":"2026-05-02T09:00:00Z"}]})),
      "/v1/networks" =>
        ok_json(~s({"networks":[{"id":5,"name":"internal","ip_range":"10.0.0.0/16",
          "subnets":[],"routes":[],"servers":[42],"created":"2026-05-03T08:00:00Z"}]})),
      "/v1/firewalls" =>
        ok_json(
          ~s({"firewalls":[{"id":9,"name":"web-ingress",
          "rules":[{"direction":"in","protocol":"tcp","port":"443"}],
          "applied_to":[{"type":"server","server":{"id":42}}],"created":"2026-05-04T07:00:00Z"}]})
        ),
      "/v1/load_balancers" => ok_json(~s({"load_balancers":[{"id":3,"name":"edge-lb",
          "load_balancer_type":{"id":1,"name":"lb11"},"location":{"id":3,"name":"hel1"},
          "public_net":{"enabled":true,"ipv4":{"ip":"192.0.2.7"}},
          "services":[],"targets":[],"created":"2026-05-05T06:00:00Z"}]})),
      "/v1/floating_ips" =>
        ok_json(~s({"floating_ips":[{"id":11,"name":"failover-ip","type":"ipv4",
          "ip":"192.0.2.99","server":42,"created":"2026-05-06T05:00:00Z"}]})),
      "/v1/primary_ips" =>
        ok_json(~s({"primary_ips":[{"id":13,"name":"guerrilla-ip","type":"ipv4",
          "ip":"192.0.2.10","assignee_id":42,"created":"2026-05-07T04:00:00Z"}]})),
      "/v1/zones" =>
        ok_json(~s({"zones":[{"id":21,"name":"barkpark.cloud","mode":"primary","status":"ok",
          "ttl":10800,"record_count":12,"created":"2026-05-08T03:00:00Z"}]})),
      "/v1/images" =>
        ok_json(~s({"images":[{"id":31,"type":"backup","name":null,"status":"available",
          "description":"guerrilla nightly","created_from":{"id":42,"name":"guerrilla"},
          "created":"2026-05-09T02:00:00Z"}]}))
    })
  end

  describe "overview contract reconciliation (charter decision 4 debt closure)" do
    test "the golden fixture itself carries exactly the pinned kind-specific fields" do
      golden = @fixture_path |> File.read!() |> Jason.decode!()

      for {kind, fields} <- @kind_fields do
        [row] = golden["resources"][kind]

        assert Enum.sort(Map.keys(row)) == Enum.sort(fields),
               "golden #{kind} row keys drifted from the pinned contract: #{inspect(Map.keys(row))}"
      end
    end

    test "the proxy envelope DEEP-EQUALS the committed golden fixture (modulo the live clock)" do
      {user, team} = user_with_team()
      # provider.label is the fixture's — the only provider field that varies.
      connect_hetzner(team, "Hetzner Cloud")
      program_golden_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))
      assert conn.status == 200
      body = json_body(conn)
      golden = @fixture_path |> File.read!() |> Jason.decode!()

      # fetched_at is a live clock (the golden pins a fixed instant) — assert it
      # is well-formed, then compare everything else by deep TERM equality. Key
      # order is a serializer artifact; term equality ignores it.
      assert {:ok, _dt, _off} = DateTime.from_iso8601(body["fetched_at"])
      assert Map.delete(body, "fetched_at") == Map.delete(golden, "fetched_at")

      # Belt-and-braces: the reconciliation's whole point is the kind-specific
      # fields, so assert each row's key set explicitly (a deep-equal failure
      # above would already catch drift, but this names the culprit kind).
      for {kind, fields} <- @kind_fields do
        [row] = body["resources"][kind]

        assert Enum.sort(Map.keys(row)) == Enum.sort(fields),
               "proxy #{kind} row keys diverged from the golden: #{inspect(Map.keys(row))}"
      end
    end
  end

  # ── Wave-1 debt: catalog destroy-tier settlement (charter decision 11) ──
  #
  # The catalog keeps 9 `:destroy` entries as declarative data (so the dashboard
  # can render the danger-tier grammar), but the proxy must NEVER execute one.
  # These tripwires fail if a future change routes a delete through the overview
  # fan-out or exposes a destroy path server-side.
  describe "destroy-tier settlement (charter decision 11 debt closure)" do
    test "the 9 :destroy entries stay as inert data — declared, never served for execution" do
      destroys = Enum.filter(HetznerCatalog.catalog(), &(&1.tier == :destroy))

      assert length(destroys) == 9
      # Data-only: every destroy is a DELETE with a server-verified confirm slot.
      assert Enum.all?(destroys, &(&1.method == :delete))
      assert Enum.all?(destroys, &("confirm" in &1.params))

      # read_entries/0 is the ONLY tier the proxy executes — zero mutate/destroy.
      assert Enum.all?(HetznerCatalog.read_entries(), &(&1.tier == :read))
      refute Enum.any?(HetznerCatalog.read_entries(), &(&1.tier in [:mutate, :destroy]))
    end

    test "GET /v1/hetzner/overview touches ONLY :read catalog paths — never a destroy/mutate template" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      program_golden_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))
      assert conn.status == 200

      read_paths = HetznerCatalog.read_entries() |> Enum.map(& &1.path) |> MapSet.new()

      # Every upstream call the fan-out made was a GET against a bare :read list
      # path — no DELETE, no `{id}` destroy/mutate template ever left the proxy.
      for req <- HetznerFakeHttpClient.requests() do
        assert req.method == :get
        %URI{path: path} = URI.parse(req.url)

        assert path in read_paths,
               "overview called a non-read path: #{path}"

        refute path =~ ~r{/\d+(/|$)},
               "overview called an id-bearing (mutate/destroy) path: #{path}"
      end
    end

    # The router-surface tripwire the settlement demands: walk EVERY :destroy
    # catalog entry and try to invoke it through the `/v1/hetzner/*` surface in
    # the shapes a wave-3 DRIVE slice that "serves catalog entries verbatim"
    # would plausibly expose — REST id (`DELETE /v1/hetzner/servers/123`), verb
    # dispatch (`.../servers/delete`), nested action (`.../servers/123/delete`),
    # and the Hetzner-mirroring actions shape (`.../servers/123/actions/delete`).
    # Each shape is probed with the entry's own DELETE method AND with POST —
    # POST because the charter's mutate executor is a POST dispatch surface
    # (every :mutate entry is `method: :post`), so an executor that serves
    # catalog entries verbatim through that dispatcher would expose destroys as
    # `POST .../servers/delete` while still firing the upstream DELETE. Today
    # only two GET routes exist, so the catch-all `match _` 404s all of these.
    # The moment a future slice wires a generic executor that fails to filter
    # out `:destroy`, one of these probes starts routing (≠ 404/405) and/or
    # fires an upstream call — reddening this gate. Auth is real (session
    # token) and a provider is connected, so a matched destroy route WOULD
    # reach the fake upstream: the zero-request assertion is the true safety
    # net, not just the status.
    test "NO /v1/hetzner route serves a :destroy entry — every destroy shape is unroutable" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      # An empty upstream: if any probe somehow reached the fan-out/executor,
      # the fake records the call — and this test's final assertion catches it.
      HetznerFakeHttpClient.program(%{})
      token = session_token(user)

      destroys = Enum.filter(HetznerCatalog.catalog(), &(&1.tier == :destroy))
      assert length(destroys) == 9

      for entry <- destroys do
        resource = to_string(entry.resource)
        verb = to_string(entry.verb)

        probes = [
          "/v1/hetzner/#{resource}/123",
          "/v1/hetzner/#{resource}/#{verb}",
          "/v1/hetzner/#{resource}/123/#{verb}",
          "/v1/hetzner/#{resource}/123/actions/#{verb}"
        ]

        for path <- probes, method <- Enum.uniq([entry.method, :post]) do
          conn = call(method, path, token)

          assert conn.status in [404, 405],
                 "#{method} #{path} routed (#{conn.status}) — a destroy-tier " <>
                   "entry became reachable through the proxy surface"
        end
      end

      # The ironclad invariant: not one destroy probe reached an upstream call.
      assert HetznerFakeHttpClient.requests() == []
    end
  end
end
