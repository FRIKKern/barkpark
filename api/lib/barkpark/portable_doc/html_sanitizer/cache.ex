defmodule Barkpark.PortableDoc.HtmlSanitizer.Cache do
  @moduledoc """
  Keeps `HtmlSanitizer.sanitize/2`'s output for a body it has scrubbed
  (task-13c9d34562701725).

  ## Why

  Since #28404 the scrub parses the body as a browser does and writes the
  clean tree back, up to three passes. It costs about 2–3 times the regex
  scrub before it: 29 ms at 40 KB, 130 ms at 400 KB, 0.7–0.9 s at 2 MB
  (review of #28404, r3). `Content.Papers` runs it on every read of a Paper
  that has only `body_html`, and the same body comes out every time.

  ## The key and the version

  An entry is keyed by the SHA-256 of the body and the Paper's own path
  (`Anchors.self_path/1` of `opts[:id]`, which decides a same-page link).
  It is served only under the policy version it was stored under:
  `version/0`, a hash of the sanitizer's rule tables (`Elements.kept/0`,
  `inert/0` and `dropped/0`, `StyleGrammar.table/0`), the compiled code of
  the sanitizer and its parts (which holds the attribute, style and class
  sets), the `lazy_html` parser's version, and the configured pass cap. A
  rule change, a code change or a parser upgrade changes the version, and
  every entry stored before it is a miss.

  ## Why ETS, per node

  Every node computes the key and the version from the body and its own
  code, so an entry is right on the node that holds it, and no node has to
  tell another anything. A deploy changes the version on each node as it
  starts. A column on the Paper would need a migration and a write on the
  read path, for a value every node can compute.

  ## What is never cached

  A call with `:editor` (its `href_allowed?` is a function), with
  `:max_passes`, or when the cache is off. The table holds at most
  `@max_bytes` of output; past it, it is emptied and refills with what is
  still read.

  ## On in `:test` too

  The scrub reads nothing but its input and its rules, so the cache is on in
  every environment and every test runs through it. `config :barkpark,
  :html_sanitizer_cache, false` turns it off.
  """

  alias Barkpark.PortableDoc.HtmlSanitizer
  alias Barkpark.PortableDoc.HtmlSanitizer.{Anchors, Elements, Serializer, StyleGrammar}

  @table :barkpark_html_sanitizer_cache
  @max_bytes 64 * 1024 * 1024
  @static_key {__MODULE__, :static_version}
  @modules [HtmlSanitizer, Elements, StyleGrammar, Serializer, Anchors]

  @doc """
  The output for `html` and `opts`: the cached one under the current
  version, else `build.()`, stored.
  """
  @spec fetch(String.t(), keyword(), (-> String.t())) :: String.t()
  def fetch(html, opts, build) when is_binary(html) and is_function(build, 0) do
    if enabled?() and cacheable?(opts) and table?() do
      key = {:crypto.hash(:sha256, html), Anchors.self_path(opts[:id])}
      version = version()

      case safe(fn -> :ets.lookup(@table, key) end) do
        [{^key, ^version, out}] ->
          out

        _ ->
          out = build.()
          store(key, version, out)
          out
      end
    else
      build.()
    end
  end

  @doc """
  The policy version: `version/1` of the current rule tables. The static
  part is computed once per node.
  """
  @spec version() :: binary()
  def version do
    code = Enum.map(@modules, & &1.module_info(:md5))

    # Rebuilt when the code changes under a running node (a reload in dev).
    static =
      case :persistent_term.get(@static_key, nil) do
        {^code, tables} ->
          tables

        _ ->
          tables = static_tables(code)
          :persistent_term.put(@static_key, {code, tables})
          tables
      end

    version({static, HtmlSanitizer.configured_max_passes()})
  end

  @doc "The version of a set of rule tables: a hash of the term."
  @spec version(term()) :: binary()
  def version(tables), do: :crypto.hash(:sha256, :erlang.term_to_binary(tables))

  defp static_tables(code) do
    version(%{
      kept: Elements.kept(),
      inert: Elements.inert(),
      dropped: Elements.dropped(),
      style: StyleGrammar.table(),
      code: code,
      parser: Application.spec(:lazy_html, :vsn)
    })
  end

  @doc "Whether the cache is on (`config :barkpark, :html_sanitizer_cache`, default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:barkpark, :html_sanitizer_cache, true) == true

  @doc "Drop every entry. Safe when the table was never created."
  @spec invalidate() :: :ok
  def invalidate do
    if table?(), do: safe(fn -> :ets.delete_all_objects(@table) end)
    :ok
  end

  @doc """
  Create the table, owned by the caller. `Barkpark.Application.start/2` calls
  it at boot so the table lives as long as the application. Idempotent.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if table?() do
      :ok
    else
      try do
        _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp cacheable?(opts),
    do: not Keyword.has_key?(opts, :editor) and not Keyword.has_key?(opts, :max_passes)

  # The output's bytes ride a counter row; past `@max_bytes` the table is
  # emptied first. A binary is stored off the ETS heap, so `:ets.info/2`'s
  # memory does not count it.
  defp store(key, version, out) do
    safe(fn ->
      bytes = :ets.update_counter(@table, :bytes, {2, byte_size(out)}, {:bytes, 0})

      if bytes > @max_bytes do
        :ets.delete_all_objects(@table)
        :ets.insert(@table, {:bytes, byte_size(out)})
      end

      :ets.insert(@table, {key, version, out})
    end)
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  # A table that vanished is a cold cache.
  defp safe(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end
end
