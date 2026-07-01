defmodule BarkparkWeb.PaperTasks do
  @moduledoc """
  Renders the reader's **"Driven tasks"** section — the expectation REVERSE
  VIEW on the paper page (living-values lvw-t8, paper
  `nextgen-wiki-living-values-v1` §8/§9). Given the
  `Barkpark.Tasks.Expectations.driven_tasks/2` result (tasks that cite the
  paper via the materialised `design_doc`/`papers` edges), it emits an HTML
  block to append AFTER the paper body, next to "Linked mentions".

  Each task shows its title, lifecycle status, criteria progress (`m/n met`,
  omitted when the task has no criteria — the lvw-t6 convention), and the
  per-claim rows: a satisfied claim (`met === true`) renders with an accent
  ✓ and its evidence; an unmet one with a muted ○. Closing a task with
  met=true + evidence (the lvw-t9 close mechanism) flips the claim here on
  the next page read — no reprojection, no reactor.

  ## Contract

    * **Zero tasks → `""`.** The caller splices the string unconditionally;
      the section vanishes when no task cites the paper (mirrors
      `BarkparkWeb.PaperBacklinks.section_html/1`).
    * Published corpus by construction — the edge projector rebuilds at
      `perspective: :published`, and hydration is fail-closed under the
      caller's scope, so the public reader never sees a task it shouldn't.
    * Inline styles only (the `Render.Walk` / `PaperBacklinks` posture — no
      new stylesheet). All user text is HTML-escaped.
  """

  alias Barkpark.PortableDoc.Render.Util

  # Warm parchment palette, matched to PaperBacklinks / the `.bp-paper-article`
  # chrome (ink / muted / rule / accent). Inline so the section is
  # self-contained.
  @ink "#1a1a1a"
  @muted "#6a6a6a"
  @rule "#e6e2d8"
  @accent "#a23925"

  @doc """
  Render the "Driven tasks" section for a `driven_tasks/2` result (or a bare
  task list). Returns `""` for an empty list or any non-conforming input, so
  the caller can splice it in unconditionally.
  """
  @spec section_html(%{tasks: [map()]} | [map()]) :: String.t()
  def section_html(%{tasks: tasks}), do: section_html(tasks)

  def section_html(tasks) when is_list(tasks) and tasks != [] do
    items =
      tasks
      |> Enum.map(&task_html/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    if items == "" do
      ""
    else
      ~s(<section class="bp-paper-tasks" aria-label="Driven tasks" ) <>
        ~s(style="margin-top:3rem;padding-top:1.4rem;border-top:1px solid #{@rule}">) <>
        ~s(<h2 style="font-size:0.82rem;letter-spacing:0.06em;text-transform:uppercase;) <>
        ~s(color:#{@muted};margin:0 0 1rem">Driven tasks</h2>) <>
        ~s(<ul style="list-style:none;margin:0;padding:0">#{items}</ul>) <>
        ~s(</section>)
    end
  end

  def section_html(_), do: ""

  # One task: title + lifecycle + progress header, then the claim rows.
  defp task_html(%{doc_id: doc_id} = task) when is_binary(doc_id) and doc_id != "" do
    title_html = Util.escape_html(title_or_id(Map.get(task, :title), doc_id))
    status_html = status_chip(Map.get(task, :lifecycle_status))
    progress_html = progress_chip(Map.get(task, :criteria_progress))

    ~s(<li style="margin:0 0 1.4rem">) <>
      ~s(<div style="font-weight:600;color:#{@ink}">) <>
      title_html <>
      status_html <>
      progress_html <>
      ~s(</div>) <>
      criteria_html(Map.get(task, :criteria)) <>
      ~s(</li>)
  end

  defp task_html(_), do: ""

  defp status_chip(status) when is_binary(status) and status != "" do
    ~s( <span style="font-size:0.78rem;font-weight:400;color:#{@muted}">·&nbsp;) <>
      Util.escape_html(status) <> ~s(</span>)
  end

  defp status_chip(_), do: ""

  # Omitted entirely when nil — never "0/0" (the lvw-t6 contract).
  defp progress_chip(%{met: met, total: total}) do
    ~s( <span style="font-size:0.78rem;font-weight:400;color:#{@muted}">·&nbsp;#{met}/#{total} met</span>)
  end

  defp progress_chip(_), do: ""

  defp criteria_html(criteria) when is_list(criteria) and criteria != [] do
    rows = criteria |> Enum.map(&criterion_html/1) |> Enum.join("")
    ~s(<ul style="list-style:none;margin:0.4rem 0 0;padding:0">#{rows}</ul>)
  end

  defp criteria_html(_), do: ""

  # A satisfied claim: accent ✓ + its evidence (the provenance, §9). An unmet
  # claim: muted ○, no evidence line. A row with no criterion text still
  # renders its marker — an unnamed claim is visible, not hidden.
  defp criterion_html(%{met: true} = row) do
    ~s(<li style="margin:0.2rem 0;color:#{@ink}">) <>
      ~s(<span style="color:#{@accent};font-weight:600">✓</span> ) <>
      Util.escape_html(criterion_text(row)) <>
      evidence_html(Map.get(row, :evidence)) <>
      ~s(</li>)
  end

  defp criterion_html(%{} = row) do
    ~s(<li style="margin:0.2rem 0;color:#{@muted}">) <>
      ~s(<span>○</span> ) <>
      Util.escape_html(criterion_text(row)) <>
      ~s(</li>)
  end

  defp criterion_html(_), do: ""

  defp evidence_html(evidence) when is_binary(evidence) and evidence != "" do
    ~s( <span style="font-size:0.85rem;font-style:italic;color:#{@muted}">— ) <>
      Util.escape_html(evidence) <> ~s(</span>)
  end

  defp evidence_html(_), do: ""

  defp criterion_text(row) do
    case Map.get(row, :criterion) do
      t when is_binary(t) and t != "" -> t
      _ -> "(untitled criterion)"
    end
  end

  defp title_or_id(title, doc_id) do
    case title do
      t when is_binary(t) and t != "" -> t
      _ -> doc_id
    end
  end
end
