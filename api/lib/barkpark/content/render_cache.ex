defmodule Barkpark.Content.RenderCache do
  @moduledoc """
  A cache that lives for ONE render (ctx-b6-memoized-visibility-gate).

  A paper with N query-carrying task blocks resolved the `task` schema N times,
  once per block (measured: 12 blocks, 12 schema reads). The render opens one
  cache with `with_cache/1` and threads its ref to every fetch; a reader asks
  `fetch/3` for a value under a key and computes it at most once per render.

  The cache is deleted when `with_cache/1` returns, so a long-lived process (a
  LiveView, a worker) never keeps a schema past the render that read it, and
  a fetch with no ref (`nil`) just computes. Content owns it so a paper can
  open one without naming the plugin that reads through it.
  """

  @doc "Run `fun` with a fresh cache ref; the cache is gone when it returns."
  @spec with_cache((reference() -> result)) :: result when result: term()
  def with_cache(fun) when is_function(fun, 1) do
    ref = make_ref()

    try do
      fun.(ref)
    after
      Process.delete({__MODULE__, ref})
    end
  end

  @doc "The value under `key` in this render's cache, computing it once."
  @spec fetch(reference() | nil, term(), (-> value)) :: value when value: term()
  def fetch(nil, _key, fun), do: fun.()

  def fetch(ref, key, fun) when is_reference(ref) do
    cache = Process.get({__MODULE__, ref}, %{})

    case cache do
      %{^key => value} ->
        value

      _ ->
        value = fun.()
        Process.put({__MODULE__, ref}, Map.put(cache, key, value))
        value
    end
  end
end
