defmodule Barkpark.Plugins.OnixEdit.Actions do
  @moduledoc """
  Phase 8 Task #16 — thin action handlers the OnixEdit plugin owns.

  The native StudioLive editor knows nothing about ONIX, Bokbasen, or XSD
  validation. It does know how to invoke a named action declared in a
  schema's `actions` registry — either by following an `href` (kind:link)
  or by opening a generic `ConfirmModal` and routing the dry-run + real
  confirmation back through `phx-click` events (kind:modal). The thin
  shim here is the dispatch target for those events.

  This module is a stateless helper — no LiveView, no GenServer, no per-doc
  socket assigns. It accepts the minimal context (doc_id + dataset, mode)
  and returns plain tagged tuples. The caller (StudioLive) decides how to
  fold the result into its assigns / flash.

  Lifted verbatim (minus socket plumbing) from the now-deleted
  `BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor` in Phase 5 WI5. The
  underlying data-layer modules — `Bokbasen.PublishWorker`,
  `Bokbasen.Status`, `Export.to_iodata/1` — are unchanged; only the
  socket-shaped entry-points moved here.

  ## Public surface

    * `export_onix_path/2` — pure URL helper for the `kind:link` export
      action (mounted route in `Barkpark.Plugins.OnixEdit.Web.ExportController`).
    * `publish_to_bokbasen/3` — handles both `:dryrun` (in-memory XML
      render + summary) and `:real` (Oban enqueue + pending marker)
      modes. Returns `{:ok, result}` or `{:error, reason}` so the caller
      can map onto a flash + assign change.
  """

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status, as: BokbasenStatus
  alias Barkpark.Plugins.OnixEdit.Export

  @type mode :: :dryrun | :real
  @type dryrun_result :: %{kind: :xml, xml: binary(), summary: map()}
  @type real_result :: %{status: map(), job: Oban.Job.t()}

  @doc """
  Returns the canonical export URL for the `book` document at `doc_id`
  in `dataset`. Mirrors the path mounted by
  `Barkpark.Plugins.OnixEdit.Web.ExportController`.

  Used by the schema registry's `kind:link` export action — StudioLive
  interpolates this into the rendered `<a href>` so a click downloads
  the ONIX XML without a LiveView round-trip.
  """
  @spec export_onix_path(String.t(), String.t()) :: String.t()
  def export_onix_path(doc_id, dataset) when is_binary(doc_id) and is_binary(dataset) do
    pub_id = Content.published_id(doc_id)
    "/v1/plugins/onixedit/export/#{dataset}/#{pub_id}.onix"
  end

  @doc """
  Publish-to-Bokbasen action handler.

  Two modes:

    * `:dryrun` — render the document as ONIX XML in memory (XSD-validated
      by `Export.to_iodata/1`), return a preview map shaped
      `{:ok, %{kind: :xml, xml: <binary>, summary: <map>}}`. Does NOT
      enqueue an Oban job and does NOT write `bp_export_status`.

    * `:real` — enqueue `Bokbasen.PublishWorker` for the doc and write
      a `pending` marker into `bp_export_status` so any subscribed pill
      can flip immediately. Returns
      `{:ok, %{status: <Status.read map>, job: <Oban.Job>}}`.

  Error cases:

    * `{:error, :no_doc}` — `doc_id` does not resolve to a draft or
      published `book` document in `dataset`.
    * `{:error, {:xsd_invalid, reasons}}` — dry-run only; the rendered
      ONIX failed XSD validation.
    * `{:error, reason}` — Oban insert error or upstream Content error.

  ## Tenancy scope (barkpark-zdvi)

  The book read goes through `Content.get_document/4`, which applies the
  workspace/project envelope IN ADDITION TO the dataset-string filter.
  `publish_to_bokbasen/4` accepts a `scope` keyword
  (`[workspace_id: ..., project_id: ...]`) sourced from the dispatching
  StudioLive's `ScopeHelpers.scope_opts/1`. Without it, two workspaces
  that share the same `"production"` dataset string could resolve to each
  other's book (global resolution falls back to the Default project's
  dataset). The scope is also threaded into the enqueued `PublishWorker`
  job args so the worker re-reads the SAME tenant's doc.

  The arity-3 form is kept for back-compat (legacy callers / the
  arity-3 plugin `action_handler` contract) — it delegates with an empty
  scope, preserving the prior unscoped (Default-resolution) behaviour.
  """
  @spec publish_to_bokbasen(String.t(), String.t(), mode()) ::
          {:ok, dryrun_result()} | {:ok, real_result()} | {:error, term()}
  def publish_to_bokbasen(doc_id, dataset, mode),
    do: publish_to_bokbasen(doc_id, dataset, mode, [])

  @spec publish_to_bokbasen(String.t(), String.t(), mode(), keyword()) ::
          {:ok, dryrun_result()} | {:ok, real_result()} | {:error, term()}
  def publish_to_bokbasen(doc_id, dataset, :dryrun, scope)
      when is_binary(doc_id) and is_binary(dataset) and is_list(scope) do
    case load_book(doc_id, dataset, scope) do
      {:ok, doc} -> build_preview(doc)
      {:error, reason} -> {:error, reason}
    end
  end

  def publish_to_bokbasen(doc_id, dataset, :real, scope)
      when is_binary(doc_id) and is_binary(dataset) and is_list(scope) do
    case load_book(doc_id, dataset, scope) do
      {:ok, doc} -> enqueue_publish(doc, dataset, scope)
      {:error, reason} -> {:error, reason}
    end
  end

  # ── doc resolution ────────────────────────────────────────────────────────

  # Prefer draft over published, matching the
  # Barkpark.Plugins.OnixEdit.Web.ExportController selection precedence
  # (the historical BookEditor LV used the same precedence before its
  # removal). Both branches return `_type == "book"`
  # by virtue of the document carrying its own type; callers may still
  # surface a non-book error if they want stricter contracts.
  defp load_book(doc_id, dataset, scope) do
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    case Content.get_document(draft_id, "book", dataset, scope) do
      {:ok, doc} ->
        {:ok, doc}

      _ ->
        case Content.get_document(pub_id, "book", dataset, scope) do
          {:ok, doc} -> {:ok, doc}
          _ -> {:error, :no_doc}
        end
    end
  end

  # ── dryrun (preview) ──────────────────────────────────────────────────────

  defp build_preview(doc) do
    book_doc = book_doc_from(doc)

    case Export.to_iodata(book_doc) do
      {:ok, iodata} ->
        binary = IO.iodata_to_binary(iodata)
        {:ok, %{kind: :xml, xml: binary, summary: summarize(book_doc, binary)}}

      {:error, {:xsd_invalid, reasons}} ->
        {:error, {:xsd_invalid, reasons}}

      # Valid-but-unseeded (or non-string) ONIX codelist code — surface the
      # structured envelope to the dryrun caller instead of letting the
      # resolver raise escape as an unhandled crash.
      {:error, {:invalid_code, detail}} ->
        {:error, {:invalid_code, detail}}
    end
  end

  defp book_doc_from(%{} = doc) do
    pub_id = Content.published_id(doc.doc_id)

    (doc.content || %{})
    |> Map.delete("bp_export_status")
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_publishedId", pub_id)
    |> Map.put("_type", doc.type)
  end

  defp summarize(book_doc, xml) do
    title =
      case book_doc do
        %{"titleDetails" => [%{"titleText" => t} | _]} when is_binary(t) -> t
        %{"title" => t} when is_binary(t) -> t
        _ -> Map.get(book_doc, "_id", "")
      end

    isbn =
      book_doc
      |> Map.get("productIdentifiers", [])
      |> List.wrap()
      |> Enum.find(fn
        %{"productIdType" => t} -> t in ["15", "03"]
        _ -> false
      end)
      |> case do
        %{"idValue" => v} when is_binary(v) -> v
        _ -> nil
      end

    thema_count =
      book_doc
      |> Map.get("themaSubjectCategory", [])
      |> List.wrap()
      |> length()

    contrib_count =
      book_doc
      |> Map.get("contributors", [])
      |> List.wrap()
      |> length()

    %{
      title: title,
      isbn: isbn,
      thema_count: thema_count,
      contributor_count: contrib_count,
      byte_size: byte_size(xml)
    }
  end

  # ── real publish (Oban enqueue + pending marker) ──────────────────────────

  defp enqueue_publish(doc, dataset, scope) do
    args =
      %{"document_id" => doc.doc_id, "type" => doc.type, "dataset" => dataset}
      |> put_scope_args(scope)

    case Oban.insert(PublishWorker.new(args)) do
      {:ok, job} ->
        # Mark the doc as pending so any subscribed pill flips immediately.
        # Reuse the canonical write path (`Status.write/2` broadcasts on
        # PubSub) so the write is indistinguishable from a worker-driven
        # update.
        updated = BokbasenStatus.write(doc, %{"state" => "pending", "last_error" => nil})
        {:ok, %{status: BokbasenStatus.read(updated), job: job}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fold the tenancy scope into the Oban job args so PublishWorker re-reads
  # the SAME tenant's document. Nil-safe: an empty / nil-valued scope adds
  # nothing (old jobs without these keys fall back to Default resolution in
  # the worker — see PublishWorker.scope_opts_from_args/1).
  defp put_scope_args(args, scope), do: PublishWorker.put_scope_args(args, scope)
end
