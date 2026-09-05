defmodule BarkparkWeb.TaskboardWireLockTest do
  @moduledoc """
  CROSS-SEAM LOCK: the field names the Go taskboard depends on are the field
  names this producer actually emits.

  THE HOLE THIS CLOSES. `internal/taskboard` decides what work EXISTS by
  decoding four HAND-HELD snapshots of the `/v1/tasks` + `/v1/tasks/prime`
  wire (`internal/taskboard/testdata/{tasks,detail,cluster,flat_queue}_fixture.json`)
  through the SAME decode-and-compose pipeline the live fetch uses. Nothing on
  the producer side regenerates or freshness-checks those files. Rename
  `ready` on the prime envelope — or `worker` / `epoch` / `previous_worker` /
  `expired_at` inside the claim map — and every Go fixture test stays green
  while the live board silently shows ZERO ready rows. A board with no
  available work looks exactly like a board with an empty queue, so the
  failure never announces itself as a bug.

  A Go-side test cannot block a merge here (nothing in `internal/taskboard`
  trips a required context), so the lock lives on the side that already
  blocks: this ExUnit file reads the Go fixtures OFF DISK, drives the REAL
  controller through a ConnCase request against a seeded task, and asserts the
  fixture's key names are names the live producer still emits.

  THE FOUR LOAD-BEARING KEYS (derived from `internal/taskboard/fetch.go`, not
  guessed):

    * readiness — `decodePrime`'s `Ready []struct{DocID string \\`json:"doc_id"\\`}`
      on `json:"ready"`. Readiness is DERIVED: storage only ever holds the
      5-value lifecycle enum, and `composeSnapshot` overlays `lifeReady` onto
      rows whose doc_id appears in the prime ready queue.
    * claim epoch — `claimWire.Epoch` on `json:"epoch"`, the CAS the whole
      board keys on.
    * claim worker — `claimWire.Worker` on `json:"worker"`; a swept lease
      nulls it, which is how the board tells an expired claim from a live one.
    * swept-claim display — `claimWire.PreviousWorker` / `ExpiredAt` on
      `json:"previous_worker"` / `json:"expired_at"`, written by
      `Barkpark.Tasks.TtlSweeper`'s reap.

  NEAR MISS, deliberately excluded: `internal/taskboard/testdata/board_fixture.json`
  sits in the same directory with the same extension but is a MARSHALLED GO
  STRUCT (PascalCase keys — `DocID`, `Claim.Worker`) where Go is both producer
  and consumer. It has no drift axis at all. It is told apart by KEY CASING,
  never by path, and a test here asserts exactly that so a future auditor
  cannot fold it back into the wire set.

  This file adds DETECTION only. No decode/compose pipeline changed, no
  production Elixir changed, no new semantics.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.TtlSweeper

  @token "barkpark-test-taskboard-wire-lock-token"
  @dataset "production"

  # The four WIRE fixtures — snake_case keys, produced by this API.
  @wire_fixtures ~w(tasks_fixture.json detail_fixture.json cluster_fixture.json flat_queue_fixture.json)
  # The Go-marshalled decoy in the same directory. NOT a wire fixture.
  @go_struct_fixture "board_fixture.json"

  # The load-bearing four, named explicitly so a rename reds a NAMED assertion.
  @readiness_key "ready"
  @readiness_entry_key "doc_id"
  @claim_worker_key "worker"
  @claim_epoch_key "epoch"
  @swept_previous_worker_key "previous_worker"
  @swept_expired_at_key "expired_at"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-taskboard-wire-lock", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  # ─── fixture reading (REFUSES on an empty read) ──────────────────────────

  defp testdata_dir, do: Path.expand("../../../../internal/taskboard/testdata", __DIR__)

  # A missing file or a fixture that carries zero rows is a FAILURE, never a
  # silent pass: the whole point of this lock is that it cannot go vacuous by
  # reading nothing.
  defp read_wire_fixture!(name) do
    path = Path.join(testdata_dir(), name)

    unless File.exists?(path) do
      flunk("""
      taskboard wire fixture missing: #{path}

      This lock reads the Go taskboard's hand-held /v1/tasks snapshots off
      disk. If the fixture moved, MOVE THIS TEST WITH IT — do not delete the
      assertion; a renamed producer key would then drift undetected again.
      """)
    end

    body = File.read!(path)
    refute body == "", "taskboard wire fixture is EMPTY: #{path}"

    decoded = Jason.decode!(body)

    docs = Map.get(decoded, "docs")
    assert is_list(docs), "#{name}: expected a `docs` list (the /v1/tasks envelope)"
    refute docs == [], "#{name}: zero rows — an empty read must FAIL, not pass"

    prime = Map.get(decoded, "prime")
    assert is_map(prime), "#{name}: expected a `prime` map (the /v1/tasks/prime envelope)"

    decoded
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # Fetch ONE seeded row back off the real list endpoint, narrowed by a label
  # unique to this test so a shared test database's foreign rows cannot make
  # the read ambiguous.
  defp fetch_emitted_doc!(conn, label, doc_id) do
    payload =
      conn
      |> authed()
      |> get("/v1/tasks?label=#{label}&limit=50")
      |> json_response(200)

    docs = payload["docs"]
    assert is_list(docs)

    refute docs == [],
           "the producer returned zero docs for label=#{label} — empty read is a FAILURE"

    # The PDS birth fence may pair a fresh row with a `drafts.`-prefixed twin,
    # so match on the suffix rather than pinning the exact spelling.
    doc =
      Enum.find(docs, &(&1["doc_id"] == doc_id or String.ends_with?(&1["doc_id"], "." <> doc_id)))

    assert doc,
           "seeded row #{doc_id} absent from the emitted list (got #{inspect(Enum.map(docs, & &1["doc_id"]))})"

    doc
  end

  # ─── 1. THE READINESS KEY ────────────────────────────────────────────────

  describe "the readiness key" do
    test "the key the board overlays readiness from is the key /v1/tasks/prime emits",
         %{conn: conn, scope: scope} do
      label = uniq("wirelock")
      doc_id = uniq("wirelock-ready")
      _ = mk_task!(doc_id, scope, %{"lifecycle_status" => "open", "labels" => [label]})

      payload = conn |> authed() |> get("/v1/tasks/prime?limit=100") |> json_response(200)

      assert Map.has_key?(payload, @readiness_key), """
      /v1/tasks/prime no longer emits #{inspect(@readiness_key)}.

      internal/taskboard/fetch.go decodePrime reads `json:"ready"` and
      composeSnapshot overlays lifeReady onto every doc_id in it. Storage
      NEVER holds "ready" — rename this key and the live board shows ZERO
      ready rows while every Go fixture test stays green.

      Emitted keys: #{inspect(Enum.sort(Map.keys(payload)))}
      """

      ready = payload[@readiness_key]
      assert is_list(ready), "prime.#{@readiness_key} must be a list"

      refute ready == [],
             "prime.#{@readiness_key} came back EMPTY — an empty read must FAIL, not vacuously pass"

      for entry <- ready do
        assert Map.has_key?(entry, @readiness_entry_key), """
        a prime.#{@readiness_key} entry no longer carries #{inspect(@readiness_entry_key)};
        decodePrime reads ONLY that field off each entry.

        Entry keys: #{inspect(Enum.sort(Map.keys(entry)))}
        """
      end

      # Every wire fixture's prime envelope names keys the producer still emits.
      emitted = MapSet.new(Map.keys(payload))

      for name <- @wire_fixtures do
        prime = read_wire_fixture!(name)["prime"]
        fixture_keys = MapSet.new(Map.keys(prime))

        assert MapSet.subset?(fixture_keys, emitted), """
        #{name} prime envelope carries keys the producer no longer emits:
        #{inspect(fixture_keys |> MapSet.difference(emitted) |> MapSet.to_list() |> Enum.sort())}
        """

        entry_keys =
          for e <- prime[@readiness_key] || [], k <- Map.keys(e), into: MapSet.new(), do: k

        refute MapSet.size(entry_keys) == 0,
               "#{name}: prime.#{@readiness_key} holds no entries — the fixture cannot exercise readiness"

        assert MapSet.member?(entry_keys, @readiness_entry_key),
               "#{name}: prime.#{@readiness_key} entries do not carry #{inspect(@readiness_entry_key)}"
      end
    end
  end

  # ─── 2. THE CLAIM CAS KEYS + THE SWEPT-CLAIM DISPLAY KEYS ────────────────

  describe "the claim keys" do
    test "claim.worker and claim.epoch survive the real claim path", %{conn: conn, scope: scope} do
      label = uniq("wirelock")
      doc_id = uniq("wirelock-claim")
      worker = uniq("wirelock-worker")
      _ = mk_task!(doc_id, scope, %{"labels" => [label]})

      conn
      |> authed()
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(%{worker_id: worker}))
      |> json_response(200)

      claim = fetch_emitted_doc!(conn, label, doc_id)["claim"]
      assert is_map(claim), "the emitted doc no longer carries a `claim` map (taskWire.Claim)"

      assert Map.has_key?(claim, @claim_worker_key), """
      the claim map no longer carries #{inspect(@claim_worker_key)} —
      claimWire.Worker in internal/taskboard/fetch.go. Emitted: #{inspect(Enum.sort(Map.keys(claim)))}
      """

      assert Map.has_key?(claim, @claim_epoch_key), """
      the claim map no longer carries #{inspect(@claim_epoch_key)} — claimWire.Epoch,
      the CAS the whole board keys on. Emitted: #{inspect(Enum.sort(Map.keys(claim)))}
      """

      assert claim[@claim_worker_key] == worker
      assert is_integer(claim[@claim_epoch_key])
    end

    test "claim.previous_worker and claim.expired_at survive the real TTL reap",
         %{conn: conn, scope: scope} do
      label = uniq("wirelock")
      doc_id = uniq("wirelock-swept")
      worker = uniq("wirelock-worker")
      _ = mk_task!(doc_id, scope, %{"labels" => [label]})

      conn
      |> authed()
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(%{worker_id: worker}))
      |> json_response(200)

      # ttl=0 → the cutoff is now, so the lease just written is expired. No
      # swept/skipped count is asserted: the test database is shared and
      # foreign rows may ride along (their writes roll back with this test's
      # sandbox transaction).
      TtlSweeper.sweep(0)

      claim = fetch_emitted_doc!(conn, label, doc_id)["claim"]
      assert is_map(claim)

      assert Map.has_key?(claim, @swept_previous_worker_key), """
      a swept claim no longer carries #{inspect(@swept_previous_worker_key)} —
      claimWire.PreviousWorker. The board's detail view renders the swept-lease
      history from it. Emitted: #{inspect(Enum.sort(Map.keys(claim)))}
      """

      assert Map.has_key?(claim, @swept_expired_at_key), """
      a swept claim no longer carries #{inspect(@swept_expired_at_key)} —
      claimWire.ExpiredAt. Emitted: #{inspect(Enum.sort(Map.keys(claim)))}
      """

      assert claim[@swept_previous_worker_key] == worker

      assert claim[@claim_worker_key] == nil,
             "a swept lease must NULL `worker` (claimWire.Worker)"
    end
  end

  # ─── 3. EVERY FIXTURE DOC/CLAIM KEY IS STILL A PRODUCER KEY ──────────────

  describe "the fixture key sets" do
    test "every doc key the four wire fixtures carry is a key the producer emits",
         %{conn: conn, scope: scope} do
      label = uniq("wirelock")
      doc_id = uniq("wirelock-shape")
      worker = uniq("wirelock-worker")

      _ =
        mk_task!(doc_id, scope, %{
          "labels" => [label],
          "priority" => 1,
          "papers" => [],
          "parent_id" => ""
        })

      conn
      |> authed()
      |> post("/v1/tasks/#{doc_id}/claim", Jason.encode!(%{worker_id: worker}))
      |> json_response(200)

      emitted_doc = fetch_emitted_doc!(conn, label, doc_id)
      emitted_keys = MapSet.new(Map.keys(emitted_doc))

      for name <- @wire_fixtures do
        docs = read_wire_fixture!(name)["docs"]

        fixture_keys =
          for d <- docs, k <- Map.keys(d), k != "_comment", into: MapSet.new(), do: k

        missing =
          fixture_keys |> MapSet.difference(emitted_keys) |> MapSet.to_list() |> Enum.sort()

        assert missing == [], """
        #{name} carries doc keys the /v1/tasks producer no longer emits: #{inspect(missing)}

        The Go fixtures are hand-held snapshots — nothing regenerates them, so
        the Go suite stays green on a producer rename. Either restore the key
        or update BOTH the fixture and internal/taskboard/fetch.go.

        Producer emitted: #{inspect(Enum.sort(MapSet.to_list(emitted_keys)))}
        """
      end
    end
  end

  # ─── 4. NON-VACUITY: THE FIXTURES REALLY DO EXERCISE READINESS ───────────

  describe "non-vacuity" do
    test "each wire fixture holds a row STORED open that becomes ready ONLY via the readiness overlay" do
      for name <- @wire_fixtures do
        fixture = read_wire_fixture!(name)
        ready_ids = for e <- fixture["prime"][@readiness_key] || [], do: e[@readiness_entry_key]

        overlaid =
          for d <- fixture["docs"],
              d["lifecycle_status"] == "open",
              d["doc_id"] in ready_ids,
              do: d["doc_id"]

        refute overlaid == [], """
        #{name} holds NO row stored `open` that the readiness overlay lifts to ready.

        Without such a row the lock above could pass over a fixture where
        readiness never mattered — which is precisely the case a rename of
        prime.#{@readiness_key} breaks in production.
        """
      end
    end

    test "no fixture stores the derived value `ready` as a lifecycle_status" do
      for name <- @wire_fixtures do
        stored = for d <- read_wire_fixture!(name)["docs"], do: d["lifecycle_status"]

        refute "ready" in stored, """
        #{name} stores "ready" as a lifecycle_status. Readiness is DERIVED from
        the prime ready queue; storage only ever holds the 5-value enum. A
        fixture that stores it makes the readiness overlay untested.
        """
      end
    end
  end

  # ─── 5. THE NEAR MISS: board_fixture.json is a Go struct, not the wire ───

  describe "the marshalled-Go-struct decoy" do
    test "board_fixture.json is told apart by KEY CASING, never by path" do
      path = Path.join(testdata_dir(), @go_struct_fixture)
      assert File.exists?(path), "the decoy fixture moved: #{path}"

      decoded = path |> File.read!() |> Jason.decode!()
      keys = Map.keys(decoded)
      refute keys == [], "#{@go_struct_fixture} is empty — an empty read must FAIL"

      # Go marshals its exported struct fields in PascalCase; the /v1/tasks
      # wire is snake_case throughout. That casing IS the discriminator.
      assert Enum.all?(keys, &(String.first(&1) == String.upcase(String.first(&1)))),
             """
             #{@go_struct_fixture} no longer looks like a marshalled Go struct
             (top-level keys #{inspect(keys)}). If it became a wire snapshot it
             belongs in @wire_fixtures; if a wire fixture became PascalCase,
             the taskboard cannot decode it at all.
             """

      refute @go_struct_fixture in @wire_fixtures,
             "the Go-marshalled decoy must never be audited as a /v1/tasks wire fixture"
    end
  end
end
