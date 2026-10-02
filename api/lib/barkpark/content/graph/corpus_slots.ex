defmodule Barkpark.Content.Graph.CorpusSlots do
  @moduledoc """
  The `/v1/graph` corpus admission-cap slot table — CORE, not the Tasks plugin.

  `GET /v1/graph` is mounted from core (router.ex, "Content graph reads — CORE,
  not the Tasks plugin") so the content graph answers with every plugin off.
  Its concurrency cap keeps one ETS row per held slot, and the table must exist
  before the first request: `BarkparkWeb.TasksController`'s acquire path never
  creates it (a request-owned table dies with the request and the bound silently
  resets), and with no table it sheds with 503. So the table's creation is a
  core boot duty. When it was called as `TasksController.init_graph_corpus_slots/0`
  it read as Tasks-plugin wiring, and moving it into the Tasks plugin would have
  made every `GET /v1/graph` shed permanently under the plugin kill switch.

  `init/0` is called ONCE from `Barkpark.Application.start/2`, so the table is
  owned by the application process and lives as long as the application. The
  acquire/release/sweep logic stays beside the route in `TasksController`; this
  module owns only the table's name and its creation.
  """

  @table :barkpark_graph_corpus_slots

  @doc "The named ETS table holding the currently-held corpus slots."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Create the slot table, owned by the caller. Idempotent: a second call (a
  re-boot in the test VM) is a no-op, and the rows are slots, so nothing is
  lost by NOT clearing them.
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          # Lost the create race to a concurrent boot (the test VM re-starts the
          # supervision tree) — the table exists, which is all this needs.
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
