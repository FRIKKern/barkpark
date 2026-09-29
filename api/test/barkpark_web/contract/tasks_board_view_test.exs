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
    * THE SEAM — the key set is not hand-copied: it is PARSED out of
      `internal/taskboard/fetch.go` and checked against the live card, so
      dropping a field the Go consumer decodes reds HERE, on the producer.
    * CONTENT DIGEST — the bounded stand-in for the deleted echo: the
      per-criterion marks and the completeness booleans the board reads on the
      ROW path, which a `{met,total}` fraction cannot rebuild.
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

  # Rows are created as drafts, so the wire doc_id is `drafts.<id>`.
  defp by_bare_id(%{"docs" => docs}),
    do: Map.new(docs, &{String.replace_prefix(&1["doc_id"], "drafts.", ""), &1})

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

      # content_digest — the ONE key the board card adds, and the reason the
      # projection is adoptable at all: `criteria_progress` is a FRACTION, and
      # the board's ladder (components.go, criteriaLadder) needs ONE STATE PER
      # RUNG. The fixture's two criteria are met + unmet-with-attempts, so the
      # marks must read exactly "ma".
      # prose_content's two criteria are [met] and [unmet, no attempts], so the
      # marks read "mo". The "a" rung (an unmet criterion carrying a recorded
      # attempt) has its own case in the content_digest describe block below.
      assert %{
               "criteria_marks" => "mo",
               "has_description" => true,
               "has_dependencies" => false,
               "has_paper" => false
             } = card["content_digest"]

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

      # EQUALITY, not a spot check: every key except `content` must survive
      # with the same value, in the same row order, and the ONLY key that may
      # be added is `content_digest`.
      #
      # WHY THIS ASSERTION CHANGED (task-9289217dc43ad78f). It used to read
      # `stripped == board["docs"]` — "no key may be ADDED". That was the
      # right assertion for a projection defined as a bare subtraction, and the
      # bare subtraction was not adoptable by the board: it took `content` away
      # while the board reads `content` on the ROW path for every row. Widening
      # it to ONE named key is deliberate, and the shape is still equality, not
      # a spot check: any SECOND added key, or any changed value, still reds.
      stripped = Enum.map(default["docs"], &Map.delete(&1, "content"))
      board_less_digest = Enum.map(board["docs"], &Map.delete(&1, "content_digest"))
      assert stripped == board_less_digest

      assert Enum.all?(board["docs"], &Map.has_key?(&1, "content_digest")),
             "every board card carries content_digest — an ABSENT digest cannot be " <>
               "told from a server too old to emit one"

      refute Enum.any?(default["docs"], &Map.has_key?(&1, "content_digest")),
             "the digest is the board card's stand-in for the echo; the full card " <>
               "still has the echo and must not carry a second copy of the same facts"

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

  # ── ARM 2b: the producer/consumer seam ────────────────────────

  # THIS IS A PRODUCER/CONSUMER PAIR, NOT A MIRROR, AND IT HAS DRIFTED ONCE.
  # Elixir owns the wire shape; Go decodes it into typed structs; and until
  # task-9289217dc43ad78f nothing on the producer side asserted conformance the
  # other way. That is exactly how a FALSE sentence about the consumer ("the
  # board fetches a row's prose separately when a pane opens") survived in the
  # producer's own comment while the Go side documented the opposite in
  # writing, and how a projection shipped that its only intended consumer could
  # not adopt.
  #
  # So the key list below is NOT hand-copied. It is PARSED out of the consumer
  # (`internal/taskboard/fetch.go`), which makes dropping a field the board
  # decodes a RED on the producer's own test run.
  @fetch_go Path.expand("../../../../internal/taskboard/fetch.go", __DIR__)

  # `content` is the one decoded field the board card deliberately does NOT
  # carry — it is the whole point of the view, and `content_digest` is its
  # bounded stand-in. Any OTHER exclusion would have to be added here, in the
  # open, with a reason.
  @deliberately_absent ~w(content)

  # Pulls the `json:"name"` tags out of one Go struct literal. Returns [] when
  # the struct is not found, which is why every caller below proves the parse
  # saw something first — an empty read must never pass as "nothing missing".
  defp go_json_tags(source, struct_name) do
    case Regex.run(~r/type #{struct_name} struct \{\n(.*?)\n\}\n/s, source) do
      [_, body] ->
        ~r/`json:"([a-z_]+)"`/
        |> Regex.scan(body)
        |> Enum.map(fn [_, tag] -> tag end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp missing_keys(card, keys), do: Enum.reject(keys, &Map.has_key?(card, &1))

  describe "the producer/consumer seam" do
    test "the board card carries every field the Go consumer decodes", %{
      conn: conn,
      scope: scope
    } do
      assert File.exists?(@fetch_go),
             "the consumer this projection exists for is not at #{@fetch_go} — this test " <>
               "cannot assert conformance against a file it cannot read"

      source = File.read!(@fetch_go)
      wire_tags = go_json_tags(source, "taskWire")
      digest_tags = go_json_tags(source, "contentDigest")

      # POSITIVE CONTROL ON THE PARSE. A regex that matched nothing would make
      # every assertion below vacuously true over an empty list, which is the
      # exact way a guard like this rots. Prove it SAW the consumer first.
      assert length(wire_tags) >= 15,
             "parsed only #{length(wire_tags)} json tags out of taskWire (#{inspect(wire_tags)}) — " <>
               "the parse, not the projection, is what this run measured"

      for expected <-
            ~w(doc_id rev title lifecycle_status criteria_progress content content_digest) do
        assert expected in wire_tags,
               "taskWire parse did not see #{expected}; got #{inspect(wire_tags)}"
      end

      # Go decodes `design_doc` (task-190780ed9852f2de), so it is REQUIRED here.
      assert Enum.sort(digest_tags) ==
               ~w(criteria_marks design_doc has_dependencies has_description has_paper),
             "contentDigest parse = #{inspect(digest_tags)}"

      # `criteria_marks` and `design_doc` are omitted when the row has none, so
      # the row carries both — the key-presence check below measures every tag.
      phase = uniq("board-seam")

      mk_task!(
        uniq("board-seam-row"),
        scope,
        Map.put(prose_content(phase), "design_doc", "board-seam-paper")
      )

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      required = wire_tags -- @deliberately_absent

      assert missing_keys(card, required) == [],
             "the board card is missing #{inspect(missing_keys(card, required))}, which " <>
               "#{Path.relative_to_cwd(@fetch_go)} decodes. Either the projection dropped a " <>
               "field its consumer reads, or the consumer stopped reading it — fix ONE side " <>
               "and this test tells you which."

      for tag <- @deliberately_absent do
        refute Map.has_key?(card, tag),
               "#{tag} is listed as deliberately absent but the card carries it"
      end

      assert missing_keys(card["content_digest"], digest_tags) == [],
             "content_digest is missing #{inspect(missing_keys(card["content_digest"], digest_tags))}"
    end

    # POSITIVE CONTROL ON THE ASSERTION ITSELF. The check above passes; this
    # proves it can FAIL — that it is looking at the card, not at nothing.
    test "…and that check can SEE a dropped field", %{conn: conn, scope: scope} do
      source = File.read!(@fetch_go)
      wire_tags = go_json_tags(source, "taskWire") -- @deliberately_absent

      phase = uniq("board-seam-control")

      mk_task!(
        uniq("board-seam-control-row"),
        scope,
        Map.put(prose_content(phase), "design_doc", "board-seam-paper")
      )

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      assert missing_keys(card, wire_tags) == []

      # Drop ONE field the consumer decodes, exactly as a regressed projection
      # would, and the same predicate must name it.
      assert missing_keys(Map.delete(card, "priority"), wire_tags) == ["priority"]

      assert missing_keys(Map.delete(card, "criteria_progress"), wire_tags) == [
               "criteria_progress"
             ]

      # …and on the digest.
      digest_tags = go_json_tags(source, "contentDigest")

      assert missing_keys(Map.delete(card["content_digest"], "has_paper"), digest_tags) ==
               ["has_paper"]
    end
  end

  # ── ARM 2c: the digest's omission law ────────────────────────

  describe "content_digest" do
    test "criteria_marks is OMITTED on a row with no criteria, never an empty string", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-nocrit")

      mk_task!(uniq("board-nocrit-row"), scope, %{
        "parent_id" => phase,
        "acceptance_criteria" => [],
        "description" => "a row that has not been given criteria yet"
      })

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      # The law criteria_progress follows (wire §4): omit the segment, never
      # render "0/0" — an empty marks string is the same ambiguity wearing a
      # different type.
      refute Map.has_key?(card, "criteria_progress")
      refute Map.has_key?(card["content_digest"], "criteria_marks")

      # …and the digest itself is STILL there, because "this row has no
      # criteria" and "this server does not emit a digest" must not look alike.
      assert %{"has_description" => true} = card["content_digest"]
    end

    test "the booleans are the inputs ScoreCompleteness consumes, not the prose", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-digest-booleans")

      mk_task!(uniq("board-digest-full"), scope, %{
        "parent_id" => phase,
        "description" => "  a real description  ",
        "dependencies" => ["task-blocker"],
        "design_doc" => "the-design",
        "acceptance_criteria" => [
          %{"criterion" => "met", "met" => true, "evidence" => "PR #1"},
          %{"criterion" => "missed", "met" => false, "attempts" => [%{"note" => "not yet"}]},
          %{"criterion" => "untouched", "met" => false}
        ]
      })

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      # `design_doc` is the one digest key that is not a boolean or a mark: the
      # paper SLUG itself (task-cf0395706361aa2e) — see the next test.
      assert card["content_digest"] == %{
               "criteria_marks" => "mao",
               "design_doc" => "the-design",
               "has_description" => true,
               "has_dependencies" => true,
               "has_paper" => true
             }

      # The prose the booleans were derived from is NOT on the wire.
      body =
        conn |> authed() |> get("/v1/tasks?parent=#{phase}&view=board") |> Map.get(:resp_body)

      refute body =~ "a real description"
      refute body =~ "not yet"
    end

    # task-cf0395706361aa2e. The Go board inverts paper -> tasks over the WHOLE
    # corpus (`DrivenTasks` / `TaskDetail.PaperRefs`,
    # internal/taskboard/detail_data.go), matching a paper against BOTH
    # `design_doc` and `papers`. `papers` survives the projection at the top
    # level; `design_doc` used to survive only as one bit OR'd into
    # `has_paper`, so every task citing its paper through `design_doc` fell
    # out of a live board's FramePaper. Per-row hydration cannot restore a
    # corpus-wide input — it has to ride the card.
    test "design_doc carries the paper SLUG, and is OMITTED when the row has none", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-digest-designdoc")
      with_dd = uniq("board-dd-with")
      papers_only = uniq("board-dd-papers-only")
      bare = uniq("board-dd-bare")
      prose = uniq("board-dd-prose")

      mk_task!(with_dd, scope, %{
        "parent_id" => phase,
        "design_doc" => "board-dd-the-paper"
      })

      mk_task!(papers_only, scope, %{"parent_id" => phase, "papers" => ["board-dd-other"]})
      mk_task!(bare, scope, %{"parent_id" => phase})

      # `design_doc` is validated only as "a string"; a sentence is storable.
      # A paper id never contains whitespace, so a value that does is not a
      # slug and the card does not carry it — bounded to the slug, never prose.
      mk_task!(prose, scope, %{
        "parent_id" => phase,
        "design_doc" => "see the design notes in the channel for the whole story"
      })

      cards = conn |> docs_at(phase, "&view=board") |> by_bare_id()

      # Every lookup below must hit a card: a missed key reads nil, and a nil
      # `design_doc` would pass the omission arms vacuously.
      assert Enum.sort(Map.keys(cards)) == Enum.sort([with_dd, papers_only, bare, prose])

      assert cards[with_dd]["content_digest"]["design_doc"] == "board-dd-the-paper"
      assert cards[with_dd]["content_digest"]["has_paper"] == true

      # Omission law (wire §4): absent, never "" or null. `has_paper` still
      # answers the rubric's question on every row.
      for id <- [papers_only, bare, prose] do
        refute Map.has_key?(cards[id]["content_digest"], "design_doc"),
               "#{id} carries no slug-shaped design_doc, so its card must carry no key"
      end

      assert cards[papers_only]["content_digest"]["has_paper"] == true
      assert cards[papers_only]["papers"] == ["board-dd-other"]
      assert cards[bare]["content_digest"]["has_paper"] == false
      assert cards[prose]["content_digest"]["has_paper"] == true

      # The full card's own echo is the source the slug was copied from: the
      # two views must hand the consumer the SAME string for the same row.
      full = conn |> docs_at(phase, "") |> by_bare_id()
      assert full[with_dd]["content"]["design_doc"] == "board-dd-the-paper"
    end

    test "a blank description and a whitespace-only one are both FALSE", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-digest-blank")

      mk_task!(uniq("board-digest-blank-row"), scope, %{
        "parent_id" => phase,
        "description" => "   ",
        "dependencies" => [],
        "papers" => []
      })

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      assert card["content_digest"]["has_description"] == false
      assert card["content_digest"]["has_dependencies"] == false
      assert card["content_digest"]["has_paper"] == false
    end

    test "has_paper is true from content.papers as well as design_doc", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-digest-papers")

      mk_task!(uniq("board-digest-papers-row"), scope, %{
        "parent_id" => phase,
        "papers" => ["/papers/some-paper"]
      })

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")
      assert card["content_digest"]["has_paper"] == true
    end

    test "one mark per entry, and only a MAP attempt earns the amber rung", %{
      conn: conn,
      scope: scope
    } do
      phase = uniq("board-digest-shapes")

      # NOTE ON WHAT IS NOT HERE. The wider tolerance contract — a `met` of
      # "yes", a non-list `attempts`, a non-map entry — cannot be exercised
      # through this door: `Barkpark.Tasks.Validation` REFUSES those writes
      # ("criterion 1 has a non-boolean `met`"), so a row carrying them cannot
      # be created over the API. That tolerance is asserted where the shapes
      # are reachable, at the unit level, in
      # test/barkpark/tasks/criteria_test.exs ("marks/1 — the compact
      # per-criterion state sequence").
      mk_task!(uniq("board-digest-shapes-row"), scope, %{
        "parent_id" => phase,
        "acceptance_criteria" => [
          %{"criterion" => "sealed", "met" => true, "evidence" => "PR #1"},
          %{"criterion" => "an honest miss", "met" => false, "attempts" => [%{"note" => "no"}]},
          %{"criterion" => "an empty attempts list", "met" => false, "attempts" => []},
          %{"criterion" => "untouched", "met" => false}
        ]
      })

      assert %{"docs" => [card]} = docs_at(conn, phase, "&view=board")

      # One character per entry, so the sequence always tracks
      # criteria_progress.total — the board's ladder draws one rung per mark.
      assert card["content_digest"]["criteria_marks"] == "maoo"
      assert card["criteria_progress"] == %{"met" => 1, "total" => 4}
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
