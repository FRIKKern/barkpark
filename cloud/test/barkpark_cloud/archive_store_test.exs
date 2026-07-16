defmodule BarkparkCloud.ArchiveStoreTest do
  @moduledoc """
  Portable-archive read conduit (charter S14 / D38-D39) — the `ArchiveStore`
  SigV4 S3 reader + its `GET /v1/archives` route.

  Proves:

    * SigV4 is NON-VACUOUS — the signing-key HMAC chain matches AWS's published
      documentation known-answer vector, and the full canonical-request →
      string-to-sign → signature → Authorization chain matches AWS's `get-vanilla`
      test-suite vector (every intermediate pinned, not just the final header)
    * the injectable transport carries a well-formed `Authorization` header
      (algorithm + credential scope + signed headers + 64-hex signature) plus the
      `x-amz-date` / `x-amz-content-sha256` headers S3 requires — asserted over
      the fake, so a signing regression reds here
    * ListObjectsV2 XML + manifest JSON parse into the pinned envelope,
      newest-first
    * team scoping is the security boundary: `list_archives/<team>` only ever
      reads `archives/<team>/` — a bucket holding TWO teams' bundles yields each
      team ONLY its own (a wrong/empty prefix would leak, and the test would catch
      it)
    * fail-closed: an unconfigured deployment degrades to `{:error,
      :not_configured}`, an unreachable store to a typed error — NEVER a crash,
      NEVER a fabricated empty-success
    * the route: 401 unauthenticated, 200 `{ok:true, archives}` scoped to the
      caller's team, 502 `{ok:false, error}` honest degrade

  Every outbound HTTP call is a fake injected via `:archive_store_http_client`;
  no test dials the network.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, ArchiveStore}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # ── AWS SigV4 known-answer vectors (documentation test suite) ───────────────

  # AWS docs "Examples of how to derive a signing key" — the canonical, widely
  # reproduced vector. Its stability is what makes our HMAC chain non-vacuous.
  @kat_secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  @kat_signing_key_hex "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"

  # AWS SigV4 test suite `get-vanilla`: GET / with only host + x-amz-date signed.
  @vanilla_access "AKIDEXAMPLE"
  @vanilla_datetime "20150830T123600Z"
  @vanilla_region "us-east-1"
  @vanilla_service "service"
  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @vanilla_canonical_request "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" <>
                               @empty_sha
  @vanilla_string_to_sign "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63"
  @vanilla_signature "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
  @vanilla_authorization "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=" <>
                           @vanilla_signature

  setup do
    prev = Application.get_env(:barkpark_cloud, BarkparkCloud.ArchiveStore, [])
    prev_client = Application.get_env(:barkpark_cloud, :archive_store_http_client)
    Process.delete(:archive_bucket)
    Process.delete(:archive_reqs)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore, prev)

      if prev_client do
        Application.put_env(:barkpark_cloud, :archive_store_http_client, prev_client)
      else
        Application.delete_env(:barkpark_cloud, :archive_store_http_client)
      end
    end)

    :ok
  end

  # ── SigV4: the non-vacuous known-answer proofs ──────────────────────────────

  test "derive_signing_key matches AWS's documented known-answer vector" do
    key = ArchiveStore.derive_signing_key(@kat_secret, "20150830", "us-east-1", "iam")
    assert Base.encode16(key, case: :lower) == @kat_signing_key_hex
  end

  test "sign_v4 reproduces the AWS get-vanilla vector at EVERY stage" do
    signed =
      ArchiveStore.sign_v4(%{
        method: "GET",
        host: "example.amazonaws.com",
        path: "/",
        query: [],
        headers: [
          {"host", "example.amazonaws.com"},
          {"x-amz-date", @vanilla_datetime}
        ],
        payload_hash: @empty_sha,
        amz_datetime: @vanilla_datetime,
        region: @vanilla_region,
        service: @vanilla_service,
        access_key: @vanilla_access,
        secret_key: @kat_secret
      })

    # The canonical request + string-to-sign are deterministic (no crypto) — a
    # mismatch pinpoints a canonicalization bug, independent of the HMAC chain.
    assert signed.canonical_request == @vanilla_canonical_request
    assert signed.string_to_sign == @vanilla_string_to_sign
    # The final signature + Authorization header — the whole chain, end to end.
    assert signed.signature == @vanilla_signature
    assert signed.authorization == @vanilla_authorization
    assert signed.signed_headers == "host;x-amz-date"
  end

  test "canonical query string encodes and sorts params (slash percent-encoded)" do
    # A signed listing carries list-type + prefix; the prefix's slashes MUST be
    # %2F-encoded and params sorted by key, or S3 rejects the signature.
    signed =
      ArchiveStore.sign_v4(%{
        method: "GET",
        host: "b.fsn1.your-objectstorage.com",
        path: "/",
        query: [{"prefix", "archives/team-1/"}, {"list-type", "2"}],
        headers: [{"host", "b.fsn1.your-objectstorage.com"}],
        payload_hash: @empty_sha,
        amz_datetime: @vanilla_datetime,
        region: "fsn1",
        service: "s3",
        access_key: @vanilla_access,
        secret_key: @kat_secret
      })

    # sorted (list-type before prefix), slashes → %2F
    assert signed.canonical_request =~ "list-type=2&prefix=archives%2Fteam-1%2F"
  end

  # ── list_archives: parse + scope + degrade ──────────────────────────────────

  test "list_archives parses ListObjectsV2 XML + manifests, newest-first" do
    configure!()

    put_bucket(%{
      "team-a" => [
        {"web-1",
         manifest_json(
           "web-1.barkpark.cloud",
           "web-1",
           "hetzner",
           "2026-07-01T00:00:00Z",
           "nbg1",
           "cax11"
         )},
        {"api-2",
         manifest_json(
           "api-2.barkpark.cloud",
           "api-2",
           "azure",
           "2026-07-08T00:00:00Z",
           "eastus",
           "Standard_B1s"
         )}
      ]
    })

    inject_fake!()

    assert {:ok, archives} = ArchiveStore.list_archives("team-a")
    assert length(archives) == 2

    # newest-first: api-2 (Jul 8) before web-1 (Jul 1)
    assert [%{slug: "api-2"}, %{slug: "web-1"}] = archives

    a = hd(archives)
    assert a.fqdn == "api-2.barkpark.cloud"
    assert a.source_provider == "azure"
    assert a.created_at == "2026-07-08T00:00:00Z"
    assert a.spec == %{region: "eastus", server_type: "Standard_B1s"}
    assert a.bundle_ref == "archives/team-a/api-2/"
  end

  test "list_archives is team-scoped: a two-team bucket yields each team only its own" do
    configure!()

    put_bucket(%{
      "team-a" => [
        {"a-box",
         manifest_json(
           "a.barkpark.cloud",
           "a-box",
           "hetzner",
           "2026-07-01T00:00:00Z",
           "nbg1",
           "cax11"
         )}
      ],
      "team-b" => [
        {"b-box",
         manifest_json(
           "b.barkpark.cloud",
           "b-box",
           "azure",
           "2026-07-02T00:00:00Z",
           "eastus",
           "Standard_B1s"
         )}
      ]
    })

    inject_fake!()

    assert {:ok, [%{slug: "a-box", fqdn: "a.barkpark.cloud"}]} =
             ArchiveStore.list_archives("team-a")

    assert {:ok, [%{slug: "b-box", fqdn: "b.barkpark.cloud"}]} =
             ArchiveStore.list_archives("team-b")

    # Every outbound listing carried the requesting team's own prefix — a wrong
    # or empty prefix (e.g. bare "archives/") is what would have leaked the other
    # team's bundle, and the two single-element results above would have grown.
    prefixes = for r <- requests(), url_has?(r, "list-type=2"), do: prefix_of(r)
    assert "archives/team-a/" in prefixes
    assert "archives/team-b/" in prefixes
    assert Enum.all?(prefixes, fn p -> p in ["archives/team-a/", "archives/team-b/"] end)
  end

  test "list_archives follows the ListObjectsV2 continuation token across pages" do
    configure!()

    # A bespoke fake: page 1 is truncated + names a continuation token; the
    # follow-up carries that token and returns the second key. Proves the reader
    # walks IsTruncated/NextContinuationToken rather than dropping the tail.
    Application.put_env(:barkpark_cloud, :archive_store_http_client, fn req ->
      %URI{query: q, path: path} = URI.parse(req.url)
      params = URI.decode_query(q || "")

      cond do
        params["list-type"] == "2" and is_nil(params["continuation-token"]) ->
          {:ok,
           %{
             status: 200,
             body:
               ~s(<?xml version="1.0"?><ListBucketResult><IsTruncated>true</IsTruncated>) <>
                 "<NextContinuationToken>TOKEN-2</NextContinuationToken>" <>
                 "<Contents><Key>archives/team-a/one/manifest.json</Key></Contents></ListBucketResult>",
             headers: []
           }}

        params["list-type"] == "2" and params["continuation-token"] == "TOKEN-2" ->
          {:ok,
           %{
             status: 200,
             body:
               ~s(<?xml version="1.0"?><ListBucketResult><IsTruncated>false</IsTruncated>) <>
                 "<Contents><Key>archives/team-a/two/manifest.json</Key></Contents></ListBucketResult>",
             headers: []
           }}

        String.ends_with?(path, "/one/manifest.json") ->
          {:ok,
           %{
             status: 200,
             body:
               manifest_json(
                 "one.example",
                 "one",
                 "hetzner",
                 "2026-07-02T00:00:00Z",
                 "nbg1",
                 "cax11"
               ),
             headers: []
           }}

        String.ends_with?(path, "/two/manifest.json") ->
          {:ok,
           %{
             status: 200,
             body:
               manifest_json(
                 "two.example",
                 "two",
                 "azure",
                 "2026-07-01T00:00:00Z",
                 "eastus",
                 "Standard_B1s"
               ),
             headers: []
           }}

        true ->
          {:ok, %{status: 404, body: "", headers: []}}
      end
    end)

    assert {:ok, archives} = ArchiveStore.list_archives("team-a")
    assert Enum.map(archives, & &1.slug) == ["one", "two"]
  end

  test "list_archives signs the request: Authorization + amz headers on the wire" do
    configure!()
    put_bucket(%{"team-a" => []})
    inject_fake!()

    assert {:ok, []} = ArchiveStore.list_archives("team-a")

    [req | _] = requests()
    auth = header(req, "Authorization")
    assert String.starts_with?(auth, "AWS4-HMAC-SHA256 Credential=AK-TEST/")
    assert auth =~ "/fsn1/s3/aws4_request"
    assert auth =~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    assert Regex.run(~r/Signature=([0-9a-f]{64})$/, auth), "signature must be 64 lowercase hex"
    assert header(req, "x-amz-date") =~ ~r/^\d{8}T\d{6}Z$/
    assert header(req, "x-amz-content-sha256") == @empty_sha
    # GET-only + virtual-hosted endpoint.
    assert req.method == :get
    assert String.starts_with?(req.url, "https://bundles.fsn1.your-objectstorage.com/")
  end

  test "list_archives fails closed when unconfigured (no crash, no fake empty)" do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore,
      access_key: nil,
      secret_key: nil,
      bucket: nil,
      location: "fsn1"
    )

    assert {:error, :not_configured} = ArchiveStore.list_archives("team-a")
  end

  test "list_archives surfaces an unreachable store as a typed error, never a crash" do
    configure!()

    Application.put_env(:barkpark_cloud, :archive_store_http_client, fn _req ->
      {:error, {:http_client, :nxdomain}}
    end)

    assert {:error, {:unreachable, _}} = ArchiveStore.list_archives("team-a")
  end

  test "list_archives drops a single corrupt manifest, keeps the rest" do
    configure!()

    put_bucket(%{
      "team-a" => [
        {"good",
         manifest_json(
           "good.barkpark.cloud",
           "good",
           "hetzner",
           "2026-07-01T00:00:00Z",
           "nbg1",
           "cax11"
         )},
        {"broken", "{ this is not json"}
      ]
    })

    inject_fake!()

    assert {:ok, [%{slug: "good"}]} = ArchiveStore.list_archives("team-a")
  end

  test "list_archives aggregates multiple failing manifests into ONE summary warning" do
    configure!()

    put_bucket(%{
      "team-a" => [
        {"good",
         manifest_json(
           "good.barkpark.cloud",
           "good",
           "hetzner",
           "2026-07-01T00:00:00Z",
           "nbg1",
           "cax11"
         )},
        {"broken-1", "{ not json 1"},
        {"broken-2", "{ not json 2"}
      ]
    })

    inject_fake!()

    log =
      capture_log(fn ->
        assert {:ok, [%{slug: "good"}]} = ArchiveStore.list_archives("team-a")
      end)

    # A store outage (or, here, two corrupt manifests) must never flood the
    # log with one line per key — exactly ONE summary warning per call.
    occurrences =
      log |> String.split("manifests failed to fetch/parse") |> length() |> Kernel.-(1)

    assert occurrences == 1, "expected exactly one aggregated warning, got log:\n#{log}"
    assert log =~ "archive_store: 2/3 manifests failed to fetch/parse:"
    assert log =~ "not valid JSON"
  end

  # ── GET /v1/archives route ──────────────────────────────────────────────────

  test "GET /v1/archives is 401 without auth" do
    conn = Router.call(conn(:get, "/v1/archives"), @opts)
    assert conn.status == 401
  end

  test "GET /v1/archives serves the caller's team bundles, scoped" do
    configure!()

    {_user_a, team_a, token_a} = user_team_session()
    # The bucket is keyed by the REAL team id so the route's prefix matches.
    put_bucket(%{
      team_a.id => [
        {"web",
         manifest_json(
           "web.barkpark.cloud",
           "web",
           "hetzner",
           "2026-07-01T00:00:00Z",
           "nbg1",
           "cax11"
         )}
      ]
    })

    inject_fake!()

    conn = authed(:get, "/v1/archives", token_a)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [%{"slug" => "web", "fqdn" => "web.barkpark.cloud"}] = body["archives"]

    # A DIFFERENT team on the same bucket sees nothing of team A's.
    {_user_b, _team_b, token_b} = user_team_session()
    conn_b = authed(:get, "/v1/archives", token_b)
    assert conn_b.status == 200
    assert Jason.decode!(conn_b.resp_body)["archives"] == []
  end

  test "GET /v1/archives degrades to 502 {ok:false} when unconfigured (never a lying empty)" do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore,
      access_key: nil,
      secret_key: nil,
      bucket: nil,
      location: "fsn1"
    )

    {_user, _team, token} = user_team_session()
    conn = authed(:get, "/v1/archives", token)
    assert conn.status == 502
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false
    assert body["error"] =~ "configured"
  end

  # ── helpers ──

  defp configure! do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore,
      access_key: "AK-TEST",
      secret_key: "SK-TEST",
      bucket: "bundles",
      location: "fsn1"
    )
  end

  # The fake bucket: %{team_id => [{slug, manifest_body}]}. Held in the test
  # process dict — the route runs synchronously in THIS process.
  defp put_bucket(bucket), do: Process.put(:archive_bucket, bucket)

  defp inject_fake! do
    Application.put_env(:barkpark_cloud, :archive_store_http_client, &fake_request/1)
  end

  # The injected transport. Records every request, then answers a ListObjectsV2
  # by filtering the bucket to the requested prefix (real S3 prefix semantics),
  # and a manifest GET by key.
  defp fake_request(req) do
    Process.put(:archive_reqs, (Process.get(:archive_reqs) || []) ++ [req])
    bucket = Process.get(:archive_bucket) || %{}
    %URI{query: query, path: path} = URI.parse(req.url)
    params = URI.decode_query(query || "")

    cond do
      params["list-type"] == "2" ->
        {:ok, %{status: 200, body: list_xml(bucket, params["prefix"] || ""), headers: []}}

      String.ends_with?(path, "/manifest.json") ->
        key = String.trim_leading(path, "/")

        case manifest_for(bucket, key) do
          nil -> {:ok, %{status: 404, body: "<Error><Code>NoSuchKey</Code></Error>", headers: []}}
          body -> {:ok, %{status: 200, body: body, headers: []}}
        end

      true ->
        {:ok, %{status: 404, body: "", headers: []}}
    end
  end

  # All keys across all teams whose key starts with `prefix` → a ListBucketResult.
  defp list_xml(bucket, prefix) do
    contents =
      for {team, entries} <- bucket,
          {slug, _body} <- entries,
          key = "archives/#{team}/#{slug}/manifest.json",
          String.starts_with?(key, prefix),
          into: "" do
        "<Contents><Key>#{key}</Key><Size>80</Size><LastModified>2026-07-01T00:00:01.000Z</LastModified></Contents>"
      end

    ~s(<?xml version="1.0"?><ListBucketResult><Name>bundles</Name><IsTruncated>false</IsTruncated>) <>
      contents <> "</ListBucketResult>"
  end

  defp manifest_for(bucket, key) do
    Enum.find_value(bucket, fn {team, entries} ->
      Enum.find_value(entries, fn {slug, body} ->
        if key == "archives/#{team}/#{slug}/manifest.json", do: body
      end)
    end)
  end

  # A manifest WITHOUT an explicit bundle_ref — the reader falls back to the
  # bundle's key PREFIX (the manifest key minus "manifest.json"), so bundle_ref
  # always names where the bundle actually lives AND is directly consumable as
  # a resurrect --bundle ref.
  defp manifest_json(fqdn, slug, provider, created_at, region, server_type) do
    Jason.encode!(%{
      fqdn: fqdn,
      slug: slug,
      source_provider: provider,
      created_at: created_at,
      spec: %{region: region, server_type: server_type}
    })
  end

  defp requests, do: Process.get(:archive_reqs) || []

  defp header(req, name) do
    Enum.find_value(req.headers, fn {k, v} ->
      if String.downcase(k) == String.downcase(name), do: v
    end)
  end

  defp url_has?(req, needle), do: String.contains?(req.url, needle)

  defp prefix_of(req) do
    %URI{query: q} = URI.parse(req.url)
    URI.decode_query(q || "")["prefix"]
  end

  defp user_team_session do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp authed(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end
end
