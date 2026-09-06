defmodule Barkpark.Tasks.BriefMirror do
  @moduledoc false
  # Keeps a task's `brief` in step with the fields it MIRRORS, on every write.
  #
  # ── The hole this closes ────────────────────────────────────────────────────
  #
  # A task brief is not independent prose. Two of its blocks are composed
  # verbatim from other fields of the same document by `ensureTaskPortableBrief`
  # (internal/cli/tasks_create_cmd.go): `purpose-copy` from `description`, and
  # `criteria-list` from `acceptance_criteria`. That composer returns early when
  # a brief already exists and is reached only from the two CREATE paths
  # (tasks_create_cmd.go and mcp_tasks.go), so both blocks are SNAPSHOTS taken
  # once at create with no update path anywhere. Every later edit — `bp doc
  # patch --set description=…`, the MCP bridge, a raw mutate, Studio — moves the
  # field and leaves the brief frozen.
  #
  # Measured on a scratch row: twelve patches took `description` from 4,000 to
  # 1,000,000 bytes, every call returning ok with a byte-exact read-back, while
  # the brief held its original 2,000-byte create text throughout; patching back
  # DOWN to 198 bytes left it there too. Size is not the variable and nothing
  # ever fails — this is the failure shape with no receipt to inspect. The write
  # succeeds, the field the caller named is stored perfectly, and only a field
  # the caller never mentioned goes stale, so there is no error, no exit code
  # and no length mismatch to catch it by. It is visible only by reading back a
  # field you did not write.
  #
  # The blast radius points at the worst possible reader. `brief` is what a
  # dispatched worker opens first, and it precedes `description` in `bp task
  # get` output — so the stale copy is the one that gets read. The 2026-08-20
  # sweep (tooling/grip/ledger/brief-purpose-drift-2026-08-20.md) measured 714
  # divergent published rows, 20 of them carrying gating or dependency language
  # on ONE SIDE ONLY, and found the drift runs one way: the brief keeps the
  # ORIGINAL framing while the description carries the later state. A builder
  # reading such a brief waits on an already-merged dependency, or works to
  # two-thirds of the criteria.
  #
  # ── Why both blocks, and why here ───────────────────────────────────────────
  #
  # That sweep is explicit that `criteria-list` drifts by the same mechanism (of
  # 1,759 docs carrying both, 94 disagree on COUNT and 50 on TEXT) and that "a
  # remedy that re-derives only the purpose leaves this half open". So both are
  # re-derived here.
  #
  # This runs in the attrs pipeline of `create_document/4` and
  # `upsert_document/4` — the chokepoint every door already passes through —
  # rather than in the CLI, for two reasons. The client cannot do it: by the
  # time `bp` assembles a patch body it does not hold the current document, so
  # client-side the only options are to refuse the edit or to clobber the
  # brief's other blocks. And a fix here covers bp, the MCP bridge, LiveView and
  # raw HTTP at once instead of one CLI verb.
  #
  # A client-side refusal was built first and rejected on evidence: it reds
  # three standing contracts in internal/cli/set_key_nesting_test.go which pin,
  # in a comment verbatim, "the CORRECT spelling still lands — the refusal is
  # not a wall". A bare `description=NEW` patch on a task is a supported
  # operation and stays one.
  #
  # ── The contract, stated so it can be relied on ─────────────────────────────
  #
  # Blocks are matched by EXACT id, never by position. The same sweep records
  # that a positional "first paragraph with content" fallback manufactured 794
  # false suspects out of the 2,458 docs that carry no purpose-copy block at
  # all, one of them matching a block holding a lone \x01 byte. There is no
  # fallback here for that reason.
  #
  # Only the derived payload of a matched block is replaced — `content` for the
  # paragraph, `items` for the list. Every other key on those blocks, every
  # other block, and block ORDER are preserved untouched, so a hand-authored
  # brief keeps everything except the two blocks that were never independent
  # prose in the first place. A brief that wants prose the description does not
  # own should carry it under any other block id.
  #
  # Pure, total and idempotent: a non-task type, a document with no brief, a
  # brief of an unexpected shape, or a missing source field all pass through
  # untouched, and re-running on already-synced content is a no-op.

  @purpose_block_id "purpose-copy"
  @criteria_block_id "criteria-list"

  # `ensureTaskPortableBrief` strips exactly these when composing, so a
  # description carrying them would otherwise differ from its own mirror
  # forever, by design. Mirrored here EXACTLY — a normaliser more aggressive
  # than the Go source would rewrite prose the composer would have kept.
  @stripped ["**", "__", "`"]

  @doc """
  Re-derives a task brief's mirrored blocks from the fields they mirror.

  Returns `attrs` unchanged for every non-task type.
  """
  # @canonical capability:task-brief-mirror-resync aka:brief drift,purpose-copy,criteria-list,brief goes stale,description mirror,brief frozen
  def maybe_resync_task_brief(attrs, "task") do
    with %{"content" => %{"brief" => %{"blocks" => blocks}} = content} when is_list(blocks) <-
           attrs,
         resynced when resynced != blocks <- resync_blocks(blocks, content, attrs) do
      brief = Map.put(content["brief"], "blocks", resynced)
      Map.put(attrs, "content", Map.put(content, "brief", brief))
    else
      _ -> attrs
    end
  end

  def maybe_resync_task_brief(attrs, _type), do: attrs

  defp resync_blocks(blocks, content, attrs) do
    Enum.map(blocks, fn
      %{"id" => @purpose_block_id} = block -> resync_purpose(block, content, attrs)
      %{"id" => @criteria_block_id} = block -> resync_criteria(block, content)
      block -> block
    end)
  end

  # The paragraph's text is the composed description. A document that carries no
  # `description` key at all is left alone rather than stamped with the stub —
  # absence is not the same as an empty description, and only the composer's own
  # create path is entitled to invent copy.
  defp resync_purpose(block, content, attrs) do
    case Map.fetch(content, "description") do
      {:ok, description} ->
        text = compose_purpose(description, content, attrs)
        Map.put(block, "content", [%{"type" => "text", "value" => text}])

      :error ->
        block
    end
  end

  defp compose_purpose(description, content, attrs) do
    case description |> to_text() |> strip_markdown() |> String.trim() do
      "" -> stub_for(content, attrs)
      text -> text
    end
  end

  defp stub_for(content, attrs) do
    title = (attrs["title"] || content["title"] || "") |> to_text() |> String.trim()
    "Complete the work described by “#{title}” and record verifiable evidence."
  end

  # The list's items are the criterion texts, in order, blanks dropped —
  # `taskCriterionTexts`'s rule exactly. A document with no
  # `acceptance_criteria`, or one whose value is not a list, leaves the block
  # untouched rather than emptying it: silently clearing a builder's criteria
  # would be a worse defect than the drift this closes.
  defp resync_criteria(block, content) do
    case Map.get(content, "acceptance_criteria") do
      criteria when is_list(criteria) -> Map.put(block, "items", criterion_texts(criteria))
      _ -> block
    end
  end

  defp criterion_texts(criteria) do
    criteria
    |> Enum.flat_map(fn
      %{"criterion" => text} when is_binary(text) -> [String.trim(text)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_markdown(text), do: Enum.reduce(@stripped, text, &String.replace(&2, &1, ""))

  defp to_text(value) when is_binary(value), do: value
  defp to_text(_), do: ""
end
