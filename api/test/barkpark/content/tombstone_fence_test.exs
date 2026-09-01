defmodule Barkpark.Content.TombstoneFenceTest do
  @moduledoc """
  cch-w39-bl — "the disposal path can no longer report a cancel it did not land".

  A DISPOSAL REASON IS A CLAIM, NOT A MEASUREMENT. `close_reason` is written once
  and re-read by nobody, so nothing can ever contradict it — the property this
  codebase refuses in a guard. One disposal loop produced two live specimens, in
  OPPOSITE directions:

    * `cch-w36-bl-mecache-unknown-arms-remaining` — a cancel aimed at a `drafts.`
      twin that never existed landed its reason on the PUBLISHED ROW OF RECORD
      and killed it. The tombstone read "The published row is the one of record
      and is NOT touched here", written onto the row it killed.
    * `cch-w36-s6-invalid-precedence-details-win` — the reason landed and the
      CLOSE DID NOT: `lifecycle_status` stayed `in_progress`.

  The fence: a `close_reason` may be MINTED only by a write that also lands a
  terminal `lifecycle_status`, so the reason and the close are ONE atomic fact.

  Every arm is written to FAIL for a stated reason, and the PERMIT arms are as
  load-bearing as the refusals — a fence that also forbids the sanctioned close,
  or forbids CORRECTING a false tombstone, has broken the repair this row exists
  to enable.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"

  setup do
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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # An UPDATE through the same door a disposal loop uses. `upsert_document` is
  # where the fence is wired, beside its transition/birth siblings.
  defp write(doc_id, content, scope) do
    Content.upsert_document(
      "task",
      %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
      @dataset,
      scope
    )
  end

  defp content_of(doc_id, scope) do
    {:ok, doc} = Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)
    doc.content
  end

  # ── REFUSAL ARM ONE: a reason with no close landing ────────────────────────

  describe "minting a tombstone on a row this write does not close" do
    test "a close_reason patched onto an OPEN row is REFUSED, and nothing is written",
         %{scope: scope} do
      id = uniq("tomb-open")
      _ = mk_task!(id, scope)

      assert {:error, {:invalid_task_content, %{"close_reason" => [message]}}} =
               write(
                 id,
                 %{
                   "kind" => "task",
                   "lifecycle_status" => "open",
                   "close_reason" =>
                     "DUPLICATE PHANTOM — cancelled by a loop that never closed it"
                 },
                 scope
               )

      # The message must TEACH, not merely refuse: name the state, the rule and
      # the sanctioned verb. A refusal a reader cannot act on sends them to the
      # wrong instrument.
      assert message =~ "may not be minted on a row this write does not close"
      assert message =~ ~s(lifecycle_status "open")
      assert message =~ "bp task close"
      assert message =~ "epitaph on a living row"

      # THE ROW IS UNTOUCHED. A fence that refuses after writing has not fenced.
      refute Map.has_key?(content_of(id, scope), "close_reason")
      assert content_of(id, scope)["lifecycle_status"] == "open"
    end

    test "a LIVE CLAIMED row is refused too — cch-w36-s6's exact shape", %{scope: scope} do
      # `open -> in_progress` is illegal for ANY document write (the claim
      # primitive owns it), so the only way to stand where cch-w36-s6 stood is to
      # claim the row for real and then patch a reason at in_progress ->
      # in_progress, which is a legal same->same no-op. A live claimed row
      # wearing an epitaph is precisely what that specimen was.
      id = uniq("tomb-inprog")
      task = mk_task!(id, scope)
      {:ok, _} = Tasks.claim_by_id(task.doc_id, "worker-tomb", scope)

      assert {:error, {:invalid_task_content, %{"close_reason" => [message]}}} =
               write(
                 id,
                 %{
                   "kind" => "task",
                   "lifecycle_status" => "in_progress",
                   "close_reason" => "the reason landed and the close did not"
                 },
                 scope
               )

      assert message =~ ~s(lifecycle_status "in_progress")
      refute Map.has_key?(content_of(id, scope), "close_reason")
    end

    test "a task BORN carrying a tombstone it never earned is refused", %{scope: scope} do
      id = uniq("tomb-birth")

      assert {:error, {:invalid_task_content, %{"close_reason" => [_message]}}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => id,
                   "title" => id,
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "close_reason" => "born with an epitaph"
                   }
                 },
                 @dataset,
                 scope
               )
    end

    test "a BLANK reason is not a value, in either direction", %{scope: scope} do
      id = uniq("tomb-blank")
      _ = mk_task!(id, scope)

      # Blank does not trip the fence — there is no tombstone here to police.
      assert {:ok, _} =
               write(
                 id,
                 %{"kind" => "task", "lifecycle_status" => "open", "close_reason" => "   "},
                 scope
               )

      # And it does not COUNT as a previous reason: the next real mint is still
      # a mint, not a "correction". Without this, writing "" and then the
      # tombstone would walk straight through the correction arm.
      assert {:error, {:invalid_task_content, %{"close_reason" => [_]}}} =
               write(
                 id,
                 %{"kind" => "task", "lifecycle_status" => "open", "close_reason" => "real"},
                 scope
               )
    end
  end

  # ── PERMIT ARMS: the fence must not break the sanctioned paths ─────────────

  describe "what the fence must NOT refuse" do
    test "a reason minted TOGETHER with a terminal status lands", %{scope: scope} do
      id = uniq("tomb-together")
      _ = mk_task!(id, scope)

      assert {:ok, _} =
               write(
                 id,
                 %{
                   "kind" => "task",
                   "lifecycle_status" => "cancelled",
                   "close_reason" => "cancelled into its survivor, with receipts"
                 },
                 scope
               )

      assert content_of(id, scope)["close_reason"] =~ "with receipts"
    end

    test "CORRECTING an existing tombstone stays legal on a REOPENED row", %{scope: scope} do
      # cch-w36-bl's own repair path: the row was cancelled, found to have been
      # killed by a cancel aimed at a phantom, REOPENED, and its false tombstone
      # corrected in place. A fence that forbade this would forbid the one action
      # that makes the error auditable.
      id = uniq("tomb-correct")
      _ = mk_task!(id, scope)

      {:ok, _} =
        write(
          id,
          %{
            "kind" => "task",
            "lifecycle_status" => "cancelled",
            "close_reason" => "DUPLICATE PHANTOM — a drafts. twin"
          },
          scope
        )

      assert {:ok, _} =
               write(
                 id,
                 %{
                   "kind" => "task",
                   "lifecycle_status" => "open",
                   "close_reason" => "CORRECTED — no drafts. twin ever existed; reopened"
                 },
                 scope
               )

      assert content_of(id, scope)["close_reason"] =~ "CORRECTED"
      assert content_of(id, scope)["lifecycle_status"] == "open"
    end

    test "a patch carrying the SAME reason through is not a re-mint", %{scope: scope} do
      id = uniq("tomb-carry")
      _ = mk_task!(id, scope)
      reason = "cancelled as a duplicate"

      {:ok, _} =
        write(
          id,
          %{"kind" => "task", "lifecycle_status" => "cancelled", "close_reason" => reason},
          scope
        )

      # The shape every merge-then-validate patch produces. It must pass, or the
      # fence is RETROACTIVE on every future write to an already-tombstoned row.
      assert {:ok, _} =
               write(
                 id,
                 %{"kind" => "task", "lifecycle_status" => "open", "close_reason" => reason},
                 scope
               )
    end

    test "a row with no close_reason at all is untouched by the fence", %{scope: scope} do
      id = uniq("tomb-none")
      _ = mk_task!(id, scope)

      assert {:ok, _} = write(id, %{"kind" => "task", "lifecycle_status" => "considering"}, scope)
    end
  end

  # ── REFUSAL ARM TWO: the close primitive's own two directions ──────────────

  describe "the close primitive itself" do
    test "a CAS-FAILED close leaves NO reason behind", %{scope: scope} do
      id = uniq("tomb-cas")
      task = mk_task!(id, scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-tomb", scope)

      import Ecto.Query
      bumped = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      {1, _} =
        from(d in Document, where: d.id == ^task.id) |> Repo.update_all(set: [rev: bumped])

      assert {:error, :stale_claim} =
               Tasks.close(task.id, "worker-tomb",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 observed_rev: claimed.rev,
                 lifecycle_status: "cancelled",
                 reason: "a reason that must not survive its own failed close"
               )

      # THE POINT: the reason is not on the row, and the row is not closed. The
      # close writes both inside ONE transaction, so a lost CAS rolls back both.
      after_close = content_of(id, scope)
      refute Map.has_key?(after_close, "close_reason")
      refute after_close["lifecycle_status"] in ~w(done cancelled blocked)
    end

    test "a cancel aimed at an id that does not resolve FAILS LOUDLY, both shapes" do
      # BEFORE THE CAST GUARD the first of these did not refuse — it RAISED
      # Ecto.Query.CastError from inside the transaction, because Document's PK
      # is a :binary_id and a slug cannot be dumped to it. A 500 is not a loud
      # failure: it sends the reader looking for an outage instead of re-reading
      # the id they typed. A malformed id and an absent id are the same fact —
      # there is no such document — so both must reach the same refusal.
      malformed = uniq("tomb-no-such-row")
      absent = Ecto.UUID.generate()

      for ghost <- [malformed, absent] do
        result =
          Tasks.close(ghost, "worker-tomb",
            observed_epoch: 1,
            lifecycle_status: "cancelled",
            reason: "a tombstone for a document that does not exist"
          )

        assert result == {:error, :not_found},
               "expected #{inspect(ghost)} to refuse with :not_found, got #{inspect(result)}"
      end
    end
  end

  # ── THE CROSS-MODULE TRIPWIRE ──────────────────────────────────────────────

  describe "the fence's terminal set" do
    test "matches Barkpark.Tasks.Close's own, read from its bytes" do
      # A module attribute cannot be read across modules, so the fence carries a
      # COPY of what "closed" means. This reads both files' own source and reds
      # if either list moves without the other: a fence keyed on a stale copy
      # would let a mint through on whichever status the two disagree about.
      root = Path.join([__DIR__, "..", "..", ".."])
      close_src = File.read!(Path.join(root, "lib/barkpark/tasks/close.ex"))
      writer_src = File.read!(Path.join(root, "lib/barkpark/content/writer.ex"))

      close_match = Regex.run(~r/@closed_lifecycle_statuses\s+~w\(([^)]+)\)/, close_src)
      assert close_match, "no @closed_lifecycle_statuses in close.ex — re-aim this tripwire"

      writer_match = Regex.run(~r/@terminal_lifecycle_statuses\s+~w\(([^)]+)\)/, writer_src)
      assert writer_match, "no @terminal_lifecycle_statuses in writer.ex — re-aim this tripwire"

      [_, close_list] = close_match
      [_, writer_list] = writer_match

      assert String.split(close_list) == String.split(writer_list),
             "the tombstone fence's terminal set #{inspect(String.split(writer_list))} has " <>
               "drifted from Close's #{inspect(String.split(close_list))} — a close status the " <>
               "fence does not know about is a status a tombstone can be minted on"
    end
  end
end
