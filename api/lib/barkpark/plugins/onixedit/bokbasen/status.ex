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
    * Broadcasts `{:bokbasen_status_update, merged_status}` on
      `bokbasen:document:<doc_id>` so subscribed LiveViews refresh
      without a re-fetch.
  """

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
  `Document.changeset/2`, and broadcast the merged map on
  `bokbasen:document:<doc_id>`.

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
