defmodule BarkparkWeb.TasksControllerReadyClaimWorkerTest do
  @moduledoc """
  task-2df8d2db70e2070d — SETTLES the ready/fixture divergence by READING the
  predicate, not by inferring a mechanism from card counts.

  ## The predicate, quoted

  There IS a claim axis on the ready queue, and it is not in `Queue.ready_query/1`
  where the name suggests: it rides in as `where: ^QueueGate.executable_query()`,
  whose first conjunct is the lease test (`api/lib/barkpark/tasks/queue_gate.ex`):

      COALESCE(btrim(?->'claim'->>'worker'), '') = ''
      OR COALESCE(btrim(?->'claim'->>'closed_at'), '') <> ''
      OR COALESCE(btrim(?->'claim'->>'closed_by'), '') <> ''
      OR CASE WHEN ?->'claim'->>'ts_iso' ~ '^[0-9]{4}-…Z$'
              THEN ?->'claim'->>'ts_iso' < to_char((now() at time zone 'UTC')
                                                   - (? * interval '1 second'), …)
              ELSE false END

  So the answer to "can a row whose claim names a worker be ready?" is YES, on
  exactly THREE arms, and the gate is on the LEASE, never on the worker:

    1. `claim.closed_at` is non-blank — the claim was CLOSED and the row later
       reopened or blocked; the closed record stays on the row as history.
    2. `claim.closed_by` is non-blank — same thing by the other field.
    3. `claim.ts_iso` is a well-formed `…T…Z` stamp AND older than
       `QueueGate.lease_ttl_seconds/0` (default 2700) — a LAPSED lease.

  And it FAILS CLOSED in the two shapes that are not on that list: a live stamp,
  and a claim with no parseable `ts_iso` at all (the `ELSE false` arm), both of
  which keep the row OFF the queue while still naming a worker.

  ## The live page, characterised against it (2026-09-10)

  `bp task ready --limit 300` served 300 cards; 17 render a worker-bearing
  `claim`. Read at the source (`bp task get <id>` → `doc.claim`, NOT
  `doc.content.claim`, which is null on these rows and measures nothing):

    * SIXTEEN are admitted by arm 1, `claim.closed_at` — sixteen `blocked`
      rows whose claim was closed and which a second actor then blocked.
    * ONE — `task-29781d0921e5a885`, the single `open` one — is admitted by
      arm 3: `claim.ts_iso` 66.8 h old against a 2700 s lease.
    * ZERO ride the worker-blank arm, which is the ONE arm that renders no
      claim block at all (`Params.brief_claim/1` drops a worker-less claim).

  ## Which side was wrong: THE FIXTURE

  `tasks_controller_test.exs`'s realistic-mix tripwire seeded its claim residues
  worker-less and wrote the reason into the file as a fact:

      "A claim naming a worker takes the row off the ready queue outright:
       seeding nine worker-bearing claims dropped the page from 50 cards to 41."

  The mechanism in that sentence does not exist. A worker-bearing claim removes a
  row only while its LEASE IS LIVE — which is what those nine seeds had, a claim
  with a worker and no `closed_at`/`closed_by` and no lapsed `ts_iso`, i.e. the
  `ELSE false` fail-closed arm. All three admitting shapes are seedable from a
  fixture in one line, so the live card shape was never "structurally
  unreachable"; the fixture rendered `claim` on ZERO of fifty cards while
  production renders it on seventeen, and the byte tripwire therefore measured
  936 B of live page as zero. This file constructs all three, and the fixture is
  corrected to carry them.

  ## Mutation proof, both directions

    * DROP the lease arm — delete the three `closed_at`/`closed_by`/`ts_iso`
      disjuncts from `QueueGate.executable_query/0`, leaving only the
      worker-blank test — and the three `admits` tests below red by name while
      the two `refuses` tests stay green.
    * WIDEN it — replace the whole disjunction with `true` — and the two
      `refuses` tests red while the `admits` ones stay green. A live lease back
      on the queue is the failure this gate exists to prevent.
    * RENDERER direction — make `Params.brief_claim/1` unconditional `nil` and
      the page test's three claim assertions red; restore the pre-#16775 rule
      (block kept on worker OR now-line) and its worker-less control reds. The
      page arm cannot be satisfied by a page that renders zero claims, which is
      what keeps it out of the vacuous-guard class of task-69ba050120c2c021.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.QueueGate

  @token "barkpark-test-ready-claim-worker"
  @dataset "production"

  # A stamp far past any plausible lease. Fixed, not computed from `utc_now`:
  # the comparison is TEXTUAL, and a stamp is either past the cutoff or it is
  # not — a fixed 2024 date can never flake on clock skew.
  @lapsed_ts "2024-01-01T00:00:00.000000Z"

  # The base record every arm below varies by exactly one field.
  @held_claim %{
    "worker" => "lead-cli-r4",
    "epoch" => 27,
    "ts_iso" => "2026-09-10T09:00:00.123456Z",
    "work_digest" => "abcd1234deadbeef",
    "now" => %{
      "text" => "wiring the serializer, tests next",
      "ts" => "2026-09-10T09:00:00.123456Z",
      "criterion" => 1
    }
  }

  setup do
    {:ok, _} = Auth.create_token(@token, "test-ready-claim-worker", "test", ["read", "write"])
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

    # Every assertion here is scoped to ONE fixture phase and addresses rows by
    # id. The test database is shared between agents; a census over the whole
    # ready queue would be measuring somebody else's rows.
    %{scope: scope, phase_id: uniq("phase-ready-claim")}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, phase_id, extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "parent_id" => phase_id,
          "priority" => 2,
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ]
        },
        extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "ready claim worker fixture #{doc_id}",
          "content" => content
        },
        @dataset,
        scope
      )

    # `create_document/4` lands a DRAFT, so the row's real address is
    # `drafts.<id>` — and `ready_query/1` admits an UNPAIRED draft twin AS
    # ITSELF (queue.ex, "WHAT IS NOT AN AXIS — documents.status"). Return the
    # STORED spelling so every assertion addresses the row the queue serves.
    doc.doc_id
  end

  defp ready_ids(scope, phase_id),
    do: Tasks.ready(scope ++ [phase_id: phase_id, limit: 100]) |> Enum.map(& &1.doc_id)

  defp ready_page(conn, phase_id, view) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> get("/v1/tasks/ready?view=#{view}&limit=100&phase_id=#{phase_id}")
    |> json_response(200)
  end

  defp card(payload, doc_id), do: Enum.find(payload["docs"], &(&1["doc_id"] == doc_id))

  describe "the ready gate is on the LEASE, not on the worker" do
    test "CONTROL: a claim-less row of this fixture family IS ready",
         %{scope: scope, phase_id: phase} do
      id = mk_task!(uniq("no-claim"), scope, phase, %{})

      assert id in ready_ids(scope, phase),
             "the fixture family itself never reaches the ready queue — every claim " <>
               "arm below would then pass or fail for a reason unrelated to claims"
    end

    test "ADMITS: a worker-bearing claim with closed_at — the arm SIXTEEN of the seventeen live cards ride",
         %{scope: scope, phase_id: phase} do
      id =
        mk_task!(uniq("closed-at"), scope, phase, %{
          "claim" => Map.put(@held_claim, "closed_at", "2026-09-09T10:00:00.000000Z"),
          "lifecycle_status" => "blocked"
        })

      assert id in ready_ids(scope, phase),
             "a CLOSED claim record still fenced its row off the queue — arm 1 of " <>
               "QueueGate.executable_query/0 is gone"
    end

    test "ADMITS: a worker-bearing claim with closed_by",
         %{scope: scope, phase_id: phase} do
      id =
        mk_task!(uniq("closed-by"), scope, phase, %{
          "claim" => Map.put(@held_claim, "closed_by", "lead-cli-r4")
        })

      assert id in ready_ids(scope, phase)
    end

    test "ADMITS: a worker-bearing claim whose ts_iso lapsed — the arm the ONE open live card rides",
         %{scope: scope, phase_id: phase} do
      id =
        mk_task!(uniq("lapsed"), scope, phase, %{
          "claim" => Map.put(@held_claim, "ts_iso", @lapsed_ts)
        })

      assert id in ready_ids(scope, phase),
             "a lease stamped #{@lapsed_ts} still reads as live against a " <>
               "#{QueueGate.lease_ttl_seconds()}s TTL"
    end

    test "REFUSES: a LIVE lease — the shape the fixture's nine seeds actually had",
         %{scope: scope, phase_id: phase} do
      live = mk_task!(uniq("live-lease"), scope, phase, %{"claim" => @held_claim})
      lapsed_control = mk_task!(uniq("lapsed-ctl"), scope, phase, %{
        "claim" => Map.put(@held_claim, "ts_iso", @lapsed_ts)
      })

      ids = ready_ids(scope, phase)

      # One field apart, opposite verdict — which is the whole finding: the
      # nine seeds that "dropped the page from 50 cards to 41" were held by a
      # LIVE lease, not by naming a worker.
      refute live in ids, "a live lease is back on the ready queue"
      assert lapsed_control in ids, "the control did not reach the queue — this test is vacuous"
    end

    test "REFUSES (fail-closed): a worker-bearing claim with NO parseable ts_iso",
         %{scope: scope, phase_id: phase} do
      id =
        mk_task!(uniq("no-ts"), scope, phase, %{
          "claim" => Map.drop(@held_claim, ["ts_iso"])
        })

      malformed =
        mk_task!(uniq("bad-ts"), scope, phase, %{
          "claim" => Map.put(@held_claim, "ts_iso", "2026-09-10 09:00:00")
        })

      ids = ready_ids(scope, phase)

      # `ELSE false` — not expired, i.e. still held. A space separator sorts
      # below 'T' and would read as expired, so the shape guard refuses it.
      refute id in ids
      refute malformed in ids
    end

    test "the LIFECYCLE is a separate axis: in_progress is refused with the SAME closed claim",
         %{scope: scope, phase_id: phase} do
      claim = Map.put(@held_claim, "closed_at", "2026-09-09T10:00:00.000000Z")

      claimable =
        mk_task!(uniq("axis-blocked"), scope, phase, %{
          "claim" => claim,
          "lifecycle_status" => "blocked"
        })

      refused =
        mk_task!(uniq("axis-in-progress"), scope, phase, %{
          "claim" => claim,
          "lifecycle_status" => "in_progress"
        })

      ids = ready_ids(scope, phase)

      assert claimable in ids
      refute refused in ids
    end
  end

  describe "the ready PAGE renders the live claim shape" do
    test "a closed and a lapsed claim both name their holder on the brief card; a swept residue does not",
         %{conn: conn, scope: scope, phase_id: phase} do
      closed =
        mk_task!(uniq("card-closed"), scope, phase, %{
          "claim" => Map.put(@held_claim, "closed_at", "2026-09-09T10:00:00.000000Z"),
          "lifecycle_status" => "blocked"
        })

      lapsed =
        mk_task!(uniq("card-lapsed"), scope, phase, %{
          "claim" => Map.put(@held_claim, "ts_iso", @lapsed_ts)
        })

      # The swept residue: the sweeper NULLS the worker and leaves the rest.
      # This is the one shape the fixture had, and the one that renders nothing.
      swept =
        mk_task!(uniq("card-swept"), scope, phase, %{
          "claim" => @held_claim |> Map.put("worker", nil) |> Map.put("ts_iso", @lapsed_ts)
        })

      payload = ready_page(conn, phase, "brief")

      for {label, id} <- [closed: closed, lapsed: lapsed, swept: swept] do
        assert card(payload, id), "#{label} row never reached the ready page — arm is vacuous"
      end

      for {label, id} <- [closed: closed, lapsed: lapsed] do
        c = card(payload, id)["claim"]

        assert c["worker"] == "lead-cli-r4",
               "the #{label} ready card dropped its claim holder: #{inspect(c)}"

        assert c["epoch"] == 27
        assert c["now"]["text"] == "wiring the serializer, tests next"

        # The brief card is a diet: fencing detail is full-view only, so a green
        # here cannot be "the renderer emits whatever map it was handed".
        refute Map.has_key?(c, "work_digest")
        refute Map.has_key?(c, "ts_iso")
      end

      refute Map.has_key?(card(payload, swept), "claim"),
             "a swept lease still renders a claim block on a ready card"

      # …and the full view still carries the history the brief card dropped.
      # (`full` surfaces `claim` at the CARD top level, the same seat
      # `bp task get` prints it at — never under `content`, which is null on
      # these rows and measures nothing.)
      full = ready_page(conn, phase, "full")
      assert card(full, closed)["claim"]["work_digest"] == "abcd1234deadbeef"
    end
  end
end
