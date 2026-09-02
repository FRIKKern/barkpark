defmodule Barkpark.Tasks.PulseTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Pulse` — the now-line heartbeat that renews
  the lease (`bp task pulse` / `POST /v1/tasks/:doc_id/pulse`).

  Covers:
    1. Happy path: ONE atomic write lands claim.now {text,ts,criterion?} +
       epoch bump + ts_iso refresh; work_digest + work_field_digests
       untouched; ONE task.pulse mutation_event in the same transaction.
    2. now.ts == the renewed lease's ts_iso (one instant — decay renders
       from one clock).
    3. criterion omitted → no "criterion" key on claim.now.
    4. Repeat pulses overwrite claim.now (a now-line, not a log).
    5. NO epoch fence: a pulse after a foreign epoch bump (L4 fence shape)
       still succeeds and keeps bumping monotonically.
    6. REAPED lease (the charter-pinned hazard case): TTL sweep reaps the
       claim → the old holder's pulse is {:error, :not_holder} — the row
       stays open/worker-nil, NO silent re-claim, no digest restamp, no
       task.pulse event, no claim.now.
    7. Released lease → :not_holder. Closed task → :not_holder (close keeps
       claim.worker, so this proves the live-lease gate, not just the
       holder match). Foreign worker on a live claim → :not_holder.
    8. Unknown uuid → :not_found.
    9. Read path: render_doc / render_doc_with_counts (GET show + list
       envelopes) surface claim.now with its ts.
   10. Manifest wiring: plugin route tuple + task.pulse CLI verb
       (bp task pulse rides generic dispatch — zero new Go).
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Pulse, TtlSweeper}

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

  defp claimed_task!(scope, worker) do
    doc_id = uniq("pulse")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          # PDS-D291: one MET criterion keeps this file's `done` close out of
          # the close-artifact gate (a criteria-less `done` close whose reason
          # names no PR+sha is refused). These tests measure the pulse.
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp reload(doc), do: Repo.get!(Document, doc.id)

  defp pulse_events(doc_id) do
    Repo.all(
      from(e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.pulse",
        order_by: e.id
      )
    )
  end

  # Age the claim's ts_iso so the TTL sweeper sees it as expired (mirrors
  # ttl_sweeper_test's age_claim! — simulate "claimed long ago, then silence").
  defp age_claim!(doc, seconds_ago) do
    iso = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    doc = reload(doc)
    new_claim = Map.put(doc.content["claim"], "ts_iso", iso)
    new_content = Map.put(doc.content, "claim", new_claim)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    reload(doc)
  end

  describe "pulse/3 — the atomic now-line + renewal write" do
    test "one write: claim.now lands, epoch bumps, ts_iso refreshes, digest untouched, one event",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      claim0 = doc.content["claim"]
      assert claim0["epoch"] == 1

      assert {:ok, pulsed} =
               Tasks.pulse_by_id(doc.id, "w-hold",
                 text: "warm-up pinned, rerunning",
                 criterion: 2
               )

      content = reload(doc).content
      claim = content["claim"]

      # The now-line, with its ts + the named criterion.
      assert claim["now"]["text"] == "warm-up pinned, rerunning"
      assert claim["now"]["criterion"] == 2
      assert is_binary(claim["now"]["ts"])

      # Lease renewed in the SAME write: epoch bump + ts_iso refresh.
      assert claim["epoch"] == 2
      assert claim["ts_iso"] != claim0["ts_iso"] or claim["ts_iso"] == claim["now"]["ts"]

      # work_digest + work_field_digests DELIBERATELY untouched (do_renew
      # semantics — the L2 close-fence must still catch a drifted brief).
      assert claim["work_digest"] == claim0["work_digest"]
      assert claim["work_field_digests"] == claim0["work_field_digests"]

      # Holder + lifecycle untouched — a pulse is a heartbeat, not a state flip.
      assert claim["worker"] == "w-hold"
      assert content["lifecycle_status"] == "in_progress"
      assert content["assignee"] == "w-hold"

      # One rev bump (the CAS write), one task.pulse event in the same txn.
      assert pulsed.rev != doc.rev
      assert [ev] = pulse_events(doc.doc_id)
      assert ev.rev == pulsed.rev
      assert ev.previous_rev == doc.rev
      assert ev.document["pulse"]["text"] == "warm-up pinned, rerunning"
      assert ev.document["pulse"]["criterion"] == 2
      assert ev.document["pulse"]["worker"] == "w-hold"
      assert ev.document["pulse"]["epoch"] == 2
      assert is_binary(ev.document["pulse"]["ts"])
    end

    test "now.ts is the SAME instant as the renewed lease's ts_iso", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "compiling")

      claim = reload(doc).content["claim"]
      assert claim["now"]["ts"] == claim["ts_iso"]
    end

    test "criterion omitted → no criterion key on the now-line", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "reading the brief")

      now = reload(doc).content["claim"]["now"]
      assert now["text"] == "reading the brief"
      refute Map.has_key?(now, "criterion")
    end

    test "repeat pulses overwrite claim.now — a now-line, not a log", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "first", criterion: 0)
      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "second")

      claim = reload(doc).content["claim"]
      assert claim["now"]["text"] == "second"
      refute Map.has_key?(claim["now"], "criterion")
      # Each pulse renewed: 1 (claim) + 2 pulses.
      assert claim["epoch"] == 3
      assert length(pulse_events(doc.doc_id)) == 2
    end
  end

  describe "pulse/3 — no epoch fence (pulse IS the renewal)" do
    test "a pulse after a foreign epoch bump (L4 fence shape) still succeeds", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      # Simulate an L4 fence: a mutating actor bumped the epoch under the
      # holder (blocker edge / move). The holder's stale-epoch CLOSE would be
      # fenced_off — but its pulse carries no epoch and must still land.
      fenced = reload(doc)
      fenced_claim = Map.update!(fenced.content["claim"], "epoch", &(&1 + 1))

      {1, _} =
        from(d in Document, where: d.id == ^doc.id)
        |> Repo.update_all(set: [content: Map.put(fenced.content, "claim", fenced_claim)])

      assert {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "still here")

      claim = reload(doc).content["claim"]
      assert claim["epoch"] == 3
      assert claim["now"]["text"] == "still here"
    end
  end

  describe "pulse/3 — a lost lease refuses (:not_holder), never a silent re-claim" do
    test "REAPED lease: the old holder's pulse is refused and the row stays reaped",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc = claimed_task!(scope, "w-crashed")
      _ = age_claim!(doc, 600)

      assert %{swept: swept} = TtlSweeper.sweep(300)
      assert swept >= 1

      reaped = reload(doc).content
      assert reaped["lifecycle_status"] == "open"
      assert reaped["claim"]["worker"] == nil
      reaped_epoch = reaped["claim"]["epoch"]

      # The crashed worker comes back and pulses — THE hazard case: a thin
      # claim_by_id delegate would silently RE-CLAIM here with a fresh digest.
      assert {:error, :not_holder} =
               Tasks.pulse_by_id(doc.id, "w-crashed", text: "i'm alive!")

      after_content = reload(doc).content
      # No re-claim, no now-line, no epoch movement, no digest restamp.
      assert after_content["lifecycle_status"] == "open"
      assert after_content["claim"]["worker"] == nil
      assert after_content["claim"]["epoch"] == reaped_epoch
      refute Map.has_key?(after_content["claim"], "now")
      assert pulse_events(doc.doc_id) == []
    end

    test "RELEASED lease → :not_holder", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = reload(doc).content["claim"]["epoch"]

      {:ok, _} = Tasks.release(doc.id, "w-hold", observed_epoch: epoch)

      assert {:error, :not_holder} = Tasks.pulse_by_id(doc.id, "w-hold", text: "late pulse")
      refute Map.has_key?(reload(doc).content["claim"], "now")
    end

    test "CLOSED task → :not_holder (close keeps claim.worker — the live-lease gate catches it)",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = reload(doc).content["claim"]["epoch"]

      {:ok, _} = Tasks.close(doc.id, "w-hold", observed_epoch: epoch)
      assert reload(doc).content["claim"]["worker"] == "w-hold"

      assert {:error, :not_holder} = Tasks.pulse_by_id(doc.id, "w-hold", text: "post-close")
      assert reload(doc).content["lifecycle_status"] == "done"
      refute Map.has_key?(reload(doc).content["claim"], "now")
    end

    test "a foreign worker on a live claim → :not_holder", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      assert {:error, :not_holder} = Tasks.pulse_by_id(doc.id, "w-thief", text: "mine now")

      claim = reload(doc).content["claim"]
      assert claim["worker"] == "w-hold"
      refute Map.has_key?(claim, "now")
    end

    test "unknown uuid → :not_found" do
      assert {:error, :not_found} =
               Pulse.pulse("00000000-0000-0000-0000-000000000099", "w", text: "hello?")
    end
  end

  describe "read path — boards render decay from claim.now.ts" do
    alias BarkparkWeb.TasksController.Params

    test "render_doc (GET /v1/tasks/:doc_id) + render_doc_with_counts (list APIs) carry claim.now with its ts",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-hold", text: "rendering", criterion: 1)

      fresh = reload(doc)

      rendered = Params.render_doc(fresh)
      assert rendered.claim["now"]["text"] == "rendering"
      assert rendered.claim["now"]["criterion"] == 1
      assert is_binary(rendered.claim["now"]["ts"])

      listed = Params.render_doc_with_counts(fresh, %{})
      assert listed.claim["now"]["text"] == "rendering"
      assert is_binary(listed.claim["now"]["ts"])
    end
  end

  describe "manifest wiring — bp task pulse via generic dispatch, zero new Go" do
    test "the plugin mounts POST /tasks/:doc_id/pulse and declares the task.pulse verb" do
      routes = Barkpark.Plugins.Tasks.register_routes(%{})

      assert Enum.any?(routes, fn
               {:post, "/tasks/:doc_id/pulse", BarkparkWeb.TasksController, :pulse, _opts} -> true
               _ -> false
             end)

      verb = Enum.find(Barkpark.Plugins.Tasks.cli_commands(), &(&1.id == "task.pulse"))
      assert verb.verb == "pulse"
      assert verb.http == %{method: "POST", path_template: "/v1/tasks/:doc_id/pulse"}
      assert Enum.map(verb.args, & &1.name) == ["doc_id", "worker_id"]
      assert Enum.map(verb.flags, & &1.name) == ["now", "criterion"]
      # NO epoch arg anywhere — pulse survives fences by design (charter D9).
      refute Enum.any?(verb.args ++ verb.flags, &(&1.name == "observed_epoch"))
      assert verb.writes == true
    end
  end
end
