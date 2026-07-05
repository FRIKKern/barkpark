defmodule Barkpark.Tasks.WorkDigest do
  @moduledoc false
  # Semantic "was I edited under my claim?" digest over a task's WORK-DEFINING
  # fields — `title`, `content.description`, `content.acceptance_criteria`.
  #
  # A claim stamps `content.claim.work_digest` (a short combined hex) plus a
  # per-field companion map `content.claim.work_field_digests`. Close (on the
  # default, no-explicit-observed_rev path) recomputes both over the doc as it
  # stands and refuses when the combined digest drifted — the brief changed
  # under the worker, so a silent close would land against stale assumptions.
  #
  # This is DELIBERATELY narrower than a raw rev CAS: the documented workflow
  # patches `code_refs`, `labels`, `last_worked_at` between claim and close, and
  # those fields are NOT in the digest — so a self-edit never trips the fence.
  # Only a change to the actual work definition does. The digest only ever
  # compares against itself, so the canonical encoding just has to be
  # deterministic (map key order, JSON round-trips), not portable.

  # The work-defining fields, in the order `changed_fields/3` reports them.
  @fields ~w(title description acceptance_criteria)

  @doc """
  Per-field digest map for a task read as `title` (the `documents.title` column)
  and `content` (the JSON map carrying `description` + `acceptance_criteria`).
  Returns `%{"title" => h, "description" => h, "acceptance_criteria" => h}` where
  each `h` is a 16-hex sub-digest of that one field.
  """
  def field_digests(title, content) when is_map(content) do
    %{
      "title" => hash(title),
      "description" => hash(Map.get(content, "description")),
      "acceptance_criteria" => hash(Map.get(content, "acceptance_criteria"))
    }
  end

  def field_digests(title, _content), do: field_digests(title, %{})

  @doc """
  The single combined `work_digest` stamped on the claim — a 16-hex digest over
  the (deterministically normalized) per-field map. Derived FROM the sub-digests
  so a combined mismatch is equivalent to at least one field having changed.
  """
  def combined(field_digests) when is_map(field_digests), do: hash(field_digests)

  @doc """
  Convenience: `field_digests/2` + `combined/1` for a task's `title`/`content`,
  returning `{combined_hex, field_digest_map}` in one pass at claim time.
  """
  def stamp(title, content) do
    fields = field_digests(title, content)
    {combined(fields), fields}
  end

  @doc """
  The subset of `@fields` whose current sub-digest differs from the one stored
  on the claim — i.e. which of title/description/acceptance_criteria changed
  since the claim. Preserves `@fields` order; empty when nothing drifted.
  """
  def changed_fields(stored_field_digests, title, content)
      when is_map(stored_field_digests) do
    current = field_digests(title, content)

    Enum.filter(@fields, fn f ->
      Map.get(current, f) != Map.get(stored_field_digests, f)
    end)
  end

  def changed_fields(_stored, _title, _content), do: @fields

  # sha256 over a canonical binary of the normalized term, truncated to the
  # first 16 hex chars — short enough to be cheap in the claim JSON, wide enough
  # (64 bits) that an accidental collision between two distinct briefs is a
  # non-concern for a self-comparing fence.
  defp hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(normalize(term)))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # Canonicalize so the digest is stable across JSON round-trips and map key
  # insertion order: every map becomes a key-sorted list of `{string_key,
  # normalized_value}` pairs; lists KEEP their order (reordering
  # acceptance_criteria is a real change); scalars (incl. nil) pass through.
  defp normalize(m) when is_map(m) do
    m
    |> Enum.map(fn {k, v} -> {to_string(k), normalize(v)} end)
    |> Enum.sort()
  end

  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(other), do: other
end
