defmodule BarkparkWeb.Studio.StudioLive.SharedNonWallRejectionTest do
  @moduledoc """
  `ae-nonwall-rejection-render` — the four real NON-WALL `{:error, reason}`
  shapes that reach `Shared.do_action/3` each render their own reason, instead
  of the content-free "Action failed".

  Wave-11's census (charter D83a) proved these four are the whole set beyond the
  wall tuples. Every fixture below is taken from the EMITTER, not invented:

    1. `{:error, :not_found}` — `lifecycle.ex:96-97`, the TOCTOU where the draft
       is gone (discarded, or published from another tab).
    2. `{:error, {:rev_mismatch, %{expected:, actual:}}}` — `mutations.ex:151`,
       `lifecycle.ex:149`. The autosave / second-tab race.
    3. `{:error, {:invalid_task_content, %{field => [msg]}}}` —
       `lifecycle.ex:349/352/365`, `mutations.ex:451/565/…`. Each `msg` is
       pre-built human prose. NOTE the row's brief says the key is
       "lifecycle_status"; the emitters also use "claim" and
       "acceptance_criteria", so the render must not key on one field name.
    4. A raw `%Ecto.Changeset{}` — `Repo.rollback(cs)` at `lifecycle.ex:184-185`.

  A REFUTED fifth: plugin exceptions cannot reach `do_action` — `Hooks.fire`
  coerces a raising `before_*` hook to `:ok`.

  The `:boom -> "Action failed"` catch-all stays, and is pinned in
  `SharedPublishWallTest`; it is re-pinned here so the four insertions are known
  not to have swallowed it.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        editor_doc: %{doc_id: "p1"},
        editor_type: "paper"
      }
    }
  end

  defp flash_for(reason, msg \\ "Published") do
    {:noreply, socket} = Shared.do_action(socket(), fn _doc, _type -> reason end, msg)
    Phoenix.Flash.get(socket.assigns.flash, :error)
  end

  describe "1. {:error, :not_found} — the TOCTOU" do
    test "names the vanished document and the tab that took it, not 'Action failed'" do
      flash = flash_for({:error, :not_found})

      refute flash == "Action failed"
      assert flash =~ "no longer there"
      assert flash =~ "discarded"
      assert flash =~ "another tab"
    end

    test "the verb tracks the action — unpublish says 'unpublished'" do
      assert flash_for({:error, :not_found}, "Unpublished") =~
               "already unpublished in another tab"

      assert flash_for({:error, :not_found}, "Published") =~ "already published in another tab"
    end
  end

  describe "2. {:error, {:rev_mismatch, …}} — the autosave race" do
    # VERBATIM emitter fixture — `Content.Mutations` (mutations.ex:151) emits
    # `%{expected: expected, actual: doc.rev}`.
    test "asks for a reload and spends no words on the opaque revs" do
      flash = flash_for({:error, {:rev_mismatch, %{expected: "rev-a", actual: "rev-b"}}})

      refute flash == "Action failed"
      assert flash =~ "changed since you loaded it"
      assert flash =~ "reload and retry"
    end

    test "the `actual: nil` variant renders the same, not a crash" do
      # `mutations.ex:1006` emits `%{expected: expected, actual: nil}` for a doc
      # that vanished under an ifRevisionID fence.
      flash = flash_for({:error, {:rev_mismatch, %{expected: "rev-a", actual: nil}}})

      assert flash =~ "changed since you loaded it"
    end
  end

  describe "3. {:error, {:invalid_task_content, …}} — the task lifecycle gate" do
    # VERBATIM emitter fixture — `Content.Lifecycle.publish_transition_error/2`
    # (lifecycle.ex:452-459).
    test "renders the emitter's own prose for an illegal lifecycle transition" do
      msg =
        "illegal lifecycle transition \"done\" → \"open\": publishing this draft would " <>
          "rewrite the published row's lifecycle — reopen it with `bp task stage`"

      flash = flash_for({:error, {:invalid_task_content, %{"lifecycle_status" => [msg]}}})

      refute flash == "Action failed"
      assert flash =~ "lifecycle_status"
      assert flash =~ "illegal lifecycle transition"
      assert flash =~ "bp task stage"
    end

    # THE FIELD IS NOT ALWAYS "lifecycle_status". `stale_claim_error/1`
    # (lifecycle.ex:461) keys on "claim" and `criteria_regression_error/1`
    # (lifecycle.ex:479) on "acceptance_criteria". A render that pattern-matched
    # the one field name in the row's brief would drop these two on the floor.
    test "renders the OTHER two fields the same family emits" do
      claim = flash_for({:error, {:invalid_task_content, %{"claim" => ["stale draft: …"]}}})
      assert claim =~ "claim: stale draft"
      refute claim == "Action failed"

      criteria =
        flash_for(
          {:error, {:invalid_task_content, %{"acceptance_criteria" => ["stale draft: …"]}}}
        )

      assert criteria =~ "acceptance_criteria: stale draft"
      refute criteria == "Action failed"
    end

    test "a multi-field rejection names every field, bounded" do
      errors = Map.new(1..7, fn i -> {"field#{i}", ["msg#{i}"]} end)
      flash = flash_for({:error, {:invalid_task_content, errors}})

      assert flash =~ "field1: msg1"
      assert flash =~ "(+3 more)"
      # Bounded: the 5th..7th are summarised, not rendered.
      refute flash =~ "field7: msg7"
    end
  end

  describe "4. a raw %Ecto.Changeset{} — and the leak it must not become" do
    defp changeset_with_secret do
      # `:data` carries the WHOLE document. This is the field that must never
      # reach the flash — `format_wall_details/1` would `inspect/1` it.
      data = %{
        __struct__: Barkpark.Content.Document,
        doc_id: "p1",
        content: %{"secret" => "SENTINEL-DO-NOT-LEAK", "blocks" => [%{"text" => "body"}]}
      }

      %Ecto.Changeset{
        data: data,
        types: %{doc_id: :string},
        valid?: false,
        errors: [doc_id: {"has already been taken", [constraint: :unique]}]
      }
    end

    test "renders the constraint error, not 'Action failed'" do
      flash = flash_for({:error, changeset_with_secret()})

      refute flash == "Action failed"
      assert flash =~ "doc_id"
      assert flash =~ "has already been taken"
    end

    test "NO struct internals reach the flash — this is the whole point of the branch" do
      flash = flash_for({:error, changeset_with_secret()})

      refute flash =~ "SENTINEL-DO-NOT-LEAK"
      refute flash =~ "Ecto.Changeset"
      refute flash =~ "Barkpark.Content.Document"
      refute flash =~ "blocks"
      refute flash =~ "%{"
    end

    # PREMISE CORRECTION on the row's own words. It says routing a changeset
    # through `format_wall_details/1` would "dump full document struct internals
    # — a real leak". MEASURED: it never gets that far. `%{} = detail` DOES match
    # a changeset (a struct is a map), but the very first thing the clause does
    # is `detail[key]`, and `Ecto.Changeset` does not implement Access — so it
    # RAISES, killing the LiveView process and taking the author's unsaved editor
    # state with it on the reconnect.
    #
    # The dedicated branch is therefore MORE load-bearing than the row argues,
    # not less: the generic clause's failure mode is a crash, which is worse than
    # the leak it was feared for. Neither is live today (the changeset lands on
    # `{:error, _}`), so this pins what a future "just send it through
    # format_wall_details" edit would actually cost.
    test "format_wall_details/1 RAISES on a changeset — it is not a viable render path" do
      assert_raise UndefinedFunctionError, ~r/Ecto\.Changeset.*Access/s, fn ->
        Shared.format_wall_details(changeset_with_secret())
      end
    end

    test "and its generic map clause DOES leak whatever reaches it — hence a dedicated branch" do
      # The same shape minus the Access problem: any map with no field/rule/fix
      # falls to `inspect/1` verbatim. This is why the changeset gets its own
      # clause instead of being made Access-friendly and passed through.
      leaked =
        Shared.format_wall_details(%{
          doc_id: "p1",
          content: %{"secret" => "SENTINEL-DO-NOT-LEAK"}
        })

      assert leaked =~ "SENTINEL-DO-NOT-LEAK"
    end

    test "message placeholders are interpolated, and a non-scalar option is summarised" do
      changeset = %Ecto.Changeset{
        data: %{},
        types: %{},
        valid?: false,
        errors: [
          title: {"should be at most %{count} character(s)", [count: 12, validation: :length]},
          kind: {"is invalid", [validation: :inclusion, enum: ["a", "b"]]}
        ]
      }

      flash = flash_for({:error, changeset})

      assert flash =~ "should be at most 12 character(s)"
      assert flash =~ "is invalid"
      refute flash =~ "%{count}"
    end
  end

  describe "the residual catch-all" do
    test ":boom still reads exactly 'Action failed' — the four insertions did not swallow it" do
      assert flash_for({:error, :boom}) == "Action failed"
    end

    test "an unrecognised tagged shape still falls through to it" do
      assert flash_for({:error, {:some_future_shape, %{a: 1}}}) == "Action failed"
    end
  end
end
