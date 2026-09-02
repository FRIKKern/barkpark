defmodule BarkparkCloud.Workers.ArchiveRetentionWorkerTest do
  @moduledoc """
  cch-w54-bl — the archive-bundle deletion path and its daily sweep.

  Before this wave a decommission `Repo.delete`d the barkpark row and left the
  bundle — a `pg_dump` plus a media tar, a full copy of the customer's content
  — in object storage with NO route that could remove it: `ArchiveStore`
  exported `list_archives/1`, `sign_v4/1` and `derive_signing_key/4`, and
  nothing else.

  Proves:

    * the 30-day boundary IN BOTH DIRECTIONS — a bundle one second past the
      window is purged, a bundle exactly at the window (and one second inside
      it) is kept. A one-sided test would stay green against a sweep that
      deleted everything.
    * the STILL-LIVE-TEAM guard — a team that still owns a barkpark row keeps
      its most recent bundle at ANY age, while its older bundles still expire;
      and the mirror, a torn-down team whose newest bundle IS purged, so the
      guard is proven to be conditional rather than a blanket keep.
    * a bundle whose manifest carries no readable `created_at` is never purged
      — an age we cannot compute is not an age of zero.
    * `ArchiveStore.delete_bundle/2` issues one signed DELETE per object under
      the bundle prefix, and REFUSES a `bundle_ref` outside the requesting
      team's own prefix without signing anything.
    * the whole sweep end to end over the injected transport: the expired
      bundle's objects are really gone from the fake bucket, the protected one
      is really still there.

  Every outbound call is a fake injected via `:archive_store_http_client`; no
  test dials the network. `async: false` because the transport and the bundle
  store config are application-global.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, ArchiveStore, Registry}
  alias BarkparkCloud.Workers.ArchiveRetentionWorker

  @retention_days 30

  setup do
    prev = Application.get_env(:barkpark_cloud, BarkparkCloud.ArchiveStore, [])
    prev_client = Application.get_env(:barkpark_cloud, :archive_store_http_client)
    Process.delete(:archive_bucket)
    Process.delete(:archive_reqs)
    Process.delete(:archive_deleted)

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

  ## ── 1. The retention window, in BOTH directions ──────────────────────────

  test "the 30-day boundary: one second past the window purges, the window itself keeps" do
    now = ~U[2026-09-02 12:00:00Z]

    just_past = bundle("past", DateTime.add(now, -(@retention_days * 24 * 3600 + 1), :second))
    exactly_at = bundle("edge", DateTime.add(now, -@retention_days * 24 * 3600, :second))
    just_inside = bundle("inside", DateTime.add(now, -(@retention_days * 24 * 3600 - 1), :second))

    doomed = ArchiveRetentionWorker.purgeable([just_past, exactly_at, just_inside], false, now)

    # The POSITIVE half: past the window really is erased.
    assert Enum.map(doomed, & &1.slug) == ["past"],
           "expected only the bundle past the window to be purgeable; got " <>
             inspect(Enum.map(doomed, & &1.slug))

    # The NEGATIVE half: without it, a sweep that purges EVERYTHING passes.
    refute exactly_at in doomed, "a bundle exactly at the retention window was purged"
    refute just_inside in doomed, "a bundle inside the retention window was purged"
  end

  test "the retention window the code applies is the 30 days the copy promises" do
    assert ArchiveRetentionWorker.retention_days() == @retention_days
  end

  ## ── 2. The still-live-team guard ─────────────────────────────────────────

  test "a still-live team never loses its most recent bundle, however old" do
    now = ~U[2026-09-02 12:00:00Z]
    newest = bundle("newest", DateTime.add(now, -100 * 24 * 3600, :second))
    older = bundle("older", DateTime.add(now, -200 * 24 * 3600, :second))
    oldest = bundle("oldest", DateTime.add(now, -300 * 24 * 3600, :second))

    doomed = ArchiveRetentionWorker.purgeable([older, newest, oldest], true, now)
    slugs = Enum.map(doomed, & &1.slug)

    refute "newest" in slugs,
           "the most recent bundle of a STILL-LIVE team was purged — the guard is gone"

    # The guard protects ONE bundle, not the shelf: the older two still expire.
    assert Enum.sort(slugs) == ["older", "oldest"],
           "the live team's older bundles must still expire; got " <> inspect(slugs)
  end

  test "a torn-down team's most recent bundle IS purged — the guard is conditional" do
    now = ~U[2026-09-02 12:00:00Z]
    newest = bundle("newest", DateTime.add(now, -100 * 24 * 3600, :second))
    older = bundle("older", DateTime.add(now, -200 * 24 * 3600, :second))

    doomed = ArchiveRetentionWorker.purgeable([newest, older], false, now)

    assert Enum.sort(Enum.map(doomed, & &1.slug)) == ["newest", "older"],
           "a team with no barkpark row left keeps nothing past the window"
  end

  test "a bundle with no readable created_at is never purged" do
    now = ~U[2026-09-02 12:00:00Z]
    stampless = %{slug: "stampless", created_at: nil, bundle_ref: "archives/t/stampless/"}
    garbled = %{slug: "garbled", created_at: "not-a-date", bundle_ref: "archives/t/garbled/"}
    expired = bundle("expired", DateTime.add(now, -60 * 24 * 3600, :second))

    doomed = ArchiveRetentionWorker.purgeable([stampless, garbled, expired], false, now)

    assert Enum.map(doomed, & &1.slug) == ["expired"]
  end

  test "a stampless bundle cannot shield a live team's real newest from expiring" do
    # The guard picks the newest among PARSEABLE stamps only. If a broken
    # manifest could be "the newest", it would hold the protection while the
    # team's real newest aged out — the opposite of the rule.
    now = ~U[2026-09-02 12:00:00Z]
    stampless = %{slug: "stampless", created_at: nil, bundle_ref: "archives/t/stampless/"}
    real_newest = bundle("real-newest", DateTime.add(now, -100 * 24 * 3600, :second))

    doomed = ArchiveRetentionWorker.purgeable([stampless, real_newest], true, now)

    assert doomed == [], "the live team's real newest bundle must be the protected one"
  end

  ## ── 3. delete_bundle: the erasure primitive ──────────────────────────────

  test "delete_bundle removes every object under the bundle prefix with signed DELETEs" do
    configure!()
    put_bucket(%{"team-a" => [{"web-1", "2026-01-01T00:00:00Z"}]})
    inject_fake!()

    assert {:ok, 3} = ArchiveStore.delete_bundle("team-a", "archives/team-a/web-1/")

    deletes = for r <- requests(), r.method == :delete, do: path_of(r)

    assert Enum.sort(deletes) == [
             "/archives/team-a/web-1/dump.sql.gz",
             "/archives/team-a/web-1/manifest.json",
             "/archives/team-a/web-1/media.tar"
           ]

    # Not decorative: every DELETE carried a real SigV4 Authorization header.
    for r <- requests(), r.method == :delete do
      auth = header(r, "Authorization")
      assert auth =~ "AWS4-HMAC-SHA256 Credential=AK-TEST/"
      assert auth =~ ~r/Signature=[0-9a-f]{64}$/
    end

    # And the bundle is really gone from the store's own view.
    assert {:ok, []} = ArchiveStore.list_archives("team-a")
  end

  test "delete_bundle refuses a ref outside the team's own prefix, before signing anything" do
    configure!()
    put_bucket(%{"team-b" => [{"victim", "2026-01-01T00:00:00Z"}]})
    inject_fake!()

    assert {:error, :cross_team_ref} =
             ArchiveStore.delete_bundle("team-a", "archives/team-b/victim/")

    # The bare team prefix is refused too — it would erase the whole shelf.
    assert {:error, :cross_team_ref} = ArchiveStore.delete_bundle("team-a", "archives/team-a/")

    assert requests() == [], "a refused delete must not reach the store at all"
  end

  test "delete_bundle degrades honestly on an unconfigured deployment" do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore, [])

    assert {:error, :not_configured} =
             ArchiveStore.delete_bundle("team-a", "archives/team-a/web-1/")
  end

  ## ── 4. The sweep, end to end over the fake bucket ────────────────────────

  test "perform purges the expired bundle and leaves the live team's newest standing" do
    configure!()
    team = team_fixture()
    _live_instance = barkpark_fixture(team)

    put_bucket(%{
      team.id => [
        {"recent", iso(days_ago(100))},
        {"ancient", iso(days_ago(400))}
      ]
    })

    inject_fake!()

    assert {:ok, summary} = perform_job(ArchiveRetentionWorker, %{})
    assert summary.purged == 1
    assert summary.kept == 1
    assert summary.failed == 0

    assert {:ok, [%{slug: "recent"}]} = ArchiveStore.list_archives(team.id),
           "the live team's most recent bundle must survive; the 400-day-old one must not"
  end

  test "perform purges every expired bundle of a team with no instances left" do
    configure!()
    team = team_fixture()

    put_bucket(%{team.id => [{"recent", iso(days_ago(100))}, {"ancient", iso(days_ago(400))}]})
    inject_fake!()

    assert {:ok, summary} = perform_job(ArchiveRetentionWorker, %{})
    assert summary.purged == 2
    assert summary.kept == 0

    assert {:ok, []} = ArchiveStore.list_archives(team.id)
  end

  test "perform is a no-op on an unconfigured bundle store and never raises" do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore, [])
    _team = team_fixture()

    assert {:ok, %{purged: 0, failed: 0}} = perform_job(ArchiveRetentionWorker, %{})
  end

  test "worker is scheduled daily on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"45 3 * * *", ArchiveRetentionWorker} in crontab
    assert ArchiveRetentionWorker.__opts__()[:queue] == :maintenance
  end

  ## ── helpers ──

  defp bundle(slug, %DateTime{} = created_at) do
    %{
      slug: slug,
      created_at: DateTime.to_iso8601(created_at),
      bundle_ref: "archives/t/#{slug}/"
    }
  end

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 24 * 3600, :second)
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp configure! do
    Application.put_env(:barkpark_cloud, BarkparkCloud.ArchiveStore,
      access_key: "AK-TEST",
      secret_key: "SK-TEST",
      bucket: "bundles",
      location: "fsn1"
    )
  end

  # The fake bucket: %{team_id => [{slug, created_at_iso}]}. Each bundle is
  # THREE objects — the manifest plus the pg_dump and media tar a real bundle
  # carries — so a delete that only removed the manifest (leaving the customer
  # content behind, the very defect this closes) would fail the count above.
  defp put_bucket(bucket), do: Process.put(:archive_bucket, bucket)

  defp inject_fake!,
    do: Application.put_env(:barkpark_cloud, :archive_store_http_client, &fake_request/1)

  defp objects do
    for {team, entries} <- Process.get(:archive_bucket) || %{},
        {slug, created_at} <- entries,
        {suffix, body} <- [
          {"manifest.json", manifest_json(slug, created_at)},
          {"dump.sql.gz", "<gzip>"},
          {"media.tar", "<tar>"}
        ],
        do: {"archives/#{team}/#{slug}/#{suffix}", body}
  end

  defp fake_request(req) do
    Process.put(:archive_reqs, (Process.get(:archive_reqs) || []) ++ [req])
    %URI{query: query, path: path} = URI.parse(req.url)
    params = URI.decode_query(query || "")
    key = String.trim_leading(path, "/")
    all = objects()

    cond do
      req.method == :delete ->
        deleted = Process.get(:archive_deleted) || MapSet.new()
        Process.put(:archive_deleted, MapSet.put(deleted, key))
        {:ok, %{status: 204, body: "", headers: []}}

      params["list-type"] == "2" ->
        {:ok, %{status: 200, body: list_xml(all, params["prefix"] || ""), headers: []}}

      true ->
        case Enum.find_value(all, fn {k, body} -> if k == key and live?(k), do: body end) do
          nil -> {:ok, %{status: 404, body: "", headers: []}}
          body -> {:ok, %{status: 200, body: body, headers: []}}
        end
    end
  end

  # A key the fake has "deleted" no longer lists and no longer GETs — otherwise
  # the end-to-end assertions would pass against a sweep that deleted nothing.
  defp live?(key), do: not MapSet.member?(Process.get(:archive_deleted) || MapSet.new(), key)

  defp list_xml(all, prefix) do
    contents =
      for {key, _body} <- all, String.starts_with?(key, prefix), live?(key), into: "" do
        "<Contents><Key>#{key}</Key><Size>80</Size></Contents>"
      end

    ~s(<?xml version="1.0"?><ListBucketResult><Name>bundles</Name><IsTruncated>false</IsTruncated>) <>
      contents <> "</ListBucketResult>"
  end

  defp manifest_json(slug, created_at) do
    Jason.encode!(%{
      fqdn: "#{slug}.barkpark.cloud",
      slug: slug,
      source_provider: "hetzner",
      created_at: created_at,
      spec: %{region: "nbg1", server_type: "cax11"}
    })
  end

  defp requests, do: Process.get(:archive_reqs) || []

  defp path_of(req), do: URI.parse(req.url).path

  defp header(req, name) do
    Enum.find_value(req.headers, fn {k, v} ->
      if String.downcase(k) == String.downcase(name), do: v
    end)
  end
end
