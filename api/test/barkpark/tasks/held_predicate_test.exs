defmodule Barkpark.Tasks.HeldPredicateTest do
  @moduledoc """
  task-4787fdd569f3aff4 — a RELEASED row must not read as HELD.

  `Tasks.Release` preserves the claim OBJECT as the audit trail: it nulls
  `claim.worker` and leaves everything else, INCLUDING a bumped `claim.epoch`
  (which `Tasks.Claim` reads as `current_epoch(doc) + 1` and `Tasks.Close`
  fences against, so it is load-bearing, not residue).

  The consequence is that three obvious presence tests are FALSE tests of
  heldness, and this file pins the difference:

      claim != nil               -> TRUE on a released row
      claim["epoch"] != nil      -> TRUE on a released row
      has_key?(claim, "worker")  -> TRUE on a released row
      Internal.held?/1           -> FALSE on a released row  <- the supported one

  MUTATION ARM: flip `Internal.held?/1` to any of the three presence tests and
  "a released row is NOT held" reds, naming the released row it misclassified.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Internal, Release}

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

  defp claimed_task!(scope, worker, extra_opts \\ []) do
    doc_id = uniq("held")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fx"}
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope ++ extra_opts)
    claimed
  end

  defp stored(doc), do: Repo.get!(Document, doc.id)

  # The three shapes a reader reaches for instead of the supported predicate.
  # A PREDICATE, not an enumeration of known-bad call sites: any reader with
  # this shape gets the same wrong answer.
  defp claim_object_present?(content), do: not is_nil(Map.get(content || %{}, "claim"))
  defp claim_epoch_present?(content), do: not is_nil(get_in(content || %{}, ["claim", "epoch"]))

  defp claim_worker_key_present?(content),
    do: Map.has_key?(Map.get(content || %{}, "claim") || %{}, "worker")

  describe "the held predicate discriminates a released row from a held one" do
    test "PRECONDITION: a released row really is released, and really keeps its claim",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-pre")
      epoch = get_in(stored(doc).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(doc.id, "w-pre", observed_epoch: epoch)

      content = stored(doc).content

      # The setup landed, asserted — not inferred from a return code.
      assert content["lifecycle_status"] == "open",
             "precondition failed: the release did not reopen #{doc.doc_id}"

      assert get_in(content, ["claim", "worker"]) == nil,
             "precondition failed: #{doc.doc_id} still names a holder"

      # And the audit trail this row exists to describe is INTACT. If a future
      # change clears the claim object, this file's whole premise is gone and
      # you should be told here rather than by a green that measures nothing.
      assert is_map(Map.get(content, "claim")),
             "premise gone: the released claim object was cleared"

      assert get_in(content, ["claim", "epoch"]) == epoch + 1
      assert is_binary(get_in(content, ["claim", "released_at"]))
      assert get_in(content, ["claim", "released_by"]) == "w-pre"
    end

    test "CONTROL: a HELD row answers held? == true", %{scope: scope} do
      doc = claimed_task!(scope, "w-live")
      content = stored(doc).content

      assert content["lifecycle_status"] == "in_progress",
             "precondition failed: #{doc.doc_id} was not claimed"

      assert Internal.held?(content) == true
      assert Internal.holder(content) == "w-live"
    end

    test "a RELEASED row is NOT held, while all three presence tests say it is",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-rel")
      epoch = get_in(stored(doc).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(doc.id, "w-rel", observed_epoch: epoch)

      content = stored(doc).content

      # THE ASSERTION THIS FILE EXISTS FOR.
      refute Internal.held?(content),
             "released row #{doc.doc_id} was classified as HELD — " <>
               "held?/1 must key on claim.worker and nothing else. " <>
               "claim=#{inspect(Map.get(content, "claim"))}"

      assert Internal.holder(content) == nil

      # …and the same row proves the three alternatives are FALSE TESTS. These
      # are not aspirational: they are what a presence-testing reader answers.
      assert claim_object_present?(content),
             "the released row lost its claim object — the defect this file pins is gone"

      assert claim_epoch_present?(content)
      assert claim_worker_key_present?(content)
    end

    test "held and released rows give DIFFERENT answers to the supported predicate",
         %{scope: scope} do
      held = claimed_task!(scope, "w-a")

      released = claimed_task!(scope, "w-b")
      epoch = get_in(stored(released).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(released.id, "w-b", observed_epoch: epoch)

      held_content = stored(held).content
      released_content = stored(released).content

      assert Internal.held?(held_content) != Internal.held?(released_content),
             "held?/1 did not discriminate: held=#{held.doc_id} released=#{released.doc_id}"

      # …and the presence tests do NOT discriminate — which is the whole point.
      assert claim_object_present?(held_content) == claim_object_present?(released_content)
      assert claim_epoch_present?(held_content) == claim_epoch_present?(released_content)
    end

    test "a blank worker string is not a holder either", %{scope: scope} do
      doc = claimed_task!(scope, "w-blank")
      content = put_in(stored(doc).content, ["claim", "worker"], "   ")
      refute Internal.held?(content)
    end

    test "a claim-less row is not held, and does not raise", %{scope: _scope} do
      refute Internal.held?(%{"lifecycle_status" => "open"})
      refute Internal.held?(%{})
      refute Internal.held?(nil)
      # A non-map claim must not blow up a read-side predicate.
      refute Internal.held?(%{"claim" => "nonsense"})
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # THE KEY SET OF A RELEASED CLAIM
  #
  # The tests above assert the FIELDS somebody remembered. That is exactly the
  # failure this block exists to close: an earlier enumeration of the released
  # claim object listed four keys (epoch, released_at, released_by, worker) and
  # the real object carries ten. Two of them — `session` and `session_origin` —
  # were in NOBODY's list. So: print the keyset, do not code against the fields
  # you remember.
  #
  # The roster below is DERIVED from the writers, each of which is the single
  # place its keys are minted:
  #
  #   Tasks.Claim.do_claim_resolved/7  worker ts_iso epoch work_digest
  #                                    work_field_digests  (a map LITERAL —
  #                                    unconditional, every claim has all five)
  #                                    + resources / execution_policy /
  #                                      criteria_unstated_override / session +
  #                                      session_origin, each behind an `if`
  #   Tasks.Pulse.pulse/3              rewrites epoch + ts_iso, and MINTS `now`
  #                                    — `now` is a PULSE key, written nowhere
  #                                    else (`grep -n \'"now"\' lib/barkpark/tasks/`
  #                                    hits pulse.ex and nothing else). A claim
  #                                    that was never pulsed releases WITHOUT
  #                                    it, which is why `now` sits in the
  #                                    conditional tier and gets its own arm
  #                                    below: measured, not remembered. An
  #                                    earlier hand enumeration of "the released
  #                                    claim" listed `now` as always-present
  #                                    because it happened to read a pulsed row.
  #   Tasks.TtlSweeper.apply_reap/1    expired_at previous_worker
  #   Tasks.Release.apply_release_update/2  +released_by +released_at,
  #                                    -resources -expired_at
  #
  # STRICT OR SUBSET? — BOTH, SPLIT BY DIRECTION, ON PURPOSE.
  #
  # A single `==` against one literal set is not available here and never was:
  # the same verb legitimately produces a DIFFERENT set depending on the claim
  # that preceded it (8 keys sessionless, 10 with a session, and a
  # resource-bearing claim differs again). An exact-match test would therefore
  # pin THIS FIXTURE, not the verb, and would red on a benign additive change —
  # a cost, not a gain. But a pure subset check cannot see a DROPPED key, and
  # the drop direction is the one that breaks the CAS fence. So:
  #
  #   DROP direction  -> strict, in `required_claim_keys/0`. Any of these
  #                      missing is a red that NAMES the missing keys. Tiers:
  #                        load-bearing  worker epoch      — the CAS fence
  #                                                          (Close/Release
  #                                                          fence on epoch,
  #                                                          held?/1 on worker)
  #                        audit trail   released_by released_at — the dossier
  #                                                          this row exists to
  #                                                          carry
  #                        carried       now ts_iso work_digest
  #                                      work_field_digests — required because
  #                                      the claim writes them unconditionally
  #                                      and release's contract is "preserve the
  #                                      claim OBJECT"; a silent drop here IS a
  #                                      break of that contract.
  #   FORBIDDEN       -> strict absence. `resources` and `expired_at` are
  #                      deleted deliberately (they describe a fence/lapse the
  #                      release superseded). Their return is a regression.
  #   GROWTH direction-> its own test, `@known_claim_keys`. A new key reds ONE
  #                      test whose name says it is a roster update, so a benign
  #                      addition is a cheap, obvious edit and is never silent.
  #
  # Every set below is DERIVED from a row put through the real `Release.release/3`
  # verb. Nothing here hand-builds a claim map: that would test the fixture.
  # ────────────────────────────────────────────────────────────────────────

  @load_bearing_claim_keys ~w(worker epoch)
  @audit_claim_keys ~w(released_by released_at)
  @carried_claim_keys ~w(ts_iso work_digest work_field_digests)
  @forbidden_claim_keys ~w(resources expired_at)

  # Minted behind a condition by claim/pulse/reap — legal to be absent, and
  # legal to be present. Listed so the growth ratchet does not red on them.
  @conditional_claim_keys ~w(now session session_origin execution_policy
                             criteria_unstated_override previous_worker)

  @required_claim_keys @load_bearing_claim_keys ++ @audit_claim_keys ++ @carried_claim_keys
  @known_claim_keys @required_claim_keys ++ @conditional_claim_keys

  # Claim -> release through the REAL verbs, and hand back the stored claim.
  defp released_claim!(scope, worker, opts \\ []) do
    {pulse_text, claim_opts} = Keyword.pop(opts, :pulse_text)
    doc = claimed_task!(scope, worker, claim_opts)

    if pulse_text do
      # `pulse` BUMPS the epoch, so the observed epoch must be re-read after it
      # (it is, below) or the release fences off.
      assert {:ok, _} = Tasks.pulse_by_id(doc.id, worker, text: pulse_text)
    end

    epoch = get_in(stored(doc).content, ["claim", "epoch"])
    assert {:ok, _} = Release.release(doc.id, worker, observed_epoch: epoch)

    content = stored(doc).content

    assert get_in(content, ["claim", "worker"]) == nil,
           "precondition failed: #{doc.doc_id} did not release"

    claim = Map.get(content, "claim")

    assert is_map(claim),
           "precondition failed: #{doc.doc_id} has no claim object to enumerate"

    {doc, claim}
  end

  defp keyset_report(doc, claim) do
    "\n  doc_id:   #{doc.doc_id}" <>
      "\n  OBSERVED: #{inspect(Enum.sort(Map.keys(claim)))}" <>
      "\n  REQUIRED: #{inspect(Enum.sort(@required_claim_keys))}" <>
      "\n  KNOWN:    #{inspect(Enum.sort(@known_claim_keys))}" <>
      "\n  claim:    #{inspect(claim)}"
  end

  describe "the released claim's key set is pinned, not remembered" do
    test "DROP ARM: every required key survives the release", %{scope: scope} do
      {doc, claim} = released_claim!(scope, "w-keys")
      observed = MapSet.new(Map.keys(claim))

      missing = MapSet.difference(MapSet.new(@required_claim_keys), observed)

      assert MapSet.size(missing) == 0,
             "the released claim DROPPED required key(s): " <>
               "#{inspect(Enum.sort(MapSet.to_list(missing)))}\n" <>
               "  load-bearing (CAS fence, breaks claim/close/held?): " <>
               "#{inspect(Enum.sort(MapSet.to_list(MapSet.intersection(missing, MapSet.new(@load_bearing_claim_keys)))))}\n" <>
               "  audit trail (the release dossier): " <>
               "#{inspect(Enum.sort(MapSet.to_list(MapSet.intersection(missing, MapSet.new(@audit_claim_keys)))))}\n" <>
               "  carried from the claim (release must PRESERVE the object): " <>
               "#{inspect(Enum.sort(MapSet.to_list(MapSet.intersection(missing, MapSet.new(@carried_claim_keys)))))}" <>
               keyset_report(doc, claim)
    end

    test "GROWTH ARM: the released claim grew no key this roster does not know",
         %{scope: scope} do
      {doc, claim} = released_claim!(scope, "w-keys-grow")
      unknown = MapSet.difference(MapSet.new(Map.keys(claim)), MapSet.new(@known_claim_keys))

      assert MapSet.size(unknown) == 0,
             "the released claim gained key(s) no tier claims: " <>
               "#{inspect(Enum.sort(MapSet.to_list(unknown)))}\n" <>
               "  This is a ROSTER UPDATE, not necessarily a defect. Classify each\n" <>
               "  new key and add it to @conditional_claim_keys (minted behind an\n" <>
               "  `if`) or to one of the required tiers (written unconditionally),\n" <>
               "  then say in a comment which writer mints it." <> keyset_report(doc, claim)
    end

    test "FORBIDDEN ARM: release strips the keys whose meaning it falsifies",
         %{scope: scope} do
      resource = uniq("lib/held_predicate")
      {doc, claim} = released_claim!(scope, "w-keys-res", resources: [resource])

      present =
        MapSet.intersection(MapSet.new(Map.keys(claim)), MapSet.new(@forbidden_claim_keys))

      assert MapSet.size(present) == 0,
             "the released claim kept superseded key(s) " <>
               "#{inspect(Enum.sort(MapSet.to_list(present)))} — `resources` is a dead " <>
               "fence and `expired_at` is a lapse the walk-away superseded." <>
               keyset_report(doc, claim)

      # …and the CONTROL: the claim really did carry `resources`, so the
      # absence above measures a DELETION, not a fixture that never had one.
      held = claimed_task!(scope, "w-keys-res-control", resources: [uniq("lib/control")])

      assert is_list(get_in(stored(held).content, ["claim", "resources"])),
             "control failed: the claim path did not write `resources`, so the " <>
               "assertion above proves nothing about release deleting it"
    end

    test "CONDITIONAL ARM: `now` appears only on a claim that was actually pulsed",
         %{scope: scope} do
      {_doc, unpulsed} = released_claim!(scope, "w-keys-nopulse")
      {doc, pulsed} = released_claim!(scope, "w-keys-pulse", pulse_text: "heartbeat")

      refute Map.has_key?(unpulsed, "now"),
             "`now` turned up on a claim nothing pulsed — it belongs to " <>
               "Tasks.Pulse; if a second writer now mints it, move it out of " <>
               "@conditional_claim_keys." <> keyset_report(doc, unpulsed)

      # The arm an enumeration taken from an UNPULSED row cannot see.
      assert Map.has_key?(pulsed, "now"),
             "a pulsed lease released WITHOUT its `now` line — the pulse\'s only " <>
               "durable trace on the claim is gone." <> keyset_report(doc, pulsed)

      extra = MapSet.difference(MapSet.new(Map.keys(pulsed)), MapSet.new(Map.keys(unpulsed)))

      assert MapSet.equal?(extra, MapSet.new(["now"])),
             "pulsing changed the released key set by " <>
               "#{inspect(Enum.sort(MapSet.to_list(extra)))}, expected exactly " <>
               "[\"now\"]." <> keyset_report(doc, pulsed)
    end

    test "the two conditional session keys are BOTH-or-NEITHER, and the sessionless " <>
           "claim is the reason nobody listed them",
         %{scope: scope} do
      {_doc, sessionless} = released_claim!(scope, "w-keys-nosess")
      {doc, with_session} = released_claim!(scope, "w-keys-sess", session: "sess-fixture")

      refute Map.has_key?(sessionless, "session")
      refute Map.has_key?(sessionless, "session_origin")

      # The arm that an enumeration built from a sessionless fixture CANNOT see.
      assert Map.has_key?(with_session, "session") and
               Map.has_key?(with_session, "session_origin"),
             "a session-bearing claim released without its session keys — the pair " <>
               "is written together by SessionId.put_session_origin/2." <>
               keyset_report(doc, with_session)

      extra =
        MapSet.difference(MapSet.new(Map.keys(with_session)), MapSet.new(Map.keys(sessionless)))

      assert MapSet.equal?(extra, MapSet.new(~w(session session_origin))),
             "the session arm differs from the sessionless arm by " <>
               "#{inspect(Enum.sort(MapSet.to_list(extra)))}, expected exactly " <>
               "[\"session\", \"session_origin\"]." <> keyset_report(doc, with_session)
    end
  end
end
