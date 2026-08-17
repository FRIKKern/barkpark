defmodule Barkpark.Plugins.OnixEdit.Bokbasen.Status do
  @moduledoc """
  Phase 8 WI1 — public read/write façade for `bp_export_status`.

  Phase 7 WI4 stored status as a JSON-encoded string. Phase 8 WI1 promoted
  the field to a native composite map. This module is the only sanctioned
  entry point for reading or writing the field — all callers (PublishWorker,
  AdminLive, StudioLive's native editor, mix tasks) go through `read/1`
  and `write/2`. (The plugin BookEditor LV that originally shared this
  façade was removed in Goal `barkpark-zdy`.)

  ## Backwards compatibility

  `read/1` accepts every shape we have ever persisted:

    * `nil` / `""`                           → empty composite (`%{}`)
    * legacy plain string (`"draft"`, …)     → `%{"state" => string}`
    * Phase 7 JSON-encoded map (string)      → decoded composite
    * Phase 8 native map                     → as-is

  String keys are preserved for parity with Phase 7 internals (the worker
  always wrote string keys via `Jason.encode!/1`). Callers passing atom
  keys to `write/2` are converted to strings for storage.

  ## Write semantics

    * Merges the patch over the current composite (last-write-wins per key).
    * Always stamps `updated_at` with the current UTC time (ISO-8601).
    * **Derives `signed_off: true` whenever `accepted_at` is present** in
      the merged result — Bokbasen acceptance is the canonical sign-off
      signal; deriving here keeps the rule out of every caller.
    * Persists via `Document.changeset/2` + `Repo.update/1`.
    * Rejoins the canonical Content event spine after commit: writes a
      `mutation_events` row and fires `Content.broadcast_document_mutation/3`
      (action `"update"`, with `:event_id`) so the SSE `/v1/data/listen`
      endpoint, webhooks, and cache revalidation see the write — a raw
      `Repo.update` alone is invisible to all three (felix-w25-s4).
    * Broadcasts `{:bokbasen_status_update, merged_status}` on
      `bokbasen:document:<doc_id>` so subscribed LiveViews refresh
      without a re-fetch. PRESERVED alongside the canonical emission.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @doc """
  Read the normalized composite status map for a document.

  Accepts a `%Document{}` or a content map. Returns a string-keyed map.
  """
  @spec read(Document.t() | map() | nil) :: map()
  def read(%Document{content: content}) when is_map(content) do
    content |> Map.get("bp_export_status") |> normalize()
  end

  def read(%{} = content) do
    content |> Map.get("bp_export_status") |> normalize()
  end

  def read(_), do: %{}

  @doc """
  Merge `patch` into the current `bp_export_status` composite, persist via
  `Document.changeset/2`, emit a canonical `mutation_events` row + broadcast so
  the write is visible to SSE/webhooks/cache-revalidation, and broadcast the
  merged map on the plugin-private `bokbasen:document:<doc_id>` topic.

  Atom-keyed patches are converted to string keys. When the merged status
  contains `accepted_at`, `signed_off` is derived to `true`.
  """
  @spec write(Document.t(), map()) :: Document.t()
  def write(%Document{} = doc, patch) when is_map(patch) do
    # Re-fetch from DB so back-to-back writes against the same in-memory
    # doc reference still merge correctly (the worker calls write/2 twice
    # within stage_step / do_stage and we must preserve fields written by
    # the first call when the second runs).
    fresh = Repo.get!(Document, doc.id)
    current = read(fresh)
    patch_strk = stringify_keys(patch)

    merged =
      current
      |> Map.merge(patch_strk)
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> derive_signed_off()

    new_content = Map.put(fresh.content || %{}, "bp_export_status", merged)

    {:ok, updated} =
      fresh
      |> Document.changeset(%{"content" => new_content})
      |> Repo.update()

    # NAMED FAILURE MODE (cross-context write bypassing the Content event path):
    # the raw Repo.update above is the sanctioned state-preserving write (charter
    # D170 keeps it — Content.upsert_document would force a draft twin and coerce
    # a published book row published→draft), but on its own the SSE
    # /v1/data/listen endpoint, webhooks, and cache revalidation never saw a
    # bp_export_status write. Rejoin the canonical event spine AFTER commit: a
    # self-written mutation_events row (the listen controller drops frames whose
    # msg has no :event_id) + the canonical fan-out on documents:<dataset> +
    # per-doc + workspace topics. `fresh.rev` is the rev observed before the write.
    ev =
      Broadcast.save_event(updated, updated.type, updated.dataset, "update", fresh.rev, :onixedit)

    Content.broadcast_document_mutation(updated, "update",
      event_id: ev.id,
      previous_rev: fresh.rev
    )

    # PRESERVED plugin-private broadcast: the Bokbasen AdminLive / StudioLive
    # native-editor consumers subscribe to bokbasen:document:<id> and refresh
    # off {:bokbasen_status_update, merged} without a re-fetch. The canonical
    # emission above is ADDITIVE — it does not replace this topic.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "bokbasen:document:#{doc.doc_id}",
      {:bokbasen_status_update, merged}
    )

    updated
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp normalize(nil), do: %{}
  defp normalize(""), do: %{}

  defp normalize(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> map
      _ -> %{"state" => value}
    end
  end

  defp normalize(%{} = map), do: map
  defp normalize(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_value(v)}
      {k, v} -> {k, normalize_value(v)}
    end)
  end

  defp normalize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_value(%{} = m) when not is_struct(m), do: stringify_keys(m)
  defp normalize_value(v), do: v

  defp derive_signed_off(%{"accepted_at" => at} = merged) when not is_nil(at) do
    Map.put(merged, "signed_off", true)
  end

  defp derive_signed_off(merged), do: merged
end
