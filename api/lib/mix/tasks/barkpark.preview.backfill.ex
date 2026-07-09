defmodule Mix.Tasks.Barkpark.Preview.Backfill do
  @moduledoc """
  Stamp the write-time **preview manifest** (`content["preview"]`) onto LEGACY
  published block-bearing documents that predate write-time projection (pc-w1,
  #1903). The reader covers itself with a read-time fallback, but the OTHER
  consumers — the web finder's `generateMetadata`, Studio/TUI card rows, the
  Projects board embeds — read the STAMPED manifest off the envelope (Next.js
  cannot call `Barkpark.Preview`). This task makes the manifest real across the
  corpus so every surface unfurls a rich card without a per-surface reimplementation.

  For every PUBLISHED block-bearing doc (`paper` / `sheet` / `form` — the same
  set that gets `content["body"]`) it re-runs `Barkpark.Preview.project/3` with
  a workspace-SCOPED media resolver bound to the doc's OWN `workspace_id` /
  `project_id` (never an unscoped lookup — cross-tenant blob leak, barkpark-af50),
  the reader url, and the raw doctype, then stamps the result under
  `content["preview"]`.

  ## Safe by default — dry-run (D3)

  A bare invocation is a DRY RUN — it reports what WOULD be stamped and writes
  NOTHING. Pass `--apply` to write.

      # report only (writes nothing) — the safe default
      mix barkpark.preview.backfill
      mix barkpark.preview.backfill --dry-run

      # perform the backfill
      mix barkpark.preview.backfill --apply

  ## Write mechanics (D21)

  The stamp is a `Barkpark.Preview.project/3` → `Document.changeset` →
  `Repo.update` — the `DoctrineBackfill.persist/2` no-broadcast precedent ("an
  offline migration, not a live edit"). It does NOT route through the Content
  writer (whose `tap_broadcast` would fire one SSE event per doc — the storm) and
  does NOT call `Projection.project` (which also rewrites `content["body"]` with
  style-less render_opts — `body_html` drift on styled papers). This change is
  render-IDENTICAL: it stamps ONLY `content["preview"]` and bumps NEITHER
  `content["rev"]` NOR the row `rev` (the Ecto `updated_at` tick is the accepted
  "normal re-save"). Drafts are never touched (`status == "published"` only).

  ## Idempotent

  The new manifest is compared to the existing `content["preview"]` by plain map
  equality; an identical manifest SKIPS the `Repo.update` entirely. The resolver
  is deterministic, so a second `--apply` run stamps nothing (the migration's
  no-op proof).

  ## Ordering hazard (HUMAN-GATED apply)

  The guerrilla `--apply` run happens ONLY after pc-w2b (the `node_text`
  inline-mark fix) is merged AND deployed. A pre-fix run would stamp GARBLED
  descriptions which the reader then serves in preference to the fixed read-time
  path (`share_meta.ex` prefers a stamped manifest). This code rides the fixed
  `Barkpark.Preview.node_text` so a stale build cannot silently stamp garble — a
  marked-up paragraph flows through to a clean sentence (proved in the test).

      # 1. Dry-run — inspect the per-doc report + counts. Writes nothing.
      mix barkpark.preview.backfill

      # 2. Apply on guerrilla ONLY after pc-w2b is deployed. Re-run the dry-run
      #    to confirm the sweep is idempotent (to-stamp → 0 on the second run).
      mix barkpark.preview.backfill --apply
  """
  @shortdoc "Stamp content[preview] onto legacy published block-docs (dry-run by default; --apply to write)"

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.Document
  alias Barkpark.Preview
  alias Barkpark.Repo

  # The block-bearing published doctypes — the same set that carries
  # `content["body"]`. Kept general even though sheets/forms have zero published
  # docs today; the Elixir-side `is_list(content["blocks"])` filter is the real
  # gate (blocks never appear on the public envelope, so it is checked in Elixir,
  # never via HTTP).
  @block_types ~w(paper sheet form)

  @switches [dry_run: :boolean, apply: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    # Safe default: write ONLY when --apply is given (and not negated by
    # --dry-run). Any other combination is a dry run.
    dry_run? = not (Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false))

    {:ok, stats} = backfill(dry_run: dry_run?)

    log_report(stats, fn line -> Mix.shell().info(line) end)

    if dry_run? do
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to stamp.")
    end

    if stats.errors != [] do
      System.halt(1)
    end
  end

  @typedoc "One stamped (or would-stamp) entry in the report."
  @type entry :: %{
          slug: String.t(),
          type: String.t(),
          dataset: String.t(),
          has_image: boolean()
        }

  @type stats :: %{
          scanned: non_neg_integer(),
          stamped: [entry()],
          unchanged: non_neg_integer(),
          errors: [%{slug: String.t(), dataset: String.t(), reason: String.t()}],
          dry_run: boolean()
        }

  @doc """
  Sweep every published block-bearing document and stamp `content["preview"]`.

  `opts`:

    * `:dry_run` (default `true`) — when true, computes the plan and reports it
      but writes NOTHING; when false, stamps changed docs via a no-broadcast
      `Repo.update`.

  Returns `{:ok, stats}`. Idempotent: a doc whose freshly-projected manifest
  equals its stored `content["preview"]` is counted `unchanged` and never
  written. Per-doc rescue: one malformed doc is recorded in `errors` and the
  sweep continues.
  """
  @spec backfill(keyword()) :: {:ok, stats()}
  def backfill(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    docs = block_bearing_docs()

    acc0 = %{stamped: [], unchanged: 0, errors: []}

    acc =
      Enum.reduce(docs, acc0, fn doc, acc ->
        process(doc, dry_run?, acc)
      end)

    stats = %{
      scanned: length(docs),
      stamped: Enum.reverse(acc.stamped),
      unchanged: acc.unchanged,
      errors: Enum.reverse(acc.errors),
      dry_run: dry_run?
    }

    {:ok, stats}
  end

  # Every PUBLISHED doc of a block-bearing type, then the Elixir-side
  # is_list(content["blocks"]) gate. `status` is the plain string column
  # (document.ex) — "published" honours "do not touch drafts". Unscoped read:
  # one pass across every workspace / project / dataset, the resolver is scoped
  # PER doc from that row's own tenancy.
  defp block_bearing_docs do
    from(d in Document, where: d.type in @block_types and d.status == "published")
    |> Repo.all()
    |> Enum.filter(&is_list(get_in(&1.content, ["blocks"])))
  end

  # Compute + compare + (maybe) stamp one doc. Wrapped so a single malformed doc
  # (a projection raise, a save refusal) is recorded and the sweep continues.
  defp process(%Document{} = doc, dry_run?, acc) do
    content = doc.content
    blocks = get_in(content, ["blocks"]) || []

    manifest = Preview.project(content, blocks, preview_opts(doc))

    cond do
      manifest == Map.get(content, "preview") ->
        # Idempotent no-op: the stored manifest already matches. Deterministic
        # resolver ⇒ the second --apply run lands entirely here.
        %{acc | unchanged: acc.unchanged + 1}

      dry_run? ->
        %{acc | stamped: [entry(doc, manifest) | acc.stamped]}

      true ->
        case stamp(doc, content, manifest) do
          {:ok, _} ->
            %{acc | stamped: [entry(doc, manifest) | acc.stamped]}

          {:error, changeset} ->
            record_error(doc, "save refused: #{inspect(changeset.errors)}", acc)
        end
    end
  rescue
    error ->
      record_error(doc, "projection/stamp raised: #{Exception.message(error)}", acc)
  end

  # The :preview sub-map — the block_ops.ex paper_preview_opts shape, generalised
  # over doctype: a media resolver bound to THIS doc's own tenancy scope
  # (barkpark-af50 — never unscoped when scope is in hand), the reader url, and
  # the raw doctype. Plus `:title` = the ROW title, exactly as the read-time
  # fallback threads it (share_meta.ex `read_time_manifest`): it is Preview's LAST
  # title fallback (content["title"]/title-block win), so a legacy paper whose
  # title lives only on the row still stamps under its real name — the stamped
  # manifest BYTE-MATCHES what the reader already serves, so deploy is invisible.
  defp preview_opts(%Document{} = doc) do
    scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]

    %{
      media_resolver: Preview.media_resolver(scope),
      url: reader_url(doc.type, doc.doc_id),
      doc_type: doc.type,
      title: doc.title
    }
  end

  # The canonical relative reader url per doctype; forms have no public reader, so
  # the manifest url stays nil (Preview leaves it nil — matching the generic
  # doc_project_opts path).
  defp reader_url("paper", slug), do: "/papers/#{slug}"
  defp reader_url("sheet", slug), do: "/sheets/#{slug}"
  defp reader_url(_type, _slug), do: nil

  # Stamp ONLY content["preview"]; cast ONLY :content so the row's scope columns,
  # status, title, and rev are preserved. Direct Repo.update — no broadcast, no
  # rev bump (D21): render-identical offline migration.
  defp stamp(%Document{} = doc, content, manifest) do
    doc
    |> Document.changeset(%{"content" => Map.put(content, "preview", manifest)})
    |> Repo.update()
  end

  defp entry(%Document{} = doc, manifest) do
    %{
      slug: doc.doc_id,
      type: doc.type,
      dataset: doc.dataset,
      has_image: is_map(Map.get(manifest, "image"))
    }
  end

  defp record_error(%Document{} = doc, reason, acc) do
    Logger.error("preview.backfill: #{reason} for #{inspect(doc.doc_id)} (#{doc.dataset})")

    %{acc | errors: [%{slug: doc.doc_id, dataset: doc.dataset, reason: reason} | acc.errors]}
  end

  @doc """
  Emit the human report via `emit.(line)`. Public so both the Mix task and the
  test can render the same summary.
  """
  @spec log_report(stats(), (String.t() -> any())) :: :ok
  def log_report(%{} = stats, emit) when is_function(emit, 1) do
    verb = if stats.dry_run, do: "would stamp", else: "stamped"

    emit.("""
    preview backfill (#{mode(stats.dry_run)}):
      scanned:   #{stats.scanned} published block-bearing docs
      #{pad(verb)} #{length(stats.stamped)}
      unchanged: #{stats.unchanged} (manifest already current)
      errors:    #{length(stats.errors)}\
    """)

    sample = Enum.take(stats.stamped, 10)

    if sample != [] do
      emit.("\n  sample (#{verb}):")

      Enum.each(sample, fn e ->
        img = if e.has_image, do: " [image]", else: ""
        emit.("    #{e.type}/#{e.slug} (#{e.dataset})#{img}")
      end)
    end

    if stats.errors != [] do
      emit.("\n  errors:")
      Enum.each(stats.errors, fn e -> emit.("    #{e.slug} (#{e.dataset}) — #{e.reason}") end)
    end

    :ok
  end

  defp mode(true), do: "dry-run"
  defp mode(false), do: "apply"

  # Right-pad the verb so the count column lines up with the other summary rows.
  defp pad(verb), do: String.pad_trailing(verb <> ":", 10)
end
