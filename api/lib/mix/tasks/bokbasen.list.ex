defmodule Mix.Tasks.Bokbasen.List do
  @moduledoc """
  List Bokbasen submissions filtered by lifecycle state.

  Phase 7 WI6. Pure DB read — no HTTP, never logs credentials.

  ## Usage

      mix bokbasen.list                          # latest 50, any state
      mix bokbasen.list --status failed          # only :failed
      mix bokbasen.list --status accepted --limit 10

  ## Canonical state form

  Lowercase strings only — `pending`, `staging`, `staged`, `polling`,
  `accepted`, `rejected`, `failed`, `cancelled`, `cannot_cancel`. Anything
  else triggers a friendly error listing the 9 valid states and exits 1.

  ## Columns

    * `book_id`         — `doc_id`
    * `title`           — truncated to ~40 chars
    * `state`           — colored via `IO.ANSI.format/1` when stdout is a TTY
    * `submission_id`   — Bokbasen submission_id, or `(none)`
    * `last_action_at`  — `updated_at` from the status JSON, or `(never)`

  ## Exit codes

    * `0` — success
    * `1` — invalid `--status` value / DB error
  """
  @shortdoc "List Bokbasen submissions filtered by state"

  use Mix.Task

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Repo

  import Ecto.Query

  @switches [status: :string, limit: :integer]
  @type_default "book"
  @dataset_default "production"
  @default_limit 50
  @states ~w(pending staging staged polling accepted rejected failed cancelled cannot_cancel)

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts =
      try do
        OptionParser.parse!(argv, strict: @switches)
      rescue
        e in OptionParser.ParseError ->
          Mix.shell().error("invalid arguments: #{Exception.message(e)}")
          Mix.raise("usage: mix bokbasen.list [--status <state>] [--limit N]")
      end
      |> elem(0)

    state_filter = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, @default_limit)

    if not is_nil(state_filter) and state_filter not in @states do
      Mix.shell().error("invalid --status: #{inspect(state_filter)}")
      Mix.shell().error("valid states (lowercase): #{Enum.join(@states, ", ")}")
      Mix.raise("invalid status")
    end

    rows = collect_rows(state_filter, limit)

    case rows do
      [] ->
        Mix.shell().info("(no matching submissions)")
        :ok

      _ ->
        print_header()
        Enum.each(rows, &print_row/1)
        :ok
    end
  end

  defp collect_rows(state_filter, limit) do
    Document
    |> where([d], d.type == ^@type_default and d.dataset == ^@dataset_default)
    |> order_by([d], desc: d.updated_at)
    |> Repo.all()
    |> Enum.map(fn doc ->
      status = PublishWorker.read_status(doc)

      %{
        doc_id: doc.doc_id,
        title: doc.title || "",
        state: Map.get(status, "state"),
        submission_id: Map.get(status, "bokbasen_submission_id"),
        last_action_at: Map.get(status, "updated_at")
      }
    end)
    |> Enum.filter(fn row ->
      cond do
        is_nil(state_filter) -> not is_nil(row.state)
        true -> row.state == state_filter
      end
    end)
    |> Enum.take(max(limit, 0))
  end

  defp print_header do
    Mix.shell().info(
      :io_lib.format("~-20s ~-40s ~-15s ~-30s ~-25s", [
        "book_id",
        "title",
        "state",
        "submission_id",
        "last_action_at"
      ])
      |> IO.iodata_to_binary()
    )

    Mix.shell().info(String.duplicate("-", 132))
  end

  defp print_row(row) do
    title = truncate(row.title, 40)
    sub = row.submission_id || "(none)"
    when_ = row.last_action_at || "(never)"
    state_text = colorize(row.state)

    Mix.shell().info(
      :io_lib.format("~-20s ~-40s ~-15ts ~-30s ~-25s", [
        row.doc_id,
        title,
        state_text,
        sub,
        when_
      ])
      |> IO.iodata_to_binary()
    )
  end

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) <= n, do: s, else: String.slice(s, 0, n - 1) <> "…"
  end

  defp truncate(_, _), do: ""

  defp colorize(nil), do: "(none)"

  defp colorize(state) do
    if IO.ANSI.enabled?() do
      [color_for(state), state, IO.ANSI.reset()]
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()
    else
      state
    end
  end

  defp color_for("accepted"), do: IO.ANSI.green()
  defp color_for(s) when s in ["staged", "polling"], do: IO.ANSI.cyan()
  defp color_for("rejected"), do: IO.ANSI.red()
  defp color_for(s) when s in ["failed", "cancelled", "cannot_cancel"], do: IO.ANSI.yellow()
  defp color_for(_), do: IO.ANSI.default_color()
end
