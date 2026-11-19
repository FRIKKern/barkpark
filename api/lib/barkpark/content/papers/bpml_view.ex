defmodule Barkpark.Content.Papers.BpmlView do
  @moduledoc """
  What a Paper row shows as BPML: the blocks and label fields that
  `GET /papers/:slug/source?format=bpml` prints for it.

  It is a function of the row alone: the anonymous reader's redaction under
  the Paper's own schema (`Content.Papers.reader_source_with_schema/3`), task
  blocks resolved for the given perspective, and the redacted label fields
  (`Content.Papers.anonymous_content/2`). The pull prints it, and a BPML push
  recomputes it from the row being written (`Bpml.WriteWall`), so both sides
  read the same view of the same row.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Document

  @type t ::
          {:blocks, blocks :: [map()], fields :: map()}
          | {:html, String.t()}
          | {:error, atom()}

  @doc """
  The view of `paper`. `scope` is the caller's tenant scope (`[]` for a flat
  route; the Paper's own workspace and project fill any gap), and
  `perspective` decides which task rows a task block resolves to.
  """
  @spec of(Document.t(), String.t(), keyword(), atom()) :: t()
  def of(%Document{} = paper, dataset, scope, perspective) do
    {reader_source, schema} = Content.Papers.reader_source_with_schema(paper, dataset, scope)

    case reader_source do
      {:blocks, blocks} ->
        resolved =
          Content.Papers.resolve_tasks_in_blocks(blocks, task_scope(paper, perspective), dataset)

        {:blocks, resolved, Content.Papers.anonymous_content(paper, schema)}

      other ->
        other
    end
  end

  @doc """
  The fingerprint of a pull's bytes (sha256, lowercase hex). The pull answers
  it in `x-bpml-view`; a push that carries it back is refused (412) when the
  row's view prints differently now, at any rev.
  """
  @spec hash(String.t()) :: String.t()
  def hash(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  `paper`'s view printed as `bp paper pull` gets it (flat route, published
  task rows): the bytes every BPML answer about the row carries. Raises
  `Bpml.UnprintableError` when the view does not print.
  """
  @spec print(Document.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def print(%Document{} = paper, dataset) do
    case of(paper, dataset, [], :published) do
      {:blocks, blocks, fields} ->
        {:ok,
         Barkpark.PortableDoc.Bpml.print_paper(
           Content.Papers.bpml_paper_map(paper, blocks, fields)
         )}

      _ ->
        {:error, "the paper has no blocks a pull can print"}
    end
  end

  @doc "The fingerprint of `print/2`'s bytes; nil when the view does not print."
  @spec hash_of(Document.t(), String.t()) :: String.t() | nil
  def hash_of(%Document{} = paper, dataset) do
    case print(paper, dataset) do
      {:ok, bytes} -> hash(bytes)
      {:error, _} -> nil
    end
  rescue
    Barkpark.PortableDoc.Bpml.UnprintableError -> nil
  end

  # The task-block scope carries the caller's OWN perspective, resolved by
  # `BarkparkWeb.AnonPerspective`, the single owner of "who may see drafts". A
  # plain anonymous caller (no token, no preview JWT, not an `:edit` share) is
  # pinned to `:published`, so `published_only: true` and a draft-only task
  # never reaches this view (task-b10e10b944f6f55b); a preview/edit-share
  # caller keeps `:drafts`/`:raw` and still sees them.
  defp task_scope(paper, perspective) do
    ws_id =
      paper.workspace_id ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [
      workspace_id: ws_id,
      project_id: paper.project_id,
      published_only: perspective == :published
    ]
  end
end
