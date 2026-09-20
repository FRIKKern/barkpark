defmodule BarkparkWeb.Contract.TasksBoardViewTest do
  @moduledoc """
  `GET /v1/tasks?view=board` — the FULL card with the `content` echo removed
  (task-1ca34359dc0805df).

  WHAT THIS FILE IS FOR. `bp tasks` re-lists the whole corpus every time the
  ledger moves, and the ledger never stops moving: three CLI-side PRs (#18468,
  #18929, #19205) cut the STEADY-STATE cost and each one landed on the same
  wall — one cold walk is ~100 MB because every row ships its `description`,
  its `operating_instruction` and its whole `acceptance_criteria` array with
  per-criterion `evidence` and up to five `attempts` notes. The board renders
  none of that. This is the server-side half: a documented projection that
  keeps EVERY OTHER FIELD byte-identical and drops the prose.

  THE THREE ARMS, and why each one is here:

    * KEY SET — the board card carries what the board's `taskWire` decode
      reads (`internal/taskboard/fetch.go`) and does NOT carry `content`.
    * NO DRIFT — the board body is the DEFAULT body with exactly one key
      removed per card, proved by equality against the default response rather
      than by a second hand-written expectation. A projection that quietly
      changed `priority`, a count or an ordering would be a worse defect than
      the bytes it saved, and a hand-written expectation cannot see that.
    * BYTES — a seeded corpus with realistic prose, measured on the wire.

  Every request is narrowed by `?parent=` to a phase id unique to its test.
  The test database is SHARED across agents and this route lists a whole
  scope, so an unnarrowed read here measures other people's rows and its byte
  numbers would be noise.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-board-view-token"
  @dataset "production"

  # The seeded corpus for the byte arm. 25 rows is a real board page and small
  # enough to stay fast; the prose sizes below are modelled on the live ledger,
  # where a worked row's `attempts` notes routinely run past 2 KB EACH (read
  # task-1ca34359dc0805df itself — five notes, none under 1 KB).
  @byte_corpus_rows 25

  setup do
    {:ok, _} = Auth.create_token(@token, "test-board-view", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp mk_task!(doc_id, scope, content_extra) do
    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "lifecycle_status" => "open",
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
      }
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # A row shaped like a WORKED one: the prose the board never renders. Sized
  # from the live ledger, not invented — a long description, an operating
  # instruction, and criteria carrying evidence plus attempt notes.
  defp prose_content(parent) do
    %{
      "parent_id" => parent,
      "description" => String.duplicate("why this row exists, at length. ", 90),
      "operating_instruction" => String.duplicate("held open on purpose: ", 60),
      "acceptance_criteria" => [
        %{
          "criterion" => "the first criterion",
          "met" => true,
          "evidence" => String.duplicate("PR #18468, measured three times across 180s. ", 40),
          "attempts" => [
            %{"note" => String.duplicate("HALF TRUE, re-measured on guerrilla. ", 45)},
            %{"note" => String.duplicate("STILL A MISS, the reason changed. ", 45)}
          ]
        },
        %{
          "criterion" => "the second criterion",
          "met" => false,
          "evidence" => String.duplicate("CGO_ENABLED=0 go test ./... green. ", 40)
        }
      ]
    }
  end

  defp docs_at(conn, phase, query) do
    conn
    |> authed()
    |> get("/v1/tasks?parent=#{phase}&limit=1000#{query}")
    |> json_response(200)
  end

  # ── ARM 1: the key set ──────────────────────────────────────────────────

  describe "?view=board key set" do
    test "carries the board's fields and NOT the content echo", %{conn: conn, scope: scope} do
      phase = uniq("board-keys")
      id = uniq("board-keys-row")
      mk_task!(id, scope, prose_content(phase))

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      # The fields internal/taskboard/fetch.go's `taskWire` decodes.
      for key <- ~w(doc_id rev title lifecycle_status kind parent_id priority
                    labels dependency_count dependent_count inserted_at updated_at
                    papers child_count) do
        assert Map.has_key?(card, key), "board card is missing #{key}"
      end

      # criteria_progress is the {met,total} pair the board's counter column
      # renders; it is present whenever the row HAS criteria (the same omission
      # law the full card follows).
      assert %{"met" => 1, "total" => 2} = card["criteria_progress"]

      # THE POINT OF THE VIEW.
      refute Map.has_key?(card, "content"),
             "the board card must not carry the content echo — that echo IS the 100 MB"

      # And the prose really is gone from the wire, not merely re-keyed.
      body =
        conn |> authed() |> get("/v1/tasks?parent=#{phase}&view=board") |> Map.get(:resp_body)

      refute body =~ "why this row exists, at length."
      refute body =~ "PR #18468, measured three times"
      refute body =~ "held open on purpose:"
    end

    test "the DEFAULT view still carries the whole echo", %{conn: conn, scope: scope} do
      phase = uniq("board-default-echo")
      mk_task!(uniq("board-default-row"), scope, prose_content(phase))

      assert %{"docs" => [card]} = docs_at(conn, phase, "")
      assert card["content"]["description"] =~ "why this row exists, at length."
      assert [first, _] = card["content"]["acceptance_criteria"]
      assert first["evidence"] =~ "PR #18468"
    end
  end

  # ── ARM 2: no drift ─────────────────────────────────────────────────────

  describe "the default view is unchanged" do
    test "the board body is the DEFAULT body minus exactly the content key", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-nodrift")

      for n <- 1..4 do
        mk_task!(uniq("board-nodrift-#{n}"), scope, prose_content(phase))
      end

      default = docs_at(conn, phase, "")
      board = docs_at(conn, phase, "&view=board")

      assert length(default["docs"]) == 4

      # EQUALITY, not a spot check: every key except `content` must survive with
      # the same value, in the same row order, and no key may be ADDED.
      stripped = Enum.map(default["docs"], &Map.delete(&1, "content"))
      assert stripped == board["docs"]

      # The envelope around the cards is untouched too.
      assert default["page"] == board["page"]
      assert default["ok"] == board["ok"]

      # …and `content` really was there to remove (a vacuous pass would be a
      # board view that matched a default view which had already lost the echo).
      assert Enum.all?(default["docs"], &Map.has_key?(&1, "content"))
    end

    test "?view=full is the same body as no view at all", %{conn: conn, scope: scope} do
      phase = uniq("board-fullalias")
      mk_task!(uniq("board-fullalias-row"), scope, prose_content(phase))

      assert docs_at(conn, phase, "")["docs"] == docs_at(conn, phase, "&view=full")["docs"]
    end
  end

  # ── ARM 3: the bytes ────────────────────────────────────────────────────

  describe "byte size on a seeded corpus" do
    @tag timeout: 120_000
    test "view=board is under 20% of the default body", %{conn: conn, scope: scope} do
      phase = uniq("board-bytes")

      for n <- 1..@byte_corpus_rows do
        mk_task!(uniq("board-bytes-#{n}"), scope, prose_content(phase))
      end

      default_body =
        conn |> authed() |> get("/v1/tasks?parent=#{phase}&limit=1000") |> Map.get(:resp_body)

      board_body =
        conn
        |> authed()
        |> get("/v1/tasks?parent=#{phase}&limit=1000&view=board")
        |> Map.get(:resp_body)

      default_bytes = byte_size(default_body)
      board_bytes = byte_size(board_body)
      pct = board_bytes * 100 / default_bytes

      IO.puts(
        "\n[board-view bytes] N=#{@byte_corpus_rows} rows  default=#{default_bytes} B  " <>
          "board=#{board_bytes} B  (#{Float.round(pct, 2)}% of default)\n"
      )

      # Both bodies really describe the same N rows — a board body that is
      # small because it is EMPTY would pass a bare ratio assertion.
      assert length(Jason.decode!(default_body)["docs"]) == @byte_corpus_rows
      assert length(Jason.decode!(board_body)["docs"]) == @byte_corpus_rows

      assert pct < 20.0,
             "view=board was #{board_bytes} B of #{default_bytes} B (#{Float.round(pct, 2)}%), " <>
               "want under 20%"
    end
  end

  # ── The refusal ─────────────────────────────────────────────────────────

  describe "an undeclared ?view= on the index" do
    test "is a named 400 in the §9 envelope, naming the accepted set", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-badview")
      mk_task!(uniq("board-badview-row"), scope, prose_content(phase))

      payload =
        conn
        |> authed()
        |> get("/v1/tasks?parent=#{phase}&view=boad")
        |> json_response(400)

      assert %{"error" => error} = payload
      assert error["code"] == "invalid_filter"
      assert error["message"] =~ "view must be one of"
      assert error["message"] =~ "board"
      assert error["details"]["param"] == "view"
      assert error["details"]["value"] == "boad"
      assert error["details"]["accepted"] == ["full", "brief", "board"]
      # The whole reason ErrorResponse owns this: a correlatable refusal.
      assert is_binary(error["request_id"])
    end

    test "each declared value is accepted", %{conn: conn, scope: scope} do
      phase = uniq("board-goodviews")
      mk_task!(uniq("board-goodviews-row"), scope, prose_content(phase))

      for view <- ~w(full brief board) do
        assert %{"docs" => [_]} = docs_at(conn, phase, "&view=#{view}")
      end
    end

    # THE ASYMMETRY, PINNED ON PURPOSE. `/v1/tasks/ready` keeps the lenient
    # fallback (`tasks_controller_test.exs`, "absent and unknown view both
    # return the full shape unchanged"). Stating it here means a future reader
    # who tightens ready finds a test that says the divergence was a decision,
    # and has to come back and delete this one deliberately.
    test "…while /v1/tasks/ready still falls back to full", %{conn: conn, scope: scope} do
      phase = uniq("board-ready-lenient")
      mk_task!(uniq("board-ready-lenient-row"), scope, %{"parent_id" => phase})

      payload =
        conn
        |> authed()
        |> get("/v1/tasks/ready?phase_id=#{phase}&view=boad")
        |> json_response(200)

      assert [doc] = payload["docs"]
      assert Map.has_key?(doc, "content")
    end
  end
end
