defmodule Barkpark.Tasks.CloseDispositionTest do
  @moduledoc """
  THE CLOSE-SIDE DISPOSITION ADVANCE (task-e91cbd0cceafc44e).

  `bp task close` wrote no adjudication term at all — `git grep -c disposition`
  over `close.ex` returned 0 — so a row staged `open` or `parked` and LATER
  closed kept its pre-close term forever.

  Not hypothetical: a census of 1,320 dispositioned rows found 42 terminal rows
  (lifecycle `done`/`cancelled`) still carrying `open` or `parked`, their
  `disposition_reason` reading "AWAITING MERGE" and "STAYS OPEN" beside a
  `close_reason` describing finished work. Two fields on one row asserting
  opposite things, and every later reader had to guess which.

  RED-WITHOUT / GREEN-WITH: every `advances` test below reads back the pre-close
  term on today's main. The PRESERVATION tests are green on main and must STAY
  green — an advance that also rewrites `disposition_reason`, invents a term on
  an unadjudicated row, or fires on `blocked` has replaced the rule rather than
  implemented it.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"

  # A real artifact — a PR number AND a 7-40 hex sha — so the close-artifact
  # gate (PDS-D291) is satisfied and these tests measure the disposition write
  # rather than tripping an unrelated honesty gate.
  @artifact "landed #14383 @ 63b89bef30 — one envelope reader"
  @reason "AWAITING MERGE — do not re-dispatch until the PR lands"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

  # CLAIMED, because `apply_close_update/9` stamps close attribution onto the
  # claim map and the preservation test asserts that map is untouched by the
  # disposition write. The lease is written into the fixture rather than taken
  # through the claim verb: these tests are about what `close` does to a row in
  # a given state, so the state is stated outright.
  @epoch 1
  @reopen_trigger "the upstream ONIX vendor ships a v3.1 feed"

  defp mk_task!(scope, content_extra) do
    doc_id = uniq("disp")

    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "in_progress",
          "claim" => %{
            "worker" => "worker-disp",
            "epoch" => @epoch,
            "ts_iso" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
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

  defp stored(%Document{id: id}), do: Repo.get!(Document, id)

  defp close!(%Document{} = doc, status) do
    {:ok, _} =
      Tasks.close(doc.id, "worker-disp",
        observed_epoch: @epoch,
        lifecycle_status: status,
        reason: @artifact
      )
  end

  describe "closing a row that carries a disposition" do
    test "advances open -> closed on a DONE close", %{scope: scope} do
      doc = mk_task!(scope, %{"disposition" => "open", "disposition_reason" => @reason})

      close!(doc, "done")

      after_close = stored(doc)
      assert after_close.content["lifecycle_status"] == "done"

      # THE DEFECT: on main this still reads "open", next to a close_reason
      # describing finished work.
      assert after_close.content["disposition"] == "closed"
    end

    test "advances parked -> closed on a CANCELLED close", %{scope: scope} do
      # A row born "parked" MUST carry a reopen_trigger — the birth fence refuses
      # a park that states nothing about what would bring the row back. So the
      # only reachable parked fixture is one that has it, and the close must not
      # destroy it: a cancelled row keeps the record of what would have revived it.
      doc =
        mk_task!(scope, %{
          "disposition" => "parked",
          "disposition_reason" => @reason,
          "reopen_trigger" => @reopen_trigger
        })

      close!(doc, "cancelled")

      after_close = stored(doc)
      assert after_close.content["lifecycle_status"] == "cancelled"
      assert after_close.content["disposition"] == "closed"
      assert after_close.content["reopen_trigger"] == @reopen_trigger
    end
  end

  describe "preservation — only the term moves" do
    test "disposition_reason, close_reason and claim are byte-identical",
         %{scope: scope} do
      doc = mk_task!(scope, %{"disposition" => "open", "disposition_reason" => @reason})
      before = stored(doc)

      close!(doc, "done")
      after_close = stored(doc)

      # The durable WHY somebody wrote by hand survives. A close has no better
      # text for it than the one already there, and `close_reason` carries the
      # close's own sentence — overwriting the reason to match the term would
      # destroy the more informative of the two.
      assert after_close.content["disposition_reason"] == before.content["disposition_reason"]
      assert after_close.content["disposition_reason"] == @reason

      # close_reason is written by the close itself, so assert it holds the
      # close's reason and was not disturbed by the disposition write.
      assert after_close.content["close_reason"] == @artifact

      # The claim gains only its close attribution; nothing else in it moves.
      assert after_close.content["claim"]["worker"] == before.content["claim"]["worker"]
      assert after_close.content["claim"]["epoch"] == before.content["claim"]["epoch"]
      assert after_close.content["claim"]["ts_iso"] == before.content["claim"]["ts_iso"]
      assert after_close.content["claim"]["closed_by"] == "worker-disp"

      # NON-VACUITY: the fixture really did store a pre-close term, so the
      # advance above is measuring something.
      assert before.content["disposition"] == "open"
    end

    test "a row with NO disposition is not GIVEN one by being closed",
         %{scope: scope} do
      # Birth adjudication is `ensure_disposition_via_verb`'s business.
      # Inventing a term here would manufacture an adjudication nobody made.
      doc = mk_task!(scope, %{})
      refute Map.has_key?(stored(doc).content, "disposition")

      close!(doc, "done")

      after_close = stored(doc)
      assert after_close.content["lifecycle_status"] == "done"
      refute Map.has_key?(after_close.content, "disposition")
    end

    test "a BLOCKED close leaves the disposition alone", %{scope: scope} do
      # `blocked` is an honest partial — the row is still live work, so its
      # adjudication is not the close's to advance.
      doc = mk_task!(scope, %{"disposition" => "open", "disposition_reason" => @reason})

      close!(doc, "blocked")

      after_close = stored(doc)
      assert after_close.content["lifecycle_status"] == "blocked"
      assert after_close.content["disposition"] == "open"
    end
  end
end
