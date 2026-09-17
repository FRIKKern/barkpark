defmodule Barkpark.Tasks.TwinCollapse do
  @moduledoc """
  THE ONE HOME for the *bucket* half of the draft-twin rule: given the rows a
  `group_by` collapsed onto one logical id, which single row IS that id?

  ## Why this is not `Tasks.TwinResolver`

  `Tasks.TwinResolver` answers the neighbouring question — "a caller named this
  doc_id, which physical row do they get?" — and for a tie it REFUSES (rule 3,
  409, naming the datasets). That is right for a by-id door and wrong for a
  snapshot reader: a board or a roster holds every row already and must render
  each logical id exactly once, so it needs a TOTAL order, not a refusal. It is
  also task-only (`type == "task"`), while this collapse is type-agnostic —
  `Tasks.Fleet` runs it over `type == "listener"` rows.

  The two rules also differ on one real bucket, deliberately: a row whose
  `status` is `"published"` but whose spelling carries the `drafts.` prefix wins
  here (rule 1 outranks rule 2) and loses in `TwinResolver.tier/1` (spelling
  first). Unifying them would be a POLICY change to two live surfaces, which is
  exactly what PDS-D748 forbids riding along on a dedup.

  ## The rule (PDS-D409 / task-f7d389c21c68839f — was four verbatim copies)

  *Collapse, published wins*; an UNPAIRED `drafts.<id>` row — no published twin
  — IS the row of record and resolves as ITSELF (rule 1 with its premise
  absent). That carve-out is deliberate, NOT a blanket `drafts.` drop: dropping
  unpaired drafts would make the whole mutate-created population unreadable
  (`Tasks.Dedup` / `Tasks.Queue` / `Tasks.DraftTerminalFence` all rest on it).

  ## Why a tie-break and not `hd/1`

  Every caller reaches here from a `Repo.all |> Enum.group_by` with NO
  `ORDER BY`, so the old `Enum.find(twins, hd(twins), …)` DEFAULT — taken
  whenever the bucket holds no published row — answered by Postgres STORAGE
  ORDER, not by a rule. The Go mirror of this exact shape
  (`internal/taskboard`'s `buildByBare`) was measured live: over 400 builds the
  draft twin won the slot 349 times and the published row 51. Nothing in the
  write path makes a two-unpublished-member bucket impossible, so the order is
  pinned by a RULE instead of by an assumption about the storage:

    1. a `status == "published"` row beats any other,
    2. then a bare id beats a `drafts.`-prefixed one,
    3. then the lexicographically lowest `doc_id`.

  Rules 2-3 are total, so the answer no longer depends on the row order the
  database happens to hand back.
  """

  alias Barkpark.Content.DraftId

  @doc """
  The canonical row of a non-empty twin bucket, by the three rules above.

  The bucket must be non-empty — every caller gets it from `Enum.group_by`,
  which never produces an empty value list, or from a `case [] -> …` arm that
  handles the empty read itself.
  """
  @spec canonical([struct()]) :: struct()
  def canonical([_ | _] = twins), do: Enum.min_by(twins, &collapse_key/1)

  @doc """
  The sort key rule 1-3 impose on one row. Exposed so a test can assert the
  ORDER rather than only a winner.
  """
  @spec collapse_key(struct()) :: {0 | 1, 0 | 1, String.t()}
  def collapse_key(%{status: status, doc_id: doc_id}) do
    {if(status == "published", do: 0, else: 1), if(DraftId.draft?(doc_id), do: 1, else: 0),
     doc_id}
  end
end
