defmodule BarkparkCloud.CloudflareTest do
  @moduledoc """
  The Cloudflare capability-provider seam (cf-w2): the context (client selection,
  fail-closed `configured?`, the `[:dns, :tls, :cdn]` menu) + Fake client
  (verify/upsert/proxy/origin-cert through the seam, deterministic ids, honest
  error branches), and the Real client's PURE request builders + fail-closed
  guards. NO DB, NO boot — mirrors `vercel_test.exs`'s pure + Fake sections.
  """
  # async: true (hg-w1-async-seam-process-scope-followup) — this module used to
  # swap node-global env (`:barkpark_cloud, Cloudflare`, incl. `:client`), which
  # was a proven live race against site_cf_deploy_test.exs (drives
  # do_bind_cloudflare/5 through `Cloudflare.client()` concurrently). Fixed at
  # the seam, not by serialization: `put_cf_config/1` now installs the override
  # in THIS TEST'S process dictionary via `Cloudflare.put_process_config/1`
  # (see Cloudflare's moduledoc "Process-scoped config override"), which
  # `Cloudflare.client()`/`configured?()` (and `Cloudflare.Real`'s own config
  # read) check before the node-global default — invisible to every other
  # concurrently-running test. Ratchet: scripts/async_env_seam_scan.exs.
  use ExUnit.Case, async: true

  alias BarkparkCloud.Cloudflare
  alias BarkparkCloud.Cloudflare.{Fake, Real}

  # Merge Cloudflare config for one test, scoped to THIS test's process only —
  # no on_exit needed, the override dies with the test process.
  defp put_cf_config(kw) do
    base = Cloudflare.resolved_config()
    Cloudflare.put_process_config(Keyword.merge(base, kw))
  end

  ## Context — client selection, configured?, capabilities

  describe "client selection + configured?" do
    test "defaults to the in-memory Fake and reports unconfigured" do
      assert Cloudflare.client() == Fake
      refute Cloudflare.configured?()
    end

    test "configured? flips only when an API token is present" do
      put_cf_config(token: "cf_test_token")
      assert Cloudflare.configured?()
    end

    test "an empty-string token is still unconfigured (fail-closed)" do
      put_cf_config(token: "")
      refute Cloudflare.configured?()
    end

    test "client/0 honours a config override at call time" do
      put_cf_config(client: Real)
      assert Cloudflare.client() == Real
    end
  end

  describe "capabilities/0" do
    test "advertises the CF-in-front menu" do
      assert Cloudflare.capabilities() == [:dns, :tls, :cdn]
    end
  end

  ## Fake client — €0 in-memory double (no wire, ever)

  describe "Fake.verify_token/1" do
    test "a good token is active and recorded" do
      assert {:ok, %{status: "active"}} = Cloudflare.verify_token("cf_good")
      assert [%{token: "cf_good"}] = Fake.verified()
    end

    test "a fail- sentinel token is rejected" do
      assert {:error, :invalid_token} = Cloudflare.verify_token("fail-token")
      assert Fake.verified() == []
    end
  end

  describe "Fake.upsert_dns_record/3 (D52 token threaded as an argument)" do
    test "creates a record with a deterministic id and records the upsert" do
      rec = %{type: "A", name: "acme.example.com", content: "203.0.113.10", proxied: true}

      assert {:ok, %{record_id: id, name: "acme.example.com"}} =
               Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)

      assert String.starts_with?(id, "rec_fake_")
      # Deterministic + IDEMPOTENT: a re-upsert of the same zone+name PATCHes the
      # same record (no duplicate row) — the read-then-branch invariant.
      assert {:ok, %{record_id: ^id}} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)

      assert [%{proxied: true, name: "acme.example.com"} | _] = Fake.records()
    end

    test "an existing :id makes the upsert an update (keeps the id)" do
      rec = %{id: "rec_existing", type: "A", name: "a.example.com", content: "203.0.113.9"}

      assert {:ok, %{record_id: "rec_existing"}} =
               Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)
    end

    test "a fail- zone id is rejected" do
      rec = %{type: "A", name: "x.example.com", content: "203.0.113.1"}
      assert {:error, :upsert_failed} = Cloudflare.upsert_dns_record("cf_tok", "fail-zone", rec)
    end

    test "a fail- token is rejected as an invalid credential (fail-closed)" do
      rec = %{type: "A", name: "x.example.com", content: "203.0.113.1"}
      assert {:error, :invalid_token} = Cloudflare.upsert_dns_record("fail-token", "zone1", rec)
      assert Fake.records() == []
    end
  end

  describe "Fake.delete_dns_record/3 — the orphan-cleanup verb" do
    test "removes the record (and its proxy flip) from the zone, and logs the delete" do
      rec = %{type: "A", name: "gone.example.com", content: "203.0.113.9", proxied: true}
      {:ok, %{record_id: id}} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)
      {:ok, %{proxied: true}} = Cloudflare.ensure_zone_proxied("cf_tok", "zone1", id)

      assert [%{record_id: ^id} | _] = Fake.records()
      assert [%{record_id: ^id}] = Fake.proxied()

      assert {:ok, %{deleted: true}} = Cloudflare.delete_dns_record("cf_tok", "zone1", id)

      # This is the zone-modeling assertion the orphan test depends on: a
      # delete REMOVES the record, so "does the zone still hold this?" reads
      # true after the fix. A call-log fake could never tell that difference.
      refute Enum.any?(Fake.records(), &(&1.record_id == id))
      assert Fake.proxied() == []
      assert [%{zone_id: "zone1", record_id: ^id}] = Fake.deletes()
    end

    test "a fail- zone id is rejected and nothing is removed" do
      rec = %{type: "A", name: "x.example.com", content: "203.0.113.1"}
      {:ok, %{record_id: id}} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)

      assert {:error, :delete_failed} = Cloudflare.delete_dns_record("cf_tok", "fail-zone", id)
      assert [%{record_id: ^id} | _] = Fake.records()
    end

    test "a fail- token is rejected as an invalid credential (fail-closed)" do
      rec = %{type: "A", name: "x.example.com", content: "203.0.113.1"}
      {:ok, %{record_id: id}} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)

      assert {:error, :invalid_token} = Cloudflare.delete_dns_record("fail-token", "zone1", id)
      assert [%{record_id: ^id} | _] = Fake.records()
    end
  end

  describe "Fake.on_upsert/1 — the orphan-race seam" do
    test "fires exactly once, right after the write, before upsert_dns_record returns" do
      test = self()
      Fake.on_upsert(fn -> send(test, :hook_fired) end)

      rec = %{type: "A", name: "race.example.com", content: "203.0.113.9"}
      assert {:ok, _} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)

      assert_received :hook_fired
      # The write landed BEFORE the hook ran, so a hook that reads Fake.records
      # sees its own write — exactly what a test simulating a concurrent
      # teardown needs (delete the resource the write just outlived).
      assert [%{name: "race.example.com"} | _] = Fake.records()
    end

    test "a nil hook is inert" do
      Fake.on_upsert(nil)
      rec = %{type: "A", name: "quiet.example.com", content: "203.0.113.9"}
      assert {:ok, _} = Cloudflare.upsert_dns_record("cf_tok", "zone1", rec)
    end
  end

  describe "Fake.ensure_zone_proxied/3 (D52 token threaded as an argument)" do
    test "flips a record to proxied and records it" do
      assert {:ok, %{proxied: true}} = Cloudflare.ensure_zone_proxied("cf_tok", "zone1", "rec_1")
      assert [%{proxied: true, record_id: "rec_1"}] = Fake.proxied()
    end

    test "the invalid-record sentinel is not_found" do
      assert {:error, :not_found} =
               Cloudflare.ensure_zone_proxied("cf_tok", "zone1", Fake.invalid_record_id())
    end

    test "a fail- token is rejected as an invalid credential (fail-closed)" do
      assert {:error, :invalid_token} =
               Cloudflare.ensure_zone_proxied("fail-token", "zone1", "rec_1")

      assert Fake.proxied() == []
    end
  end

  describe "Fake.create_origin_ca_cert/2" do
    test "mints a deterministic cert for hostnames + csr" do
      hosts = ["example.com", "*.example.com"]
      assert {:ok, %{id: id, certificate: cert}} = Cloudflare.create_origin_ca_cert(hosts, "CSR")
      assert String.starts_with?(id, "cert_fake_")
      assert cert =~ "BEGIN CERTIFICATE"
      # Deterministic on its inputs.
      assert {:ok, %{id: ^id}} = Cloudflare.create_origin_ca_cert(hosts, "CSR")
      assert [%{hostnames: ^hosts} | _] = Fake.certs()
    end

    test "an empty hostname list is rejected" do
      assert {:error, :no_hostnames} = Cloudflare.create_origin_ca_cert([], "CSR")
    end

    test "a fail- hostname is rejected" do
      assert {:error, :cert_failed} = Cloudflare.create_origin_ca_cert(["fail-host"], "CSR")
    end
  end

  ## Real client — pure request builders (no network, ever)

  describe "Real request builders" do
    test "verify_token_request hits /user/tokens/verify with the Bearer token" do
      req = Real.verify_token_request("cf_x")
      assert req.method == :get
      assert req.url == "https://api.cloudflare.com/client/v4/user/tokens/verify"
      assert {"Authorization", "Bearer cf_x"} in req.headers
    end

    test "upsert_dns_record_request POSTs a create when there is no id" do
      req =
        Real.upsert_dns_record_request("cf_x", "zone1", %{
          type: "A",
          name: "a.example.com",
          content: "203.0.113.9",
          proxied: true
        })

      assert req.method == :post
      assert req.url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records"

      body = Jason.decode!(req.body)
      assert body["type"] == "A"
      assert body["name"] == "a.example.com"
      assert body["content"] == "203.0.113.9"
      assert body["proxied"] == true
      assert body["ttl"] == 1
    end

    test "upsert_dns_record_request PUTs an update when the record carries an id" do
      req =
        Real.upsert_dns_record_request("cf_x", "zone1", %{
          id: "rec_9",
          type: "A",
          name: "a.example.com",
          content: "203.0.113.9"
        })

      assert req.method == :put
      assert req.url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec_9"
      assert Jason.decode!(req.body)["proxied"] == false
    end

    test "delete_dns_record_request DELETEs the record, no body" do
      req = Real.delete_dns_record_request("cf_x", "zone1", "rec_9")
      assert req.method == :delete
      assert req.url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec_9"
      assert req.body == ""
    end

    test "ensure_zone_proxied_request PATCHes proxied:true on the record" do
      req = Real.ensure_zone_proxied_request("cf_x", "zone1", "rec_9")
      assert req.method == :patch
      assert req.url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec_9"
      assert Jason.decode!(req.body) == %{"proxied" => true}
    end

    test "create_origin_ca_cert_request POSTs /certificates with hostnames + csr" do
      req = Real.create_origin_ca_cert_request("cf_x", ["example.com"], "CSRDATA")
      assert req.method == :post
      assert req.url == "https://api.cloudflare.com/client/v4/certificates"

      body = Jason.decode!(req.body)
      assert body["hostnames"] == ["example.com"]
      assert body["csr"] == "CSRDATA"
      assert body["request_type"] == "origin-rsa"
    end

    test "build_request carries the Bearer + UA + content-type headers" do
      req = Real.build_request(:post, "/x", "cf_x", "{}", "application/json")
      assert {"Authorization", "Bearer cf_x"} in req.headers
      assert {"User-Agent", "barkpark-cloud"} in req.headers
      assert {"Content-Type", "application/json"} in req.headers
    end
  end

  ## Real client — fail-closed guards (never touches the wire unconfigured)

  describe "Real fail-closed guards" do
    test "a blank threaded token fails closed BEFORE any request is built (D52)" do
      # The DNS callbacks now take the token as an ARGUMENT; a blank/nil one is
      # :not_configured before the wire, so a caller that failed to resolve a
      # per-team credential never reaches Cloudflare.
      rec = %{type: "A", name: "a.example.com", content: "1.1.1.1"}
      assert {:error, :not_configured} = Real.upsert_dns_record("", "zone1", rec)
      assert {:error, :not_configured} = Real.upsert_dns_record(nil, "zone1", rec)
      assert {:error, :not_configured} = Real.ensure_zone_proxied("", "zone1", "rec_1")
      assert {:error, :not_configured} = Real.ensure_zone_proxied(nil, "zone1", "rec_1")
      assert {:error, :not_configured} = Real.delete_dns_record("", "zone1", "rec_1")
      assert {:error, :not_configured} = Real.delete_dns_record(nil, "zone1", "rec_1")
    end

    test "create_origin_ca_cert still fails closed on an unset config token" do
      # create_origin_ca_cert keeps the config-token path (the TLS slice threads
      # its own credential later) — no config token → :not_configured.
      assert {:error, :not_configured} = Real.create_origin_ca_cert(["example.com"], "CSR")
    end

    test "verify_token (token as arg) fails on the absent HTTP client, not the wire" do
      # verify_token authenticates with the passed token, so it skips token/0 and
      # reaches request/1 — which fails closed when no http_client is configured.
      assert {:error, :http_client_not_configured} = Real.verify_token("cf_supplied")
    end
  end

  ## Real client — request/1 decode paths (stub transport, no wire)
  #
  # request/1 is the module's only non-trivial runtime logic (2xx → decode →
  # extract; non-2xx → typed error). Exercise it at €0 with a stub http_client
  # fn injected via config — the GitHub.Real real_test precedent. No real
  # credential, no byte to api.cloudflare.com.

  # A stub transport that returns `resp` for any request and echoes the request
  # map back to the test process so the built shape can be asserted end-to-end.
  defp stub_http_client(resp) do
    test = self()
    fn req -> send(test, {:cf_req, req}) && resp end
  end

  describe "Real request/1 decode (stub transport)" do
    test "verify_token maps a 200 CF envelope to {:ok, %{status: ...}}" do
      put_cf_config(
        http_client:
          stub_http_client({:ok, %{status: 200, body: ~s({"result":{"status":"active"}})}})
      )

      assert {:ok, %{status: "active"}} = Real.verify_token("cf_supplied")
      # The exact request the transport received is the connect-time verify call.
      assert_received {:cf_req, %{method: :get, url: url}}
      assert url == "https://api.cloudflare.com/client/v4/user/tokens/verify"
    end

    test "a connected-instance upsert threads the ARG token → transport → decoded result" do
      put_cf_config(
        http_client:
          stub_http_client(
            {:ok, %{status: 200, body: ~s({"result":{"id":"rec_live","name":"a.example.com"}})}}
          )
      )

      assert {:ok, %{record_id: "rec_live", name: "a.example.com"}} =
               Real.upsert_dns_record("cf_arg_token", "zone1", %{
                 type: "A",
                 name: "a.example.com",
                 content: "203.0.113.9"
               })

      # The THREADED per-team token (D52), not config, authenticated the call —
      # so two concurrent teams can't race over a shared put_env.
      assert_received {:cf_req, %{headers: headers}}
      assert {"Authorization", "Bearer cf_arg_token"} in headers
    end

    test "ensure_zone_proxied threads the ARG token and PATCHes proxied:true" do
      put_cf_config(
        http_client:
          stub_http_client({:ok, %{status: 200, body: ~s({"result":{"proxied":true}})}})
      )

      assert {:ok, %{proxied: true}} =
               Real.ensure_zone_proxied("cf_arg_token", "zone1", "rec_9")

      assert_received {:cf_req, %{method: :patch, url: url, headers: headers}}
      assert url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec_9"
      assert {"Authorization", "Bearer cf_arg_token"} in headers
    end

    test "delete_dns_record threads the ARG token and DELETEs the record" do
      put_cf_config(
        http_client: stub_http_client({:ok, %{status: 200, body: ~s({"result":{"id":"rec_9"}})}})
      )

      assert {:ok, %{deleted: true}} = Real.delete_dns_record("cf_arg_token", "zone1", "rec_9")

      assert_received {:cf_req, %{method: :delete, url: url, headers: headers}}
      assert url == "https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec_9"
      assert {"Authorization", "Bearer cf_arg_token"} in headers
    end

    test "a non-2xx status becomes a typed {:cloudflare_http_error, status, body}" do
      put_cf_config(
        http_client: stub_http_client({:ok, %{status: 403, body: ~s({"success":false})}})
      )

      assert {:error, {:cloudflare_http_error, 403, ~s({"success":false})}} =
               Real.verify_token("cf_supplied")
    end

    test "a 200 whose body lacks the expected shape is :unexpected_response" do
      put_cf_config(http_client: stub_http_client({:ok, %{status: 200, body: ~s({"result":{}})}}))

      assert {:error, :unexpected_response} = Real.verify_token("cf_supplied")
    end

    test "a transport-level failure is surfaced verbatim" do
      put_cf_config(http_client: stub_http_client({:error, {:http_client, :timeout}}))

      assert {:error, {:http_client, :timeout}} = Real.verify_token("cf_supplied")
    end
  end
end
