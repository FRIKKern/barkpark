defmodule Barkpark.Plugins.Indx.IntegrationTest do
  @moduledoc """
  LIVE end-to-end test of the Indx search plugin against a REAL local Indx
  engine — no fakes, no Bypass. Tagged `:indx_live` and EXCLUDED from the
  default suite (like `:boot_test`); the default `mix test` never reaches a
  network. Run explicitly:

      mix test --only indx_live test/barkpark/plugins/indx/integration_test.exs

  ## What it proves

    1. Seed 5 real `post` documents into Postgres (Content.create +
       publish, Default tenant scope).
    2. Render them and run the plugin's REAL blue/green indexer
       (`Indexer.rebuild/3`) through the REAL HTTP `Client` against the live
       Indx at http://127.0.0.1:5001 — create_or_open → set_searchable_fields
       → load_string (text/plain) → index_dataset → poll get_status →
       verify GetNumberOfJsonRecordsInDb.
    3. `Indexer.swap/2` flips the live pointer to the freshly-indexed
       dataset.
    4. A TYPO / PARTIAL query goes through `Retriever.search/4` (the real
       `Client`) and the right Barkpark `%Document{}` comes back HYDRATED by
       `_id`, in the `{hits, total}` shape that matches
       `DocumentsRetriever`.

  The Indx dataset is deleted in `on_exit`.

  ## A REAL plugin bug this test surfaced (do NOT paper over)

  `Indexer.rebuild/3` issues the lifecycle calls in this order:

      create_or_open → set_searchable_fields → load_string → index_dataset

  That order is WRONG for this engine (Indx 4.1.2.0). Empirically confirmed
  against the live server:

    * `SetSearchableFields` returns `400 "SearchController.SetSearchableFields
      invalid status"` whenever `DocumentFields == null`.
    * `DocumentFields` is populated by **`AnalyzeString`** (or a prior persisted
      analyze), NOT by `LoadString`. `LoadString`'s internal `Load` only reads
      DocumentFields back from the DB if they were already saved.

  So the working sequence is:

      create_or_open → AnalyzeString → set_searchable_fields → load_string
        → index_dataset

  FOUR genuine defects this live test surfaced (for the implement stage —
  production code is NOT changed here):

    1. `Indexer.rebuild/3` runs `set_searchable_fields` BEFORE `load_string`
       and never analyzes. It must: create_or_open → analyze → set_searchable
       (AFTER analyze) → load_string → index.
    2. `Client` has NO `analyze_string` verb (`POST /api/AnalyzeString/{ds}`,
       body = the corpus JSON re-encoded as a JSON string).
    3. `Client.search/3` and `get_json/3` POST a JSON body with NO
       `content-type: application/json` header → Indx returns
       `415 Unsupported Media Type`. (Verified: identical curl WITH the header
       returns records; WITHOUT it returns 415.)
    4. `GetJson` returns `string[]` — an array where each element is the doc
       serialized as a JSON STRING. `Client.get_json/3`'s `extract_docs`
       returns those strings unparsed, so `Retriever.load_document/3` calls
       `Map.get/2` on a string, gets nil, and DROPS every hit. `extract_docs`
       must JSON-decode each `string[]` element into a map.

  Because of #2–#4 the REAL `Retriever.search/4` through the REAL `Client`
  currently yields `{[], 0}` against live Indx. To still prove the READ path
  end-to-end — the retriever's query-text parsing, documentKey→_id mapping,
  and Postgres hydration via `Content.get_document/3` — the read-path test
  injects a thin `WorkaroundClient` that DELEGATES to the real `Client` for
  search/get_json but applies the #3/#4 fixes (adds the content-type header,
  decodes the `string[]`). Every other call (create_or_open,
  set_searchable_fields, load_string, index, count, delete) goes through the
  REAL `Client` unchanged. This is the minimum shim that lets the genuine
  retriever logic run against genuine live engine output without touching
  plugin source.

  This file proves the indexer bug with `test "Indexer.rebuild/3 currently
  FAILS …"` and proves the read path with `test "typo/partial search through
  the REAL Retriever …"`.

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

  # Thin client injected ONLY into the read-path test's `Retriever.search/4`.
  # It DELEGATES every call to the real `Client` and applies the minimum
  # workarounds for bugs #3 and #4 (see moduledoc) so the genuine retriever
  # logic runs against genuine live engine output:
  #
  #   * search/3   — adds `content-type: application/json` (bug #3).
  #   * get_json/3 — adds the header (bug #3) AND JSON-decodes the `string[]`
  #     elements into maps the retriever can read `_id`/`_type` off (bug #4).
  #
  # No lifecycle verb is touched — those go straight through the real Client.
  defmodule WorkaroundClient do
    alias Barkpark.Plugins.Indx.Auth

    @base "http://127.0.0.1:5001"

    def search(dataset, text, opts) do
      body = Jason.encode!(%{"text" => text, "maxNumberOfRecordsToReturn" => Keyword.get(opts, :max, 30)})

      case post("Search/#{dataset}", body) do
        {:ok, %{"records" => records}} when is_list(records) -> {:ok, records}
        {:ok, _} -> {:ok, []}
        {:error, _} = err -> err
      end
    end

    def get_json(dataset, keys, _opts) do
      body = Jason.encode!(keys)

      case post("GetJson/#{dataset}", body) do
        {:ok, list} when is_list(list) ->
          # Engine returns string[]; decode each JSON string into a map.
          {:ok, Enum.flat_map(list, &decode_doc/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} = err ->
          err
      end
    end

    defp decode_doc(s) when is_binary(s) do
      case Jason.decode(s) do
        {:ok, m} when is_map(m) -> [m]
        _ -> []
      end
    end

    defp decode_doc(m) when is_map(m), do: [m]
    defp decode_doc(_), do: []

    defp post(path, body) do
      {:ok, jwt} = Auth.token()

      resp =
        Req.request(
          Req.new(
            url: "#{@base}/api/#{path}",
            method: :post,
            headers: [
              {"authorization", "Bearer " <> jwt},
              {"content-type", "application/json"},
              {"accept", "application/json"}
            ],
            body: body,
            receive_timeout: 30_000,
            retry: false,
            decode_body: false
          )
        )

      case resp do
        {:ok, %{status: status, body: b}} when status in 200..299 -> {:ok, Jason.decode!(b)}
        {:ok, %{status: status, body: b}} -> {:error, {status, b}}
        other -> other
      end
    end
  end

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

    # The corpus fed to Indx: each record carries a numeric "id" key (Indx's
    # default key field), the embedded Barkpark "_id" + "_type", and the
    # searchable "title". The retriever maps documentKey → embedded _id →
    # Postgres row. This mirrors exactly what `Indexer.render_corpus/1` builds.
    records =
      published
      |> Enum.with_index(1)
      |> Enum.map(fn {doc, key} ->
        %{"id" => key, "_id" => doc.doc_id, "_type" => doc.type, "title" => doc.title}
      end)

    {:ok, published: published, records: records}
  end

  test "Indexer.rebuild/3 currently FAILS against live Indx — wrong call order (bug for implement stage)",
       %{published: published} do
    # Drive the REAL plugin blue/green indexer end-to-end against the live
    # engine. It does create_or_open → set_searchable_fields → load_string →
    # index_dataset. Because set_searchable_fields runs BEFORE any Analyze/
    # LoadString, DocumentFields is null and the engine returns 400.
    corpus =
      Enum.map(published, fn doc ->
        %{"_id" => doc.doc_id, "_type" => doc.type, "title" => doc.title}
      end)

    result =
      Indexer.rebuild("#{@scope}_bug", corpus,
        client: Client,
        base_url: @indx_base,
        timeout: 30_000,
        poll_attempts: 4,
        poll_interval_ms: 200,
        weights: [{"title", 0}, {"_id", 2}]
      )

    # Document the exact failure so the implement stage has a regression bar.
    assert {:error, %{__struct__: struct, status: 400} = err} = result,
           "EXPECTED Indexer.rebuild/3 to fail with the SetSearchableFields 400 " <>
             "until the call order is fixed; got: #{inspect(result)}"

    assert struct == Barkpark.Plugins.Indx.Errors.IndexError
    assert err.body =~ "SetSearchableFields invalid status"
    assert err.endpoint =~ "/api/SetSearchableFields/"

    # Best-effort cleanup of the half-created dataset.
    on_exit(fn -> Client.delete_dataset("bp_#{slugify("#{@scope}_bug")}_v1", @client_opts) end)
  end

  test "typo/partial search through the REAL Retriever hydrates the right Documents (read path E2E)",
       %{records: records} do
    # The READ path under test (`Retriever.search/4`) is independent of the
    # indexer's call-order bug. We prepare the live dataset with the plugin's
    # OWN Client verbs in the empirically-correct order, with one raw
    # AnalyzeString call the Client cannot yet make (test-only; see moduledoc).
    dataset = "bp_#{slugify(@scope)}_read_v1"
    on_exit(fn -> Client.delete_dataset(dataset, @client_opts) end)

    corpus_json = Jason.encode!(records)

    # CORRECT order: CreateOrOpen → AnalyzeString → SetSearchableFields →
    # LoadString → IndexDataSet.
    assert :ok = Client.create_or_open(dataset, @client_opts)
    assert :ok = analyze_string(dataset, corpus_json)

    assert :ok =
             Client.set_searchable_fields(dataset, [{"title", 0}, {"_id", 2}], @client_opts)

    assert :ok = Client.load_string(dataset, corpus_json, @client_opts)
    assert :ok = Client.index_dataset(dataset, @client_opts)

    # Poll until the engine reports the records indexed.
    assert {:ok, 5} = poll_count(dataset, 5, 30)

    # CRITICAL: the Retriever's `scope` argument doubles as the Barkpark
    # DATASET it re-reads hydrated hits from via `Content.get_document/3`.
    # Our 5 posts live in the "production" Barkpark dataset (@ds), so the
    # retriever scope MUST be @ds — NOT the Indx dataset name. We therefore
    # key the live pointer under @ds and point it at our unique Indx dataset.
    Indexer.swap(@ds, %{new_dataset: dataset, key_map: %{}})
    assert Indexer.current_dataset(@ds) == dataset
    on_exit(fn -> :persistent_term.put({Indexer, :live_dataset}, %{}) end)

    # ---- 4a. Exact-term search through the Retriever -----------------------
    {hits, total} =
      Retriever.search(@ds, parsed(["kubernetes"]), %{"engine" => "indx"},
        client: WorkaroundClient,
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
        client: WorkaroundClient,
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
        client: WorkaroundClient,
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
        client: WorkaroundClient,
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

  # Raw AnalyzeString call. The plugin `Client` has no verb for this yet (the
  # bug), so the read-path test issues it directly. POST /api/AnalyzeString/{ds}
  # binds a `[FromBody] string`, so the body is the corpus JSON *re-encoded as a
  # JSON string*. Auth token comes from the plugin's own Auth cache.
  defp analyze_string(dataset, corpus_json) do
    {:ok, jwt} = Auth.token()
    url = "#{@indx_base}/api/AnalyzeString/#{dataset}"
    body = Jason.encode!(corpus_json)

    resp =
      Req.request(
        Req.new(
          url: url,
          method: :post,
          headers: [
            {"authorization", "Bearer " <> jwt},
            {"content-type", "application/json"}
          ],
          body: body,
          receive_timeout: 30_000,
          retry: false,
          decode_body: false
        )
      )

    case resp do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  # Poll GetNumberOfJsonRecordsInDb until it reports `expected` (or attempts
  # run out). Returns the last `{:ok, count}` / `{:error, _}`.
  defp poll_count(_dataset, _expected, 0), do: {:error, :timeout}

  defp poll_count(dataset, expected, attempts) do
    case Client.get_number_of_json_records(dataset, @client_opts) do
      {:ok, ^expected} ->
        {:ok, expected}

      {:ok, _other} ->
        Process.sleep(500)
        poll_count(dataset, expected, attempts - 1)

      {:error, _} ->
        Process.sleep(500)
        poll_count(dataset, expected, attempts - 1)
    end
  end
end
