defmodule Barkpark.Test.IdempotencyMounts do
  @moduledoc """
  The one reader the Idempotency tripwires share: where is
  `BarkparkWeb.Plugs.Idempotency` mounted, and does code stream
  (task-ccf7bc7003c505c9). Reads source ASTs; never compiles or writes.

  A mount is a `plug` call whose module, once the file's own `alias`es are
  applied, is `BarkparkWeb.Plugs.Idempotency`: by full name or through an
  alias (`alias …Idempotency`, `as:`, `alias BarkparkWeb.Plugs.{…}`), with or
  without options, with or without a `when` guard.

  A streaming call is `send_chunked` or `send_file` called bare, piped,
  captured, or by a qualified name (`Plug.Conn.send_chunked(conn, 200)`).
  """

  @plug [:BarkparkWeb, :Plugs, :Idempotency]
  @streaming [:send_chunked, :send_file]

  @typedoc "One mount: its options (nil when none) and its `when` guard (nil when unguarded)."
  @type mount :: %{opts: Macro.t() | nil, guard: Macro.t() | nil}

  @doc """
  Every Idempotency mount in `ast`. `aliases` defaults to the aliases declared
  in `ast` itself; pass the enclosing module's (from `aliases/1`) when `ast` is
  a fragment such as one pipeline's body.
  """
  @spec mounts(Macro.t(), %{atom() => [atom()]} | nil) :: [mount()]
  def mounts(ast, aliases \\ nil) do
    aliases = aliases || aliases(ast)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:plug, _, args} = node, acc when is_list(args) ->
          case mount(args, aliases) do
            nil -> {node, acc}
            mount -> {node, [mount | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # `plug M`, `plug M, opts`, `plug M when g`, `plug M, opts when g`.
  defp mount([{:when, _, [module, guard]}], aliases), do: mount_of(module, nil, guard, aliases)
  defp mount([module], aliases), do: mount_of(module, nil, nil, aliases)

  defp mount([module, {:when, _, [opts, guard]}], aliases),
    do: mount_of(module, opts, guard, aliases)

  defp mount([module, opts], aliases), do: mount_of(module, opts, nil, aliases)
  defp mount(_args, _aliases), do: nil

  defp mount_of({:__aliases__, _, segments}, opts, guard, aliases) do
    if expand(segments, aliases) == @plug, do: %{opts: opts, guard: guard}
  end

  defp mount_of(_module, _opts, _guard, _aliases), do: nil

  @doc "Does `ast` call `send_chunked` or `send_file` in any form?"
  @spec streams?(Macro.t()) :: boolean()
  def streams?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {call, _, _} = node, _acc when call in @streaming -> {node, true}
        {:., _, [_module, call]} = node, _acc when call in @streaming -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  @doc "The short name → full segments map of every `alias` in `ast`."
  @spec aliases(Macro.t()) :: %{atom() => [atom()]}
  def aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, segments}]} = node, acc ->
          {node, put_alias(acc, segments, nil)}

        {:alias, _, [{:__aliases__, _, segments}, opts]} = node, acc when is_list(opts) ->
          {node, put_alias(acc, segments, Keyword.get(opts, :as))}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn
             {:__aliases__, _, segments}, acc -> put_alias(acc, base ++ segments, nil)
             _other, acc -> acc
           end)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp put_alias(acc, segments, {:__aliases__, _, [as]}) when is_atom(as),
    do: Map.put(acc, as, segments)

  defp put_alias(acc, segments, _as) do
    case List.last(segments) do
      name when is_atom(name) -> Map.put(acc, name, segments)
      _ -> acc
    end
  end

  # Elixir expands only the FIRST segment of a module name through an alias.
  defp expand([head | tail] = segments, aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> full ++ tail
      :error -> segments
    end
  end

  defp expand(segments, _aliases), do: segments
end
