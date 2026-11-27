defmodule Barkpark.Content.PortableText.ParseMemo do
  @moduledoc """
  One save's parses of the editor's HTML (task-6a5c3e075299d4bc).

  The save's edit read (`Forms.edits/3`) parses one posted rich text up to
  five times: the post and the form's image of the stored value each twice
  over the field and its object, and the post once more against the stored
  blocks. A 50k-object post took a fifth of a second of work per parse.
  `PortableText.from_html/3` is a pure function of its arguments, so inside
  `around/1` each distinct `{html, stored, opts}` is parsed once and the
  same blocks are given again. Nothing outlives the call.
  """

  @key {__MODULE__, :parsed}

  @doc "Runs `fun` with one parse per distinct input; nested calls share it."
  def around(fun) do
    case Process.get(@key) do
      nil ->
        Process.put(@key, %{})

        try do
          fun.()
        after
          Process.delete(@key)
        end

      _ ->
        fun.()
    end
  end

  @doc "`parse.()`, or the blocks the same input gave inside `around/1`."
  def parsed(input, parse) do
    case Process.get(@key) do
      %{^input => blocks} ->
        blocks

      %{} = memo ->
        blocks = parse.()
        Process.put(@key, Map.put(memo, input, blocks))
        blocks

      nil ->
        parse.()
    end
  end
end
