defmodule Barkpark.Search.SurfaceConfigs.CacheOwner do
  @moduledoc """
  Owns the `Barkpark.Search.SurfaceConfigs` ETS cache for the life of the node.

  An ETS table dies with the process that created it. The cache used to be
  created lazily by whichever process called `SurfaceConfigs.get/3` first — a
  request handler, a Task, an async test — so the table vanished when that
  caller exited, and any process between `ensure_cache/0` and its next
  `:ets.insert/2` or `:ets.lookup/2` raised `ArgumentError` ("the table
  identifier does not refer to an existing ETS table"). That reddened main's
  elixir Test (SurfaceConfigTest, run 36976528873); in production it was a rare
  500 plus a cache that silently reset whenever its creator exited.

  This process does nothing but create the table at boot and hold it.
  `SurfaceConfigs.ensure_cache/0` remains the fallback for code that runs with
  no application started (mix tasks, scripts).
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Barkpark.Search.SurfaceConfigs.create_cache_table()
    {:ok, nil}
  end
end
