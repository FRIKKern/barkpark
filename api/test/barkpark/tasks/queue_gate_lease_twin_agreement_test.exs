defmodule Barkpark.Tasks.QueueGateLeaseTwinAgreementTest do
  @moduledoc """
  THE TWIN INVARIANT, PINNED BY A TEST INSTEAD OF BY A COMMENT
  (task-16b12b4fbef83e65).

  `Barkpark.Tasks.QueueGate` answers "is this claim lease still live?" TWICE on
  the same JSON — `lease_live?/1` in Elixir (reached here through the public
  `claim_lease_live?/1`, which gates the TARGETED claim) and the lease arm of
  `executable_query/0` in SQL (which gates the READY QUEUE `bp task ready` and
  `bp task next` read). `executable_query/0` already carried a comment saying
  the two MUST move together. A comment is what let them drift into DISAGREEING:

      "2026-02-30T12:00:00Z"       SQL: EXPIRED   Elixir: LIVE   <== FAILED OPEN
      "2026-07-26T18:00:00+00:00"  SQL: HELD      Elixir: EXPIRED    (failed closed)

  Every case below feeds ONE ts_iso to BOTH arms against the SAME row shape and
  asserts they reach the SAME verdict. The set deliberately spans the malformed,
  the calendar-impossible, the leap-year pair, the offset forms, and a
  well-formed live and a well-formed dead value.

  A POSITIVE CONTROL runs the same harness over a shape the agreeing table was
  NOT written against — a non-zero UTC offset, the one documented divergence —
  and asserts the harness REPORTS the disagreement. Without it a harness that
  silently computed the same verdict twice would pass every row above while
  measuring nothing.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.QueueGate

  @dataset "production"

  setup do
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_claimed_row!(scope, claim, extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          # `open`, not `in_progress`, so the queue's lifecycle filter does NOT
          # exclude the row before the lease arm is ever consulted — otherwise
          # every case below would pass whatever the lease arm answered.
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}],
          "claim" => claim
        },
        extra
      )

    doc_id = uniq("twin-lease")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp held_claim(ts_iso), do: %{"worker" => "worker-holder", "epoch" => 3, "ts_iso" => ts_iso}

  # THE SQL ARM, ISOLATED. The row carries a non-blank `claim.worker`, no
  # `closed_at`/`closed_by` and no `queue_gate`, so the other three disjuncts of
  # `executable_query/0` are all false and the LEASE arm alone decides whether
  # this id comes back. Present => the SQL arm called the lease EXPIRED.
  defp sql_lease_live?(doc) do
    rows =
      Repo.all(
        from(d in Document,
          as: :doc,
          where: d.id == ^doc.id,
          where: ^QueueGate.executable_query(),
          select: d.id
        )
      )

    rows == []
  end

  defp elixir_lease_live?(doc), do: QueueGate.claim_lease_live?(doc.content)

  defp verdicts(scope, ts_iso) do
    doc = mk_claimed_row!(scope, held_claim(ts_iso))
    {elixir_lease_live?(doc), sql_lease_live?(doc)}
  end

  defp stale_utc_z do
    DateTime.utc_now()
    |> DateTime.add(-(QueueGate.lease_ttl_seconds() + 86_400), :second)
    |> DateTime.to_iso8601()
  end

  defp fresh_utc_z, do: DateTime.utc_now() |> DateTime.to_iso8601()

  describe "the harness itself" do
    test "the isolated SQL arm can answer BOTH ways on this fixture shape", %{scope: scope} do
      # PRECONDITION, asserted rather than assumed. Without this a harness whose
      # query returned [] for everything would report "live" for every case and
      # agree with the Elixir arm wherever the Elixir arm also said live.
      held = mk_claimed_row!(scope, held_claim(fresh_utc_z()))
      assert sql_lease_live?(held), "a seconds-old Z lease must read as HELD in SQL"

      dead = mk_claimed_row!(scope, held_claim(stale_utc_z()))
      refute sql_lease_live?(dead), "a day-dead Z lease must read as EXPIRED in SQL"

      # And the row really is ready-eligible, so an `[]` above is the lease arm
      # refusing and not the gate conjunct or a tenancy filter.
      reloaded = Repo.get!(Document, held.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["claim"]["worker"] == "worker-holder"
      refute Map.has_key?(reloaded.content, "queue_gate")
    end
  end

  describe "the two arms agree on every ts_iso shape either can see" do
    test "the two MEASURED inputs from the row, quoted", %{scope: scope} do
      # (1) February 30th. Matches a merely-anchored shape; is not a real date.
      #     BEFORE: SQL EXPIRED / Elixir LIVE — the ready queue handed out a row
      #     the targeted-claim path still considered held. THE FAIL-OPEN.
      {ex_feb30, sql_feb30} = verdicts(scope, "2026-02-30T12:00:00Z")

      assert ex_feb30 == sql_feb30,
             "2026-02-30T12:00:00Z: Elixir live?=#{ex_feb30} SQL live?=#{sql_feb30}"

      assert ex_feb30, "an unparseable date must fail CLOSED (held) in BOTH arms"

      # (2) A valid ISO-8601 offset form, the same instant as the Z form.
      #     BEFORE: SQL HELD (its pattern required a trailing Z) / Elixir EXPIRED.
      {ex_off, sql_off} = verdicts(scope, "2026-07-26T18:00:00+00:00")

      assert ex_off == sql_off,
             "2026-07-26T18:00:00+00:00: Elixir live?=#{ex_off} SQL live?=#{sql_off}"

      refute ex_off, "a two-month-old UTC lease must read EXPIRED in BOTH arms"
    end

    test "the whole agreeing table — malformed, impossible, leap, offset, live, dead",
         %{scope: scope} do
      cases = [
        # {label, ts_iso, expected live? in BOTH arms}
        {"garbage", "yesterday-ish", true},
        {"impossible month and day", "2026-13-45T99:99:99Z", true},
        {"February 30th", "2026-02-30T12:00:00Z", true},
        {"June 31st", "2026-06-31T18:00:00Z", true},
        {"February 29th in a NON-leap year", "2026-02-29T12:00:00Z", true},
        {"leap second", "2026-07-26T18:00:60Z", true},
        {"hour 24", "2026-07-26T24:00:00Z", true},
        {"fractionless digits glued to the designator", "2026-07-26T18:00:00123Z", true},
        {"multi-dot fractional tail", "2026-07-26T18:00:00.1.2Z", true},
        {"February 29th in a LEAP year, long dead", "2024-02-29T12:00:00Z", false},
        {"a real 31-day month, long dead", "2026-07-31T18:00:00Z", false},
        {"+00:00 offset, long dead", "2026-07-26T18:00:00+00:00", false},
        {"-00:00, an ISO-8601-illegal negative zero offset", "2026-07-26T18:00:00-00:00", true},
        {"fractional seconds, long dead", "2026-07-26T18:00:00.123Z", false},
        {"well-formed Z, long dead", stale_utc_z(), false},
        {"well-formed Z, seconds old", fresh_utc_z(), true}
      ]

      disagreements =
        for {label, ts_iso, expected_live} <- cases,
            {ex, sql} = verdicts(scope, ts_iso),
            ex != sql or ex != expected_live do
          "#{label} (#{ts_iso}): Elixir live?=#{ex} SQL live?=#{sql} expected both #{expected_live}"
        end

      assert disagreements == [],
             "the twin lease predicates disagreed, or agreed on the wrong verdict:\n" <>
               Enum.join(disagreements, "\n")
    end
  end

  describe "the positive control" do
    test "the harness SEES a disagreement it was not written against", %{scope: scope} do
      # A non-zero UTC offset — the one documented divergence, recorded in
      # `ts_iso_shape_pattern/0`'s @doc, in `executable_query/0`'s inline comment
      # and above `lease_live?/1`. Elixir shifts '18:00-05:00' to 23:00Z and
      # calls the two-month-old lease EXPIRED; SQL rejects the designator and
      # falls to HELD. Run through the SAME `verdicts/2` every case above uses,
      # so a pass here proves the harness can distinguish the arms at all.
      {ex, sql} = verdicts(scope, "2026-07-26T18:00:00-05:00")

      refute ex == sql,
             "the control shape must DISAGREE — a harness that cannot see this " <>
               "disagreement proves nothing about the agreements above"

      refute ex, "Elixir converts the offset and calls the old lease EXPIRED"
      assert sql, "SQL rejects a non-zero offset and FAILS CLOSED — the row stays HELD"
    end
  end

  describe "neither arm fails OPEN" do
    test "the READY QUEUE never hands out a row the Elixir arm calls LIVE", %{scope: scope} do
      # C2, driven through the real queue rather than the isolated predicate:
      # `Tasks.claim/2` is what `bp task next` calls.
      held_inputs = [
        "2026-02-30T12:00:00Z",
        "2026-13-45T99:99:99Z",
        "2026-06-31T18:00:00Z",
        "2026-02-29T12:00:00Z",
        "2026-07-26T18:00:60Z",
        "2026-07-26T18:00:00-00:00",
        "yesterday-ish",
        fresh_utc_z()
      ]

      for ts_iso <- held_inputs do
        phase_id = uniq("phase-held")
        doc = mk_claimed_row!(scope, held_claim(ts_iso), %{"parent_id" => phase_id})

        assert elixir_lease_live?(doc),
               "fixture precondition: the Elixir arm must call #{ts_iso} LIVE"

        handed_out =
          Tasks.claim("worker-newcomer", scope ++ [phase_id: phase_id, dataset: @dataset])

        # SHAPE BEFORE VALUE: an `{:error, _}` is not the queue refusing, it is the
        # queue never having answered, and it must not read as a pass here.
        assert match?({:ok, _}, handed_out),
               "the queue errored instead of answering for #{ts_iso}: #{inspect(handed_out)}"

        {:ok, row} = handed_out
        handed_doc_id = row && row.doc_id

        assert is_nil(handed_doc_id),
               "the ready queue handed out a row whose lease the Elixir arm calls live: " <>
                 "#{ts_iso} => #{handed_doc_id}"
      end

      # CONTROL — this queue, this scope, this fixture SHAPE can hand a row out,
      # so the `{:ok, nil}`s above are refusals and not an empty board.
      dead_phase = uniq("phase-dead")

      _dead =
        mk_claimed_row!(scope, held_claim(stale_utc_z()), %{"parent_id" => dead_phase})

      assert {:ok, %Document{}} =
               Tasks.claim("worker-control", scope ++ [phase_id: dead_phase, dataset: @dataset])
    end
  end
end
