defmodule Barkpark.Tasks.EventsStagedPayloadTest do
  @moduledoc """
  The task-events feed carries the STAGED PAYLOAD, so the recovery channel
  `bp task stage --help` promises actually exists.

  ## The defect these arms close

  `bp task stage --note` REPLACES `content.disposition_reason`. `stage.ex`
  already writes the displaced text onto the `task.staged` mutation_event as
  `staged.superseded_note` (PR #13722) — the only durable copy of a clobbered
  note. But `Tasks.Events.replay_since/3` projected `%{id, event, doc_id, rev,
  at}` and never selected `document`, so nothing the promised reader
  (`bp task events` → `GET /v1/tasks/events`) returned could carry it. The help
  text promised a recovery channel the channel did not implement.

  ## What is proven here

    * criterion 0 — a `task.staged` row in the replay carries
      `payload.staged.superseded_note`, both from the module and over HTTP; and
      the DEFAULT shape is byte-for-byte unchanged (no `:payload` key, no
      `:document` leak, no envelope `content` blob);
    * criterion 1 — the PIN: the shipped `bp task stage --note` help text is
      parsed for the command and dotted field path it promises, and the feed is
      then driven WITH THOSE, failing if the promised channel omits the note.
      Rewording the sentence to name a different channel, or dropping the field
      from the response, reds this test.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Tasks.Events

  @token "barkpark-test-events-payload-token"
  @dataset "production"

  @first_note "FIRST: do not execute this row as written"
  @second_note "SECOND: a different caution, written by the next agent"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-events-payload", "test", ["read", "write", "admin"])

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

  defp mk_task!(doc_id, scope) do
    content = %{
      "kind" => "task",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ],
      "lifecycle_status" => "open"
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp stage!(conn, doc_id, body) do
    resp = conn |> authed() |> post("/v1/tasks/#{doc_id}/stage", Jason.encode!(body))
    assert resp.status == 200
    resp
  end

  # The fixture is a REAL overwrite driven through the REAL verb: a first note,
  # then a second that displaces it. `superseded_note` on the SECOND event is
  # the first note's text — that is the thing a recovery sweep needs to read.
  #
  # The second stage passes `supersede: true` because it MUST: #16582 made a
  # `:note` that would displace a different non-blank `disposition_reason` a
  # 409 `note_would_supersede` unless the caller opts in per call. Passing the
  # flag is not a workaround for the refusal — it is the only door to the
  # behaviour under test. `superseded_note` exists precisely so a deliberate
  # displacement stays recoverable, so the recovery channel can only be
  # exercised through a deliberate displacement.
  defp overwrite_fixture!(conn, scope) do
    doc_id = uniq("evt-payload")
    task = mk_task!(doc_id, scope)

    # The keyset baseline: the max mutation_events id BEFORE the two stages, so
    # a shared test database's backlog (thousands of rows, and a page is 500)
    # can never push our own events off the first page.
    baseline = Repo.one(from(e in MutationEvent, select: max(e.id))) || 0

    stage!(conn, doc_id, %{state: "considering", note: @first_note})
    stage!(conn, doc_id, %{state: "researching", note: @second_note, supersede: true})
    {task.doc_id, baseline}
  end

  defp staged_rows(rows, doc_id) do
    Enum.filter(rows, &(&1.doc_id == doc_id and &1.event == "task.staged"))
  end

  describe "criterion 0 — the feed exposes the staged payload" do
    test "a task.staged replay row carries superseded_note under :payload",
         %{conn: conn, scope: scope} do
      {doc_id, baseline} = overwrite_fixture!(conn, scope)

      rows = Events.replay_since(@dataset, baseline, payload: true, limit: 500)

      superseded =
        rows
        |> staged_rows(doc_id)
        |> Enum.map(&get_in(&1, [:payload, "staged", "superseded_note"]))

      # RED ON MAIN: `replay_since/3` selects only id/event/doc_id/rev/at, so
      # no row has a `:payload` key at all and this list is [nil, nil].
      assert @first_note in superseded,
             "the displaced note is not readable from the events feed: #{inspect(superseded)}"

      # The note that was WRITTEN rides beside it, so one event answers both
      # "what did I write" and "what did I just overwrite".
      notes =
        rows |> staged_rows(doc_id) |> Enum.map(&get_in(&1, [:payload, "staged", "note"]))

      assert @first_note in notes
      assert @second_note in notes
    end

    test "the default shape is unchanged — no :payload, no :document, no content blob",
         %{conn: conn, scope: scope} do
      {doc_id, baseline} = overwrite_fixture!(conn, scope)

      rows = Events.replay_since(@dataset, baseline, limit: 500)
      [row | _] = staged_rows(rows, doc_id)

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :rev]
      refute Map.has_key?(row, :payload)
      refute Map.has_key?(row, :document)
    end

    test "the opt-in adds ONLY the whitelisted typed stamp — the envelope stays out",
         %{conn: conn, scope: scope} do
      {doc_id, baseline} = overwrite_fixture!(conn, scope)

      rows = Events.replay_since(@dataset, baseline, payload: true, limit: 500)
      [row | _] = staged_rows(rows, doc_id)

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :payload, :rev]
      # The Envelope half of `mutation_events.document` (the whole row content
      # and the caller_token_id audit stamp) is NEVER on the wire.
      assert Map.keys(row.payload) == ["staged"]
      refute Map.has_key?(row, :document)
    end

    test "over HTTP: ?payload=1 carries it, the bare poll does not",
         %{conn: conn, scope: scope} do
      {doc_id, baseline} = overwrite_fixture!(conn, scope)

      with_payload =
        conn
        |> authed()
        |> get("/v1/tasks/events?since=#{baseline}&limit=500&payload=1")
        |> json_response(200)

      superseded =
        with_payload["events"]
        |> Enum.filter(&(&1["doc_id"] == doc_id and &1["event"] == "task.staged"))
        |> Enum.map(&get_in(&1, ["payload", "staged", "superseded_note"]))

      assert @first_note in superseded

      bare =
        conn
        |> authed()
        |> get("/v1/tasks/events?since=#{baseline}&limit=500")
        |> json_response(200)

      bare_row =
        Enum.find(bare["events"], &(&1["doc_id"] == doc_id and &1["event"] == "task.staged"))

      assert Enum.sort(Map.keys(bare_row)) == ["at", "doc_id", "event", "id", "rev"]
    end
  end

  describe "criterion 1 — the help text's recovery promise is PINNED to the feed" do
    # The pin reads the SHIPPED help text (the manifest `bp` renders `--help`
    # from), extracts the channel it names, and drives that channel. It fails in
    # both directions: reword the sentence to promise something the feed does
    # not do, or drop the field from the response, and this reds.
    test "the shipped --note help names a channel that actually carries the note",
         %{conn: conn, scope: scope} do
      note_help = stage_note_help()

      # The promise, as shipped today: recoverable from `bp task events
      # --payload` as `payload.staged.superseded_note`.
      assert note_help =~ "recoverable from",
             "the --note help no longer states a recovery channel: #{note_help}"

      command = extract_backticked(note_help, "bp task events")

      assert command,
             "the --note help promises recovery but names no `bp task events …` command: #{note_help}"

      field_path = extract_backticked(note_help, "payload.")

      assert field_path,
             "the --note help names no dotted field path for the recovered note: #{note_help}"

      # 1. The manifest actually offers every flag the sentence tells a caller
      #    to type — a promise naming a flag that does not exist is a lie the
      #    caller discovers at the shell.
      promised_flags =
        Regex.scan(~r/--([a-z][a-z0-9-]*)/, command) |> Enum.map(fn [_, f] -> f end)

      offered = events_flag_names()

      for flag <- promised_flags do
        assert flag in offered,
               "`bp task stage --help` promises `--#{flag}` on `bp task events`, which offers #{inspect(offered)}"
      end

      # 2. The channel, driven exactly as promised, carries the displaced note
      #    at exactly the promised path.
      {doc_id, baseline} = overwrite_fixture!(conn, scope)
      query = Enum.map_join(promised_flags, "&", &"#{&1}=1")

      body =
        conn
        |> authed()
        |> get("/v1/tasks/events?since=#{baseline}&limit=500&" <> query)
        |> json_response(200)

      keys = String.split(field_path, ".")

      recovered =
        body["events"]
        |> Enum.filter(&(&1["doc_id"] == doc_id and &1["event"] == "task.staged"))
        |> Enum.map(&get_in(&1, keys))

      assert @first_note in recovered,
             "`bp task stage --help` promises the superseded note at `#{field_path}` via `#{command}`, and that channel returned #{inspect(recovered)}"
    end
  end

  # The shipped help text for `bp task stage --note`, read from the manifest the
  # CLI renders `--help` from — never a copy of the sentence.
  defp stage_note_help do
    Barkpark.Plugins.Tasks.cli_commands()
    |> Enum.find(&(&1.id == "task.stage"))
    |> Map.fetch!(:flags)
    |> Enum.find(&(&1.name == "note"))
    |> Map.fetch!(:summary)
  end

  defp events_flag_names do
    Barkpark.Plugins.Tasks.cli_commands()
    |> Enum.find(&(&1.id == "task.events"))
    |> Map.fetch!(:flags)
    |> Enum.map(& &1.name)
  end

  # The first backticked span in `text` containing `needle`, unbackticked.
  defp extract_backticked(text, needle) do
    ~r/`([^`]+)`/
    |> Regex.scan(text)
    |> Enum.map(fn [_, inner] -> inner end)
    |> Enum.find(&String.contains?(&1, needle))
  end
end
