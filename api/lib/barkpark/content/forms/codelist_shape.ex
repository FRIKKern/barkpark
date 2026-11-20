defmodule Barkpark.Content.Forms.CodelistShape do
  @moduledoc """
  A codelist field's post from the page is one short code, or nothing
  (task-6617a482448ddb3d, review of #27107).

  A codelist field holds one code. An unknown code is still stored on purpose
  (task-400a66c6ebd31026): Validation warns under the field. But a post made
  by hand stored a list, a map or a 200 KB string for it, and a combobox over
  a long list takes any typed text. `split/2` takes such a post out of the
  page's params, so the store keeps what it held, and names the field, so
  the page can say it was not saved (`RefusedSave.not_codes/2`).

  Only posts from the page are read here. A write the server built from a
  stored value (Review changes' Revert, an undo) is written as it is: a
  stored list put back is not a typed one. A paste is read by the same rule
  (`code?/1`, `FieldPaste`), so a value typed and a value pasted are a code
  alike (task-141a4243ed18f4c5).

  A code is at most 64 characters: the longest bundled code is 19
  (`all-rights-reserved`), Thema's 14.
  """

  alias Barkpark.Content.Forms.Unset

  @max_length 64

  @doc "The longest code a page post may write, in characters."
  def max_length, do: @max_length

  @doc """
  `{params, dropped}`: `params` without each top-level codelist field whose
  post is not a code, and those fields' names. A field not posted, an empty
  post and the unset marker are left as they are.
  """
  @spec split(map(), term()) :: {map(), [String.t()]}
  def split(params, %{fields: fields}) when is_map(params) and is_list(fields) do
    dropped =
      for %{"name" => key, "type" => "codelist"} <- fields,
          is_binary(key),
          {:ok, posted} <- [Map.fetch(params, key)],
          not code?(posted),
          do: key

    {Map.drop(params, dropped), dropped}
  end

  def split(params, _schema), do: {params, []}

  @doc """
  Whether `value` is what a codelist field holds: one code of at most
  `max_length/0` characters (and four bytes each), or nothing. Nothing, nil
  or the unset marker, clears the field, as TanStack's paste of a null does.
  A list, a map or a number is not a code.
  """
  @spec code?(term()) :: boolean()
  def code?(nil), do: true
  def code?(%Unset{}), do: true

  def code?(code) when is_binary(code),
    do: byte_size(code) <= 4 * @max_length and String.length(code) <= @max_length

  def code?(_value), do: false
end
