defmodule Barkpark.Content.Papers.BpmlView do
  @moduledoc """
  The reader's view of a Paper as BPML: the blocks and label fields an
  anonymous reader may see, under the Paper's own schema, with task blocks
  resolved for the perspective.

  ONE builder serves the pull (`GET /papers/:slug/source`), the answers to a
  push that updates or creates a Paper, and the comparison a push is diffed
  against (`Bpml.Diff.derive/3`). What it refuses, all four refuse alike, and
  a push it refuses writes nothing.

  It refuses a Paper whose reader is shown no blocks (the reader's own
  answer: an HTML source, a redacted source, or nothing), a view with an
  untyped block, an empty view, and a cache that holds text its stored blocks
  lack. A refusal names its reason only; it quotes nothing stored.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Envelope}
  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.PortableDoc.{Bpml, Projection}
  alias Barkpark.PortableDoc.Bpml.Diff

  @reasons %{
    ambiguous_source: "this Paper's stored HTML holds text its blocks lack",
    semantic_empty: "the reader's view of this Paper is empty",
    redacted_source: "the reader may see none of this Paper's blocks",
    invalid_blocks: "a block of this Paper has no type"
  }

  @type t ::
          {:blocks, blocks :: [map()], fields :: map()}
          | {:html, String.t()}
          | {:error, atom()}

  @doc """
  The view of `paper`. `scope` is the caller's tenant scope (`[]` for a flat
  route; the Paper's own workspace and project fill any gap), and
  `perspective` decides which task rows a task block resolves to. Pure but
  for the schema and label reads: it writes nothing.
  """
  @spec of(Document.t(), String.t(), keyword(), atom()) :: t()
  def of(%Document{} = paper, dataset, scope, perspective) do
    schema = Content.Papers.reader_schema(paper, "paper", dataset, scope)
    content = paper.content || %{}
    stored = Projection.read_blocks(content)

    case Map.get(Envelope.render(paper, schema, CallerContext.anonymous()), "blocks") do
      blocks when is_list(blocks) and is_list(stored) ->
        cond do
          not Enum.all?(blocks, &typed?/1) ->
            {:error, :invalid_blocks}

          Hollow.hollow?(blocks) ->
            {:error, :semantic_empty}

          # A cache that holds text its stored blocks lack is refused.
          Content.Papers.cache_provenance(paper, stored, content["body_html"], dataset) ==
              :divergent ->
            {:error, :ambiguous_source}

          true ->
            resolved =
              Content.Papers.resolve_tasks_in_blocks(
                blocks,
                task_scope(paper, perspective),
                dataset
              )

            {:blocks, resolved, Content.Papers.anonymous_content(paper, schema)}
        end

      _no_blocks_shown ->
        case Content.Papers.reader_source(paper, dataset, scope) do
          {:blocks, _blocks} -> {:error, :redacted_source}
          other -> other
        end
    end
  end

  defp typed?(%{"type" => type}) when is_binary(type), do: String.trim(type) != ""
  defp typed?(_block), do: false

  @doc """
  `paper`'s view printed as `bp paper pull` gets it (flat route, published
  task rows): the bytes the pull, push and create answers carry, or the
  refusal (`refusal/1`) every one of them gives.
  """
  @spec print(Document.t(), String.t()) :: {:ok, String.t()} | {:refused, map()}
  def print(%Document{} = paper, dataset) do
    case of(paper, dataset, [], :published) do
      {:blocks, blocks, fields} -> print(paper, blocks, fields)
      other -> {:refused, refusal(other)}
    end
  end

  defp print(paper, blocks, fields) do
    {:ok, Bpml.print_paper(Content.Papers.bpml_paper_map(paper, blocks, fields))}
  rescue
    e in Bpml.UnprintableError -> {:refused, refusal({:unprintable, Exception.message(e)})}
  end

  @doc """
  The ops a push of `pushed` derives against `paper`, compared with the
  view: a pushed block that spells as the view showed it was not edited.
  Refused, before anything is written, when the view cannot be built, or when
  the Paper as the ops would leave it has no view that prints.
  """
  @spec push(Document.t(), [map()], String.t()) ::
          {:ok, [map()]} | {:refused, map()} | {:error, :diff_verification_failed}
  def push(%Document{} = paper, pushed, dataset) do
    stored = Projection.read_blocks(paper.content || %{}) || []

    with {:blocks, shown, fields} <- of(paper, dataset, [], :published),
         {:ok, _bpml} <- print(paper, shown, fields),
         {:ok, blocks, ops} <- Diff.derive(stored, pushed, shown),
         nil <- if(ops != [], do: write_refusal(written(paper, blocks), dataset)) do
      {:ok, ops}
    else
      {:error, :diff_verification_failed} = failed -> failed
      {:refused, _body} = refused -> refused
      %{} = body -> {:refused, body}
      view -> {:refused, refusal(view)}
    end
  end

  @doc """
  The refusal a write of `paper` gets when the Paper it would leave has no
  view that prints; nil when it has one.
  """
  @spec write_refusal(Document.t(), String.t()) :: map() | nil
  def write_refusal(%Document{} = paper, dataset) do
    case print(paper, dataset) do
      {:ok, _bpml} -> nil
      {:refused, body} -> body
    end
  end

  @doc "The Paper a create of `parsed` at `slug` would store, for `write_refusal/2`."
  @spec created(String.t(), map(), keyword()) :: Document.t()
  def created(slug, parsed, scope) do
    content = Map.take(parsed, ["blocks", "description", "tags", "style"])

    %Document{
      doc_id: slug,
      type: "paper",
      workspace_id: scope[:workspace_id],
      project_id: scope[:project_id],
      content: content
    }
  end

  # The row as a write of `blocks` leaves it: the cache is rendered from them.
  defp written(paper, blocks) do
    content = paper.content |> Map.put("blocks", blocks) |> Map.drop(["body", "body_html"])
    %{paper | content: content}
  end

  @doc """
  The error the pull, a push and a create give when the view cannot be
  built. It names the reason only and quotes nothing stored.
  """
  @spec refusal(t() | {:unprintable, String.t()}) :: map()
  def refusal({:html, _html}),
    do: body("this Paper's source is HTML; it has no blocks to show as BPML", "bpml_unavailable")

  def refusal({:unprintable, why}) do
    "the reader's view of this Paper does not print as BPML (#{why})"
    |> body("bpml_unprintable")
    |> Map.put(:hint, "nothing was written; fetch format=json, and edit it with block ops")
  end

  def refusal({:error, reason}),
    do:
      body(
        to_string(reason),
        @reasons[reason] || "the reader's view of this Paper cannot be built"
      )

  defp body(message, code) do
    %{
      code: code,
      message: message <> ", so it cannot be pulled or pushed as text",
      hint: "nothing was written; bp paper pull answers the same until the Paper changes"
    }
  end

  @doc """
  The title the view shows: derived from the view the way the row's title is
  derived from the row (the bound `title` field, else the first heading's
  text, else the slug), so a heading the view hides is not printed as the
  title. A row title that does not come from the row's content is printed as
  it is.
  """
  @spec title(Document.t(), [map()], map()) :: String.t() | nil
  def title(%Document{} = paper, blocks, fields) do
    raw = paper.content || %{}

    if paper.title == derived_title(raw["title"], raw["blocks"], paper.doc_id),
      do: derived_title(fields["title"], blocks, paper.doc_id),
      else: paper.title
  end

  defp derived_title(field, blocks, slug) do
    case field do
      s when is_binary(s) and s != "" -> s
      _ -> Content.Papers.BlockOps.heading_title(blocks) || slug
    end
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
