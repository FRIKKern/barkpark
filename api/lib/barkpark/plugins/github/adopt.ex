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

  The content write persists via `Content.upsert_document(source: :github)`, so
  its `mutation_events` row is stamped EXACTLY `"github"` (`to_string(:github)`),
  which the wave-1 outbox reader (`source != "github"`) EXCLUDES — the adopt
  write can never echo back out as an outbound mirror. If the task was already
  PUBLISHED, the draft twin the upsert writes is collapsed back into the
  published row via `Content.publish_document(source: :github)` — same stamp,
  also outbox-excluded (the `Link.put` D12 pattern). A never-published task is
  LEFT a draft (adoption never force-publishes under a human).

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

  @task_type "task"
  @gate_label "needs-human"
  @content_key "github"

  @typedoc """
  Adopt outcome:

    * `{:ok, %Document{}}`   — the task was adopted (a genuine `intake → adopted`
      flip, backlink attempted) OR was already `"adopted"` (idempotent no-op)
    * `{:ok, %Document{}, collapse}` — adopted, but the draft-twin collapse
      publish (D12) was REJECTED (e.g. the published task carries an
      unregistered weighted tag the authoring wall now blocks). The adopt side
      effects are already committed — a 422 here would lie — so this stays an
      `:ok`, carrying `collapse = %{published: false, error: <wall detail>}` so
      the caller can surface + retry (authoring-excellence D23). The label strip
      + state flip landed on the DRAFT; the published perspective is unchanged.
    * `{:error, :not_intake}` — the task exists but is not an adoptable intake
    * `{:error, :not_found}`  — no such task
    * `{:error, term()}`      — the ledger write failed
  """
  @type result ::
          {:ok, Document.t()}
          | {:ok, Document.t(), %{published: false, error: map()}}
          | {:error, :not_intake | :not_found | term()}

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

  defp flip(task, dataset, opts) do
    github = Link.get(task) || %{}
    content = task.content || %{}

    new_content =
      content
      |> Map.put("labels", strip_gate(Map.get(content, "labels")))
      |> Map.put(@content_key, Map.put(github, "state", "adopted"))

    pid = Content.published_id(task.doc_id)

    # Capture the published perspective BEFORE the upsert writes its draft twin,
    # so a never-published intake is never force-published under the operator.
    was_published? =
      match?({:ok, _}, Content.get_document(pid, @task_type, dataset, opts))

    attrs = %{
      "doc_id" => pid,
      "title" => task.title,
      "content" => new_content
    }

    source_opts = Keyword.put_new(opts, :source, :github)

    with {:ok, upserted} <-
           Content.upsert_document(@task_type, attrs, dataset, source_opts) do
      {doc, collapse} = collapse_draft_twin(was_published?, upserted, pid, dataset, source_opts)
      maybe_backlink(github, opts)

      case collapse do
        nil -> {:ok, doc}
        %{} = collapse -> {:ok, doc, collapse}
      end
    end
  end

  # Drop the `needs-human` gate label, KEEP everything else (notably
  # `src:github` — provenance is permanent). A nil/absent label list yields an
  # empty list (the task is adopted regardless of how it was labelled).
  defp strip_gate(labels) when is_list(labels), do: Enum.reject(labels, &(&1 == @gate_label))
  defp strip_gate(_), do: []

  # Collapse the draft twin the upsert wrote (D12 / the `Link.put` pattern).
  # Returns `{doc, collapse}` where `collapse` is `nil` on success (or when no
  # collapse was needed) and a `%{published: false, error: <wall detail>}` map
  # when the collapse publish was REJECTED. Only when the task was ALREADY
  # published do we publish the fresh draft back into the published row so no
  # phantom unpublished draft is left in Studio; the publish carries the same
  # `source: :github` stamp, so its `mutation_events` row is outbox-excluded
  # (loop cut #2). A never-published task is left a draft.
  #
  # A REJECTED collapse publish (authoring-excellence D23) was silently
  # swallowed before — the label edit never reached the published perspective
  # and no signal reached anyone. It is no longer silent: the discarded reason
  # is logged (the `maybe_backlink` best-effort precedent) AND returned as a
  # machine-readable `collapse` detail so the operator/agent can retry. The
  # adopt itself stays committed on the draft (a 422-after-commit would lie), so
  # the return is still `{:ok, …}` upstream.
  defp collapse_draft_twin(false, upserted, _pid, _dataset, _opts), do: {upserted, nil}

  defp collapse_draft_twin(true, upserted, pid, dataset, opts) do
    case Content.publish_document(pid, @task_type, dataset, opts) do
      {:ok, published} ->
        {published, nil}

      {:error, reason} ->
        Logger.warning(
          "github adopt: draft-twin collapse publish for #{pid} rejected: #{inspect(reason)}"
        )

        {upserted, %{published: false, error: collapse_error_detail(reason)}}
    end
  end

  # Machine-readable summary of a publish-wall rejection for the `collapse`
  # response field — mirrors the wall's own error atoms (label_spine 422,
  # unknown_tag 422, duplicate_of 409) so an agent keys on `code` to retry with
  # a fixed label set. Anything unexpected degrades LOUDLY (inspected), never
  # into a hint-less blob.
  defp collapse_error_detail({:label_spine, details}),
    do: %{code: "label_spine", details: details}

  defp collapse_error_detail({:unknown_tag, payload}),
    do: %{code: "unknown_tag", details: payload}

  defp collapse_error_detail({:duplicate_of, payload}),
    do: %{code: "duplicate_of", details: payload}

  defp collapse_error_detail({:halted, reason}),
    do: %{code: "halted", message: to_string(reason)}

  defp collapse_error_detail(other),
    do: %{code: "publish_failed", message: inspect(other)}

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
