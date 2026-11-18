defmodule Barkpark.PortableDoc.FromMarkdown.KeptBack do
  @moduledoc """
  The ` ```portabledoc ` fences a Markdown import kept back as code blocks, and
  the PortableDoc errors their own blocks carry: the one helper for every door
  that writes imported Markdown behind the ratchet (`Validate.NewErrors`).

  `FromMarkdown` never splices a fence whose blocks would not validate, so its
  output always validates and the ratchet's own check finds nothing. Before, it
  spliced such a fence and the ratchet named the error. `check/2` keeps the
  author told: each kept-back fence that holds a JSON list is validated as the
  blocks of a doc, and every error it gives counts, at the place the fence's
  blocks would have taken instead of its code block. A fence whose code block is
  at `/blocks/2` with a bad `level` in its first block reports `/blocks/2/level`.
  A fence that is not a JSON list gives no error, as before. A fence the stored
  blocks already hold, as a code block with the same source, keeps its errors
  as old ones, so re-publishing the same Markdown adds none.
  """

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Validate
  alias Barkpark.PortableDoc.Validate.NewErrors

  @type fence :: %{source: String.t(), path: String.t()}

  @doc "`FromMarkdown.read/1`: the blocks and the fences it kept back."
  @spec read(term()) :: {[map()], [fence()]}
  def read(markdown), do: FromMarkdown.read(markdown)

  @doc "The errors of each fence's own blocks, at the fence's place."
  @spec errors([fence()]) :: [Validate.error()]
  def errors(fences), do: Enum.flat_map(fences, &fence_errors/1)

  @doc """
  The ratchet's verdict on the kept-back `fences` of a write over `stored`
  blocks: `:ok`, a `portable_doc_invalid` warning, or `{:error, {:halted, _}}`,
  as `NewErrors.check/2` answers.
  """
  @spec check(term(), [fence()]) :: :ok | {:error, {:halted, String.t()}}
  def check(_stored, []), do: :ok

  def check(stored, fences) do
    held = code_values(stored)
    {old, new} = Enum.split_with(fences, &MapSet.member?(held, &1.source))
    NewErrors.judge(errors(new), errors(old))
  end

  defp fence_errors(%{source: source, path: path}) do
    with {:ok, blocks} when is_list(blocks) <- Jason.decode(source),
         {:error, errors} <- Validate.validate(%{"blocks" => blocks}) do
      Enum.map(errors, &%{&1 | path: rebase(&1.path, path)})
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # The fence's block `j` takes the place `i + j` in the list its code block
  # sits in at `i`.
  defp rebase(error_path, code_path) do
    {prefix, [index]} = code_path |> String.split("/") |> Enum.split(-1)

    case Regex.run(~r{\A/blocks/(\d+)(.*)\z}s, error_path) do
      [_, j, rest] ->
        place = String.to_integer(index) + String.to_integer(j)
        Enum.join(prefix ++ [Integer.to_string(place)], "/") <> rest

      _ ->
        code_path
    end
  end

  # The sources of the stored top-level code blocks: a kept-back fence is one.
  defp code_values(stored) when is_list(stored),
    do: MapSet.new(for(%{"type" => "code", "value" => value} <- stored, do: value))

  defp code_values(_stored), do: MapSet.new()
end
