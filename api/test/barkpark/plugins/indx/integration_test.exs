defmodule Barkpark.Plugins.Indx.IntegrationTest do
  @moduledoc """
  LIVE end-to-end test of the Indx search plugin against a REAL local Indx
  engine — no fakes, no Bypass, NO shim. Tagged `:indx_live` and EXCLUDED
  from the default suite (like `:boot_test`); the default `mix test` never
  reaches a network. Run explicitly:

      mix test --only indx_live test/barkpark/plugins/indx/integration_test.exs

  ## What it proves

    1. Seed 5 real `post` documents into Postgres (Content.create +
       publish, Default tenant scope, dataset "production").
    2. Drive the plugin's REAL blue/green indexer (`Indexer.rebuild/3`)
       through the REAL HTTP `Client` against the live Indx at
       http://127.0.0.1:5001 — create_or_open → analyze_string →
       set_searchable_fields → load_string → index_dataset → poll
       get_status → verify GetNumberOfJsonRecordsInDb. It SUCCEEDS and
       reports the corpus count.
    3. `Indexer.swap/2` flips the live pointer to the freshly-indexed
       dataset.
    4. TYPO / PARTIAL queries go through the REAL `Retriever.search/4`
       (the REAL `Client`) and the right Barkpark `%Document{}`s come back
       HYDRATED by `_id`, in the `{hits, total}` shape that matches
       `DocumentsRetriever`.

  The Indx dataset is deleted in `on_exit`.

  ## History: four real plugin bugs this test surfaced — now FIXED

  An earlier revision of this file asserted FAILURE and injected a shim,
  because `Indexer.rebuild/3` / `Client` carried four genuine defects:

    1. `Indexer.rebuild/3` ran `set_searchable_fields` BEFORE any analyze,
       so `DocumentFields == null` and `SetSearchableFields` 400'd
       ("SetSearchableFields invalid status").
    2. `Client` had no `analyze_string` verb (`POST /api/AnalyzeString/{ds}`,
       text/plain corpus body).
    3. `Client.search/3` / `get_json/3` POSTed a JSON body with NO
       `content-type: application/json` header → Indx answered
       `415 Unsupported Media Type`.
    4. `GetJson` returns `string[]` — each element is the doc serialized as
       a JSON STRING; `Client.get_json/3` returned those strings unparsed so
       the retriever dropped every hit.

  All four are fixed in the plugin source:

    * `Indexer.rebuild/3` now: create_or_open → analyze_string →
      set_searchable_fields → load_string → index_dataset.
    * `Client.analyze_string/3` exists (text/plain body).
    * `Client.search/3` / `get_json/3` send `content-type: application/json`.
    * `Client.get_json/3`'s `extract_docs` JSON-decodes each `string[]`
      element into a map.

  So this file now drives the REAL Indexer and REAL Retriever through the
  REAL Client end-to-end with NO workaround. There is nothing left to paper
  over — if a query returns nothing, that is a genuine regression.

  ## Why the Auth GenServer is allowed onto the sandbox

  `Indx.Auth` (the JWT cache the real `Client` calls via `Auth.token/0`) is
  ALREADY running in the test VM — it boots under `Barkpark.Supervisor` via
  the plugin's `register_workers/1`, ancestor = the app supervisor, NOT a
  test process. `Settings.get/0` ALWAYS reads the encrypted
  `plugin_settings` row (it does not short-circuit when env supplies every
  credential), so that supervised Auth process touches the DB on login.

  Because the per-test SQL sandbox is owned by the TEST process, we
  `Sandbox.allow/3` the supervised Auth pid onto the test's connection and
  `invalidate/0` its cache so it re-logs-in against THIS test's env
  credentials. We must NOT start a competing Auth under the same registered
  name — the supervisor would just keep the original, and a name clash would
  point the Client at the wrong process. This is pure test wiring; plugin
  production logic is untouched.
  """
  use Barkpark.DataCase, async: false

  @moduletag :indx_live

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Indx.{Auth, Client, Indexer, Retriever}

  @indx_base "http://127.0.0.1:5001"
  @ds "production"
  # Use a unique scope per run so the blue/green dataset name never collides
  # with a wedged leftover from a prior aborted run.
  @scope "itest#{System.system_time(:millisecond)}"

  @client_opts [base_url: @indx_base, timeout: 30_000]

  # Five posts with distinctive titles so a typo/partial query has an
  # unambiguous target. The :term field is the word we will misspell.
  @posts [
    %{doc_id: "ix_kubernetes", title: "Kubernetes Orchestration Guide", term: "kubernetes"},
    %{doc_id: "ix_postgres", title: "PostgreSQL Performance Tuning", term: "postgresql"},
    %{doc_id: "ix_elixir", title: "Elixir Concurrency Patterns", term: "elixir"},
    %{doc_id: "ix_typography", title: "Typography Fundamentals", term: "typography"},
    %{doc_id: "ix_photography", title: "Landscape Photography Basics", term: "photography"}
  ]

  setup do
    # Credentials via env. Restore the prior env on the way out.
    prior_env = Application.get_env(:barkpark, Barkpark.Plugins.Indx)

    Application.put_env(:barkpark, Barkpark.Plugins.Indx,
      api_base: @indx_base,
      user_email: "admin@indx.co",
      user_password: "Admin123!@#"
    )

    # The supervised Auth process (booted under Barkpark.Supervisor) reads the
    # `plugin_settings` row via Settings.get/0, so it needs the test's sandbox
    # connection. Allow it explicitly. Drop any cached token so its next login
    # uses THIS test's env credentials, and so the DB read happens while the
    # allow is in force. Fall back to starting one only if (in some future VM)
    # it is not supervised.
    auth_pid =
      case Process.whereis(Auth) do
        nil ->
          {:ok, pid} = Auth.start_link([])
          pid

        pid ->
          pid
      end

    Ecto.Adapters.SQL.Sandbox.allow(Barkpark.Repo, self(), auth_pid)
    Auth.invalidate()

    # Fail fast with a clear message if the engine is not reachable.
    case Auth.token() do
      {:ok, jwt} when is_binary(jwt) and jwt != "" ->
        :ok

      other ->
        flunk(
          "Indx not reachable at #{@indx_base} — start it before running :indx_live. " <>
            "Auth.token/0 returned: #{inspect(other)}"
        )
    end

    on_exit(fn ->
      # Leave the supervised Auth running; just clear the token so the next
      # test/run re-logs-in cleanly. Restore the prior env.
      if Process.whereis(Auth), do: Auth.invalidate()

      if prior_env do
        Application.put_env(:barkpark, Barkpark.Plugins.Indx, prior_env)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Indx)
      end
    end)

    :ok
  end

  setup :seed_corpus

  # Seed 5 real published posts in Postgres (Default scope) and stash the
  # rendered corpus on the test context.
  defp seed_corpus(_ctx) do
    published =
      Enum.map(@posts, fn p ->
        {:ok, %Document{}} =
          Content.create_document("post", %{"doc_id" => p.doc_id, "title" => p.title}, @ds)

        {:ok, %Document{} = pub} = Content.publish_document(p.doc_id, "post", @ds)
        pub
      end)

    # The Barkpark doc maps fed to the REAL Indexer. `Indexer.render_corpus/1`
    # assigns the numeric "id" key itself and embeds it alongside the "_id" we
    # supply, so we only hand it the searchable fields. The retriever maps
    # documentKey → embedded _id → Postgres row.
    corpus =
      Enum.map(published, fn doc ->
        %{"_id" => doc.doc_id, "_type" => doc.type, "title" => doc.title}
      end)

    {:ok, published: published, corpus: corpus}
  end

  test "Indexer.rebuild/3 SUCCEEDS against live Indx — correct call order, full corpus indexed",
       %{corpus: corpus} do
    # Drive the REAL plugin blue/green indexer end-to-end against the live
    # engine through the REAL Client. The fixed call order is
    # create_or_open → analyze_string → set_searchable_fields → load_string
    # → index_dataset → poll → verify count. No shim, no manual lifecycle.
    scope = "#{@scope}_rebuild"
    dataset = "bp_#{slugify(scope)}_v1"
    on_exit(fn -> Client.delete_dataset(dataset, @client_opts) end)

    result =
      Indexer.rebuild(scope, corpus,
        client: Client,
        base_url: @indx_base,
        timeout: 30_000,
        poll_attempts: 30,
        poll_interval_ms: 500,
        weights: [{"title", 0}, {"_id", 2}]
      )

    # It now SUCCEEDS — no 400, no error struct.
    assert {:ok, rebuild} = result,
           "EXPECTED Indexer.rebuild/3 to SUCCEED end-to-end against live Indx now that the " <>
             "call order + analyze_string + content-type + string[] decode bugs are fixed; " <>
             "got: #{inspect(result)}"

    assert rebuild.new_dataset == dataset
    assert rebuild.old_dataset == nil
    # All 5 seeded posts made it into the index.
    assert rebuild.count == length(corpus)
    assert rebuild.count == 5
    # The numeric-key → _id map covers every record.
    assert map_size(rebuild.key_map) == 5
    assert Enum.sort(Map.values(rebuild.key_map)) == Enum.sort(Enum.map(corpus, & &1["_id"]))

    # Independently confirm against the engine that the dataset really holds
    # the full corpus (not just that rebuild/3 reported it).
    assert {:ok, 5} = Client.get_number_of_json_records(dataset, @client_opts)
  end

  test "typo/partial search through the REAL Retriever hydrates the right Documents (read path E2E)",
       %{corpus: corpus} do
    # Build the live dataset through the REAL Indexer (same fixed path the
    # worker uses), then exercise the READ path through the REAL Retriever +
    # REAL Client — no WorkaroundClient.
    #
    # CRITICAL: the Retriever's `scope` argument doubles as the Barkpark
    # DATASET it re-reads hydrated hits from via `Content.get_document/3`.
    # Our 5 posts live in the "production" Barkpark dataset (@ds), so the
    # retriever scope MUST be @ds — NOT the Indx dataset name. We therefore
    # rebuild + swap the live pointer keyed under @ds.
    assert {:ok, rebuild} =
             Indexer.rebuild(@ds, corpus,
               client: Client,
               base_url: @indx_base,
               timeout: 30_000,
               poll_attempts: 30,
               poll_interval_ms: 500,
               weights: [{"title", 0}, {"_id", 2}]
             )

    dataset = rebuild.new_dataset
    on_exit(fn -> Client.delete_dataset(dataset, @client_opts) end)
    assert rebuild.count == 5

    # Flip the live pointer keyed under the Barkpark dataset @ds.
    Indexer.swap(@ds, rebuild)
    assert Indexer.current_dataset(@ds) == dataset
    on_exit(fn -> :persistent_term.put({Indexer, :live_dataset}, %{}) end)

    # ---- 4a. Exact-term search through the Retriever (REAL Client) ----------
    {hits, total} =
      Retriever.search(@ds, parsed(["kubernetes"]), %{"engine" => "indx"},
        client: Client,
        base_url: @indx_base,
        timeout: 30_000
      )

    assert is_integer(total)
    assert {hits, total} == {hits, length(hits)}, "{hits, total} shape: total must equal length"
    assert total >= 1, "exact-term 'kubernetes' search returned nothing from #{dataset}"
    assert Enum.all?(hits, &match?(%Document{}, &1)), "hits must be %Document{} structs"

    hit_ids = Enum.map(hits, & &1.doc_id)

    assert "ix_kubernetes" in hit_ids,
           "exact search did not return the Kubernetes post; got #{inspect(hit_ids)}"

    # The top hit must be the Kubernetes post (score-ordered by the engine).
    assert hd(hits).doc_id == "ix_kubernetes"
    assert hd(hits).type == "post"

    # ---- 4b. TYPO / PARTIAL search — the real point of a fuzzy engine ------
    # "kubernets" (missing the 'e'), "postgre" (partial). A plain Postgres
    # exact/ILIKE retriever would miss these; the Indx fuzzy index should not.
    {typo_hits, typo_total} =
      Retriever.search(@ds, parsed(["kubernets"]), %{"engine" => "indx"},
        client: Client,
        base_url: @indx_base,
        timeout: 30_000
      )

    typo_ids = Enum.map(typo_hits, & &1.doc_id)

    assert typo_total >= 1,
           "typo search 'kubernets' returned nothing — fuzzy match not working in #{dataset}"

    assert "ix_kubernetes" in typo_ids,
           "typo 'kubernets' did not surface the Kubernetes post; got #{inspect(typo_ids)}"

    assert Enum.all?(typo_hits, &match?(%Document{}, &1))

    {partial_hits, partial_total} =
      Retriever.search(@ds, parsed(["postgre"]), %{"engine" => "indx"},
        client: Client,
        base_url: @indx_base,
        timeout: 30_000
      )

    partial_ids = Enum.map(partial_hits, & &1.doc_id)

    assert partial_total >= 1,
           "partial search 'postgre' returned nothing in #{dataset}"

    assert "ix_postgres" in partial_ids,
           "partial 'postgre' did not surface the PostgreSQL post; got #{inspect(partial_ids)}"

    # ---- 4c. A miss returns the empty shape, not a crash -------------------
    {miss_hits, miss_total} =
      Retriever.search(@ds, parsed(["zzzznonexistentqq"]), %{"engine" => "indx"},
        client: Client,
        base_url: @indx_base,
        timeout: 30_000
      )

    assert miss_total == length(miss_hits)
    refute "ix_kubernetes" in Enum.map(miss_hits, & &1.doc_id)
  end

  # The QueryPipeline hands the retriever a parsed map; mirror that shape.
  defp parsed(terms), do: %{terms: terms, phrases: [], prefixes: [], excludes: []}

  # Slug that matches `Indexer`'s private slug/1 so test-built dataset names
  # line up with what the indexer would produce.
  defp slugify(scope) do
    scope
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
