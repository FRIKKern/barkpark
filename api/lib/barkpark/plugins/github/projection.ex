defmodule Barkpark.Plugins.Github.Projection do
  @moduledoc """
  PURE task → GitHub Issue projection (epic charter Wave 1, D3/D11). Given a task
  document it computes the DESIRED issue shape — `title`, `body`, `labels`,
  `state`, `state_reason` — that the outbound mirror should converge the issue
  to. It is desired-state only: it decides nothing about WHETHER to push (the
  MirrorJob compares `synced_rev`) and it makes no HTTP or DB call. No
  `Content.*`, no `Req`, no Ecto — a plain map in, a plain map out.

  ## Directional purity

  This module reads ONLY the `:outbound_only` fields declared in
  `Barkpark.Plugins.Github.Fields`. There is no inverse — no function here (or
  anywhere) reads a GitHub value back into a task. That is the charter's D5
  invariant made physical.

  ## Lifecycle → issue state (charter Ownership table)

      done      → {state: "closed", state_reason: "completed"}
      cancelled → {state: "closed", state_reason: "not_planned"}
      _else_    → {state: "open",   state_reason: nil}

  The `_else_` branch covers `open`/`in_progress`/`blocked`, an unknown status,
  and the missing-status case. Projecting `state: "open"` onto an issue that
  GitHub currently has closed is exactly a REOPEN — GitHub records reason
  `reopened` for us; the desired state we assert carries `state_reason: nil`.

  ## Body layout (idempotent)

      <human brief>

      <!-- barkpark:acceptance:start -->
      ### Acceptance criteria
      - [x] first criterion
      - [ ] second criterion
      <!-- barkpark:acceptance:end -->

      <!-- barkpark:blocks:start -->
      Blocked by: #12, #34
      <!-- barkpark:blocks:end -->

      <!-- barkpark:parent:start -->
      Parent: <parent_task_id>
      <!-- barkpark:parent:end -->

      Task: <doc_id>

  The `Task: <doc_id>` trailer (D11) is what keeps `pr-task-gate` working from a
  GitHub-side PR. The `parent` marker is the D11 cap-flatten fallback: when a
  parent chain is too deep for a native sub-issue link, the caller hydrates a
  `"parent_marker"` key and this fence carries the parent id instead. Each fenced
  marker (acceptance, blocks, parent) is rewritten ONLY
  inside its own fence — any human prose outside the fences is preserved — so
  re-projecting is idempotent:
  `upsert_blocks_marker(upsert_blocks_marker(body, refs), refs) == upsert_blocks_marker(body, refs)`.

  The acceptance-criteria checkboxes are the charter's flagship liveness signal:
  each `acceptance_criteria` row (`%{"criterion" => …, "met" => bool}`) becomes a
  GitHub task-list item (`- [x]`/`- [ ]`), so the issue's checkbox tally tracks
  the ledger. Absent/empty criteria → no acceptance fence.

  Blocker issue refs are NOT discovered here (that needs the blockers' mirror
  state, which is DB-resident); the caller hydrates them onto the doc as
  `"blocker_issue_refs"` — a list of issue numbers — exactly like the edge
  projector hydrates `task_edges`. Absent → no marker block (leave it ABSENT
  when unknown; never fabricate a blocker).

  ## Sentinel safety

  Barkpark authors EVERY `<!-- barkpark:… -->` sentinel. The human brief (which,
  for an adopted `gh-<num>` task, originated as outsider-controlled issue text)
  is scrubbed of any `barkpark:` HTML comment before the projection lays down its
  own fences — so an attacker cannot forge a fence sentinel to hijack the
  idempotent-upsert region or corrupt human prose on a later PATCH.
  """

  @blocks_start "<!-- barkpark:blocks:start -->"
  @blocks_end "<!-- barkpark:blocks:end -->"
  @accept_start "<!-- barkpark:acceptance:start -->"
  @accept_end "<!-- barkpark:acceptance:end -->"
  @parent_start "<!-- barkpark:parent:start -->"
  @parent_end "<!-- barkpark:parent:end -->"
  @trailer_prefix "Task:"

  @typedoc "The desired GitHub Issue shape the mirror should converge to."
  @type issue :: %{
          title: String.t(),
          body: String.t(),
          labels: [String.t()],
          state: String.t(),
          state_reason: String.t() | nil,
          synced_rev: String.t() | nil
        }

  @doc """
  Project a task document to its desired GitHub Issue shape. Pure.

  Tolerates atom- or string-keyed content. Returns a map with `:title`,
  `:body`, `:labels`, `:state`, `:state_reason`, plus `:synced_rev` (the
  `content.github.synced_rev` the caller compares against the task's live `_rev`
  to decide whether a push is even needed).
  """
  @spec task_to_issue(map()) :: issue()
  def task_to_issue(task_doc) when is_map(task_doc) do
    doc_id = doc_id(task_doc)
    content = content(task_doc)

    {state, state_reason} = state_for(get(content, "lifecycle_status"))

    %{
      title: title(content, doc_id),
      body: body(content, doc_id, blocker_refs(task_doc), parent_marker(task_doc)),
      labels: labels(content),
      state: state,
      state_reason: state_reason,
      synced_rev: synced_rev(task_doc)
    }
  end

  @doc """
  Map a `lifecycle_status` string to `{state, state_reason}`. Total — every
  input (including `nil` and unknown strings) maps to a defined pair, so the
  projection never crashes on a malformed task.

      done      → {"closed", "completed"}
      cancelled → {"closed", "not_planned"}
      _else_    → {"open",   nil}
  """
  @spec state_for(String.t() | nil) :: {String.t(), String.t() | nil}
  def state_for("done"), do: {"closed", "completed"}
  def state_for("cancelled"), do: {"closed", "not_planned"}
  def state_for(_other), do: {"open", nil}

  @doc """
  The `synced_rev` bookkeeping value (`content.github.synced_rev`) — the task
  `_rev` last mirrored. `nil` when the task has never been mirrored. The caller
  compares it to the task's live `_rev`; equality means the MirrorJob no-ops.
  Pure read; this module never writes it.
  """
  @spec synced_rev(map()) :: String.t() | nil
  def synced_rev(task_doc) when is_map(task_doc) do
    case get(content(task_doc), "github") do
      gh when is_map(gh) -> get(gh, "synced_rev")
      _ -> nil
    end
  end

  @doc """
  Insert or replace the fenced blocks marker inside `body`, preserving every
  byte outside the fence. Idempotent: applying it twice equals applying it once.

    * `refs` empty → strip any existing fence entirely (no blockers → no marker).
    * `refs` present, body already fenced → replace ONLY the fenced region.
    * `refs` present, no fence yet → append the fence at the end.

  Human prose above (or below) the fence is never touched. This is the primitive
  the outbound PATCH uses so a hand-edited issue body keeps its human text while
  the blocks list stays in sync.
  """
  @spec upsert_blocks_marker(String.t(), [integer() | String.t()]) :: String.t()
  def upsert_blocks_marker(body, refs) when is_binary(body) and is_list(refs) do
    upsert_fenced(body, marker_block(refs), @blocks_start, @blocks_end)
  end

  @doc """
  Insert or replace the fenced acceptance-criteria checklist inside `body`,
  preserving every byte outside the fence. Idempotent, like
  `upsert_blocks_marker/2`. `criteria` is a list of `%{"criterion"|"text" => …,
  "met" => bool}` rows (plain strings tolerated). Empty/all-blank → strip the
  fence entirely. This is the primitive Wave 2's outbound PATCH uses to keep the
  liveness checkboxes in sync without clobbering hand-typed issue prose.
  """
  @spec upsert_acceptance_marker(String.t(), list()) :: String.t()
  def upsert_acceptance_marker(body, criteria) when is_binary(body) and is_list(criteria) do
    upsert_fenced(body, acceptance_block(criteria), @accept_start, @accept_end)
  end

  @doc """
  Insert or replace the fenced cap-flatten PARENT marker inside `body`,
  preserving every byte outside the fence. Idempotent, like the blocks marker.

  This is the D11 graceful-degradation surface: when the parent chain is too deep
  to link natively (a native sub-issue would flatten past GitHub's practical
  tree limits), the wiring hydrates the parent task id as a `"parent_marker"` key
  and the projection renders it as a body marker instead of a native link.

    * `parent_marker` a non-empty task-id string → upsert the fenced marker.
    * `nil`/blank → strip any existing parent fence (no marker).

  The parent id is scrubbed of any forged `barkpark:` sentinel first (same
  discipline as every other fence), so only the projection authors the sentinel.
  """
  @spec upsert_parent_marker(String.t(), String.t() | nil) :: String.t()
  def upsert_parent_marker(body, parent_marker) when is_binary(body) do
    upsert_fenced(body, parent_block(parent_marker), @parent_start, @parent_end)
  end

  # ---- internals -----------------------------------------------------------

  # Strip any existing fence for the given sentinels, then append the fresh block
  # (or leave it stripped when the block is nil). Shared by every fenced marker.
  defp upsert_fenced(body, block, start_sentinel, end_sentinel) do
    stripped = strip_fence(body, fence_regex(start_sentinel, end_sentinel))

    case block do
      nil -> stripped
      b -> append_block(stripped, b)
    end
  end

  defp title(content, doc_id) do
    case get(content, "title") do
      t when is_binary(t) and t != "" -> t
      # No title on the task — don't fabricate prose; anchor on the doc_id so the
      # issue is still identifiable and the projection stays deterministic.
      _ -> "Task #{doc_id}"
    end
  end

  defp body(content, doc_id, refs, parent_marker) do
    brief =
      case get(content, "description") do
        # Scrub any forged barkpark sentinel out of the human brief BEFORE we lay
        # down our own fences — Barkpark authors every sentinel (see moduledoc).
        d when is_binary(d) and d != "" -> d |> neutralize_sentinels() |> String.trim_trailing()
        _ -> ""
      end

    brief
    |> upsert_acceptance_marker(acceptance_criteria(content))
    |> upsert_blocks_marker(refs)
    |> upsert_parent_marker(parent_marker)
    |> append_trailer(doc_id)
  end

  # Labels from priority / status / worker / goal. Absent input → absent label
  # (never a fabricated placeholder). Sorted for a deterministic, diff-stable set.
  defp labels(content) do
    [
      priority_label(get(content, "priority")),
      status_label(get(content, "lifecycle_status")),
      worker_label(worker(content)),
      goal_label(get(content, "parent_id"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp priority_label(p) when is_integer(p) and p >= 0 and p <= 4, do: "priority:p#{p}"
  defp priority_label(_), do: nil

  defp status_label(s) when is_binary(s) and s != "", do: "status:#{s}"
  defp status_label(_), do: nil

  defp worker_label(w) when is_binary(w) and w != "", do: "worker:#{w}"
  defp worker_label(_), do: nil

  defp goal_label(g) when is_binary(g) and g != "", do: "goal:#{g}"
  defp goal_label(_), do: nil

  # The claimed worker lives at content.claim.worker; a flat content.worker is a
  # tolerated fallback. Never the epoch/fence — those are :never fields.
  defp worker(content) do
    case get(content, "claim") do
      claim when is_map(claim) -> get(claim, "worker") || get(content, "worker")
      _ -> get(content, "worker")
    end
  end

  defp blocker_refs(task_doc) do
    case get(task_doc, "blocker_issue_refs") do
      refs when is_list(refs) -> refs
      _ -> []
    end
  end

  # The cap-flatten parent task id the caller hydrated (D11), or nil.
  defp parent_marker(task_doc) do
    case get(task_doc, "parent_marker") do
      pid when is_binary(pid) and pid != "" -> pid
      _ -> nil
    end
  end

  defp acceptance_criteria(content) do
    case get(content, "acceptance_criteria") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ---- acceptance criteria -------------------------------------------------

  # Build the fenced checklist, or nil when no row carries usable text.
  defp acceptance_block(criteria) do
    items =
      criteria
      |> Enum.map(&acceptance_item/1)
      |> Enum.reject(&is_nil/1)

    case items do
      [] ->
        nil

      lines ->
        "#{@accept_start}\n### Acceptance criteria\n#{Enum.join(lines, "\n")}\n#{@accept_end}"
    end
  end

  # A row is either a map (`criterion`/`text` + `met`) or a bare string.
  defp acceptance_item(%{} = row) do
    text = get(row, "criterion") || get(row, "text")

    case text do
      t when is_binary(t) and t != "" ->
        box = if get(row, "met") == true, do: "x", else: " "
        "- [#{box}] #{criterion_line(t)}"

      _ ->
        nil
    end
  end

  defp acceptance_item(t) when is_binary(t) do
    case String.trim(t) do
      "" -> nil
      trimmed -> "- [ ] #{criterion_line(trimmed)}"
    end
  end

  defp acceptance_item(_), do: nil

  # Keep a criterion to a single well-formed list line: collapse newlines and
  # scrub any barkpark sentinel it might carry (adopted-outsider text).
  defp criterion_line(text) do
    text
    |> neutralize_sentinels()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.trim()
  end

  # Remove any `<!-- barkpark:… -->` comment (complete or a lone opener) from
  # human-authored text so only the projection can author a fence sentinel.
  defp neutralize_sentinels(text) do
    text
    |> String.replace(~r/<!--\s*barkpark:.*?-->/s, "")
    |> String.replace(~r/<!--\s*barkpark:[^\n]*/, "")
  end

  # ---- body assembly -------------------------------------------------------

  # Build the fenced block body, or nil when there are no blockers.
  defp marker_block([]), do: nil

  defp marker_block(refs) do
    line =
      refs
      |> Enum.map(&format_ref/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    case line do
      "" -> nil
      list -> "#{@blocks_start}\nBlocked by: #{list}\n#{@blocks_end}"
    end
  end

  defp format_ref(n) when is_integer(n) and n > 0, do: "##{n}"

  defp format_ref(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      "#" <> _ = ref -> ref
      other -> "##{other}"
    end
  end

  defp format_ref(_), do: nil

  # Build the fenced parent marker, or nil when there is no parent to flatten.
  # The parent id is scrubbed of any forged sentinel (adopted-outsider text can
  # never reach a task id, but the discipline is uniform across every fence).
  defp parent_block(pid) when is_binary(pid) do
    case pid |> neutralize_sentinels() |> String.trim() do
      "" -> nil
      clean -> "#{@parent_start}\nParent: #{clean}\n#{@parent_end}"
    end
  end

  defp parent_block(_), do: nil

  # Remove an existing fence (and the blank whitespace that padded it), leaving
  # everything else exactly as it was.
  defp strip_fence(body, regex) do
    body
    |> String.replace(regex, "")
    |> String.trim_trailing()
  end

  defp append_block(body, block) do
    case String.trim(body) do
      "" -> block
      trimmed -> "#{trimmed}\n\n#{block}"
    end
  end

  # Append `Task: <doc_id>` as the final trailer, once. Idempotent: if the body
  # already carries the trailer for THIS doc_id on its OWN line, leave it. The
  # match is line-exact — a substring guard would suppress the real trailer for
  # doc_id "gh-1" whenever the brief merely mentions "Task: gh-12".
  defp append_trailer(body, doc_id) do
    trailer = "#{@trailer_prefix} #{doc_id}"

    cond do
      has_trailer_line?(body, trailer) -> body
      String.trim(body) == "" -> trailer
      true -> "#{String.trim_trailing(body)}\n\n#{trailer}"
    end
  end

  defp has_trailer_line?(body, trailer) do
    body
    |> String.split("\n")
    |> Enum.any?(&(String.trim(&1) == trailer))
  end

  # Matches the fence and any leading blank lines so repeated strip/append never
  # accumulates whitespace. `(?s)` = dot matches newlines; non-greedy `.*?`.
  defp fence_regex(start_sentinel, end_sentinel) do
    ~r/\n*#{Regex.escape(start_sentinel)}.*?#{Regex.escape(end_sentinel)}/s
  end

  # ---- key-tolerant accessors ---------------------------------------------

  defp content(task_doc) do
    case get(task_doc, "content") do
      c when is_map(c) -> c
      _ -> %{}
    end
  end

  defp doc_id(task_doc) do
    get(task_doc, "doc_id") || get(task_doc, "id") || "unknown"
  end

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key))
    end
  end

  # Only resolve atoms that already exist — never create new ones from external
  # data (atom-table exhaustion guard).
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
