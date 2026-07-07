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
       duplicate, so the task is born. On RE-DELIVERY the `gh-<num>` doc already
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
      opts)` in, `{:ok, _}` = posted, anything else = logged and swallowed.
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
  alias Barkpark.Plugins.Github.{Client, Settings}

  @task_type "task"
  @default_dataset "production"
  @intake_labels ["src:github", "needs-human"]
  @backlink_body "This issue is now tracked internally in Barkpark. " <>
                   "Updates will be posted here."

  @typedoc """
  Intake outcome:

    * `{:ok, :born, doc}`   — a fresh task was born (backlink comment attempted)
    * `{:ok, :exists, doc}` — re-delivery; the task already existed (idempotent no-op)
    * `:ignored`            — not an `issues.opened` event (D6)
    * `:dropped`            — the App's own `[bot]` sender (D4 cut #1)
    * `{:error, reason}`    — the Content create failed (e.g. dedup refusal)
  """
  @type result ::
          {:ok, :born | :exists, Document.t()}
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

  defp bot_sender?(payload) do
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

          {:error, reason} ->
            {:error, reason}
        end
    end
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
  defp build_attrs(doc_id, number, issue, payload) do
    content =
      %{
        "kind" => "task",
        "labels" => @intake_labels,
        "lifecycle_status" => "open",
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

  # Post the "tracked internally" backlink on a fresh birth. Best-effort: a nil
  # repo skips silently; a failed or raising comment is logged and swallowed so
  # the durably-born task is never lost to a flaky GitHub comment API.
  defp maybe_backlink(number, opts) do
    repo = Keyword.get(opts, :repo) || Settings.repo()
    comment_fun = Keyword.get(opts, :comment_fun, &Client.create_comment/4)

    cond do
      not is_binary(repo) ->
        Logger.debug("github intake: no repo configured, skipping backlink comment")
        :ok

      true ->
        post_comment(comment_fun, repo, number, opts)
    end
  end

  defp post_comment(comment_fun, repo, number, opts) do
    case comment_fun.(repo, number, @backlink_body, opts) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("github intake: backlink comment on ##{number} failed: #{inspect(other)}")

        :ok
    end
  rescue
    e ->
      Logger.warning("github intake: backlink comment on ##{number} raised: #{inspect(e)}")

      :ok
  end
end
