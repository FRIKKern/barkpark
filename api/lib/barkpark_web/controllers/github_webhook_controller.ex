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

  ## Dispatch (event-gate, D6)

  A single action, `receive/2`, branches on the `X-GitHub-Event` header:

    * `"issues"` → hand the parsed payload to
      `Barkpark.Plugins.Github.Intake.ingest/2` (dataset threaded from
      `Settings.datasets/0`). Intake enforces the SECOND gate: it acts only on
      `action == "opened"`, drops `[bot]`-sender deliveries (D4 cut #1), and
      births a deterministic `gh-<num>` task through the `Tasks.Dedup` seam.
      The controller/Intake action-gate pair is the joint enforcement of D6.
    * `"ping"` → `200 {ok: true}`. GitHub's install handshake; nothing to do.
    * anything else → `202` no-op (accepted, ignored).

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
  def receive(conn, params) do
    case github_event(conn) do
      "issues" -> handle_issues(conn, params)
      "ping" -> json(conn, %{ok: true})
      _other -> conn |> put_status(:accepted) |> json(%{ok: true, ignored: "event"})
    end
  end

  # `issues` event → the intake service owns action-gating (opened-only) and the
  # bot-drop. Map its result to an HONEST status: born/dropped/ignored are all
  # 2xx (verified + handled), a real error is 5xx (retryable, idempotent).
  defp handle_issues(conn, params) do
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

  # Thread the target dataset explicitly (Intake defaults to the first
  # configured dataset, but the controller owns the choice). Env-only read —
  # no DB, no audit row — so it's cheap per delivery.
  defp ingest_opts do
    dataset = List.first(Settings.datasets()) || "production"
    [dataset: dataset]
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
end
