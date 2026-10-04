defmodule Barkpark.Content.DocumentSize do
  @moduledoc """
  The per-document size cap (owner ruling #39, task-923e630674853500).

  Every save copies the whole document into history (`revisions`) and the
  event log (`mutation_events.document`), and webhooks post it on every
  delivery, so one oversized document multiplies on each small edit. Nothing
  capped a document before: HTTP accepted 100 MB bodies.

  The cap is measured as the JSON-encoded byte size of `title` + `content`,
  the bytes a reader of the API receives. It is checked in
  `Barkpark.Content.Document.changeset/2`, the one changeset every write door
  goes through (mutate, Studio save, paper and block ops, plugins), and only
  when `title` or `content` changes, so a status-only update to an old large
  row is never blocked.

  Default 10 MB (`@default_max_bytes`). Set `config :barkpark,
  :max_document_bytes, n` or `BARKPARK_MAX_DOCUMENT_BYTES` (runtime.exs) to
  change it; `nil` or `0` turns the cap off. A refusal renders as HTTP 413
  `document_too_large` with `details.limit_bytes` and `details.size_bytes`.
  """

  @default_max_bytes 10_000_000

  @doc "The configured cap in bytes, or `nil` when the cap is off."
  @spec max_bytes() :: pos_integer() | nil
  def max_bytes do
    case Application.get_env(:barkpark, :max_document_bytes, @default_max_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc "The default cap, for docs and tests."
  def default_max_bytes, do: @default_max_bytes

  @doc """
  JSON-encoded byte size of a document's title and content. Falls back to the
  external term size for a value Jason cannot encode, so the measure never
  raises on the write path.
  """
  @spec measure(String.t() | nil, term()) :: non_neg_integer()
  def measure(title, content) do
    encoded_size(title) + encoded_size(content)
  end

  defp encoded_size(nil), do: 0

  defp encoded_size(term) do
    term |> Jason.encode_to_iodata!() |> IO.iodata_length()
  rescue
    _ -> :erlang.external_size(term)
  end

  @doc """
  Changeset guard: adds a `:content` error tagged `validation:
  :document_too_large` when the changed title/content exceed the cap.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = cs) do
    with limit when is_integer(limit) <- max_bytes(),
         true <- Map.has_key?(cs.changes, :content) or Map.has_key?(cs.changes, :title),
         size when size > limit <-
           measure(Ecto.Changeset.get_field(cs, :title), Ecto.Changeset.get_field(cs, :content)) do
      Ecto.Changeset.add_error(
        cs,
        :content,
        "document is %{size} bytes, over the %{limit}-byte limit",
        validation: :document_too_large,
        size: size,
        limit: limit
      )
    else
      _ -> cs
    end
  end

  @doc """
  `{limit, size}` when the changeset was refused by `validate/1`, else `nil`.
  `Barkpark.Content.Errors` uses it to answer 413 instead of a generic 422.
  """
  @spec refusal(Ecto.Changeset.t()) :: {pos_integer(), non_neg_integer()} | nil
  def refusal(%Ecto.Changeset{errors: errors}) do
    Enum.find_value(errors, fn
      {:content, {_msg, opts}} ->
        if opts[:validation] == :document_too_large, do: {opts[:limit], opts[:size]}

      _ ->
        nil
    end)
  end
end
