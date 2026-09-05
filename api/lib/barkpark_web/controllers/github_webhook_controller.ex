defmodule BarkparkWeb.GithubWebhookController do
  @moduledoc """
  Inbound GitHub webhook sink (design paper `bp-github-bridge-epic-charter`,
  Wave 3 — inbound intake). Mounted by the github plugin's `register_routes/1`
  on the `:github_webhook` bucket at `POST /v1/plugins/github/webhook`.

  ## Trust boundary

  The route's pipeline (`BarkparkWeb.Plugs.GithubWebhookSignature`, Wave 3
  slice 1) has ALREADY verified the `X-Hub-Signature-256` HMAC over the raw
  request body before the request reaches this controller. Reaching an action
  here therefore MEANS the delivery is authentic — the controller does NO
  re-verification. Signature is the only auth (server-to-server callback, no
  bearer token, no CORS).

  ## Dispatch (event-gate, D6 + D14)

  A single action, `receive/2`, branches on the `X-GitHub-Event` header:

    * `"issues"` → split by `action`:
      * `deleted` / `transferred` / `closed` → hand to
        `Barkpark.Plugins.Github.InboundEvents.handle/2` (Wave 8, D14 — inbound
        breadth as VISIBLE detach bookkeeping). Deleted/transferred detaches a
        `gh-<num>` intake task; a self-`closed` intake detaches with reason
        `closed_by_author`; a bot-sender close, an adopted-task close, or a
        missing task is a deliberate 2xx no-op.
      * anything else (`opened`, `edited`, …) → hand to
        `Barkpark.Plugins.Github.Intake.ingest/2`. Intake enforces its own gate:
        it acts only on `action == "opened"`, drops `[bot]`-sender deliveries
        (D4 cut #1), and births a deterministic `gh-<num>` task through the
        `Tasks.Dedup` seam.
    * `"pull_request"` → `Barkpark.Plugins.Github.MergeEvents.handle/2`
      (ledger-merge-criterion-autostamp). A merged close (`action == "closed"` +
      `pull_request.merged == true`) resolves the PR's `Task: <doc_id>` trailer and
      auto-stamps the task's explicit `merge_gate:true` criterion via
      `Tasks.reconcile_merge_gate/3` (STAMP-ONLY — never a lifecycle flip, so the
      lead keeps close's claim/epoch judgment and other unmet criteria stay
      visibly partial). Named idempotent outcomes; a non-merge close is a no-op.
    * `"ping"` → `200 {ok: true}`. GitHub's install handshake; nothing to do.
    * anything else → `202` no-op (accepted, ignored).

  Both `issues` handlers receive the SAME `ingest_opts/0` — dataset from
  `Settings.datasets/0` plus an optional `:workspace_id` from
  `Settings.intake_workspace_id/0` (D15; absent → today's default-workspace
  behavior byte-identical, no `:workspace_id` key threaded).

  ## Why always 2xx on an unactionable delivery

  A verified-but-unactionable delivery (ping, non-`issues` event, non-`opened`
  action, bot-drop) returns 2xx so GitHub marks it delivered and does NOT
  retry-storm. A dedup-REFUSED intake (`{:refused, _}` — the outsider issue
  looked like existing tracked work) is likewise 2xx: Intake already posted the
  maintainer comment and recorded a findable dead-letter row, so a redelivery
  would only double-post — GitHub must never retry it. Only a genuine intake
  FAILURE (`{:error, _}` — e.g. a transient DB error) returns 5xx, inviting
  GitHub to redeliver; the deterministic `gh-<num>` doc_id makes that
  redelivery idempotent (no duplicate task).

  ## Intake seam

  `receive/2` calls `Barkpark.Plugins.Github.Intake.ingest/2` through a private
  seam so a controller test can assert dispatch without a live intake path.
  Override with `config :barkpark, :github_webhook_intake_fun, fun/2` in test
  (the DrainWorker/MirrorJob seam-injection precedent). Absent → the real
  Intake module.
  """

  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.Plugins.Github.Settings

  @doc """
  The single webhook action. Signature is already verified upstream; this
  branches on `X-GitHub-Event` and always answers 2xx unless intake genuinely
  fails. See the moduledoc for the dispatch contract.
  """
  # Actions D14 routes to the InboundEvents bookkeeping handler instead of Intake.
  @inbound_actions ["deleted", "transferred", "closed"]

  def receive(conn, params) do
    case github_event(conn) do
      "issues" -> handle_issues(conn, params)
      "pull_request" -> handle_pull_request(conn, params)
      "ping" -> json(conn, %{ok: true})
      _other -> conn |> put_status(:accepted) |> json(%{ok: true, ignored: "event"})
    end
  end

  # `issues` event → split by action (D14). deleted/transferred/closed are
  # bookkeeping detaches (InboundEvents); everything else is the birth path
  # (Intake). Both share `ingest_opts/0` so tenant scope threads identically.
  defp handle_issues(conn, params) do
    if Map.get(params, "action") in @inbound_actions do
      handle_inbound(conn, params)
    else
      handle_intake(conn, params)
    end
  end

  # deleted/transferred/closed → the InboundEvents handler owns bot-drop +
  # gh-<num> lookup + the detach bookkeeping. EVERY outcome tag gets an explicit
  # 2xx clause — the case is closed, so a new tag with no clause would
  # CaseClauseError → 500 → GitHub retry-storm. Only a genuine ledger-write
  # failure ({:error, _}) is 5xx (retryable, idempotent via gh-<num>).
  defp handle_inbound(conn, params) do
    case inbound_fun().(params, ingest_opts()) do
      {:ok, :detached, _doc_id} ->
        # The gh-<num> intake task was detached + a visible conflict recorded.
        json(conn, %{ok: true, detached: true})

      :dropped ->
        # D4 cut #1 — the App's own `[bot]` close echo. Never a detach; 2xx.
        json(conn, %{ok: true, dropped: true})

      :ignored ->
        # No gh-<num> task, a non-intake close, or a non-inbound action.
        # Accepted, deliberate no-op.
        conn |> put_status(:accepted) |> json(%{ok: true, ignored: "action"})

      {:error, reason} ->
        # The link state flip failed for a genuine reason. 5xx invites GitHub to
        # redeliver; the deterministic gh-<num> + Conflicts dedup keep it idempotent.
        Logger.error(
          "github webhook: inbound event failed for issue ##{issue_number(params)}: #{inspect(reason)}"
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "inbound_failed", message: "could not process delivery"}})
    end
  end

  # opened/edited/… → the intake service owns action-gating (opened-only) and the
  # bot-drop. Map its result to an HONEST status: born/dropped/ignored are all
  # 2xx (verified + handled), a real error is 5xx (retryable, idempotent).
  defp handle_intake(conn, params) do
    case intake_fun().(params, ingest_opts()) do
      # Intake reports `{:ok, :born, doc}` on a fresh birth and `{:ok, :exists,
      # doc}` on an idempotent re-delivery — both are 2xx handled deliveries.
      # Match the TAG explicitly: a bare `{:ok, _doc}` (2-tuple) would miss the
      # real 3-tuple shape and CaseClauseError → a perpetual 500 GitHub retries.
      {:ok, _tag, _doc} ->
        json(conn, %{ok: true, ingested: true})

      :dropped ->
        # D4 cut #1 — the App's own `[bot]` write. Handled by deliberately
        # doing nothing; 2xx so GitHub never retries a loop-cut delivery.
        json(conn, %{ok: true, dropped: true})

      :ignored ->
        # action != "opened" (edited/closed/labeled/reopened/…). Accepted, no-op.
        conn |> put_status(:accepted) |> json(%{ok: true, ignored: "action"})

      {:refused, _doc_id} ->
        # Dedup judged the outsider issue a look-alike (D6). No task born, but
        # Intake already posted a maintainer comment + recorded a findable
        # dead-letter row. 2xx (accepted) so GitHub never redelivers — the
        # comment must post exactly once.
        conn |> put_status(:accepted) |> json(%{ok: true, refused: true})

      {:error, reason} ->
        # A genuine intake failure (transient DB, etc.). 5xx invites GitHub to
        # redeliver; the deterministic `gh-<num>` doc_id keeps that idempotent.
        # Log it — a silently-500ing webhook that GitHub keeps redelivering is
        # otherwise invisible. Include the issue number (small int, safe) but
        # NEVER the attacker-controlled title/body (log-injection / spam).
        Logger.error(
          "github webhook: intake failed for issue ##{issue_number(params)}: #{inspect(reason)}"
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "intake_failed", message: "could not process delivery"}})
    end
  end

  # `pull_request` event → the merge-event bridge (ledger-merge-criterion-autostamp).
  # A merged close auto-stamps the task's explicit `merge_gate:true` criterion via
  # `Tasks.reconcile_merge_gate/3` (STAMP-ONLY — never a lifecycle flip). Every
  # outcome tag gets an explicit 2xx clause so a new tag never CaseClauseErrors →
  # 500 → GitHub retry-storm. Only a genuine ledger-write failure ({:error, _}) is
  # 5xx (retryable, replay-safe via `:already_stamped`).
  defp handle_pull_request(conn, params) do
    case merge_events_fun().(params, ingest_opts()) do
      {:ok, :stamped, doc_id, indices} ->
        # The merge-gate criterion (or several) flipped met on the resolved task.
        json(conn, %{ok: true, stamped: true, task: doc_id, criteria: indices})

      {:ok, :unflagged_merge_gates, doc_id, indices} ->
        # Nothing was stamped, and that is deliberate: the flag is the permit,
        # because a prose-wide permit fabricates dones (close.ex
        # reconcile_locked/4 carries the measurement). The criteria are NAMED
        # rather than counted — a count says there is a problem, a list says
        # where — so the strand is actionable instead of silent. 2xx: this is a
        # reported no-write, not a failure.
        json(conn, %{
          ok: true,
          reconciled: "unflagged_merge_gates",
          task: doc_id,
          criteria: indices
        })

      {:ok, tag, doc_id} when tag in [:already_stamped, :no_marker, :no_guardable_marker] ->
        # Named idempotent / no-write outcomes: replayed event, unmarked legacy
        # gate, or an unguardable gate. All handled — 2xx, never a retry.
        json(conn, %{ok: true, reconciled: to_string(tag), task: doc_id})

      {:ambiguous_trailer, ids} ->
        # The PR body references more than one distinct task — refused, not guessed.
        conn
        |> put_status(:accepted)
        |> json(%{ok: true, ignored: "ambiguous_trailer", tasks: ids})

      {:unknown_task, doc_id} ->
        # The trailer names a doc that does not resolve. Accepted no-op (a retry
        # cannot make the task exist; a re-projection/adopt will, on a later merge).
        conn |> put_status(:accepted) |> json(%{ok: true, ignored: "unknown_task", task: doc_id})

      tag when tag in [:no_trailer, :ignored] ->
        # No `Task:` trailer, or not a merged close. Verified + deliberately no-op.
        conn |> put_status(:accepted) |> json(%{ok: true, ignored: to_string(tag)})

      {:error, reason} ->
        # A genuine ledger-write failure (e.g. a rev-CAS race). 5xx invites GitHub
        # to redeliver; the reconcile is replay-safe (redelivery → :already_stamped).
        Logger.error(
          "github webhook: merge reconcile failed for PR ##{pr_number(params)}: #{inspect(reason)}"
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{code: "merge_reconcile_failed", message: "could not process delivery"}
        })
    end
  end

  # First non-blank X-GitHub-Event header value, downcased, or "" when absent.
  # GitHub sends exactly one; a missing/blank header falls through to the 202
  # no-op branch (never crashes).
  defp github_event(conn) do
    conn
    |> get_req_header("x-github-event")
    |> List.first()
    |> case do
      v when is_binary(v) -> v |> String.trim() |> String.downcase()
      _ -> ""
    end
  end

  # The issue number if present, else "?" — for the failure log line only.
  # Kept to the small integer GitHub assigns; never the free-text fields.
  defp issue_number(params) do
    case get_in(params, ["issue", "number"]) do
      n when is_integer(n) -> n
      _ -> "?"
    end
  end

  # The PR number if present, else "?" — for the failure log line only (never the
  # attacker-controlled title/body).
  defp pr_number(params) do
    case get_in(params, ["pull_request", "number"]) do
      n when is_integer(n) -> n
      _ -> "?"
    end
  end

  # Thread the target dataset explicitly (Intake defaults to the first
  # configured dataset, but the controller owns the choice) plus the optional
  # intake workspace (D15). Env-only reads — no DB, no audit row — so cheap per
  # delivery. When no workspace is configured, NO `:workspace_id` key is added:
  # the ingest opts are byte-identical to today's default-workspace behavior.
  defp ingest_opts do
    dataset = List.first(Settings.datasets()) || "production"
    base = [dataset: dataset]

    case Settings.intake_workspace_id() do
      nil -> base
      workspace_id -> Keyword.put(base, :workspace_id, workspace_id)
    end
  end

  # Intake seam: overridable in test via app env, else the real module. The
  # module is resolved dynamically so a build without the Wave-3 slice-2 Intake
  # module present still compiles clean (no xref warning) — the call resolves at
  # request time, by which point the module is loaded.
  defp intake_fun do
    Application.get_env(:barkpark, :github_webhook_intake_fun) || (&default_ingest/2)
  end

  defp default_ingest(payload, opts) do
    mod = Module.concat(Barkpark.Plugins.Github, Intake)
    mod.ingest(payload, opts)
  end

  # InboundEvents seam, mirroring `intake_fun/0`: overridable in test via app env
  # (`:github_webhook_inbound_fun`), else the real module resolved dynamically.
  defp inbound_fun do
    Application.get_env(:barkpark, :github_webhook_inbound_fun) || (&default_inbound/2)
  end

  defp default_inbound(payload, opts) do
    mod = Module.concat(Barkpark.Plugins.Github, InboundEvents)
    mod.handle(payload, opts)
  end

  # MergeEvents seam, mirroring `inbound_fun/0`: overridable in test via app env
  # (`:github_webhook_merge_events_fun`), else the real module resolved dynamically.
  defp merge_events_fun do
    Application.get_env(:barkpark, :github_webhook_merge_events_fun) || (&default_merge_events/2)
  end

  defp default_merge_events(payload, opts) do
    mod = Module.concat(Barkpark.Plugins.Github, MergeEvents)
    mod.handle(payload, opts)
  end
end
