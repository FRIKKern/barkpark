defmodule Barkpark.Plugins.Github.Adopt do
  @moduledoc """
  ADOPTION — an operator flips a born-dark `gh-<num>` intake task INTO Barkpark
  ownership (epic charter Wave 4, D5/D6/D4-cut-#2).

  Wave 3 births an outsider's GitHub Issue as a task `gh-<num>` labelled
  `src:github` + `needs-human`, `content.github.state = "intake"`, UNCLAIMED. It
  sits in a holding pen until a maintainer decides it is real work. `adopt/3` is
  that explicit decision — one `bp github adopt <task>` (or a Studio button):

    1. **Strip the gate.** Remove `"needs-human"` from `content.labels`; KEEP
       `"src:github"` (provenance is permanent — the task was born from an issue).
    2. **Flip ownership.** `content.github.state` `"intake" → "adopted"`. From here
       the task is a first-class Barkpark task the outbound MirrorJob will mirror.
    3. **Backlink.** Best-effort "Tracked as gh-<num> on the Barkpark board."
       comment on the source issue, so the outsider sees it was picked up.

  ## Idempotent + gated (D6)

  Only a task whose `content.github.state == "intake"` is adoptable. A second
  adopt of an already-`"adopted"` task is a `{:ok, doc}` NO-OP (no re-flip, no
  duplicate backlink) — so the CLI verb and the Studio button are safe to hit
  twice. Any OTHER state (`nil`, `"synced"`, `"detached"`, …) → `{:error,
  :not_intake}`: a plain task, a mirrored task, or a detached one is not an
  intake awaiting adoption. A missing task → `{:error, :not_found}`.

  We chose `{:ok, doc}` for the already-adopted re-hit (over `{:error,
  :not_intake}`) so the operator surface is idempotent: re-running `adopt` on a
  task you already adopted succeeds quietly instead of erroring, and the button
  a stale Studio session still renders never dead-ends. The backlink and the
  ledger write fire ONLY on the genuine `intake → adopted` flip.

  ## What adoption NEVER does (D6)

  Adoption flips ownership + clears the `needs-human` gate ONLY. It NEVER sets a
  claim/worker/epoch/fence — those NEVER leave Barkpark, and an adopted task is
  UNCLAIMED. A human or agent claims it afterward through the normal `bp task`
  path. Adoption also never reads a GitHub field value back into a task (D5):
  the only writes are the ledger-owned label strip + the `github.state` bump.

  ## Loop cut (D4 cut #2)

  The adopt write's `mutation_events` row is stamped EXACTLY `"github"`, which
  the wave-1 outbox reader (`source != "github"`) EXCLUDES — the adopt write can
  never echo back out as an outbound mirror.

  ## The flip never forks a twin (task-184760672ff3414b)

  `Content.upsert_document/4` ALWAYS writes the draft row (it forces the id to
  `drafts.<id>` and coerces `status -> draft`). The flip used to go through it
  unconditionally and then collapse the fresh draft back into the published row
  with `Content.publish_document/4`. That collapse is REFUSABLE — the publish
  door's claim fence (`Content.Lifecycle.stale_claim?/2`) compares the whole
  claim map and `Tasks.Renew` moves it every ~90 s — so on a claimed task the
  collapse was refused and the adopt left a permanent `drafts.<id>` twin beside
  the published row. That is the same fork `Link.put/4` (`MirrorJob.stamp`) was
  measured making eight times in 45 minutes (task-aa8f25be2c04d391, repaired in
  PR #16479).

  `adopt/3` is now PUBLISHED-FIRST, the rule
  `Content.Mutations.@published_first_patch_types` already applies to the `patch`
  door for type `task`: when a published row exists, the label strip and the
  `github.state` bump are applied to THAT row's content through
  `Tasks.Internal.fenced_content_write/4` — the rev-fenced `UPDATE … RETURNING`
  every task verb (claim/pulse/stamp/close) writes through. The published row is
  the MERGE BASE as well as the target, so `content.claim`, the acceptance
  criteria and everything else it carries survive byte for byte (a draft-based
  merge onto the published row is exactly the erasure
  `link_put_erasure_test.exs` forbids); it cannot draft-prefix; and there is no
  publish to refuse. The write still carries `source: "github"`, so the Outbox
  still excludes it (loop cut #2).

  A never-published intake is LEFT a draft — adoption clears the gate and flips
  ownership, it never force-publishes under a human (D6). A pre-existing twin
  beside a published row is NAMED at error level and left alone: publishing a
  twin whose provenance is unknown can destroy live published state.

  ## Injected seams (Intake precedent — no network in tests)

    * `:comment_fun` — default `&Client.create_comment/4`; `(repo, number, body,
      opts)` in. Best-effort: a failed or raising comment is LOGGED and
      swallowed — a flaky GitHub comment API must never fail an adoption that
      already durably flipped the ledger.
    * every other `opts` key (`:workspace_id`/`:project_id`/`:user_id`) threads
      straight through to the Content read + write path for tenant scoping.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Client, Link, Settings}
  alias Barkpark.Tasks.Internal

  @task_type "task"
  @gate_label "needs-human"
  @content_key "github"

  @typedoc """
  Adopt outcome:

    * `{:ok, %Document{}}`   — the task was adopted (a genuine `intake → adopted`
      flip, backlink attempted) OR was already `"adopted"` (idempotent no-op)
    * `{:error, {:adopt_refused, detail}}` — the published row moved under the
      fenced write (`detail.gate == "rev_fence"`). NOTHING was committed — no
      ledger write, no backlink — so an error here does not lie, and the caller
      re-reads and retries. Reported LOUDLY (error log + telemetry), never
      swallowed into a bare `{:ok, doc}`.
    * `{:error, :not_intake}` — the task exists but is not an adoptable intake
    * `{:error, :not_found}`  — no such task
    * `{:error, term()}`      — the ledger write failed

  The old `{:ok, %Document{}, %{published: false, error: …}}` third element
  (authoring-excellence D23: a refused draft-twin collapse AFTER the adopt had
  committed, where a 422 would have lied) can no longer occur — there is no
  collapse. Consumers keep their 3-tuple clause as a harmless total match.
  """
  @type result ::
          {:ok, Document.t()}
          | {:error, :not_intake | :not_found | {:adopt_refused, map()} | term()}

  @doc """
  Adopt an intake task into Barkpark. See the moduledoc for the gate, the
  idempotency choice, and the loop cut. `doc_id` is the `gh-<num>` task id
  (draft- or published-form both accepted); `dataset` is the task's dataset.
  """
  # @canonical capability:github-adopt aka:adopt,claim-issue,flip-ownership doc:.claude/workflows/bp-github-bridge-epic-charter.md
  @spec adopt(String.t(), String.t(), keyword()) :: result()
  def adopt(doc_id, dataset, opts \\ [])
      when is_binary(doc_id) and is_binary(dataset) do
    case load_task(doc_id, dataset, opts) do
      nil ->
        {:error, :not_found}

      %Document{} = task ->
        case github_state(task) do
          "intake" -> flip(task, dataset, opts)
          "adopted" -> {:ok, task}
          _ -> {:error, :not_intake}
        end
    end
  end

  # ── the genuine intake → adopted flip ──────────────────────────────────────

  # PUBLISHED-FIRST. When a published row exists it is BOTH the write target and
  # the merge base (see the moduledoc): the two adoption edits ride the
  # rev-fenced task-write primitive, so no draft twin is minted and nothing else
  # the row carries moves. Only a never-published intake takes the draft upsert.
  defp flip(task, dataset, opts) do
    pid = Content.published_id(task.doc_id)

    case Content.get_document(pid, @task_type, dataset, opts) do
      {:ok, %Document{} = published} -> adopt_published(published, dataset, opts)
      _ -> flip_on_draft(task, pid, dataset, opts)
    end
  end

  @doc """
  The PUBLISHED-FIRST arm of `adopt/3`, for a caller that already holds the
  published row. The write target IS that row, so it goes through the rev-fenced
  `Tasks.Internal.fenced_content_write/4` rather than `Content.upsert_document/4`
  (which always draft-prefixes). Only `content.labels` and `content.github` move;
  the claim, the acceptance criteria and the lifecycle the row carries are
  preserved verbatim, and there is no publish door to refuse.

  `published` is the row the write is FENCED on: a struct read before someone
  else moved the row yields `{:error, {:adopt_refused, %{gate: "rev_fence"}}}`
  with nothing committed.
  """
  @spec adopt_published(Document.t(), String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def adopt_published(%Document{} = published, dataset, opts \\ []) do
    pid = Content.published_id(published.doc_id)
    report_draft_twin(pid, dataset, opts)

    github = Link.get(published) || %{}
    content = published.content || %{}

    new_content =
      content
      |> Map.put("labels", strip_gate(Map.get(content, "labels")))
      |> Map.put(@content_key, Map.put(github, "state", "adopted"))

    observed_rev = published.rev
    new_rev = Internal.generate_rev()

    case Internal.fenced_content_write(published, observed_rev, new_content, new_rev) do
      {:ok, %Document{} = stored} ->
        # Same event contract as the old upsert path: stamped `source: "github"`,
        # so `Outbox.fetch/3` excludes it and the adopt write can never echo back
        # out as an outbound mirror (loop cut #2).
        ev = Internal.insert_mutation_event!(stored, "update", observed_rev, "github")

        Content.broadcast_document_mutation(stored, "update",
          event_id: ev.id,
          previous_rev: observed_rev
        )

        maybe_backlink(github, opts)
        {:ok, stored}

      :stale ->
        detail = %{doc_id: pid, gate: "rev_fence", observed_rev: observed_rev}
        report_anomaly(detail)
        {:error, {:adopt_refused, detail}}
    end
  end

  # NEVER-PUBLISHED arm — byte for byte the pre-existing behaviour minus the
  # collapse: the flip lands on the draft row and the task is LEFT a draft.
  # Adoption clears the `needs-human` gate and flips ownership; publishing is a
  # human authoring act, so adoption never force-publishes under an operator
  # (D6, and the same arm `Link.put/4` kept in #16479).
  defp flip_on_draft(task, pid, dataset, opts) do
    github = Link.get(task) || %{}
    content = task.content || %{}

    new_content =
      content
      |> Map.put("labels", strip_gate(Map.get(content, "labels")))
      |> Map.put(@content_key, Map.put(github, "state", "adopted"))

    attrs = %{
      "doc_id" => pid,
      "title" => task.title,
      "content" => new_content
    }

    source_opts = Keyword.put_new(opts, :source, :github)

    with {:ok, upserted} <-
           Content.upsert_document(@task_type, attrs, dataset, source_opts) do
      maybe_backlink(github, opts)
      {:ok, upserted}
    end
  end

  # Drop the `needs-human` gate label, KEEP everything else (notably
  # `src:github` — provenance is permanent). A nil/absent label list yields an
  # empty list (the task is adopted regardless of how it was labelled).
  defp strip_gate(labels) when is_list(labels), do: Enum.reject(labels, &(&1 == @gate_label))
  defp strip_gate(_), do: []

  # A twin beside the published row is a FORK someone else minted (this module
  # can no longer make one). The flip lands on the published row — the row every
  # task reader serves — and the twin is NAMED, never silently published over:
  # a twin whose provenance is unknown may hold state the published row does not.
  defp report_draft_twin(pid, dataset, opts) do
    case Content.get_document(Content.draft_id(pid), @task_type, dataset, opts) do
      {:ok, %Document{doc_id: twin_id}} ->
        report_anomaly(%{doc_id: pid, gate: "draft_twin_present", twin: twin_id})

      _ ->
        :ok
    end
  end

  # LOUD, always: error level with the doc_id and the refusing/tripped gate, plus
  # a telemetry count. The predecessor logged a warning on a refused collapse and
  # still returned `{:ok, …}`, so a refusal raised nothing an operator saw.
  defp report_anomaly(%{doc_id: doc_id, gate: gate} = detail) do
    Logger.error("github adopt: flip for #{doc_id} hit #{gate}: #{inspect(detail)}")

    :telemetry.execute([:barkpark, :github, :adopt, :write_anomaly], %{count: 1}, %{
      doc_id: doc_id,
      gate: gate
    })

    :ok
  end

  # ── best-effort backlink ────────────────────────────────────────────────────

  # Post the "tracked on the board" backlink on a genuine adoption only (never on
  # the idempotent no-op). Best-effort: a nil repo or missing issue number skips
  # silently; a failed or raising comment is logged and swallowed so the durably
  # flipped ledger is never undone by a flaky GitHub comment API.
  defp maybe_backlink(github, opts) do
    repo = Map.get(github, "repo") || Keyword.get(opts, :repo) || Settings.repo()
    number = Map.get(github, "issue")
    comment_fun = Keyword.get(opts, :comment_fun, &Client.create_comment/4)

    cond do
      not is_binary(repo) ->
        Logger.debug("github adopt: no repo configured, skipping backlink comment")
        :ok

      is_nil(number) ->
        Logger.debug("github adopt: no issue number on link, skipping backlink comment")
        :ok

      true ->
        post_comment(comment_fun, repo, number, opts)
    end
  end

  defp post_comment(comment_fun, repo, number, opts) do
    body = "Tracked as gh-#{number} on the Barkpark board."

    case comment_fun.(repo, number, body, opts) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("github adopt: backlink comment on ##{number} failed: #{inspect(other)}")

        :ok
    end
  rescue
    e ->
      Logger.warning("github adopt: backlink comment on ##{number} raised: #{inspect(e)}")

      :ok
  end

  # ── task load (draft-first, mirror of MirrorJob.load_task) ──────────────────

  # Load the task DRAFT-FIRST: the write target is always the draft row, so
  # bookkeeping lives on the draft (a mirrored/adopted task's `content.github`
  # rides the draft). Fall back to the published perspective. `doc_id` is
  # normalised to its published form so the write path and the backlink read the
  # same id whether the caller passed `gh-10` or `drafts.gh-10`.
  defp load_task(doc_id, dataset, opts) do
    published = Content.published_id(doc_id)

    doc =
      case Content.get_document(Content.draft_id(published), @task_type, dataset, opts) do
        {:ok, %Document{} = d} -> d
        _ -> unwrap(Content.get_document(published, @task_type, dataset, opts))
      end

    case doc do
      %Document{} = d -> %{d | doc_id: published}
      _ -> nil
    end
  end

  defp unwrap({:ok, %Document{} = d}), do: d
  defp unwrap(_), do: nil

  # Read `content.github.state` off a task, string- and atom-key safe. Absent →
  # nil (a plain task, not an intake).
  defp github_state(task) do
    case Link.get(task) do
      m when is_map(m) -> Map.get(m, "state") || Map.get(m, :state)
      _ -> nil
    end
  end
end
