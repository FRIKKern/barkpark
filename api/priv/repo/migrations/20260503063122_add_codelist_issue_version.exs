defmodule Barkpark.Repo.Migrations.AddCodelistIssueVersion do
  @moduledoc """
  Phase 8 WI4 — backfills `issue_version: "73"` onto every legacy codelist
  reference that lacks one.

  Two data sources are walked:

    * `schema_definitions.fields` — the declarative side. Each field map
      whose `type == "codelist"` is a codelist *declaration*; we add
      `issue_version` so downstream tooling (`StalenessChecker`,
      OnixEdit admin LV) can resolve the pinned issue without falling
      back to the legacy `version` integer.
    * `documents.content` — the value side. For documents that captured
      the registry issue at write time as an inlined ref (any nested map
      that already carries a `codelistId` key), the migration adds
      `issue_version: "73"` if absent. Plain scalar codelist values
      (e.g. `"03"`) are left untouched — they have no slot for a pin.

  Idempotent: re-running yields the same shape (the `add_default/1`
  helper short-circuits when `issue_version` is already present).
  Reversible: `down/0` strips `issue_version` from every map that has
  both `issue_version` and a codelist-shaped sibling.

  ## Test seam

  `apply_up/1` and `apply_down/1` are exposed for the migration test —
  they accept a `Repo` module so the test can drive the transformation
  inside the sandboxed connection without invoking `up/0` / `down/0`
  directly (which the migration runner reserves).
  """

  use Ecto.Migration

  @default_issue "73"

  def up, do: forward(&add_default/1, repo())
  def down, do: forward(&strip/1, repo())

  @doc """
  Applies the up-transformation to every schema_definitions and documents
  row. Exposed for tests; production callers go through `up/0`.
  """
  def apply_up(repo \\ Barkpark.Repo), do: forward(&add_default/1, repo)

  @doc """
  Applies the down-transformation. Exposed for tests; production callers
  go through `down/0`.
  """
  def apply_down(repo \\ Barkpark.Repo), do: forward(&strip/1, repo)

  # ── orchestration ─────────────────────────────────────────────────────

  defp forward(transform, repo) do
    transform_schemas(transform, repo)
    transform_documents(transform, repo)
    :ok
  end

  # `schema_definitions.fields` is `jsonb[]` (a Postgres array of jsonb
  # objects), not a single `jsonb`. Casting `fields::text` directly returns
  # the Postgres array literal `{"{...}","{...}"}`, which is NOT valid JSON
  # and breaks `Jason.decode!`. We round-trip through `to_jsonb(fields)` so
  # the value reaches Elixir as a JSON array string, then on write-back we
  # let Postgres unfold a JSON-encoded array back into `jsonb[]` via
  # `jsonb_array_elements`.
  #
  # Note: the chained `$1::text::jsonb` cast is required. Postgrex's
  # text-format param binding does not coerce a `Jason.encode!` payload
  # directly into the jsonb scalar that `jsonb_array_elements/1` needs —
  # the bare `$1::jsonb` form raises SQLSTATE 22023 "cannot extract
  # elements from a scalar" against a real Postgres connection (even
  # though the same SQL with an inline literal works). The chained cast
  # forces Postgrex to bind the param as text and lets Postgres do the
  # text→jsonb cast in SQL on a known-text value, which is the standard
  # Postgrex jsonb param workaround.
  defp transform_schemas(transform, repo) do
    %{rows: rows} = repo.query!("SELECT id, to_jsonb(fields)::text FROM schema_definitions")

    Enum.each(rows, fn [id, fields_json] ->
      fields = Jason.decode!(fields_json)
      new_fields = Enum.map(fields, &walk(&1, transform))

      if new_fields != fields do
        repo.query!(
          """
          UPDATE schema_definitions
          SET fields = ARRAY(SELECT jsonb_array_elements($1::text::jsonb))::jsonb[]
          WHERE id = $2
          """,
          [Jason.encode!(new_fields), id]
        )
      end
    end)
  end

  defp transform_documents(transform, repo) do
    %{rows: rows} = repo.query!("SELECT id, content::text FROM documents")

    Enum.each(rows, fn [id, content_json] ->
      content = Jason.decode!(content_json)
      new_content = walk(content, transform)

      if new_content != content do
        repo.query!(
          "UPDATE documents SET content = $1 WHERE id = $2",
          [new_content, id]
        )
      end
    end)
  end

  # ── recursive walker ──────────────────────────────────────────────────

  # Walks any value, applying `transform` to maps that look like a
  # codelist ref. Recurses into maps and lists so nested composites,
  # arrays of composites, and the top-level container are all covered.
  defp walk(value, transform) when is_map(value) do
    transformed =
      if codelist_ref?(value) do
        transform.(value)
      else
        value
      end

    Map.new(transformed, fn {k, v} -> {k, walk(v, transform)} end)
  end

  defp walk(value, transform) when is_list(value) do
    Enum.map(value, &walk(&1, transform))
  end

  defp walk(value, _transform), do: value

  # ── codelist-ref classifier ───────────────────────────────────────────

  # A "codelist ref" is any map that:
  #   * declares `"type" => "codelist"` (schema_definitions side), OR
  #   * carries a `"codelistId"` key alongside structured ref data
  #     (documents side — used by inlined value annotations).
  defp codelist_ref?(%{} = m) do
    Map.get(m, "type") == "codelist" or Map.has_key?(m, "codelistId")
  end

  # ── transforms ────────────────────────────────────────────────────────

  defp add_default(%{} = m) do
    case Map.get(m, "issue_version") do
      nil -> Map.put(m, "issue_version", @default_issue)
      "" -> Map.put(m, "issue_version", @default_issue)
      _ -> m
    end
  end

  defp strip(%{} = m), do: Map.delete(m, "issue_version")
end
