defmodule Barkpark.Content.Forms.Unset do
  @moduledoc """
  The desk's unset marker (`Barkpark.Content.Forms.unset/0`): a key posted
  with it is taken off its object by the save, as TanStack's `write()`
  unsets it. The save strips every marker before storage
  (`Forms.edits/3`), and the form buffer holds nil in its place
  (`Forms.unset_as_nil/1`).

  A marker that gets past those is a bug, and it fails loudly: rendering it
  into a page or encoding it as JSON raises, so it is never drawn into an
  input or stored as text.
  """

  defstruct []

  @type t :: %__MODULE__{}

  @doc false
  def leaked!(where),
    do:
      raise(ArgumentError, "the desk's unset marker reached #{where}: it must be stripped first")
end

defimpl Phoenix.HTML.Safe, for: Barkpark.Content.Forms.Unset do
  def to_iodata(_marker), do: Barkpark.Content.Forms.Unset.leaked!("a page")
end

defimpl Jason.Encoder, for: Barkpark.Content.Forms.Unset do
  def encode(_marker, _opts), do: Barkpark.Content.Forms.Unset.leaked!("a JSON encoding")
end

defimpl JSON.Encoder, for: Barkpark.Content.Forms.Unset do
  def encode(_marker, _encoder), do: Barkpark.Content.Forms.Unset.leaked!("a JSON encoding")
end
