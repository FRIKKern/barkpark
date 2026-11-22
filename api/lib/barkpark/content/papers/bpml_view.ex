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
  untyped block, a view that hides a key a push matches blocks by
  (`Bpml.Diff.match_keys/0`, at any depth), an empty view, a cache that holds
  text its stored blocks lack, and a view whose print does not read back as
  BPML. A refusal names its reason only; it quotes nothing stored.

  A write's answer is the view of the Paper as saved: `saved_check/3` reads
  the row back inside the write's transaction, and a refusal rolls it back.

  The pull also answers the fingerprint of its bytes (`hash/1`, sent as
  `x-bpml-view`), so a push can tell that the view changed since its pull at
  the same rev.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Envelope}
  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.PortableDoc.{BlockIds, Bpml, Projection}
  alias Barkpark.PortableDoc.Bpml.{CalloutBody, Diff, ListItems, PrintMark, WriteWall}

  # A block holding a form a fingerprint-less push may not change: only a bp
  # that sends its pull's fingerprint back can change it.
  @update_hint "update bp, then bp paper pull and make your edit again"

  @reasons %{
    ambiguous_source: "this Paper's stored HTML holds text its blocks lack",
    semantic_empty: "the reader's view of this Paper is empty",
    hidden_block_id: "the reader may not see the ids this Paper's blocks are matched by",
    scope_unresolved: "no reader schema resolves for this Paper's dataset, workspace and project",
    unreadable_print: "the reader's view of this Paper does not read back as BPML",
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
  for the schema and label reads: it writes nothing. A Paper whose scope and
  dataset resolve no `paper` schema, not even the global one (a dataset
  outside the seeded one with none registered), has no view
  (`scope_unresolved`).
  """
  @spec of(Document.t(), String.t(), keyword(), atom()) :: t()
  def of(%Document{} = paper, dataset, scope, perspective) do
    case Content.Papers.reader_schema(paper, "paper", dataset, scope) do
      nil -> {:error, :scope_unresolved}
      schema -> of_schema(paper, schema, dataset, scope, perspective)
    end
  end

  defp of_schema(paper, schema, dataset, scope, perspective) do
    content = paper.content || %{}
    stored = Projection.read_blocks(content)

    case Map.get(Envelope.render(paper, schema, CallerContext.anonymous()), "blocks") do
      blocks when is_list(blocks) and is_list(stored) ->
        cond do
          not Enum.all?(blocks, &typed?/1) ->
            {:error, :invalid_blocks}

          # A push matches its blocks to the stored ones by these keys; a view
          # without them cannot be pushed back without minting new blocks.
          hides_match_key?(stored, blocks) ->
            {:error, :hidden_block_id}

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

  # Redaction drops keys and keeps every list's length, so stored and shown
  # positions pair up at any depth.
  defp hides_match_key?(%{} = stored, %{} = shown) do
    Enum.any?(Diff.match_keys(), &(Map.has_key?(stored, &1) and not Map.has_key?(shown, &1))) or
      Enum.any?(shown, fn {key, value} -> hides_match_key?(Map.get(stored, key), value) end)
  end

  defp hides_match_key?(stored, shown) when is_list(stored) and is_list(shown) do
    length(stored) == length(shown) and
      stored |> Enum.zip(shown) |> Enum.any?(fn {s, v} -> hides_match_key?(s, v) end)
  end

  defp hides_match_key?(_stored, _shown), do: false

  @doc """
  `paper`'s view printed as `bp paper pull` gets it (flat route, published
  task rows): the bytes the pull, push and create answers carry, or the
  refusal (`refusal/1`) every one of them gives.
  """
  @spec print(Document.t(), String.t()) :: {:ok, String.t()} | {:refused, map()}
  def print(%Document{} = paper, dataset) do
    case of(paper, dataset, [], :published) do
      {:blocks, blocks, fields} ->
        with {:ok, bpml, _pulled} <- printed(paper, blocks, fields), do: {:ok, bpml}

      other ->
        {:refused, refusal(other)}
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
  A view `of/4` built, printed: the bytes, and the blocks they read back as,
  which is what a push of those bytes carries. Refused when the view does not
  print, or its print does not read back.
  """
  @spec printed(Document.t(), [map()], map()) :: {:ok, String.t(), [map()]} | {:refused, map()}
  def printed(%Document{} = paper, blocks, fields) do
    bpml = Bpml.print_paper(Content.Papers.bpml_paper_map(paper, blocks, fields))

    case Bpml.parse_copy(bpml) do
      {:ok, parsed} -> {:ok, bpml, parsed["blocks"] || []}
      {:error, _errors} -> {:refused, refusal({:error, :unreadable_print})}
    end
  rescue
    e in Bpml.UnprintableError -> {:refused, refusal({:unprintable, Exception.message(e)})}
  end

  @doc """
  The ops a push of `copy` (a `Bpml.parse_copy/1` paper) derives against
  `paper`, compared with the blocks the pull's text reads back as: a pushed
  block that spells as the pull printed it was not edited, so an unedited push
  derives no op whatever the view hides. A callout's body and `<kept>` lines
  follow `Bpml.CalloutBody.resolve/4` first; its notes come back with the ops.
  `Bpml.WriteWall` refuses, before that, a copy pulled from another view (its
  `bpmlView` fingerprint, 412) and a hidden label field it sets (422
  `bpml_unshown`), and after it, an id pushed twice (422 `bpml`) and blocks
  that change what the pull did not show (422 `bpml_unshown`). Between the
  two, a list item id pushed twice in one block is refused (422 `bpml`,
  `Bpml.ListItems.check_ids/2`).
  Refused, writing nothing, when the view cannot be built or printed. The
  Paper the ops leave is checked as saved (`saved_check/3`).
  """
  @spec push(Document.t(), map(), String.t()) ::
          {:ok, [map()], [String.t()]}
          | {:refused, map()}
          | {:error, :diff_verification_failed}
  def push(%Document{} = paper, %{} = copy, dataset) do
    stored = Projection.read_blocks(paper.content || %{}) || []
    copy = Map.update(copy, "blocks", [], &BlockIds.ensure_block_ids(&1 || []))

    with {:blocks, shown, fields} <- of(paper, dataset, [], :published),
         {:ok, bpml, pulled} <- printed(paper, shown, fields),
         :ok <- WriteWall.same_view(hash(bpml), copy["bpmlView"]),
         :ok <- WriteWall.check_fields(paper.content || %{}, fields, copy),
         pulled = BlockIds.ensure_block_ids(pulled),
         {:ok, pushed, notes} <- CalloutBody.resolve(stored, shown, pulled, copy),
         :ok <- ListItems.check_ids(pushed, stored),
         {:ok, target} <- wall(paper, {stored, shown, fields}, pulled, pushed, copy),
         {:ok, _blocks, ops} <- Diff.derive_target(stored, target) do
      {:ok, ops, notes}
    else
      {:error, :diff_verification_failed} = failed -> failed
      {:refused, _body} = refused -> refused
      view -> {:refused, refusal(view)}
    end
  end

  # The write wall's target. A push without its pull's fingerprint is believed
  # up to `PrintMark.believed/1`; a form the view holds past that is unshown to
  # it, so the wall reads the push against the view as the printer before
  # that form printed it, and its refusal says to update bp.
  defp wall(paper, {stored, shown, fields}, pulled, pushed, copy) do
    believed = PrintMark.believed(copy)

    with {:ok, target} <- WriteWall.target(stored, pulled, pushed) do
      if PrintMark.newer(shown, believed) == [] do
        {:ok, target}
      else
        with {:ok, _bpml, before} <- printed(paper, PrintMark.before(shown, believed), fields) do
          case WriteWall.target(stored, BlockIds.ensure_block_ids(before), pushed) do
            {:refused, %{code: "bpml_unshown"} = body} -> {:refused, %{body | hint: @update_hint}}
            other -> other
          end
        end
      end
    end
  end

  @doc """
  A pushed copy (`Bpml.parse_copy/1`) for a Paper that does not exist yet, as
  a create reads it: refused when its `<paper slug>` names another Paper, or
  when it holds a `<kept>` line (it stands for no stored block), or a list
  item id twice.
  """
  @spec create_copy(map(), String.t()) :: {:ok, map()} | {:refused, map()}
  def create_copy(%{} = copy, slug) do
    doc_slug = copy["slug"]

    if is_binary(doc_slug) and doc_slug != "" and doc_slug != slug do
      {:refused,
       %{
         code: "slug_mismatch",
         message:
           "the document says <paper slug=\"#{doc_slug}\"> but you pushed to #{slug} — " <>
             "nothing was written",
         hint:
           "the pushed path is the paper's identity; rename the file or fix the <paper slug> " <>
             "so they agree"
       }}
    else
      case Bpml.clean_copy(copy) do
        {:ok, paper} ->
          with :ok <- ListItems.check_ids(paper["blocks"] || [], []), do: {:ok, paper}

        {:error, errors} ->
          {:refused, %{code: "bpml", message: "the BPML document did not parse", errors: errors}}
      end
    end
  end

  @doc """
  A copy (`Bpml.parse_copy/1`) as the validate dry run reads it, so
  `bp paper push --check` answers what the push would: against the Paper at
  its `<paper slug>`, resolved as `push/3` resolves it; as a create reads it
  (`Bpml.clean_copy/1`) when there is no such Paper. `scope` is the ingest
  tenant rule's answer, `{:ok, {workspace_id, project_id}}`; a refused scope
  reads no Paper.
  """
  @spec check_copy(map(), String.t(), {:ok, {term(), term()}} | {:error, term()}) ::
          {:ok, map()} | {:error, list()} | {:refused, map()}
  def check_copy(%{} = copy, dataset, scope) do
    slug = copy["slug"]

    found =
      with {:ok, {ws_id, project_id}} when is_binary(slug) <- scope do
        opts = [workspace_id: ws_id, project_id: project_id]
        Content.get_paper(slug, dataset, Enum.reject(opts, &is_nil(elem(&1, 1))))
      end

    case found do
      %Document{} = paper ->
        stored = Projection.read_blocks(paper.content || %{}) || []
        copy = Map.update(copy, "blocks", [], &BlockIds.ensure_block_ids(&1 || []))

        with {:blocks, shown, fields} <- of(paper, dataset, [], :published),
             {:ok, _bpml, pulled} <- printed(paper, shown, fields),
             pulled = BlockIds.ensure_block_ids(pulled),
             {:ok, blocks, _notes} <- CalloutBody.resolve(stored, shown, pulled, copy),
             :ok <- ListItems.check_ids(blocks, stored) do
          {:ok, copy |> Map.delete("print") |> Map.put("blocks", blocks)}
        else
          {:refused, _body} = refused -> refused
          view -> {:refused, refusal(view)}
        end

      _none ->
        Bpml.clean_copy(copy)
    end
  end

  @doc """
  A push or create answer: `bpmlView`, the fingerprint of its `bpml` (the view
  as saved, which bp keeps for the next push), and `notes`, one line per
  callout whose stored body the push kept (`Bpml.CalloutBody`). No key for
  either when there is nothing to say.
  """
  @spec push_answer(map(), [String.t()]) :: map()
  def push_answer(payload, notes) do
    payload
    |> then(&if(is_binary(&1[:bpml]), do: Map.put(&1, :bpmlView, hash(&1[:bpml])), else: &1))
    |> then(&if(notes == [], do: &1, else: Map.put(&1, :notes, notes)))
  end

  @doc "The HTTP status a push refusal answers: 412 for a changed view, 422 otherwise."
  @spec status(map()) :: :precondition_failed | :unprocessable_entity
  def status(%{code: "precondition_failed"}), do: :precondition_failed
  def status(_refusal), do: :unprocessable_entity

  @doc """
  The `before_commit` check a write runs inside its transaction, handed the
  row the write saved. It reads that row back by the row's own slug, dataset,
  workspace and project, and prints its view (`print/2`, whose schema is
  resolved from the read row's own workspace and project). Nothing comes from
  the request. The bytes go to the calling process as `{ref, bpml}` (the
  write's answer); a refusal is `{:error, {:view_refused, body}}`, and the
  write rolls back.
  """
  @spec saved_check(reference()) :: (Document.t() -> :ok | {:error, term()})
  def saved_check(ref) when is_reference(ref) do
    fn %Document{} = row ->
      scope =
        Enum.reject(
          [workspace_id: row.workspace_id, project_id: row.project_id],
          &is_nil(elem(&1, 1))
        )

      case Content.get_paper(row.doc_id, row.dataset, scope) do
        %Document{} = saved -> answer(ref, print(saved, saved.dataset))
        nil -> {:error, {:view_refused, refusal({:error, :not_found})}}
      end
    end
  end

  defp answer(ref, {:ok, bpml}) do
    send(self(), {ref, bpml})
    :ok
  end

  defp answer(_ref, {:refused, body}), do: {:error, {:view_refused, body}}

  @doc "The bytes `saved_check/3` printed for `ref`; nil when no check ran."
  @spec checked(reference()) :: String.t() | nil
  def checked(ref) do
    receive do
      {^ref, bpml} -> bpml
    after
      0 -> nil
    end
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
        @reasons[reason] || "the reader's view of this Paper cannot be built",
        to_string(reason)
      )

  @doc """
  The error the JSON source read gives when the reader source refuses: the
  code `refusal/1` would give, worded for a read rather than a text pull. It
  names the reason only and quotes nothing stored.
  """
  @spec read_refusal(atom()) :: map()
  def read_refusal(reason) when is_atom(reason) do
    %{
      code: to_string(reason),
      message:
        (@reasons[reason] || "the reader's source of this Paper cannot be built") <>
          ", so its blocks cannot be read",
      hint: "nothing was written; this read answers the same until the Paper changes"
    }
  end

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
