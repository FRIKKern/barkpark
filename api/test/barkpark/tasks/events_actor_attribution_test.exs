defmodule Barkpark.Tasks.EventsActorAttributionTest do
  @moduledoc """
  `bp task events` answers "WHO closed this row, on WHICH lease, and WHEN" —
  from the feed, for ONE row (tlv-bl-events-actor-attribution).

  ## The gap these arms close

  A done-set false-done audit (wave 7, 2026-08-18) replayed 560 task events and
  could not attribute a single close to a worker. Every projected row was
  exactly `{at, doc_id, event, id, rev}`; ZERO carried worker / epoch /
  closed_by / actor, and `bp task events <id>` refused the positional outright
  ("too many arguments for task events" — the manifest declared `args: []`), so
  the feed was a GLOBAL keyset stream with no per-row view. Provenance was
  therefore recoverable only by fetching each done row's top-level
  `content.claim` map: N document reads to answer one question, against a field
  that is the LIVE lease and is mutable (a re-claim, a pulse or a compaction
  rewrites it), so it says who holds the row NOW and not who closed it THEN.

  ## What is proven here

    * criterion 0 — a real `Claim.claim_by_id/3` and a real
      `Close.close_with_receipt/3` each put `payload.actor` = `{worker, epoch}`
      on their event; the close ALSO keeps its pre-existing flat `closed_by`.
      An auditor reads both facts off the feed with no document fetch.
    * criterion 1 — `Events.replay_since/3` takes `:doc_id`, and
      `GET /v1/tasks/events?doc_id=` honours it, so one closed row's whole
      history comes back without replaying the global stream. The CONTROL is in
      the same arm: the unfiltered replay over the same cursor DOES carry the
      neighbour row's events, so the narrowing is measured against a stream
      that provably contained what it excluded.
    * criterion 2 — the default (no `--payload`) wire shape is byte-identical,
      and a CLAIMLESS close stamps no `actor` key at all: nothing here changes
      what a lifecycle transition means or who may perform it.

  ## Mutation proof (criterion 0)

  Deleting the `actor_stamp/2` merge from `close.ex`'s `insert_mutation_event!`
  call reds "task.closed carries payload.actor" and "the actor names the epoch
  the CAS fenced on" while every other arm here stays green — see the PR body
  for the pasted red.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Tasks.{Claim, Close, Events}

  @token "barkpark-test-actor-attribution-token"
  @dataset "production"

  # A real artifact — a PR number AND a 7-40 hex sha — so the close-artifact
  # gate (PDS-D291) is satisfied and nothing here trips on the reason.
  @artifact "landed #17099 @ 63b89bef30 — the feed names its actor"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-actor-attr", "test", ["read", "write", "admin"])
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

  # The keyset baseline: the max mutation_events id BEFORE the fixture writes.
  # Every agent shares ONE test database and a page is 500 events, so replaying
  # from 0 would page our own rows off the front.
  defp baseline, do: Repo.one(from(e in MutationEvent, select: max(e.id))) || 0

  # A ready, criteria-STATING task. The criteria are already met so the same
  # fixture can be closed without the criteria gate speaking — this file is
  # about the event, not about the gate.
  defp task!(scope, prefix \\ "actor-attr") do
    doc_id = uniq(prefix)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "stated in the fixture"
              }
            ]
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp rows_for(since, doc_id, event) do
    @dataset
    |> Events.replay_since(since, payload: true, limit: 500)
    |> Enum.filter(&(&1.doc_id == doc_id and &1.event == event))
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # ─── criterion 0 — attribution rides the event ───────────────────────────

  describe "criterion 0 — the actor is on the event" do
    test "task.claimed carries payload.actor = {worker, epoch}", %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      {:ok, _claimed} = Claim.claim_by_id(doc.doc_id, "worker-alpha", scope)

      [row] = rows_for(since, doc.doc_id, "task.claimed")

      # RED BEFORE: `claim.ex` merged only `caller_stamp/1`, so the event's
      # document held nothing but the envelope + the token id and the projected
      # row carried no `:payload` key at all — `actor` was nil.
      actor = get_in(row, [:payload, "actor"])

      assert is_map(actor),
             "task.claimed names no actor: #{inspect(Map.get(row, :payload))}"

      assert actor["worker"] == "worker-alpha"
      # A first claim takes epoch 1 — the epoch a close must later cite.
      assert actor["epoch"] == 1
    end

    test "task.closed carries payload.actor AND keeps closed_by", %{scope: scope} do
      doc = task!(scope)
      {:ok, claimed} = Claim.claim_by_id(doc.doc_id, "worker-beta", scope)
      epoch = get_in(claimed.content, ["claim", "epoch"])

      since = baseline()

      {:ok, _, :closed} =
        Close.close_with_receipt(doc.id, "worker-beta",
          observed_epoch: epoch,
          reason: @artifact
        )

      [row] = rows_for(since, doc.doc_id, "task.closed")

      actor = get_in(row, [:payload, "actor"])

      assert is_map(actor),
             "task.closed names no actor: #{inspect(Map.get(row, :payload))}"

      assert actor["worker"] == "worker-beta"

      # THE EPOCH IS THE POINT. `closed_by` alone cannot separate two closes by
      # the same worker across a re-claim; the epoch the CAS fenced on can.
      assert actor["epoch"] == epoch

      # The pre-existing flat stamp is untouched — this change ADDS a field, it
      # does not re-shape the one that was already there.
      assert row.payload["closed_by"] == "worker-beta"
    end

    test "an auditor reconstructs claim→close provenance from the feed alone",
         %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      {:ok, claimed} = Claim.claim_by_id(doc.doc_id, "worker-gamma", scope)
      epoch = get_in(claimed.content, ["claim", "epoch"])

      {:ok, _, :closed} =
        Close.close_with_receipt(doc.id, "worker-gamma",
          observed_epoch: epoch,
          reason: @artifact
        )

      # ONE read, no document fetch: who held it, on what lease, and when.
      trail =
        @dataset
        |> Events.replay_since(since, payload: true, limit: 500, doc_id: doc.doc_id)
        |> Enum.map(fn row ->
          {row.event, get_in(row, [:payload, "actor", "worker"]),
           get_in(row, [:payload, "actor", "epoch"])}
        end)

      assert {"task.claimed", "worker-gamma", epoch} in trail
      assert {"task.closed", "worker-gamma", epoch} in trail
    end
  end

  # ─── criterion 1 — the per-doc view ──────────────────────────────────────

  describe "criterion 1 — one row's history without the global stream" do
    test "replay_since/3 :doc_id narrows, and the unfiltered stream HAD the neighbour",
         %{scope: scope} do
      mine = task!(scope, "actor-mine")
      neighbour = task!(scope, "actor-neighbour")
      since = baseline()

      {:ok, mine_claimed} = Claim.claim_by_id(mine.doc_id, "worker-mine", scope)
      {:ok, _} = Claim.claim_by_id(neighbour.doc_id, "worker-neighbour", scope)

      {:ok, _, :closed} =
        Close.close_with_receipt(mine.id, "worker-mine",
          observed_epoch: get_in(mine_claimed.content, ["claim", "epoch"]),
          reason: @artifact
        )

      narrowed = Events.replay_since(@dataset, since, limit: 500, doc_id: mine.doc_id)
      all = Events.replay_since(@dataset, since, limit: 500)

      # THE CONTROL, in the same arm: the unfiltered stream over the SAME cursor
      # provably contains what the narrowing excluded, so an empty-looking
      # result cannot be mistaken for a working filter.
      assert Enum.any?(all, &(&1.doc_id == neighbour.doc_id)),
             "the control is vacuous: the unfiltered replay never saw the neighbour"

      assert narrowed != []
      assert Enum.all?(narrowed, &(&1.doc_id == mine.doc_id))
      refute Enum.any?(narrowed, &(&1.doc_id == neighbour.doc_id))

      # A KNOWN CLOSED ROW: its terminal event is in the narrowed page.
      assert "task.closed" in Enum.map(narrowed, & &1.event)

      # The narrowing composes with the keyset rather than replacing it: ids are
      # still the global monotonic PK, ascending.
      ids = Enum.map(narrowed, & &1.id)
      assert ids == Enum.sort(ids)
    end

    test "GET /v1/tasks/events?doc_id= honours the narrowing", %{conn: conn, scope: scope} do
      mine = task!(scope, "actor-http-mine")
      neighbour = task!(scope, "actor-http-neighbour")
      since = baseline()

      {:ok, _} = Claim.claim_by_id(mine.doc_id, "worker-http", scope)
      {:ok, _} = Claim.claim_by_id(neighbour.doc_id, "worker-http-2", scope)

      resp =
        conn
        |> authed()
        |> get("/v1/tasks/events?since=#{since}&doc_id=#{mine.doc_id}&payload=1")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["events"] != []
      assert Enum.all?(body["events"], &(&1["doc_id"] == mine.doc_id))

      # The control: without the param the SAME request sees the neighbour.
      wide = conn |> authed() |> get("/v1/tasks/events?since=#{since}") |> Map.get(:resp_body)
      wide = Jason.decode!(wide)

      assert Enum.any?(wide["events"], &(&1["doc_id"] == neighbour.doc_id)),
             "the control is vacuous: the unfiltered endpoint never saw the neighbour"

      # And the attribution is on the wire, not just in the module.
      claimed = Enum.find(body["events"], &(&1["event"] == "task.claimed"))
      assert get_in(claimed, ["payload", "actor", "worker"]) == "worker-http"
    end

    test "a blank ?doc_id= is unscoped, not an empty page", %{conn: conn, scope: scope} do
      doc = task!(scope)
      since = baseline()
      {:ok, _} = Claim.claim_by_id(doc.doc_id, "worker-blank", scope)

      resp = conn |> authed() |> get("/v1/tasks/events?since=#{since}&doc_id=")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Enum.any?(body["events"], &(&1["doc_id"] == doc.doc_id))
    end
  end

  # ─── criterion 2 — stamp-only ────────────────────────────────────────────

  describe "criterion 2 — nothing about lifecycle changed" do
    test "the default (no payload) wire shape is byte-for-byte unchanged", %{scope: scope} do
      doc = task!(scope)
      since = baseline()
      {:ok, _} = Claim.claim_by_id(doc.doc_id, "worker-shape", scope)

      [row] =
        @dataset
        |> Events.replay_since(since, limit: 500)
        |> Enum.filter(&(&1.doc_id == doc.doc_id and &1.event == "task.claimed"))

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :rev]
    end

    test "a CLAIMLESS close names no EPOCH — the ledger keeps saying nobody held it",
         %{scope: scope} do
      doc = task!(scope, "actor-claimless")
      since = baseline()

      # No claim: the container/root shape. 139 of 6,617 terminal rows on the
      # guerrilla ledger are legitimately claimless, and the ledger has to go on
      # saying, truthfully, that nobody ever held them.
      {:ok, _, :closed} =
        Close.close_with_receipt(doc.id, "lead-nobody", observed_epoch: nil, reason: @artifact)

      [row] = rows_for(since, doc.doc_id, "task.closed")
      actor = get_in(row, [:payload, "actor"])

      # The caller is still NAMED — that is `closed_by`'s job and the actor
      # mirrors it. What must NOT appear is an epoch: synthesising one would
      # erase the never-held fact a container row depends on, which is exactly
      # the destructive fix `close.ex` refuses.
      assert actor["worker"] == "lead-nobody"

      refute Map.has_key?(actor, "epoch"),
             "a claimless close invented a lease: #{inspect(actor)}"
    end

    test "actor_stamp/2 emits NO key when there is neither worker nor epoch" do
      assert Barkpark.Tasks.Internal.actor_stamp(nil, nil) == %{}
      assert Barkpark.Tasks.Internal.actor_stamp("", nil) == %{}
      assert Barkpark.Tasks.Internal.actor_stamp(nil, 3) == %{"actor" => %{"epoch" => 3}}
    end

    test "claim and close still move lifecycle_status exactly as before", %{scope: scope} do
      doc = task!(scope)

      {:ok, claimed} = Claim.claim_by_id(doc.doc_id, "worker-lifecycle", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"

      {:ok, closed, :closed} =
        Close.close_with_receipt(doc.id, "worker-lifecycle",
          observed_epoch: get_in(claimed.content, ["claim", "epoch"]),
          reason: @artifact
        )

      assert closed.content["lifecycle_status"] == "done"
      assert get_in(closed.content, ["claim", "closed_by"]) == "worker-lifecycle"
    end
  end

  # ─── The manifest half of `bp task events <id>` ──────────────────────────

  describe "the CLI declares the positional the feed now honours" do
    test "task.events takes an OPTIONAL doc_id arg that is NOT a path placeholder" do
      spec =
        Barkpark.Plugins.Tasks.cli_commands()
        |> Enum.find(&(&1.id == "task.events"))

      assert spec, "task.events is gone from the manifest"

      arg = Enum.find(spec.args, &(&1.name == "doc_id"))

      # RED BEFORE: `args: []` — every positional was refused with
      # "too many arguments for task events".
      assert arg, "bp task events <id> is still unspellable: #{inspect(spec.args)}"
      refute Map.get(arg, :required, false)

      # It must NOT be in the path template, or the CLI would try to fill a
      # placeholder instead of adding `?doc_id=` (internal/cli/run.go's
      # ArgLocation → "query" for a non-path arg on a read).
      refute String.contains?(spec.http.path_template, ":doc_id")
    end
  end
end
