defmodule Barkpark.Plugins.Github.Intake do
  @moduledoc """
  INBOUND intake — births a born-dark Barkpark task from an outsider's GitHub
  Issue, through the SAME `Tasks.Dedup` find-or-create seam every task uses
  (epic charter Wave 3, D3/D4/D6).

  An outsider who cannot see the guerrilla ledger opens an issue in the mirror
  repo. GitHub delivers an `issues` webhook; the wave-3 controller verifies the
  HMAC signature and hands the decoded payload here. `ingest/2` turns exactly
  ONE shape — `action == "opened"` with an `issue` — into a task
  `gh-<number>` labelled `src:github` + `needs-human`, born `open` and
  UNCLAIMED (adoption is an explicit operator action in wave 4, never automatic).

  ## The five gates (in order)

    1. **Event filter (D6).** Act ONLY on `payload["action"] == "opened"` with an
       `"issue"` present. Any other action (`edited`/`closed`/`labeled`/…) or a
       missing issue → `:ignored`. The bridge intakes a BIRTH, never an edit —
       GitHub-side edits never flow back into a task (the ownership matrix is
       inbound-intake-only, read ONCE at birth).

    2. **Bot drop (D4 cut #1).** If `payload["sender"]["type"] == "Bot"` →
       `:dropped`, BEFORE any Content write. The App's own outbound mirror writes
       always carry a `[bot]` sender of type `Bot`; dropping them here is the
       structural inbound loop cut — an echo of our own issue-create can never
       mint a second task. This runs before the deterministic-id create, so a
       bot echo never even touches the dedup seam.

    3. **Deterministic id (D3/D6).** `doc_id = "gh-" <> issue["number"]`. The id is
       a pure function of the issue number, so a RE-DELIVERY of the same webhook
       resolves the SAME `gh-<num>` doc.

    4. **Create through the normal path (D6).** On a genuine FIRST delivery
       (`gh-<num>` resolves to no existing task) call `Content.create_document/4`
       with `source: :github`. There is no `prev_doc`, so
       `Tasks.Dedup.check_new_task/5` runs — a fresh outsider issue is not a
       duplicate, so the task is born. If instead the Dedup seam judges the
       issue a LOOK-ALIKE of existing tracked work, the create returns
       `{:error, {:duplicate_task, verdict}}`. We do NOT swallow that silently
       (silence would leave the outsider un-acknowledged, re-refuse on every
       re-delivery, and never surface a row an `adopt` could find). Instead we
       SURFACE the refusal (D7 spirit): a maintainer-visible comment on the
       issue, a findable `dedup_refused` dead-letter row via `Github.Conflicts`,
       and a DISTINCT `{:refused, doc_id}` outcome the controller maps to 2xx
       (accepted — GitHub never re-delivers, so the comment posts exactly once).
       A deterministic lifecycle-gate veto (`{:halted, reason}`) is logged and
       returned as the same clean `{:refused, doc_id}` 2xx outcome: retrying an
       unchanged issue can never make that write succeed. A genuine OTHER
       create error stays `{:error, reason}` → the controller answers 5xx
       (retryable — that transient IS worth retrying).
       On RE-DELIVERY the `gh-<num>` doc already
       exists, so intake SHORT-CIRCUITS to `{:ok, :exists, doc}` and never
       touches the write path at all — the outsider issue is read EXACTLY ONCE,
       at birth (ownership matrix). Re-running the create would find the row as
       `prev_doc` and UPDATE it back to the birth attrs, clobbering any
       post-birth Barkpark-side change; the short-circuit read forbids that.
       Because the birth write is stamped `source: :github`,
       `Broadcast.save_event` records the `mutation_events` row
       `source = "github"` EXACTLY (D4 cut #2, never `"github:inbound"`), so the
       wave-1 outbox reader (`source != "github"`) excludes it — no OUTBOUND echo
       of an inbound birth.

    4b. **The acknowledgement criterion (born, not remembered).** The birth attrs
       carry exactly ONE `acceptance_criteria` entry —
       `Github.Acknowledgement.criterion/2`, flagged `"ack_gate" => true` — which
       names the comment a maintainer still owes the reporter. Before this, an
       intake was born with NO criteria key at all, and an empty criteria list
       reads to every audit as fully proven: measured 2026-08-24, 9 of the 11
       intaken rows carried zero criteria and 8 reporters had heard nothing but
       the gate-5 backlink, the oldest 29 days old. The criterion is what
       `Tasks.Close` reads to refuse a `done`/`cancelled` close that would leave
       the reporter with silence.

    5. **Backlink comment (best-effort).** After a genuine BIRTH only (never a
       re-delivery no-op, a drop, or an ignore) post a "tracked internally"
       comment via the injectable `:comment_fun` seam (default
       `&Client.create_comment/4`). It is best-effort: a failed or raising comment
       is LOGGED and swallowed — a flaky GitHub comment API must never fail the
       intake or lose the task that was already durably born.

  ## What intake NEVER does

  Never sets `synced_rev` (this task is inbound-BORN, not outbound-mirrored — the
  wave-2 MirrorJob owns that field). Never sets a claim/worker/epoch/fence (those
  NEVER leave Barkpark, and adoption is wave 4). Never reads a GitHub field back
  into a task after birth (D5). Leaves any unknown field ABSENT rather than
  fabricating it (a nil issue body yields no `description` key).

  ## Injected seams (DrainWorker precedent — no network in tests)

    * `:comment_fun` — default `&Client.create_comment/4`; `(repo, number, body,
      opts)` in, `{:ok, _}` = posted, anything else = logged and swallowed. Used
      for BOTH the birth backlink AND the dedup-refusal maintainer comment.
    * `:conflict_fun` — default `&Github.Conflicts.record/1` (resolved
      dynamically); `(attrs_map)` in. Records the `dedup_refused` dead-letter
      row. Best-effort: a failure is logged and swallowed so a flaky recorder
      never turns a delivered-and-commented refusal into a retry storm.
    * `:repo`        — the `owner/name` for the backlink comment; defaults to
      `Settings.repo/0`.
    * `:dataset`     — the dataset the task is born into; defaults to
      `"production"`. Also threaded to `Content.create_document/4` as the
      positional dataset.

  Every other `opts` key (`:workspace_id`/`:project_id`/`:user_id`) is threaded
  straight through to the Content create path for tenant scoping.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Acknowledgement, Client, Settings}

  @task_type "task"
  @default_dataset "production"
  @intake_labels ["src:github", "needs-human"]
  @backlink_body "This issue is now tracked internally in Barkpark. " <>
                   "Updates will be posted here."
  @refused_comment_body "This issue looks related to existing tracked work; " <>
                          "a maintainer will review it."

  @typedoc """
  Intake outcome:

    * `{:ok, :born, doc}`   — a fresh task was born (backlink comment attempted)
    * `{:ok, :exists, doc}` — re-delivery; the task already existed (idempotent no-op)
    * `{:refused, doc_id}`  — the birth was deterministically refused: either
      Dedup judged it a look-alike (and surfaced a maintainer comment plus a
      `dedup_refused` dead-letter row), or a lifecycle gate vetoed it (and the
      reason was logged). The controller maps both to 2xx (accepted)
    * `:ignored`            — not an `issues.opened` event (D6)
    * `:dropped`            — the App's own `[bot]` sender (D4 cut #1)
    * `{:error, reason}`    — a genuine (non-dedup) Content create failure; the
      controller maps this to 5xx so GitHub redelivers (idempotent via `gh-<num>`)
  """
  @type result ::
          {:ok, :born | :exists, Document.t()}
          | {:refused, String.t()}
          | :ignored
          | :dropped
          | {:error, term()}

  @doc """
  Ingest a decoded GitHub `issues` webhook payload, birthing a born-dark task on
  `action == "opened"`. See the moduledoc for the full gate order and the
  `result` type for every outcome.
  """
  # @canonical capability:github-inbound-intake aka:webhook,issues.opened,gh-birth doc:.claude/workflows/bp-github-bridge-epic-charter.md
  @spec ingest(map(), keyword()) :: result()
  def ingest(payload, opts \\ []) when is_map(payload) do
    cond do
      not opened_issue?(payload) -> :ignored
      bot_sender?(payload) -> :dropped
      true -> birth(payload, opts)
    end
  end

  # ── gate 1: event filter (D6, issues.opened ONLY) ──────────────────────────

  defp opened_issue?(payload) do
    Map.get(payload, "action") == "opened" and is_map(Map.get(payload, "issue"))
  end

  # ── gate 2: bot drop (D4 cut #1) ───────────────────────────────────────────

  @doc """
  `true` when the webhook's `sender` is a GitHub App/`[bot]` identity (`sender.type
  == "Bot"`). The App's own outbound mirror writes always carry a Bot sender;
  dropping them is the structural inbound loop cut (D4 cut #1).

  Public so the sibling `Github.InboundEvents` handler reuses the EXACT same
  bot-drop as the FIRST gate on every inbound path — the App's own issue-close
  echo must never be mistaken for a human action and mint a detach.
  """
  @spec bot_sender?(map()) :: boolean()
  def bot_sender?(payload) do
    case Map.get(payload, "sender") do
      %{"type" => "Bot"} -> true
      _ -> false
    end
  end

  # ── gates 3-5: deterministic birth through the Dedup seam ──────────────────

  defp birth(payload, opts) do
    issue = Map.get(payload, "issue")
    number = Map.get(issue, "number")
    doc_id = "gh-" <> to_string(number)
    dataset = Keyword.get(opts, :dataset, @default_dataset)

    # The ownership matrix reads the outsider issue EXACTLY ONCE, at birth. A
    # re-delivery resolves the same deterministic `gh-<num>` doc — so if a task
    # already exists we RETURN it as-is and short-circuit. We deliberately do
    # NOT re-run the create path: `Content.create_document` finds the existing
    # row as `prev_doc` and takes the UPDATE branch, which would rewrite the row
    # back to the birth attrs — clobbering any post-birth Barkpark-side change (a
    # Studio edit, or a wave-4 adoption that stripped `needs-human`/flipped
    # lifecycle). Idempotency is by short-circuit READ, never by rewrite.
    case fetch_existing(doc_id, dataset, opts) do
      {:ok, existing} ->
        {:ok, :exists, existing}

      :none ->
        attrs = build_attrs(doc_id, number, issue, payload)
        create_opts = Keyword.put(opts, :source, :github)

        case Content.create_document(@task_type, attrs, dataset, create_opts) do
          {:ok, doc} ->
            maybe_backlink(number, opts)
            {:ok, :born, doc}

          # The Dedup seam (Tasks.Dedup, via Content.Writer) judged the outsider
          # issue a look-alike of existing tracked work. Surface it — never
          # silence (D6/D7 spirit): a maintainer comment + a findable dead-letter
          # row + a DISTINCT outcome the controller answers 2xx.
          {:error, {:duplicate_task, verdict}} ->
            refused(doc_id, number, dataset, verdict, opts)

          # A lifecycle gate veto is deterministic for this unchanged webhook:
          # GitHub redelivery would only hit the same veto forever. Log the
          # server-owned reason and return the controller's clean 2xx refusal;
          # Writer already stopped before persistence, so there is no task or
          # backlink side effect to undo.
          {:error, {:halted, reason}} ->
            Logger.warning("github intake: lifecycle gate refused #{doc_id}: #{inspect(reason)}")

            {:refused, doc_id}

          # The dedup gate could not RUN (PDS wave 24). This looks like the
          # veto above and is its exact opposite: the veto is deterministic, so
          # answering 2xx is right; a dedup outage is TRANSIENT, so answering
          # 2xx would drop this issue FOREVER — GitHub never redelivers a 2xx —
          # while logging it as a policy refusal that never happened. It must
          # fall through to the 5xx path so redelivery re-runs the check, which
          # the deterministic `gh-<num>` doc_id keeps idempotent.
          {:error, {:dedup_unavailable, reason}} ->
            Logger.warning(
              "github intake: dedup gate unavailable for #{doc_id}: #{inspect(reason)} — " <>
                "answering 5xx so GitHub redelivers rather than dropping the issue"
            )

            {:error, {:dedup_unavailable, reason}}

          # A genuine, non-dedup/non-gate failure (transient DB, etc.) stays an error so
          # the controller answers 5xx and GitHub redelivers — the deterministic
          # `gh-<num>` doc_id keeps that redelivery idempotent.
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ── dedup-refusal surfacing (no outsider gets silence) ─────────────────────

  # The Dedup verdict refused a birth. Do the two visible things — comment +
  # dead-letter row — then return the distinct `{:refused, doc_id}`. Neither
  # side effect may crash intake or force a redelivery: both are best-effort so
  # the maintainer comment posts EXACTLY ONCE (2xx, GitHub never re-delivers).
  # `doc_id` rides the outcome (the intended `gh-<num>`), but the recorded row
  # carries `doc_id: nil` — no task exists to point at.
  defp refused(doc_id, number, dataset, verdict, opts) do
    maybe_comment(number, @refused_comment_body, opts)
    record_refusal(number, dataset, verdict, opts)
    {:refused, doc_id}
  end

  # Dead-letter the refusal into `github_sync_conflicts` (slice-1 recorder) so
  # it is FINDABLE — the wave-6 console lists it and a maintainer can reconcile
  # by hand. Slice-1's recorder DEDUPES on the open `{repo, issue, kind}` row,
  # so a re-delivery UPDATES the same row instead of piling duplicates. The
  # recorder is out-of-band bookkeeping — it never touches `Content.*` or
  # `mutation_events`, so it can never re-trigger sync (no loop surface).
  defp record_refusal(number, dataset, verdict, opts) do
    repo = Keyword.get(opts, :repo) || Settings.repo()
    record_fun = Keyword.get(opts, :conflict_fun, &default_record/1)

    attrs = %{
      repo: repo,
      issue: number,
      doc_id: nil,
      dataset: dataset,
      kind: "dedup_refused",
      detail: verdict
    }

    case record_fun.(attrs) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "github intake: recording dedup_refused for ##{number} failed: #{inspect(other)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "github intake: recording dedup_refused for ##{number} raised: #{inspect(e)}"
      )

      :ok
  end

  # Default conflict recorder, resolved dynamically (the controller's
  # `default_ingest` precedent) so this compiles clean whether or not the
  # slice-1 `Github.Conflicts` module is present in the tree yet.
  defp default_record(attrs) do
    mod = Module.concat(Barkpark.Plugins.Github, Conflicts)
    mod.record(attrs)
  end

  # Resolve an already-born `gh-<num>` task (draft-first, then the published
  # perspective for a task that was adopted+published) so a re-delivery is a
  # read, never a rewrite. Returns `{:ok, doc}` or `:none`.
  defp fetch_existing(doc_id, dataset, opts) do
    with :none <- lookup(Content.draft_id(doc_id), dataset, opts) do
      lookup(Content.published_id(doc_id), dataset, opts)
    end
  end

  defp lookup(id, dataset, opts) do
    case Content.get_document(id, @task_type, dataset, opts) do
      {:ok, doc} -> {:ok, doc}
      _ -> :none
    end
  end

  # Build the born-dark task attrs. `src:github` + `needs-human` labels, born
  # `open` and UNCLAIMED. `content.github` is Barkpark bookkeeping (never
  # rendered to GitHub); `state: "intake"` marks a not-yet-adopted task. NO
  # `synced_rev` — this is inbound-born, not outbound-mirrored. The description
  # is left ABSENT when the issue has no body (never fabricated).
  #
  # BORN ADJUDICATED, NOT EXEMPTED (PDS wave 28). The birth fence
  # (`Content.Writer.ensure_task_born_adjudicated/5`) exempts every non-`:api`
  # source, and this write is stamped `source: :github` — so the bridge would
  # pass the fence by carve-out while filing exactly the unadjudicated row the
  # fence exists to stop. It states its adjudication instead: `"open"` (the term
  # is honest — an intake row IS open and untriaged) plus a reason that is
  # RE-DERIVABLE rather than prose, because it names the issue number, the repo
  # and the author a reader can go and check. The carve-out remains behind this
  # as the fail-safe, and that ordering is load-bearing: an unmatched intake
  # error falls through `birth/2` to the controller's 500, and GitHub redelivers
  # a 5xx forever — so the bridge must never be the thing a fence refuses.
  defp build_attrs(doc_id, number, issue, payload) do
    content =
      %{
        "kind" => "task",
        "labels" => @intake_labels,
        "lifecycle_status" => "open",
        "disposition" => "open",
        "disposition_reason" => intake_disposition_reason(number, issue, payload),
        # BORN WITH THE ONE OBLIGATION IT OWES, not with an empty list. Every
        # intake before this carried NO `acceptance_criteria` key at all, and an
        # empty criteria list reads to every audit as fully proven — so eight
        # outsider reports sat in a blind spot where nothing could see that the
        # reporter had never been answered (`Github.Acknowledgement` carries the
        # 2026-08-24 measurement). The row now states the obligation itself, and
        # `Tasks.Close` refuses a `done`/`cancelled` close while it is unmet.
        "acceptance_criteria" => [Acknowledgement.criterion(issue_repo(payload), number)],
        "github" => %{
          "repo" => issue_repo(payload),
          "issue" => number,
          "state" => "intake"
        }
      }
      |> maybe_put("description", Map.get(issue, "body"))

    %{
      "doc_id" => doc_id,
      "title" => Map.get(issue, "title") || "",
      "content" => content
    }
  end

  # The birth reason, built ONLY from facts carried on the delivery: the issue
  # number, the repo it lives in, and the login that opened it. Every clause is
  # something a reader can re-derive by opening that issue — deliberately NOT a
  # prose judgement, which is the class of reason nothing can ever check.
  defp intake_disposition_reason(number, issue, payload) do
    where =
      case issue_repo(payload) do
        repo when is_binary(repo) and repo != "" -> " in #{repo}"
        _ -> ""
      end

    who =
      case Map.get(issue, "user") || Map.get(payload, "sender") do
        %{"login" => login} when is_binary(login) and login != "" -> " opened by @#{login}"
        _ -> ""
      end

    "inbound GitHub intake: issue ##{number}#{where}#{who} — born open and UNADOPTED, " <>
      "labelled #{Enum.join(@intake_labels, "/")} and awaiting human triage. Re-derive from " <>
      "the issue itself."
  end

  # The repo the issue lives in — read ONCE at birth from the webhook's
  # `repository.full_name`, falling back to the configured mirror repo. Left
  # `nil` (absent-safe) if neither is present.
  defp issue_repo(payload) do
    case Map.get(payload, "repository") do
      %{"full_name" => full} when is_binary(full) -> full
      _ -> Settings.repo()
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── gate 5: best-effort backlink comment ───────────────────────────────────

  # Post the "tracked internally" backlink on a fresh birth.
  defp maybe_backlink(number, opts), do: maybe_comment(number, @backlink_body, opts)

  # Post a maintainer-visible comment via the `:comment_fun` seam. Best-effort:
  # a nil repo skips silently; a failed or raising comment is logged and
  # swallowed so a durably-born task (or a durably-recorded refusal) is never
  # lost to a flaky GitHub comment API. Shared by the birth backlink and the
  # dedup-refusal notice (only the body differs).
  defp maybe_comment(number, body, opts) do
    repo = Keyword.get(opts, :repo) || Settings.repo()
    comment_fun = Keyword.get(opts, :comment_fun, &Client.create_comment/4)

    cond do
      not is_binary(repo) ->
        Logger.debug("github intake: no repo configured, skipping comment on ##{number}")
        :ok

      true ->
        post_comment(comment_fun, repo, number, body, opts)
    end
  end

  defp post_comment(comment_fun, repo, number, body, opts) do
    case comment_fun.(repo, number, body, opts) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("github intake: comment on ##{number} failed: #{inspect(other)}")

        :ok
    end
  rescue
    e ->
      Logger.warning("github intake: comment on ##{number} raised: #{inspect(e)}")

      :ok
  end
end
