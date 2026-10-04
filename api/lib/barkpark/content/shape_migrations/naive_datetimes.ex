defmodule Barkpark.Content.ShapeMigrations.NaiveDatetimes do
  @moduledoc """
  Census and dry-run rewrite of datetime values stored without a time zone
  (owner ruling #46, task-6a953e4a9ef729a6). Dry run by default; never runs
  on its own.

  Before #46 Studio stored what the datetime-local input held
  (`"2026-10-03T10:30"`): the editor's wall time with no zone. New Studio
  writes are UTC instants (`"2026-10-03T08:30:00Z"`), and Studio still SHOWS
  an old value as written, so nothing breaks while old values remain. This
  module counts them and, given the zone offset the editors were in, rewrites
  them as instants.

  The offset is fixed (`"+02:00"`), not a named zone, because the release
  carries no time-zone database, so one run cannot tell summer time from
  winter time. Review the dry-run rows, which list every value and its
  rewrite, before applying.

  Release form (no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.NaiveDatetimes.census())'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.NaiveDatetimes.run(offset: "+02:00"))'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.NaiveDatetimes.run(offset: "+02:00", apply: true))'

  Checkout form: `mix barkpark.shape.naive_datetimes [--offset +02:00] [--apply]`.

  Only top-level `datetime` fields are scanned. An applied row gets the new
  value and a fresh `_rev`; it records no history revision or mutation event.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Repo

  @naive ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/
  @naive_sql "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?$"

  @doc "The `{type, field}` pairs declared `datetime` in any stored schema."
  def datetime_fields do
    from(s in SchemaDefinition, select: {s.name, s.fields})
    |> Repo.all()
    |> Enum.flat_map(fn {type, fields} ->
      for %{} = f <- List.wrap(fields),
          (f["type"] || f[:type]) == "datetime",
          name = f["name"] || f[:name],
          is_binary(name),
          do: {type, name}
    end)
    |> Enum.uniq()
  end

  @doc "Counts of zone-less datetime values per `{type, field}`; zero rows are left out."
  @spec census() :: [%{type: String.t(), field: String.t(), count: non_neg_integer()}]
  def census do
    for {type, field} <- datetime_fields(),
        count = count_naive(type, field),
        count > 0,
        do: %{type: type, field: field, count: count}
  end

  defp count_naive(type, field) do
    from(d in Document,
      where: d.type == ^type and fragment("(?->>?) ~ ?", d.content, ^field, ^@naive_sql),
      select: count(d.id)
    )
    |> Repo.one()
  end

  @doc """
  Options: `offset:` (required, `"+HH:MM"` / `"-HH:MM"`, the editors' UTC
  offset), `apply:` (default `false`). Returns `%{applied?, rows}` where each
  row is `%{doc_id, type, field, from, to}`.
  """
  @spec run(keyword()) :: map()
  def run(opts) do
    offset_seconds = parse_offset!(Keyword.fetch!(opts, :offset))
    apply? = Keyword.get(opts, :apply, false)

    rows =
      for {type, field} <- datetime_fields(),
          doc <- naive_docs(type, field),
          raw = doc.content[field],
          is_binary(raw) and Regex.match?(@naive, raw) do
        to = to_instant(raw, offset_seconds)

        if apply? and to do
          doc
          |> Ecto.Changeset.change(
            content: Map.put(doc.content, field, to),
            rev: Barkpark.Content.Writer.generate_rev()
          )
          |> Repo.update!()
        end

        %{doc_id: doc.doc_id, type: type, field: field, from: raw, to: to}
      end

    %{applied?: apply?, rows: rows}
  end

  defp naive_docs(type, field) do
    from(d in Document,
      where: d.type == ^type and fragment("(?->>?) ~ ?", d.content, ^field, ^@naive_sql),
      order_by: d.id
    )
    |> Repo.all()
  end

  @doc false
  def to_instant(raw, offset_seconds) do
    with {:ok, ndt} <- NaiveDateTime.from_iso8601(pad_seconds(raw)) do
      ndt
      |> NaiveDateTime.add(-offset_seconds, :second)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp pad_seconds(raw) do
    if Regex.match?(~r/T\d{2}:\d{2}$/, raw), do: raw <> ":00", else: raw
  end

  @doc false
  def parse_offset!(<<sign, hh::binary-size(2), ":", mm::binary-size(2)>>)
      when sign in [?+, ?-] do
    seconds = String.to_integer(hh) * 3600 + String.to_integer(mm) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  def parse_offset!(other),
    do: raise(ArgumentError, "offset must look like +02:00 or -05:00, got #{inspect(other)}")
end
