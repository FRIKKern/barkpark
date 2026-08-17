defmodule Barkpark.PortableDoc.Bpml.UnprintableError do
  @moduledoc """
  The printer's ONE typed refusal: these blocks cannot be spelled in BPML.

  BPML is a kernel vocabulary, not the whole PortableDoc block set, so a
  persisted paper can legitimately be unprintable. Before this exception the
  printer said so in two incompatible ways — an `ArgumentError` for an unknown
  block type (rescued into an honest 422) and a bare `FunctionClauseError` for
  every other shape (unknown inline node, raw string where an inline node
  belongs, `inline/1` on a non-list, a bare-string table head cell), which
  escaped the rescue and became a raw HTTP 500 with an HTML error page — 141 of
  776 published papers on the 2026-08-17 census
  (`tooling/grip/ledger/bpml-full-corpus-census-2026-08-17.md`). A `%{"text" =>
  …}`-less head-cell map was worse than a crash: it printed `""` and lost the
  cell silently.

  Every unprintable shape now raises THIS, tagged with the `kind` of position
  that could not be spelled and the offending `type` when the shape carries one
  (`nil` when it does not — a type-less block, a raw string inline child):

    * `:block`     — a block whose `type` is outside the kernel, or a block map
      with no `type` at all;
    * `:inline`    — an inline node type the printer has no clause for, or a
      non-node where inline content belongs;
    * `:mark`      — a text mark outside strong|em|code|underline|strike;
    * `:head_cell` — a table head cell that is neither an inline-node list nor
      a legacy `%{"text" => binary}` map.

  It stays TYPED rather than becoming a broadened rescue at the callers (charter
  D3): a blanket `rescue` would convert genuine printer bugs into the same 422,
  making progress unmeasurable and bugs invisible. Only a typed raise lets the
  sync path tell "the canonical echo is unprintable, degrade to 200 + rev" apart
  from "the printer is broken, crash loudly".

  The `Plug.Exception` implementation is a BACKSTOP: callers that know what they
  are printing rescue it explicitly (and shape their own teaching envelope), but
  an unrescued escape answers 422 rather than 500 — an unprintable paper is
  never a server fault.
  """

  @kinds [:block, :inline, :mark, :head_cell]

  defexception [:kind, :type, :message]

  @type kind :: :block | :inline | :mark | :head_cell
  @type t :: %__MODULE__{kind: kind(), type: String.t() | nil, message: String.t()}

  @doc "The four positions BPML can fail to spell."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build the refusal for `kind` at `type` (`nil` when the offending shape carries
  no type name). The message names BOTH — the census buckets papers by it, so
  the wording is part of the contract.
  """
  @spec new(kind(), String.t() | atom() | nil) :: t()
  def new(kind, type) when kind in @kinds do
    %__MODULE__{kind: kind, type: type_name(type), message: build_message(kind, type)}
  end

  defp build_message(kind, nil),
    do: "BPML printer: #{noun(kind)} #{shapeless(kind)} (kind: #{kind})"

  defp build_message(kind, type),
    do:
      "BPML printer: #{noun(kind)} type #{inspect(type_name(type))} is outside the BPML kernel vocabulary (kind: #{kind})"

  defp noun(:block), do: "block"
  defp noun(:inline), do: "inline node"
  defp noun(:mark), do: "inline mark"
  defp noun(:head_cell), do: "table head cell"

  defp shapeless(:block), do: "carries no \"type\" — it cannot be spelled"
  defp shapeless(:inline), do: "is not a typed inline node — it cannot be spelled"
  defp shapeless(:mark), do: "is not a mark name — it cannot be spelled"

  defp shapeless(:head_cell),
    do: "is neither an inline-node list nor a %{\"text\" => binary} map — it cannot be spelled"

  defp type_name(nil), do: nil
  defp type_name(type) when is_binary(type), do: type
  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(other), do: inspect(other, limit: 3, printable_limit: 64)
end

defimpl Plug.Exception, for: Barkpark.PortableDoc.Bpml.UnprintableError do
  def status(_e), do: 422
  def actions(_e), do: []
end
