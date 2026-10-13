defmodule Barkpark.SchemaDiff do
  @moduledoc """
  Compares the schemas of two Postgres databases, object by object (Barkspark
  phase 2, slice 3, task-097a1b8ed6d27a8b). Slice 4 uses it to prove the
  per-owner baselines build the same schema as the 212 legacy migrations.

  Each side is a `pg_dump --schema-only --no-owner --no-privileges` text. The
  dump is normalised: comment lines, `SET` and `set_config` lines, the
  `\\restrict` pair and blank lines go, and whitespace collapses to one space.
  It is then split into statements, dollar-quoted bodies kept whole, and each
  statement is keyed by the object it creates, as `{kind, name}`: a table, an
  index, a constraint `table.name`, a trigger `table.name`, a function with
  its arguments, a column default `table.column`, and so on. A statement no
  rule names is keyed by its own text.

  Two dumps are equal when they hold the same keys with the same statements.
  Column order inside a table counts: it is part of the schema `SELECT *` sees.

      mix barkpark.schema_diff DB_A DB_B
  """

  @type key :: {String.t(), String.t()}
  @type difference ::
          {:only_in_a, key()} | {:only_in_b, key()} | {:differs, key(), String.t(), String.t()}

  @dropped ~r/^(--|SET |SELECT pg_catalog\.set_config\(|\\restrict |\\unrestrict )/

  # Names are schema-qualified in the dump; key/1 drops a leading `public.`.
  @keys [
    {"table", ~r/^CREATE (?:UNLOGGED )?TABLE (\S+) \(/},
    {"view", ~r/^CREATE (?:MATERIALIZED )?VIEW (\S+) /},
    {"index", ~r/^CREATE (?:UNIQUE )?INDEX (\S+) ON /},
    {"trigger", ~r/^CREATE (?:CONSTRAINT )?TRIGGER (\S+) .*? ON (\S+) /},
    {"constraint", ~r/^ALTER TABLE (?:ONLY )?(\S+) ADD CONSTRAINT (\S+) /},
    {"default", ~r/^ALTER TABLE (?:ONLY )?(\S+) ALTER COLUMN (\S+) SET DEFAULT /},
    {"function", ~r/^CREATE FUNCTION ([^(\s]+\([^)]*\))/},
    {"sequence", ~r/^CREATE SEQUENCE (\S+)/},
    {"sequence owner", ~r/^ALTER SEQUENCE (\S+) OWNED BY /},
    {"type", ~r/^CREATE TYPE (\S+) /},
    {"extension", ~r/^CREATE EXTENSION IF NOT EXISTS (\S+) /},
    {"schema", ~r/^CREATE SCHEMA (\S+);/},
    {"comment", ~r/^COMMENT ON (\w+) (\S+) IS /}
  ]

  @doc "Runs `pg_dump` for `database` (a name or a conninfo string)."
  @spec dump(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def dump(database) do
    case System.cmd(
           "pg_dump",
           ["--schema-only", "--no-owner", "--no-privileges", "--dbname", database],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "pg_dump #{database} exited #{status}: #{String.trim(out)}"}
    end
  end

  @doc "The normalised statements of a dump, keyed by the object each one creates."
  @spec objects(String.t()) :: %{key() => String.t()}
  def objects(dump) do
    dump
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or Regex.match?(@dropped, &1)))
    |> statements()
    |> Enum.map(&collapse/1)
    |> Enum.reduce(%{}, fn statement, acc ->
      key = key(statement)

      if Map.has_key?(acc, key),
        do: Map.put(acc, {"statement", statement}, statement),
        else: Map.put(acc, key, statement)
    end)
  end

  @doc "The differences between two dumps, sorted by key. `[]` when they match."
  @spec diff(String.t(), String.t()) :: [difference()]
  def diff(dump_a, dump_b) do
    a = objects(dump_a)
    b = objects(dump_b)

    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, sa}, {:ok, sb}} -> [{:differs, key, sa, sb}]
        {{:ok, _}, :error} -> [{:only_in_a, key}]
        {:error, {:ok, _}} -> [{:only_in_b, key}]
      end
    end)
  end

  @doc "One line per difference, naming the object."
  @spec format(difference()) :: String.t()
  def format({:only_in_a, {kind, name}}), do: "only in A: #{kind} #{name}"
  def format({:only_in_b, {kind, name}}), do: "only in B: #{kind} #{name}"

  def format({:differs, {kind, name}, a, b}) do
    # Statements split at ", " into parts (columns, options); only the parts
    # one side lacks are printed, so a changed table shows its changed column.
    parts_a = parts(a)
    parts_b = parts(b)

    detail =
      case {parts_a -- parts_b, parts_b -- parts_a} do
        {[], []} -> ["    same parts in a different order"]
        {only_a, only_b} -> Enum.map(only_a, &"    A: #{&1}") ++ Enum.map(only_b, &"    B: #{&1}")
      end

    Enum.join(["differs:   #{kind} #{name}" | detail], "\n")
  end

  # Joins lines into statements. A statement ends at a line ending in `;`
  # outside a dollar-quoted body, so a function body's own `;` lines stay in it.
  defp statements(lines) do
    {done, current, _quote} =
      Enum.reduce(lines, {[], [], nil}, fn line, {done, current, quote} ->
        quote = track_quote(line, quote)
        current = [line | current]

        if quote == nil and String.ends_with?(String.trim_trailing(line), ";") do
          {[current |> Enum.reverse() |> Enum.join("\n") | done], [], nil}
        else
          {done, current, quote}
        end
      end)

    done = if current == [], do: done, else: [current |> Enum.reverse() |> Enum.join("\n") | done]
    Enum.reverse(done)
  end

  # Each `$tag$` either opens a body (when none is open) or closes the open one.
  defp track_quote(line, quote) do
    ~r/\$[A-Za-z_0-9]*\$/
    |> Regex.scan(line)
    |> Enum.reduce(quote, fn [tag], open ->
      cond do
        open == nil -> tag
        open == tag -> nil
        true -> open
      end
    end)
  end

  # A table's closing " );" would otherwise make its last column differ too.
  defp parts(statement), do: statement |> String.replace_suffix(" );", "") |> String.split(", ")

  defp unqualify("public." <> name), do: name
  defp unqualify(name), do: name

  defp collapse(statement), do: statement |> String.split() |> Enum.join(" ")

  defp key(statement) do
    Enum.find_value(@keys, {"statement", statement}, fn {kind, regex} ->
      case Regex.run(regex, statement, capture: :all_but_first) do
        nil ->
          nil

        [name] ->
          {kind, unqualify(name)}

        [what, name] when kind == "comment" ->
          {kind, "#{what} #{unqualify(name)}"}

        [table, name] when kind in ["constraint", "default"] ->
          {kind, "#{unqualify(table)}.#{name}"}

        [name, table] ->
          {kind, "#{unqualify(table)}.#{name}"}
      end
    end)
  end
end
