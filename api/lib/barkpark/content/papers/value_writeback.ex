defmodule Barkpark.Content.Papers.ValueWriteback do
  @moduledoc """
  lvw-t10 — gated edit-through for inline valuerefs (writeback v1.5, strategy
  paper `nextgen-wiki-living-values-v1` §11 "the sharp knife").

  Editing a valueref in Studio may mutate the CANONICAL target document's
  field — never as an implicit prose-edit side effect, only through the
  explicit affordance this module authorizes. Three mandatory gates:

    1. **Explicit affordance** — the Studio panel renders a write control
       only after `inspect_target/4` authorized it, and `writeback/6`
       re-derives the full authorization server-side on confirm (the hidden
       control is UX; THIS module is the security boundary).

    2. **Authorization against the TARGET** (§11 clause 1) — evaluated
       against the target canonical doc's write scope, NEVER the hosting
       paper's: the caller principal must be write-capable
       (`write_capable?/1` — anonymous never; an api_token needs
       `write`/`admin`; an authenticated user rides its resolved workspace
       membership) AND the target must resolve under the CALLER's own
       tenancy/ownership scope opts (`Content.resolve_docs_by_ids/3` —
       cross-scope, cross-owner, or nonexistent targets are indistinguishable:
       `{:error, :unauthorized}`, no existence oracle). A field the caller
       cannot READ (redacted by the envelope) or that is not DECLARED in the
       target's schema refuses edit-through (fail closed).

    3. **Impact preview** (§11 clause 2) — "changes N docs" comes from
       `Content.Graph.reverse_referencers/2` called with the caller's scope
       opts, inheriting its MEDIUM-5 fail-closed hydration wholesale:
       out-of-scope referencers are dropped ENTIRELY — no titles, no stub,
       and NO aggregate "K you cannot see" count. The impact map carries
       `:count` and `:referencers` and nothing else; `count` is always
       `length(referencers)` (deduped per source doc). The valueref-kind
       edges from the body-walk extractor feed this, same as the shipped
       used-by panel (lvw-t3).

  The write itself goes through the EXISTING guarded mutation path —
  `Content.apply_mutations/3` with a `patch` op + `ifRevisionID` CAS (rev
  conflict ⇒ `{:error, {:rev_mismatch, …}}`, nothing written) — so tenancy
  stamping, field encryption, lifecycle hooks, edge reprojection, deferred
  broadcasts and the redacted echo all apply; never a raw `Repo` write (the
  paper block-op writers bypassing WriteScope are the cautionary precedent,
  wire §7). Provenance: the guarded path records the ordinary `update`
  revision with `actor_user_id`, and a best-effort attributed revision with
  action `"valueref-writeback"` is tapped on top (the lvw-t2
  `valueref-accept-baseline` posture) so version history names the sanctioned
  edit-through.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, CallerContext, Document, DraftId, Envelope, Graph}

  @revision_action "valueref-writeback"

  # Keys the patch path protects; edit-through refuses them outright (they are
  # not content fields — `title` IS a content-adjacent field but flows through
  # the dedicated patch `set` semantics; keep v1 to declared content fields).
  @protected_fields ~w(title status _id _type _rev doc_id)

  @type inspect_result :: %{
          doc_id: String.t(),
          type: String.t(),
          rev: String.t() | nil,
          title: String.t() | nil,
          current_value: String.t() | nil,
          impact: %{count: non_neg_integer(), referencers: [map()]}
        }

  @doc """
  Authorize edit-through for `(target, field)` under the caller's scope opts
  and, when authorized, return the resolved target + the impact preview.

  Returns `{:ok, inspect_result}` or `{:error, :unauthorized}` /
  `{:error, :invalid_field}`. Unauthorized is deliberately UNIFORM across
  "no write-capable principal", "target out of the caller's scope",
  "target does not exist", "no schema", "field undeclared" and "field
  redacted for this caller" — the affordance disables entirely with no
  existence/visibility oracle.
  """
  @spec inspect_target(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, inspect_result()} | {:error, :unauthorized | :invalid_field}
  def inspect_target(target, field, dataset, opts \\ []) do
    with :ok <- validate_field(field),
         :ok <- validate_target(target),
         {:ok, caller} <- write_capable_caller(opts),
         {:ok, doc} <- resolve_target(target, dataset, opts),
         {:ok, schema} <- target_schema(doc.type, dataset, opts),
         :ok <- ensure_declared(schema, field),
         {:ok, current} <- readable_value(doc, schema, caller, field) do
      {:ok,
       %{
         doc_id: doc.doc_id,
         type: doc.type,
         rev: write_target_rev(doc, dataset, opts),
         title: doc.title,
         current_value: current,
         impact: impact_preview(doc.doc_id, dataset, opts)
       }}
    end
  end

  # The `rev` handed back is the CAS token the confirm-time writeback pins as
  # `ifRevisionID` — so it MUST name the row the guarded patch actually fences
  # against. That row is decided by `Mutations.get_patch_base/4`, which reads
  # the DRAFT twin first and falls back to the canonical row only when no draft
  # exists (merge base == write target). `resolve_target` above prefers the
  # PUBLISHED row (D3), so pinning `doc.rev` would name the published rev while
  # get_patch_base fences the draft twin — a guaranteed `{:rev_mismatch}` for
  # EVERY target that has a clean (non-diverged) draft twin, the most common
  # live-Studio state. Derive the rev from the very same row get_patch_base
  # will read (draft-twin-preferred) so there is ONE source of rev truth across
  # inspect → writeback. `doc.doc_id` stays canonical (published-preferred) for
  # the publish-propagation and divergence checks that key off it.
  defp write_target_rev(%Document{doc_id: doc_id, type: type, rev: rev}, dataset, opts) do
    case Content.get_document(DraftId.draft_id(doc_id), type, dataset, opts) do
      {:ok, %Document{rev: draft_rev}} -> draft_rev
      _ -> rev
    end
  end

  @doc """
  Perform the gated edit-through: re-derive the FULL authorization (never
  trust a previously rendered affordance), then patch `field` on the target
  through `Content.apply_mutations/3` with an `ifRevisionID` CAS pinned to
  `expected_rev` (the rev the caller inspected — a concurrent change surfaces
  as `{:error, {:rev_mismatch, %{expected:, actual:}}}` and nothing writes).

  On success taps the attributed `"valueref-writeback"` provenance revision
  (best-effort — the guarded write itself already recorded the `update`
  revision with `actor_user_id`) and returns `{:ok, %{doc_id:, type:,
  impact:}}` with the impact preview that gated the confirm.
  """
  @spec writeback(String.t(), String.t(), term(), String.t(), String.t(), keyword()) ::
          {:ok, %{doc_id: String.t(), type: String.t(), impact: map()}}
          | {:error, term()}
  def writeback(target, field, value, expected_rev, dataset, opts \\ []) do
    with {:ok, info} <- inspect_target(target, field, dataset, opts),
         {:ok, value} <- validate_value(value),
         :ok <- validate_expected_rev(expected_rev),
         :ok <- ensure_no_diverged_draft(info, dataset, opts) do
      mutation = %{
        "patch" => %{
          "id" => info.doc_id,
          "type" => info.type,
          "set" => %{field => coerce_value(info, field, value, dataset, opts)},
          "ifRevisionID" => expected_rev
        }
      }

      # The Sanity-shaped patch writes the DRAFT twin (upsert_document
      # normalises every write to `drafts.`); when the canonical row we
      # inspected is the PUBLISHED one, propagate the patched draft through
      # `publish_document/4` — the same guarded publish the Studio button
      # uses — so the shared truth every valueref renders actually changes.
      # A draft-only target ends at the patch (publishing it here would
      # silently change its VISIBILITY, not just its value).
      with {:ok, {_tx_id, _results}} <- Content.apply_mutations([mutation], dataset, opts),
           :ok <- maybe_propagate_publish(info, dataset, opts) do
        tap_provenance_revision(info.doc_id, info.type, dataset, opts)
        {:ok, %{doc_id: info.doc_id, type: info.type, impact: info.impact}}
      end
    end
  end

  # ── gate 2: authorization against the TARGET ────────────────────────────

  # The caller principal must be write-capable BEFORE any target read.
  # Fail closed: no caller_context in opts ⇒ anonymous ⇒ refused.
  defp write_capable_caller(opts) do
    caller = Keyword.get(opts, :caller_context) || %CallerContext{}

    if write_capable?(caller), do: {:ok, caller}, else: {:error, :unauthorized}
  end

  defp write_capable?(%CallerContext{is_admin: true}), do: true

  defp write_capable?(%CallerContext{principal_type: :api_token, roles: roles}),
    do: "write" in roles

  # An authenticated user principal's workspace membership was already
  # resolved by the scope layer that produced the opts (owner/admin/member —
  # every membership role writes); the tenancy gate below still binds the
  # write to the caller's OWN scope.
  defp write_capable?(%CallerContext{principal_type: :user}), do: true
  defp write_capable?(_), do: false

  # Resolve the target doc under the CALLER's scope opts (workspace/project/
  # dataset tenancy + unconditional owner scoping ride `resolve_docs_by_ids`,
  # the valueref resolve pass's own scoped read). Published row preferred
  # (D3); the `drafts.` twin only when no published row exists. Anything that
  # does not hydrate under the caller's scope is `:unauthorized` — never a
  # distinct not-found.
  defp resolve_target(target, dataset, opts) do
    pub = DraftId.published_id(target)
    draft = DraftId.draft_id(pub)

    rows = Content.resolve_docs_by_ids([pub, draft], dataset, opts)

    case Enum.find(rows, &(&1.doc_id == pub)) || Enum.find(rows, &(&1.doc_id == draft)) do
      %Document{} = doc -> {:ok, doc}
      _ -> {:error, :unauthorized}
    end
  end

  # No schema ⇒ no visibility gate ⇒ no edit-through (the resolve pass's own
  # fail-closed rule: a schema-free envelope drops only encrypted ciphertext,
  # so proceeding would let a caller edit a field it may not even read).
  # Lookup mirrors `Papers.value_schema/3` (the resolve pass): the tenant's
  # own schema first, then a retry WITHOUT tenant scope trusted ONLY when the
  # row is genuinely global (nil workspace) — another workspace's same-named
  # schema never gates this tenant's visibility.
  defp target_schema(type, dataset, opts) do
    case Content.Schema.get_schema_for_redaction(type, dataset, opts) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, :unauthorized}
    end
  end

  # Edit-through writes only DECLARED fields — an undeclared key would dodge
  # the envelope's visibility contract entirely (undeclared fields are
  # invisible on read; writing one would be a blind write).
  defp ensure_declared(schema, field) do
    declared? =
      schema.fields
      |> List.wrap()
      |> Enum.any?(fn f -> is_map(f) and Map.get(f, "name") == field end)

    if declared?, do: :ok, else: {:error, :unauthorized}
  end

  # RENDER-THEN-READ (the resolve pass's redaction posture): the current value
  # is read off the envelope rendered under the CALLER's authority. A field
  # present in the raw content but ABSENT from the caller's envelope was
  # redacted (private/owner_only/encrypted) ⇒ the caller may not edit what it
  # cannot read. Absent from BOTH is a declared-but-unset field — editable
  # (that is the "propagate to canonical" fill-in case), current value nil.
  defp readable_value(doc, schema, caller, field) do
    env = Envelope.render(doc, schema, caller)

    case {Map.has_key?(env, field), Map.has_key?(doc.content || %{}, field)} do
      {false, true} -> {:error, :unauthorized}
      {false, false} -> {:ok, nil}
      {true, _} -> {:ok, value_to_display(Map.get(env, field))}
    end
  end

  defp value_to_display(v) when is_binary(v), do: v
  defp value_to_display(v) when is_number(v), do: to_string(v)
  defp value_to_display(v) when is_boolean(v), do: to_string(v)
  defp value_to_display(_), do: nil

  # ── gate 3: impact preview ───────────────────────────────────────────────

  # `Content.Graph.reverse_referencers/2` with the caller's scope opts —
  # the MEDIUM-5 fail-closed hydration drops out-of-scope sources entirely
  # inside the engine; this wrapper only DEDUPES per source doc (multiple
  # edges from one paper are one impacted doc) and shapes the map. `:count`
  # is `length(:referencers)` BY CONSTRUCTION — there is no other counter,
  # no "hidden" bucket, no aggregate remainder.
  defp impact_preview(doc_id, dataset, opts) do
    referencers =
      doc_id
      |> Graph.reverse_referencers(Keyword.put(opts, :dataset, dataset))
      |> Enum.uniq_by(& &1.from_doc_id)
      |> Enum.map(fn r ->
        %{doc_id: r.from_doc_id, title: r.title, type: r.type, kind: r.kind}
      end)

    %{count: length(referencers), referencers: referencers}
  end

  # The write path merges over the CANONICAL row and republishes — so an
  # unpublished draft twin whose content already DIVERGED from the published
  # row would be silently clobbered by the propagation. That is the spec's
  # own "never silently overwrite prose" rule inverted; refuse instead
  # (`:draft_diverged`) and let a human resolve the draft first. A draft that
  # matches the published content byte-for-byte is fine (it IS the published
  # state).
  defp ensure_no_diverged_draft(%{doc_id: doc_id, type: type}, dataset, opts) do
    if DraftId.draft?(doc_id) do
      :ok
    else
      draft_id = DraftId.draft_id(doc_id)

      with {:ok, draft} <- Content.get_document(draft_id, type, dataset, opts),
           {:ok, published} <- Content.get_document(doc_id, type, dataset, opts) do
        if (draft.content || %{}) == (published.content || %{}),
          do: :ok,
          else: {:error, :draft_diverged}
      else
        # No draft twin ⇒ nothing to clobber.
        _ -> :ok
      end
    end
  end

  # Propagate the patched draft to the published (canonical) row — only when
  # the row the caller inspected WAS the published one.
  defp maybe_propagate_publish(%{doc_id: doc_id, type: type}, dataset, opts) do
    if DraftId.draft?(doc_id) do
      :ok
    else
      case Content.publish_document(doc_id, type, dataset, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:publish_failed, reason}}
      end
    end
  end

  # ── input validation ─────────────────────────────────────────────────────

  # Same field shape the valueref collect pass enforces (wire §3): a single
  # non-empty top-level declared name — dot-paths and the `content.` prefix
  # never reach the envelope gate, and the patch path's protected keys are
  # refused here too.
  defp validate_field(field) when is_binary(field) and field != "" do
    if String.contains?(field, ".") or field in @protected_fields do
      {:error, :invalid_field}
    else
      :ok
    end
  end

  defp validate_field(_), do: {:error, :invalid_field}

  defp validate_target(target) when is_binary(target) and target != "", do: :ok
  defp validate_target(_), do: {:error, :unauthorized}

  # Only scalar strings arrive from the affordance input; the CAS rev is
  # mandatory — a writeback without the inspected rev is a blind overwrite.
  defp validate_value(value) when is_binary(value), do: {:ok, value}
  defp validate_value(_), do: {:error, :invalid_value}

  defp validate_expected_rev(rev) when is_binary(rev) and rev != "", do: :ok
  defp validate_expected_rev(_), do: {:error, :rev_required}

  # Preserve a numeric canonical type: when the CURRENT raw value is a number
  # and the submitted string parses cleanly as one, write the number — a
  # valueref over `launch_delay: 14` edited to "21" stays an integer instead
  # of silently becoming "21". Anything else writes the string verbatim.
  defp coerce_value(info, field, value, dataset, opts) do
    with true <- is_binary(value),
         {:ok, doc} <- Content.get_document(info.doc_id, info.type, dataset, opts),
         current when is_number(current) <- Map.get(doc.content || %{}, field) do
      case {Integer.parse(value), Float.parse(value)} do
        {{int, ""}, _} -> int
        {_, {float, ""}} -> float
        _ -> value
      end
    else
      _ -> value
    end
  end

  # ── provenance ───────────────────────────────────────────────────────────

  # Attributed provenance revision on top of the guarded write's own `update`
  # row — action `"valueref-writeback"` + the caller's user id, the same tap
  # posture as lvw-t2's `valueref-accept-baseline`. Best-effort: a failed
  # revision insert never unwinds the already-committed write.
  defp tap_provenance_revision(doc_id, type, dataset, opts) do
    with {:ok, %Document{} = saved} <- Content.get_document(doc_id, type, dataset, opts),
         {:error, reason} <-
           Broadcast.save_revision(
             saved,
             type,
             dataset,
             @revision_action,
             Keyword.get(opts, :user_id)
           ) do
      Logger.warning(
        "valueref-writeback provenance revision failed for #{inspect(doc_id)}: #{inspect(reason)}"
      )

      :ok
    else
      _ -> :ok
    end
  end
end
