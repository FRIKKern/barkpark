defmodule Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker do
  @moduledoc """
  Phase 8 WI4 — pure-data staleness analyzer for ONIX codelist refs.

  When a `book` document is written, every codelist ref is annotated with
  the registry `issue_version` it was validated against. As ONIX issues
  ship (74, 75, …), older refs drift out of date. The Bokbasen pipeline
  surfaces this drift via:

    * `detect_stale/2` — given a document and the current registry issue,
      returns one struct per ref describing whether it is `:current`,
      `:stale`, `:deprecated`, or `:acknowledged`.
    * `revalidate/2` — given a document and a current registry snapshot,
      returns a diff (`:added` / `:removed` / `:changed`) describing
      what would have to change to bring the doc to the current issue.

  Both functions are pure. They never touch the DB, never log, never
  call out — all inputs are passed in. The admin LV and the
  `mix codelists.staleness` task are responsible for assembling the
  registry snapshot before calling in.

  ## What counts as a codelist ref?

  A "codelist ref" is any nested map inside `book_doc.content` (or the
  content itself) that carries BOTH a `"codelistId"` key AND an
  `"issue_version"` key. The Phase 8 WI4 migration backfills
  `issue_version` onto every legacy ref, so this shape is stable across
  the corpus after the migration runs.

  Plain scalar codelist values (e.g. `"03"`) are ignored — they have no
  pin slot and contribute nothing to the staleness signal.

  ## Acknowledgement

  When a document carries `staleness_acknowledged: true` at the top of
  `content`, refs that would otherwise classify as `:stale` or
  `:deprecated` are instead reported as `:acknowledged`. `:current`
  refs are unaffected — acknowledgement is for drift the editor has
  consciously deferred, not for masking accurate data.
  """

  @typedoc """
  One classified ref returned from `detect_stale/2`.

    * `:path` — dotted JSON path inside `content`, e.g.
      `"contributors.0.role"`.
    * `:codelist` — the `codelistId` of the ref, e.g.
      `"onixedit:contributor_role"`.
    * `:ref_issue` — the issue the ref was pinned to.
    * `:current_issue` — the registry issue the document was checked
      against.
    * `:status` — one of `:current`, `:stale`, `:deprecated`,
      `:acknowledged`.
  """
  @type ref_status :: %{
          path: String.t(),
          codelist: String.t(),
          ref_issue: String.t() | nil,
          current_issue: String.t(),
          status: :current | :stale | :deprecated | :acknowledged
        }

  @typedoc """
  Snapshot of the current codelist registry as understood by the caller.
  Keyed by `codelistId`.

      %{
        "onixedit:contributor_role" => %{
          issue_version: "74",
          codes: ["A01", "A02", "A03", "A04"]
        },
        ...
      }

  `:codes` may be `nil` or `:any` to skip per-code validation for that
  codelist (useful for very large lists like Thema where the admin LV
  only cares about the issue pin, not value membership).
  """
  @type registry :: %{
          required(String.t()) => %{
            required(:issue_version) => String.t(),
            optional(:codes) => [String.t()] | nil | :any
          }
        }

  @typedoc """
  Whether a corpus-wide staleness read actually SAW anything.

    * `:empty` — the corpus held no documents. Nothing to say.
    * `:instrumented` — at least one document yielded at least one
      recognized codelist ref. The classification below it is a real
      measurement.
    * `:blind` — documents were read, and NOT ONE of them yielded a
      single recognized ref. Drift is UNMEASURED, not absent.
  """
  @type coverage :: :empty | :instrumented | :blind

  @doc """
  Non-vacuity check for a corpus-wide staleness read.

  `detect_stale/2` returns `[]` in two situations a caller cannot tell
  apart from the list alone:

    1. the document genuinely carries no codelist refs, and
    2. `codelist_ref?/1` recognized nothing, because the annotation this
       module's moduledoc promises ("every codelist ref is annotated with
       the registry `issue_version` it was validated against") is not
       actually performed by any writer.

  Case 2 is the dangerous one: every caller then reports `:current` for
  every book forever, and a silent instrument is indistinguishable from a
  healthy corpus. `codelist_ref?/1` requires BOTH `"codelistId"` AND
  `"issue_version"` on the same map, while `Barkpark.Content.Validation`
  rejects any `codelist` field whose value is not a plain string — so a
  book's `content` cannot hold that shape at all, and this analyzer reads
  zero refs on a real corpus.

  Pass the per-document ref lists (in any order) and this returns
  `:blind` when the whole corpus yielded nothing, so a caller can say
  "I looked in the wrong place" instead of "everything is current".
  It is a count the caller computed itself — not a second detector that
  can go quiet in the same way.

      corpus_coverage([])        #=> :empty
      corpus_coverage([[], []])  #=> :blind
      corpus_coverage([[], [r]]) #=> :instrumented
  """
  @spec corpus_coverage([[ref_status()]]) :: coverage()
  def corpus_coverage([]), do: :empty

  def corpus_coverage(per_document_refs) when is_list(per_document_refs) do
    if Enum.any?(per_document_refs, &(&1 != [])), do: :instrumented, else: :blind
  end

  @doc """
  Classify every codelist ref in `book_doc` against `current_issue`.

  `book_doc` may be a `%Barkpark.Content.Document{}` struct, a content
  map, or any map carrying a `:content` / `"content"` key that points
  at a content map. Returns a flat list — refs nested inside composites
  or arrays are surfaced with their full dotted path.
  """
  @spec detect_stale(map(), String.t()) :: [ref_status()]
  def detect_stale(book_doc, current_issue) when is_binary(current_issue) do
    content = extract_content(book_doc)
    acknowledged = Map.get(content, "staleness_acknowledged") == true

    content
    |> walk_refs([])
    |> Enum.map(&classify(&1, current_issue, acknowledged))
  end

  @doc """
  Compute the diff between the document's codelist refs and the current
  registry snapshot.

  Returns:

      %{
        added: [%{codelist: ..., issue_version: ...}, ...],
        removed: [%{path: ..., codelist: ..., code: ...}, ...],
        changed: [%{path: ..., codelist: ..., from: ..., to: ...}, ...]
      }

    * `:added` — codelists present in the current `registry` that the
      document never references. Surfaced so the admin LV can suggest
      enriching the document.
    * `:removed` — refs in the document whose value (`code`) is no
      longer present in the current registry's allowed codes.
    * `:changed` — refs whose `issue_version` differs from the
      registry's current issue.

  Acknowledged documents (`staleness_acknowledged: true`) get an empty
  diff — the editor explicitly accepted the drift, so re-validate is a
  no-op until they unset the flag.
  """
  @spec revalidate(map(), registry()) :: %{
          added: [map()],
          removed: [map()],
          changed: [map()]
        }
  def revalidate(book_doc, registry \\ %{}) when is_map(registry) do
    content = extract_content(book_doc)

    if Map.get(content, "staleness_acknowledged") == true do
      %{added: [], removed: [], changed: []}
    else
      doc_refs = walk_refs(content, [])
      doc_codelists = doc_refs |> Enum.map(fn {_path, ref} -> Map.get(ref, "codelistId") end)

      added = compute_added(registry, doc_codelists)
      removed = compute_removed(doc_refs, registry)
      changed = compute_changed(doc_refs, registry)

      %{added: added, removed: removed, changed: changed}
    end
  end

  # ── content extraction ────────────────────────────────────────────────

  defp extract_content(%{__struct__: _} = struct) do
    case Map.get(struct, :content) do
      nil -> %{}
      content when is_map(content) -> content
    end
  end

  defp extract_content(%{} = m) do
    cond do
      is_map(Map.get(m, :content)) -> Map.get(m, :content)
      is_map(Map.get(m, "content")) -> Map.get(m, "content")
      true -> m
    end
  end

  defp extract_content(_), do: %{}

  # ── recursive ref walker ──────────────────────────────────────────────

  # Returns a list of `{path_parts, ref_map}` tuples in document order.
  # Path parts are reversed during the walk and reversed back on emit so
  # the public path reads top-down.
  defp walk_refs(value, path) when is_map(value) do
    direct =
      if codelist_ref?(value) do
        [{Enum.reverse(path), value}]
      else
        []
      end

    nested =
      value
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.flat_map(fn {k, v} -> walk_refs(v, [k | path]) end)

    direct ++ nested
  end

  defp walk_refs(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, idx} -> walk_refs(v, [idx | path]) end)
  end

  defp walk_refs(_, _), do: []

  defp codelist_ref?(%{} = m) do
    Map.has_key?(m, "codelistId") and Map.has_key?(m, "issue_version")
  end

  # ── classification ────────────────────────────────────────────────────

  defp classify({path, ref}, current_issue, acknowledged) do
    ref_issue = Map.get(ref, "issue_version")
    codelist = Map.get(ref, "codelistId")
    deprecated? = Map.get(ref, "deprecated") == true

    base_status =
      cond do
        deprecated? -> :deprecated
        is_nil(ref_issue) -> :stale
        ref_issue == current_issue -> :current
        compare_issue(ref_issue, current_issue) == :lt -> :stale
        true -> :current
      end

    status =
      if acknowledged and base_status in [:stale, :deprecated],
        do: :acknowledged,
        else: base_status

    %{
      path: format_path(path),
      codelist: codelist,
      ref_issue: ref_issue,
      current_issue: current_issue,
      status: status
    }
  end

  defp format_path([]), do: ""
  defp format_path(parts), do: Enum.map_join(parts, ".", &to_string/1)

  defp compare_issue(a, b) when is_binary(a) and is_binary(b) do
    case {Integer.parse(a), Integer.parse(b)} do
      {{na, ""}, {nb, ""}} ->
        cond do
          na < nb -> :lt
          na > nb -> :gt
          true -> :eq
        end

      _ ->
        cond do
          a < b -> :lt
          a > b -> :gt
          true -> :eq
        end
    end
  end

  defp compare_issue(_, _), do: :eq

  # ── revalidate diff ───────────────────────────────────────────────────

  defp compute_added(registry, doc_codelists) do
    doc_set = MapSet.new(doc_codelists)

    registry
    |> Enum.reject(fn {codelist_id, _} -> MapSet.member?(doc_set, codelist_id) end)
    |> Enum.map(fn {codelist_id, snapshot} ->
      %{codelist: codelist_id, issue_version: Map.get(snapshot, :issue_version)}
    end)
    |> Enum.sort_by(& &1.codelist)
  end

  defp compute_removed(doc_refs, registry) do
    doc_refs
    |> Enum.flat_map(fn {path, ref} ->
      codelist = Map.get(ref, "codelistId")
      code = Map.get(ref, "code") || Map.get(ref, "value")
      snapshot = Map.get(registry, codelist)

      cond do
        is_nil(snapshot) -> []
        is_nil(code) -> []
        codes_allow_any?(snapshot) -> []
        code in (Map.get(snapshot, :codes) || []) -> []
        true -> [%{path: format_path(path), codelist: codelist, code: code}]
      end
    end)
  end

  defp compute_changed(doc_refs, registry) do
    doc_refs
    |> Enum.flat_map(fn {path, ref} ->
      codelist = Map.get(ref, "codelistId")
      ref_issue = Map.get(ref, "issue_version")
      snapshot = Map.get(registry, codelist)
      current = snapshot && Map.get(snapshot, :issue_version)

      cond do
        is_nil(snapshot) -> []
        is_nil(current) -> []
        ref_issue == current -> []
        true -> [%{path: format_path(path), codelist: codelist, from: ref_issue, to: current}]
      end
    end)
  end

  defp codes_allow_any?(%{codes: nil}), do: true
  defp codes_allow_any?(%{codes: :any}), do: true
  defp codes_allow_any?(%{} = snap), do: not Map.has_key?(snap, :codes)
end
