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

      <!-- barkpark:blocks:start -->
      Blocked by: #12, #34
      <!-- barkpark:blocks:end -->

      Task: <doc_id>

  The `Task: <doc_id>` trailer (D11) is what keeps `pr-task-gate` working from a
  GitHub-side PR. The blocks marker is rewritten ONLY inside its fence — any
  human prose above the fence is preserved — so re-projecting is idempotent:
  `upsert_blocks_marker(upsert_blocks_marker(body, refs), refs) == upsert_blocks_marker(body, refs)`.

  Blocker issue refs are NOT discovered here (that needs the blockers' mirror
  state, which is DB-resident); the caller hydrates them onto the doc as
  `"blocker_issue_refs"` — a list of issue numbers — exactly like the edge
  projector hydrates `task_edges`. Absent → no marker block (leave it ABSENT
  when unknown; never fabricate a blocker).
  """

  @blocks_start "<!-- barkpark:blocks:start -->"
  @blocks_end "<!-- barkpark:blocks:end -->"
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
      body: body(content, doc_id, blocker_refs(task_doc)),
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
    stripped = strip_marker(body)

    case marker_block(refs) do
      nil -> stripped
      block -> append_block(stripped, block)
    end
  end

  # ---- internals -----------------------------------------------------------

  defp title(content, doc_id) do
    case get(content, "title") do
      t when is_binary(t) and t != "" -> t
      # No title on the task — don't fabricate prose; anchor on the doc_id so the
      # issue is still identifiable and the projection stays deterministic.
      _ -> "Task #{doc_id}"
    end
  end

  defp body(content, doc_id, refs) do
    brief =
      case get(content, "description") do
        d when is_binary(d) and d != "" -> String.trim_trailing(d)
        _ -> ""
      end

    brief
    |> upsert_blocks_marker(refs)
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

  # Remove an existing fence (and the blank whitespace that padded it), leaving
  # everything else exactly as it was.
  defp strip_marker(body) do
    body
    |> String.replace(marker_regex(), "")
    |> String.trim_trailing()
  end

  defp append_block(body, block) do
    case String.trim(body) do
      "" -> block
      trimmed -> "#{trimmed}\n\n#{block}"
    end
  end

  # Append `Task: <doc_id>` as the final trailer, once. If the body already ends
  # with the trailer for THIS doc_id (idempotent re-projection), leave it.
  defp append_trailer(body, doc_id) do
    trailer = "#{@trailer_prefix} #{doc_id}"

    cond do
      String.contains?(body, trailer) -> body
      String.trim(body) == "" -> trailer
      true -> "#{String.trim_trailing(body)}\n\n#{trailer}"
    end
  end

  # Matches the fence and any leading blank lines so repeated strip/append never
  # accumulates whitespace. `(?s)` = dot matches newlines; non-greedy `.*?`.
  defp marker_regex do
    ~r/\n*#{Regex.escape(@blocks_start)}.*?#{Regex.escape(@blocks_end)}/s
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
