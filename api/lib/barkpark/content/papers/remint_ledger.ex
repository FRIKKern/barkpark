defmodule Barkpark.Content.Papers.RemintLedger do
  @moduledoc """
  The ids a Paper's batch write re-minted, so a later op from an editor that
  still holds the repeated id cannot overwrite the wrong copy (decision in
  task-c91fbd0c5c7bb4a6).

  An editor on contracts 1.14-1.21 that splits a section paragraph sends one
  id twice, and a fenced batch heals a duplicate already stored. Either way the
  first copy keeps the id and the others get fresh ids. While that editor
  stays focused it never applies the echo, so its next `patch-block <id>` may
  mean any copy. The ledger names the copies,
  `%{repeated_id => %{"fresh" => [fresh_id], "at" => unix_s}}`, stored in the
  Paper's content under `"id_remints"`.

  A patch or replace on a ledgered id goes to the one copy it clearly
  continues: the text of the fields the op writes is that copy's text of the
  same fields with one run inserted or removed, and no other copy's is. When
  that names no copy, or more than one, nothing is overwritten: the op's
  content lands as a new block after the closest copy and joins the ledger,
  and a remove is skipped. An op that writes no field goes to the kept id. An
  entry drops once an op names one of its fresh ids (that editor has the new
  ids), once fewer than two of its copies remain, or 24 hours after it was
  last written: a client may resend a batch under its idempotency key for 24
  hours (`Barkpark.Idempotency`), and a resent batch still carries the old id.
  """

  require Logger

  alias Barkpark.PortableDoc.BlockIds

  @key "id_remints"
  @ttl_seconds 24 * 3600

  @type t :: %{optional(String.t()) => %{required(String.t()) => term()}}

  def ttl_seconds, do: @ttl_seconds

  @spec load(map() | nil, integer()) :: t()
  def load(content, now) do
    case content && Map.get(content, @key) do
      %{} = ledger ->
        for {id, %{"fresh" => [_ | _] = fresh, "at" => at} = entry} <- ledger,
            is_binary(id) and is_integer(at) and now - at < @ttl_seconds and
              Enum.all?(fresh, &is_binary/1),
            into: %{},
            do: {id, entry}

      _ ->
        %{}
    end
  end

  @spec put(map(), t()) :: map()
  def put(content, ledger) when ledger == %{}, do: Map.delete(content, @key)
  def put(content, ledger), do: Map.put(content, @key, ledger)

  @spec record(t(), [{String.t(), String.t()}], integer()) :: t()
  def record(ledger, pairs, now) do
    Enum.reduce(pairs, ledger, fn {id, fresh}, acc ->
      Map.update(acc, id, %{"fresh" => [fresh], "at" => now}, fn entry ->
        %{"fresh" => Enum.uniq(entry["fresh"] ++ [fresh]), "at" => now}
      end)
    end)
  end

  @spec forget_named(t(), map()) :: t()
  def forget_named(ledger, op) when is_map(op) do
    named = op |> Map.take(["id", "afterId", "after"]) |> Map.values()

    ledger
    |> Enum.reject(fn {_id, entry} -> Enum.any?(entry["fresh"], &(&1 in named)) end)
    |> Map.new()
  end

  def forget_named(ledger, _op), do: ledger

  @spec settle(t(), list()) :: t()
  def settle(ledger, blocks) do
    present = blocks |> ids() |> MapSet.new()

    for {id, entry} <- ledger,
        fresh = Enum.filter(entry["fresh"], &MapSet.member?(present, &1)),
        fresh != [] and (MapSet.member?(present, id) or length(fresh) > 1),
        into: %{},
        do: {id, %{entry | "fresh" => fresh}}
  end

  @doc """
  Route one op against the ledger. Returns `{op, ledger}`, or `{nil, ledger}`
  for a remove that must not run.
  """
  @spec route(t(), list(), map(), integer()) :: {map() | nil, t()}
  def route(ledger, blocks, %{"op" => kind, "id" => id} = op, now)
      when kind in ["patch-block", "replace-block", "remove-block"] and
             is_map_key(ledger, id) do
    case Enum.flat_map([id | ledger[id]["fresh"]], &find(blocks, &1)) do
      [_only] -> {op, ledger}
      [] -> {op, ledger}
      copies -> route_among(ledger, blocks, op, copies, now)
    end
  end

  def route(ledger, _blocks, op, _now), do: {op, ledger}

  defp route_among(ledger, _blocks, %{"op" => "remove-block", "id" => id}, _copies, _now) do
    doubt(id, "remove-block")
    {nil, ledger}
  end

  defp route_among(ledger, blocks, %{"op" => kind, "id" => id} = op, copies, now) do
    case written_keys(op) do
      [] ->
        {op, ledger}

      keys ->
        text = fields_text(payload(op), keys)

        case Enum.filter(copies, &continues?(fields_text(&1, keys), text)) do
          [copy] ->
            {%{op | "id" => copy["id"]}, ledger}

          _doubt ->
            doubt(id, kind)
            closest = Enum.max_by(copies, &shared(fields_text(&1, keys), text))
            fresh = BlockIds.fresh_id(blocks, id)

            {%{
               "op" => "insert-after",
               "afterId" => closest["id"],
               "block" => doubt_block(op, closest, fresh)
             }, record(ledger, [{id, fresh}], now)}
        end
    end
  end

  defp doubt_block(%{"op" => "patch-block", "patch" => patch}, closest, fresh),
    do:
      closest
      |> Map.merge(Map.drop(patch, ["id", "type", "locked", "role"]))
      |> Map.put("id", fresh)

  defp doubt_block(%{"block" => block}, _closest, fresh), do: Map.put(block, "id", fresh)

  defp doubt(id, kind),
    do:
      Logger.warning(
        "paper re-mint doubt: #{kind} on repeated id #{inspect(id)} overwrites no copy"
      )

  defp payload(%{"patch" => patch}) when is_map(patch), do: patch
  defp payload(%{"block" => block}) when is_map(block), do: block
  defp payload(_op), do: %{}

  defp written_keys(op),
    do: op |> payload() |> Map.keys() |> Kernel.--(["id", "type"]) |> Enum.sort()

  defp fields_text(map, keys), do: Enum.map_join(keys, "\n", &plain(Map.get(map, &1)))

  defp plain(nil), do: ""
  defp plain(text) when is_binary(text), do: text

  defp plain(nodes) when is_list(nodes) do
    if Enum.all?(nodes, &is_map/1), do: inline_text(nodes), else: Jason.encode!(nodes)
  end

  defp plain(value), do: Jason.encode!(value)

  defp inline_text(nodes) do
    Enum.map_join(nodes, fn
      %{"value" => value} when is_binary(value) -> value
      %{"text" => text} when is_binary(text) -> text
      %{"content" => content} when is_list(content) -> inline_text(content)
      node -> Jason.encode!(node)
    end)
  end

  defp continues?(stored, text),
    do: shared(stored, text) == min(String.length(stored), String.length(text))

  defp shared(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)
    prefix = common(a, b)
    rest = min(length(a), length(b)) - prefix
    prefix + min(common(Enum.reverse(a), Enum.reverse(b)), rest)
  end

  defp common([x | a], [x | b]), do: 1 + common(a, b)
  defp common(_a, _b), do: 0

  defp find(blocks, id) when is_list(blocks),
    do: Enum.flat_map(blocks, &find(&1, id)) |> Enum.take(1)

  defp find(%{"id" => id} = block, id), do: [block]

  defp find(block, id) when is_map(block),
    do: block |> Map.values() |> Enum.filter(&(is_list(&1) or is_map(&1))) |> find_in(id)

  defp find(_value, _id), do: []

  defp find_in(values, id), do: values |> Enum.flat_map(&find(&1, id)) |> Enum.take(1)

  defp ids(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &ids/1)

  defp ids(%{} = block) do
    own = if is_binary(block["id"]), do: [block["id"]], else: []

    own ++
      (block
       |> Map.values()
       |> Enum.filter(&(is_list(&1) or is_map(&1)))
       |> Enum.flat_map(&ids/1))
  end

  defp ids(_value), do: []
end
