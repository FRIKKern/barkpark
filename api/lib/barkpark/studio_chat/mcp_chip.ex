defmodule Barkpark.StudioChat.McpChip do
  @moduledoc """
  The durable, compact summary of an `mcp__barkpark__*` tool RESULT — the
  replay half of the D64 chip (task-5a49dc55626ea80d, scc-w12-chip-replay-cap).

  ## Why this exists

  A live tab reads the wire `tool_result` block UNCAPPED
  (`ChatLive.tool_result_text/1`), so `ChatToolRenderer.chip/2` decodes it and
  draws a first-class chip. The Recorder persists at most
  `Recorder.@result_text_cap` characters of that same text — a size policy that
  keeps one jsonb row from carrying a 112 KB `task_ready` dump. A result past
  the cap therefore lands in the store cut MID-OBJECT: invalid JSON, no chip,
  generic `⎿` row. The same session then renders two different things
  depending on whether you were watching.

  This module closes that gap WITHOUT raising the cap: it reduces the full
  payload to the handful of fields `ChatToolRenderer` actually reads, and the
  Recorder stores that envelope beside the still-capped raw text.

  ## The envelope

      %{"v" => 1, "payload" => <reduced, same-shaped payload>,
        "list_total" => <int>, "ready_total" => <int>}

  `payload` is deliberately the SAME SHAPE the renderer already classifies (a
  prime `counts`/`ready` pair, a `docs`/`hits`/`results` list, or a single
  entity), just stripped to the whitelisted keys — so the renderer feeds it to
  the identical `build_chip/2` and cannot drift into a second classifier. The
  `*_total` fields carry the honest pre-truncation lengths, because the chip's
  "+N more" line is a receipt: a summarized list must not report itself as the
  whole result set.

  `v` is the version gate. A payload written by a FUTURE shape reads as unknown
  here and degrades to the generic row rather than being half-interpreted.

  ## What is guaranteed

    * **Whitelist, never blacklist.** Only `@entity_keys` (+ the engagement
      object) survive. A result body, a token, a credential, an attachment —
      anything not on the list — is structurally incapable of reaching the
      store through this seam.
    * **Bounded.** Lists are capped at `@hit_cap` / `@ready_cap` entries,
      strings at `@string_cap` characters, count maps at `@count_cap` keys, and
      the whole encoded envelope at `@envelope_byte_cap` bytes — over which the
      envelope is DROPPED (the row keeps the capped raw text and the generic
      chip-less row, which is the honest answer, never a partial chip).
    * **Total.** Every malformed input answers `nil`. Nothing here raises.

  A title longer than `@string_cap` is elided in the envelope, so its replayed
  chip label differs from the live one at the tail. That is the one deliberate
  divergence: a bounded store beats byte-exact parity for a pathological title.
  """

  # Bump ONLY with a shape change. `ChatToolRenderer` matches this number
  # exactly; an older/newer envelope degrades to the generic row.
  @version 1

  # Mirrors ChatToolRenderer's own caps — a summarized payload must be able to
  # feed at least as many rows as the renderer draws, never fewer.
  @hit_cap 8
  @ready_cap 5

  @string_cap 500
  @count_cap 32
  @envelope_byte_cap 8_000

  @list_keys ~w(docs hits results)
  @prime_keys ~w(counts ready)

  # EVERY key the renderer reads off an entity/hit/ready row. Adding a field to
  # a chip means adding it HERE — that is the whole point of the whitelist.
  @entity_keys ~w(doc_id id _id title type slug lifecycle_status)

  @doc """
  Reduce a full MCP result body to its versioned chip envelope, or `nil` when
  there is no chip to persist (not JSON, not an object, an `{"ok": false}`
  non-result, a shape that classifies to nothing, or an envelope that would
  exceed the byte cap).
  """
  @spec summarize(term()) :: map() | nil
  def summarize(output) when is_binary(output) do
    with {:ok, payload} when is_map(payload) <- decode(output),
         false <- payload["ok"] == false,
         %{} = envelope <- reduce(payload) do
      bounded(envelope)
    else
      _ -> nil
    end
  end

  def summarize(_), do: nil

  @doc "The envelope version this build writes and reads."
  @spec version() :: pos_integer()
  def version, do: @version

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  # Same three-way dispatch ChatToolRenderer.build_chip/2 performs, so the
  # reduced payload always lands in the branch the full one would have.
  defp reduce(payload) do
    cond do
      prime?(payload) -> reduce_prime(payload)
      true -> reduce_list(payload) || reduce_entity(payload)
    end
  end

  defp prime?(payload), do: Enum.all?(@prime_keys, &Map.has_key?(payload, &1))

  defp reduce_prime(payload) do
    ready = as_list(payload["ready"])

    envelope(
      %{
        "counts" => counts(payload["counts"]),
        "ready" => ready |> Enum.take(@ready_cap) |> Enum.map(&entity/1)
      },
      %{"ready_total" => length(ready)}
    )
  end

  defp reduce_list(payload) do
    Enum.find_value(@list_keys, fn key ->
      case payload[key] do
        [_ | _] = list ->
          envelope(
            %{key => list |> Enum.take(@hit_cap) |> Enum.map(&entity/1)},
            %{"list_total" => length(list)}
          )

        _ ->
          nil
      end
    end)
  end

  # `{"doc": {…}}` keeps its wrapper (the renderer unwraps it); a top-level
  # receipt reduces in place. Anything else classifies to no chip at all.
  defp reduce_entity(%{"doc" => doc}) when is_map(doc),
    do: envelope(%{"doc" => entity(doc)}, %{})

  defp reduce_entity(%{"doc_id" => _} = payload), do: envelope(entity(payload), %{})
  defp reduce_entity(%{"id" => _} = payload), do: envelope(entity(payload), %{})
  defp reduce_entity(_), do: nil

  defp envelope(payload, totals),
    do: Map.merge(%{"v" => @version, "payload" => payload}, totals)

  # One entity/hit/ready row, whitelisted and string-bounded. A non-map row is
  # kept as `nil` so the renderer's own "drop the unreadable row" path runs —
  # exactly as it does live.
  defp entity(row) when is_map(row) do
    row
    |> Map.take(@entity_keys)
    |> Map.new(fn {k, v} -> {k, clamp(v)} end)
    |> put_engagement(row)
  end

  defp entity(_), do: nil

  # `content.engagement.object` is hoisted to the top level — the renderer reads
  # the top level first, so the deep `content` map (a whole task body) never
  # needs to be persisted to keep the thought-state marker.
  defp put_engagement(reduced, row) do
    engagement = row["engagement"] || get_in_map(row, ["content", "engagement"])

    case is_map(engagement) && engagement["object"] do
      object when is_binary(object) and object != "" ->
        Map.put(reduced, "engagement", %{"object" => clamp(object)})

      _ ->
        reduced
    end
  end

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      next when rest == [] -> next
      next when is_map(next) -> get_in_map(next, rest)
      _ -> nil
    end
  end

  defp get_in_map(_, _), do: nil

  # Integer counts only, at most @count_cap of them — a malformed or unbounded
  # counts map yields the empty map the renderer already draws neutrally.
  defp counts(counts) when is_map(counts) do
    counts
    |> Enum.filter(fn {k, v} -> is_binary(k) and is_integer(v) end)
    |> Enum.sort()
    |> Enum.take(@count_cap)
    |> Map.new()
  end

  defp counts(_), do: %{}

  defp clamp(v) when is_binary(v), do: String.slice(v, 0, @string_cap)
  defp clamp(v), do: v

  defp as_list(v) when is_list(v), do: v
  defp as_list(_), do: []

  # The LAST gate: an envelope that somehow still encodes large is dropped
  # whole. A chip-less row is honest; a half-stored one is not.
  defp bounded(envelope) do
    case Jason.encode(envelope) do
      {:ok, json} when byte_size(json) <= @envelope_byte_cap -> envelope
      _ -> nil
    end
  end
end
