defmodule Barkpark.Plugins.Sheets.Charts do
  @moduledoc """
  Charts on a sheet tab — the model, its validation, the two session ops and
  the data a chart draws. Pure: no Repo, no I/O.

  A tab stores its charts under `"charts"`, an ordered list (the order is the
  order they show under the grid):

      %{"id" => "ch-1", "range" => "A1:C6", "type" => "line" | "bar",
        "title" => "Sales", "headers" => true, "labels" => true}

  `"headers"`: the first row names the series. `"labels"`: the first column
  labels the points. Both default to `true`.

  ## Ops (`apply_op/3`, called from `Session.Ops.apply_one/2`)

    * `%{"op" => "set_chart", "tab" => i, "chart" => chart, "at" => n?}` —
      adds the chart, or replaces the one with the same `"id"`. `"at"` (0-based)
      places or moves it in the list. A chart without an id gets one.
    * `%{"op" => "delete_chart", "tab" => i, "id" => id}`.

  Each returns a `{:structural, op}` inverse, so undo/redo ride the session's
  existing machinery. A new chart's id comes from `"chart_seq"`, a counter kept
  on the tab, so an id is never handed out twice — an undo cannot land on a
  chart another editor added later.

  ## One rule for the two caps

  A stored chart reads at most `area_cap/0` cells and a tab holds at most
  `chart_cap/0` charts. The op refuses more, the save gate (`list_errors/2`)
  refuses more, and a row/column insert that would grow a chart past the cell
  cap trims the range at its end (`list/1`, called by `Structure`).

  ## Undo of a row/column edit never fails on a chart

  `wrap_shift_inverse/4` pairs the edit's own inverse with a `{:charts, tab,
  items}` entry that puts the changed charts back. That entry is applied by
  `put_back/2`, which cannot fail: a chart that no longer fits under the chart
  cap is left out, and the rows and columns come back either way.

  ## The read side is total

  Every reader goes through `list/1`, which keeps only well-formed charts.
  `clean_content/1` does the same to a document when a session loads it, so a
  stored value the gate would refuse cannot block later saves.
  """

  alias Barkpark.Plugins.Sheets.Core

  @types ~w(line bar)
  @chart_cap 20
  @area_cap 2_000
  @title_max 120
  # The renderer's palette holds four series.
  @max_series 4
  @max_points 200
  @read_rows 500
  @read_cols 27
  # Deliberate copy of the Excel grid bounds (the Session.Ops convention).
  @grid_max_col 16_384
  @grid_max_row 1_048_576
  # The renderer drops numbers outside this magnitude; drop them here first so
  # a point never shifts under its label.
  @min_magnitude 1.0e-100
  @max_magnitude 1.0e100
  @id_re ~r/^[A-Za-z0-9_-]{1,64}\z/
  @known_keys ~w(id range type title headers labels)

  def chart_cap, do: @chart_cap
  def area_cap, do: @area_cap

  @doc """
  The tab's charts in stored form — total. An entry that is not a well-formed
  chart is dropped, an oversized range is trimmed to `area_cap/0`, a repeated
  id keeps its first chart, and at most `chart_cap/0` are returned.
  """
  @spec list(term()) :: [map()]
  def list(%{"charts" => charts}) when is_list(charts) do
    charts
    |> Enum.flat_map(fn chart ->
      case shape(chart) do
        {:ok, chart, corners} -> [Map.put(chart, "range", format_range(trim(corners)))]
        {:error, _} -> []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(@chart_cap)
  end

  def list(_tab), do: []

  @doc """
  A sheet document's content with every tab's `"charts"` put through `list/1`.
  A tab with no `"charts"` key is left exactly as it is.
  """
  @spec clean_content(term()) :: term()
  def clean_content(%{"tabs" => tabs} = content) when is_list(tabs) do
    Map.put(content, "tabs", Enum.map(tabs, &clean_tab/1))
  end

  def clean_content(content), do: content

  defp clean_tab(%{"charts" => _} = tab), do: Map.put(tab, "charts", list(tab))
  defp clean_tab(tab), do: tab

  # Trim a range to the cell cap: whole rows off the end, and for a range wider
  # than the cap itself, one row of the first `area_cap` columns.
  defp trim({c1, r1, c2, r2} = corners) do
    width = c2 - c1 + 1

    cond do
      width * (r2 - r1 + 1) <= @area_cap -> corners
      width > @area_cap -> {c1, r1, c1 + @area_cap - 1, r1}
      true -> {c1, r1, c2, r1 + div(@area_cap, width) - 1}
    end
  end

  # ── validation ───────────────────────────────────────────────────────────

  @doc "Gate errors for a tab's `charts` value (`[]` when it may be stored)."
  @spec list_errors(term(), non_neg_integer()) :: [String.t()]
  def list_errors(nil, _idx), do: []

  def list_errors(charts, idx) when is_list(charts) do
    cap =
      if length(charts) > @chart_cap,
        do: ["tab #{idx}: #{length(charts)} charts; the cap is #{@chart_cap}"],
        else: []

    each =
      Enum.flat_map(charts, fn chart ->
        case normalize(chart) do
          {:ok, _} -> []
          {:error, message} -> ["tab #{idx}: chart: #{message}"]
        end
      end)

    ids = for %{"id" => id} <- charts, is_binary(id), do: id
    dup = if ids == Enum.uniq(ids), do: [], else: ["tab #{idx}: charts: duplicate id"]
    cap ++ each ++ dup
  end

  def list_errors(_charts, idx), do: ["tab #{idx}: charts must be a list"]

  @doc "A chart in its stored form, or why it may not be stored."
  @spec normalize(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize(chart) do
    with {:ok, chart, corners} <- shape(chart),
         :ok <- in_area(corners) do
      {:ok, chart}
    end
  end

  # Everything but the cell cap, which `list/1` trims instead of refusing.
  defp shape(%{} = chart) do
    with :ok <- known_keys(chart),
         {:ok, id} <- valid_id(Map.get(chart, "id")),
         {:ok, corners} <- parse_range(Map.get(chart, "range")),
         :ok <- in_grid(corners),
         {:ok, type} <- valid_type(Map.get(chart, "type")),
         {:ok, title} <- valid_title(Map.get(chart, "title")),
         {:ok, headers} <- valid_flag(chart, "headers"),
         {:ok, labels} <- valid_flag(chart, "labels") do
      {:ok,
       %{
         "id" => id,
         "range" => format_range(corners),
         "type" => type,
         "title" => title,
         "headers" => headers,
         "labels" => labels
       }, corners}
    end
  end

  defp shape(_chart), do: {:error, "must be a map"}

  defp known_keys(chart) do
    case Map.keys(chart) -- @known_keys do
      [] -> :ok
      extra -> {:error, "unknown keys #{inspect(extra)}"}
    end
  end

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(@id_re, id),
      do: {:ok, id},
      else: {:error, "id must be 1-64 of A-Z a-z 0-9 _ -"}
  end

  defp valid_id(_), do: {:error, "id must be a string"}

  defp valid_type(type) when type in @types, do: {:ok, type}

  defp valid_type(type),
    do: {:error, "type must be one of #{Enum.join(@types, ", ")}, got #{inspect(type)}"}

  defp valid_title(nil), do: {:ok, ""}

  defp valid_title(title) when is_binary(title) do
    if String.valid?(title) and String.length(title) <= @title_max,
      do: {:ok, String.trim(title)},
      else: {:error, "title must be text of at most #{@title_max} characters"}
  end

  defp valid_title(_), do: {:error, "title must be text"}

  defp valid_flag(chart, key) do
    case Map.get(chart, key, true) do
      flag when is_boolean(flag) -> {:ok, flag}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  defp in_grid({_c1, _r1, c2, r2}) when c2 <= @grid_max_col and r2 <= @grid_max_row, do: :ok
  defp in_grid(_), do: {:error, "range is outside the sheet"}

  defp in_area({c1, r1, c2, r2}) do
    area = (c2 - c1 + 1) * (r2 - r1 + 1)

    if area <= @area_cap,
      do: :ok,
      else: {:error, "range holds #{area} cells; a chart reads at most #{@area_cap}"}
  end

  @doc "`\"A1\"` or `\"A1:B2\"` (any corner order) → `{c1, r1, c2, r2}`, top-left first."
  @spec parse_range(term()) ::
          {:ok, {pos_integer(), pos_integer(), pos_integer(), pos_integer()}}
          | {:error, String.t()}
  def parse_range(range) when is_binary(range) do
    refs = range |> String.trim() |> String.split(":")

    with true <- length(refs) in [1, 2],
         [{:ok, {ca, ra}}, {:ok, {cb, rb}}] <-
           Enum.map([List.first(refs), List.last(refs)], &Core.parse_ref/1) do
      {:ok, {min(ca, cb), min(ra, rb), max(ca, cb), max(ra, rb)}}
    else
      _ -> {:error, "range must look like A1:C6, got #{inspect(range)}"}
    end
  end

  def parse_range(range), do: {:error, "range must look like A1:C6, got #{inspect(range)}"}

  defp format_range({c1, r1, c2, r2}) when {c1, r1} == {c2, r2}, do: Core.format_ref({c1, r1})

  defp format_range({c1, r1, c2, r2}),
    do: Core.format_ref({c1, r1}) <> ":" <> Core.format_ref({c2, r2})

  # ── ops ──────────────────────────────────────────────────────────────────

  @doc """
  Apply a chart op to `tab`. Returns `{:ok, new_tab, inverse}` or the session's
  `{:error, code, message}`.
  """
  @spec apply_op(map(), map(), non_neg_integer()) ::
          {:ok, map(), tuple()} | {:error, String.t(), String.t()}
  def apply_op(%{"op" => "set_chart", "chart" => %{} = chart} = op, tab, tab_idx) do
    charts = list(tab)

    {chart, tab} =
      if Map.get(chart, "id") in [nil, ""] do
        n = next_seq(tab, charts)
        {Map.put(chart, "id", "ch-#{n}"), Map.put(tab, "chart_seq", n)}
      else
        {chart, tab}
      end

    prior_at = Enum.find_index(charts, &(Map.get(&1, "id") == chart["id"]))

    with {:ok, chart} <- normalize(chart),
         {:ok, at} <- valid_at(Map.get(op, "at")),
         :ok <- under_cap(charts, prior_at) do
      rest = if prior_at, do: List.delete_at(charts, prior_at), else: charts
      at = min(at || prior_at || length(rest), length(rest))

      inverse =
        case prior_at do
          nil -> %{"op" => "delete_chart", "tab" => tab_idx, "id" => chart["id"]}
          i -> set_op(tab_idx, Enum.at(charts, i), i)
        end

      {:ok, Map.put(tab, "charts", List.insert_at(rest, at, chart)), {:structural, inverse}}
    else
      {:error, message} -> {:error, "invalid_chart", message}
    end
  end

  def apply_op(%{"op" => "set_chart"}, _tab, _tab_idx),
    do: {:error, "invalid_chart", "\"chart\" must be a map"}

  def apply_op(%{"op" => "delete_chart", "id" => id}, tab, tab_idx) do
    charts = list(tab)

    case Enum.find_index(charts, &(Map.get(&1, "id") == id)) do
      nil ->
        {:error, "chart_not_found", "the tab has no chart #{inspect(id)}"}

      i ->
        {:ok, Map.put(tab, "charts", List.delete_at(charts, i)),
         {:structural, set_op(tab_idx, Enum.at(charts, i), i)}}
    end
  end

  def apply_op(_op, _tab, _tab_idx),
    do: {:error, "malformed_op", "set_chart needs \"chart\"; delete_chart needs \"id\""}

  defp set_op(tab_idx, chart, at),
    do: %{"op" => "set_chart", "tab" => tab_idx, "chart" => chart, "at" => at}

  defp valid_at(nil), do: {:ok, nil}
  defp valid_at(at) when is_integer(at) and at >= 0, do: {:ok, at}
  defp valid_at(at), do: {:error, "at must be a whole number from 0, got #{inspect(at)}"}

  defp under_cap(charts, nil) when length(charts) >= @chart_cap,
    do: {:error, "a tab holds at most #{@chart_cap} charts"}

  defp under_cap(_charts, _prior_at), do: :ok

  # The next number for a generated id: past the tab's counter, and past any
  # caller-chosen `ch-N` already there. The counter only grows, so a deleted
  # chart's id is not handed out again.
  defp next_seq(tab, charts) do
    seq =
      case Map.get(tab, "chart_seq") do
        n when is_integer(n) and n >= 0 -> n
        _ -> 0
      end

    taken = MapSet.new(charts, & &1["id"])

    (seq + 1)
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find(&(not MapSet.member?(taken, "ch-#{&1}")))
  end

  @doc """
  Pair a row/column edit's own inverse with a `{:charts, tab, items}` entry
  holding the tab's charts as they were before the edit (`put_back/2`), so undo
  returns each chart exactly — also one the edit trimmed, shrank or removed. A
  tab with no charts gets the inverse back as it is.
  """
  @spec wrap_shift_inverse(term(), map(), non_neg_integer()) :: term()
  def wrap_shift_inverse(inverse, old_tab, tab_idx) do
    items = for {chart, i} <- Enum.with_index(list(old_tab)), do: {chart["id"], chart, i}

    # A group is undone back to front: the edit's own inverse runs first and
    # puts the rows or columns back, then the charts.
    if items == [], do: inverse, else: {:group, [{:charts, tab_idx, items}, inverse]}
  end

  @doc """
  Put charts back on a tab, for undo and redo. `items` is `[{id, chart | nil,
  at}]`: a chart replaces the one with that id (or is inserted) at index `at`;
  `nil` removes the id. Never fails: a chart that would take the tab past
  `chart_cap/0` is left out. Returns `{new_tab, counter_items}`, the items
  that undo this call.
  """
  @spec put_back(map(), list()) :: {map(), list()}
  def put_back(tab, items) when is_map(tab) and is_list(items) do
    before = list(tab)

    counter =
      for {id, _chart, _at} <- items do
        at = Enum.find_index(before, &(&1["id"] == id))
        {id, at && Enum.at(before, at), at || 0}
      end

    ids = MapSet.new(items, fn {id, _chart, _at} -> id end)
    here = MapSet.new(before, & &1["id"])
    kept = Enum.reject(before, &MapSet.member?(ids, &1["id"]))

    # A chart still on the tab always goes back; one that is gone goes back
    # only while there is room under the cap.
    {present, absent} =
      items
      |> Enum.filter(fn {_id, chart, _at} -> is_map(chart) end)
      |> Enum.sort_by(fn {_id, _chart, at} -> at end)
      |> Enum.split_with(fn {id, _chart, _at} -> MapSet.member?(here, id) end)

    room = max(@chart_cap - length(kept) - length(present), 0)

    # Lowest index first, so each chart lands where it was.
    charts =
      (present ++ Enum.take(absent, room))
      |> Enum.sort_by(fn {_id, _chart, at} -> at end)
      |> Enum.reduce(kept, fn {_id, chart, at}, acc ->
        List.insert_at(acc, min(at, length(acc)), chart)
      end)

    {Map.put(tab, "charts", list(%{"charts" => charts})),
     Enum.sort_by(counter, fn {_id, _chart, at} -> at end)}
  end

  # ── data ─────────────────────────────────────────────────────────────────

  @doc """
  What a chart draws from the tab's `cells`.

  Returns `%{state, series, labels, table, skipped, more_series, truncated}`:
  `series` is `[%{label, points}]` (numbers only, at most four), `labels` the
  point labels, `table` the shown values as display strings (header row first)
  for the data-table fallback. A row where a drawn series has no number is left
  out (`skipped` counts those that held something); a column with no number is
  not a series. `state` is `:ok`, `:no_numbers` or `:bad_range`.
  """
  @spec data(map(), map()) :: map()
  def data(chart, cells) when is_map(chart) and is_map(cells) do
    case parse_range(Map.get(chart, "range")) do
      {:ok, {c1, r1, c2, r2}} ->
        c2 = min(c2, c1 + @read_cols - 1)
        r2 = min(r2, r1 + @read_rows - 1)
        labels? = Map.get(chart, "labels", true) == true and c2 > c1
        headers? = Map.get(chart, "headers", true) == true and r2 > r1
        cols = Enum.to_list(if(labels?, do: c1 + 1, else: c1)..c2)
        rows = Enum.to_list(if(headers?, do: r1 + 1, else: r1)..r2)
        build(cells, cols, rows, labels? && c1, headers? && r1)

      {:error, _} ->
        empty(:bad_range)
    end
  end

  def data(_chart, _cells), do: empty(:bad_range)

  defp empty(state) do
    %{
      state: state,
      series: [],
      labels: [],
      table: [],
      skipped: 0,
      more_series: 0,
      truncated: false
    }
  end

  defp build(cells, cols, rows, label_col, header_row) do
    numeric_cols =
      Enum.filter(cols, fn c -> Enum.any?(rows, &is_number(number_at(cells, c, &1))) end)

    drawn = Enum.take(numeric_cols, @max_series)

    {kept, dropped} =
      Enum.split_with(rows, fn r -> Enum.all?(drawn, &is_number(number_at(cells, &1, r))) end)

    shown = Enum.take(kept, @max_points)

    if drawn == [] or shown == [] do
      empty(:no_numbers)
    else
      names =
        Enum.map(drawn, fn c ->
          name = if header_row, do: text_at(cells, c, header_row), else: ""
          if name == "", do: Core.format_ref({c, 1}) |> String.trim_trailing("1"), else: name
        end)

      labels = if label_col, do: Enum.map(shown, &text_at(cells, label_col, &1)), else: []
      corner = if label_col && header_row, do: text_at(cells, label_col, header_row), else: ""

      body =
        for r <- shown do
          head = if label_col, do: text_at(cells, label_col, r), else: Integer.to_string(r)
          [head | Enum.map(drawn, &text_at(cells, &1, r))]
        end

      %{
        state: :ok,
        series:
          Enum.zip_with(drawn, names, fn c, name ->
            %{label: name, points: Enum.map(shown, &number_at(cells, c, &1))}
          end),
        labels: labels,
        table: [[corner | names] | body],
        skipped: Enum.count(dropped, fn r -> Enum.any?(cols, &(text_at(cells, &1, r) != "")) end),
        more_series: length(numeric_cols) - length(drawn),
        truncated: length(kept) > length(shown)
      }
    end
  end

  defp cell_at(cells, c, r), do: Map.get(cells, Core.format_ref({c, r}))

  # A formula cell's computed value counts; an error value or text never does.
  defp number_at(cells, c, r) do
    with %{"v" => v} = cell when is_number(v) <- cell_at(cells, c, r),
         true <- Map.get(cell, "t") != "e",
         true <- v == 0 or (abs(v) >= @min_magnitude and abs(v) <= @max_magnitude) do
      v
    else
      _ -> nil
    end
  end

  defp text_at(cells, c, r) do
    case cell_at(cells, c, r) do
      %{} = cell -> Core.display_value(cell)
      _ -> ""
    end
  end
end
