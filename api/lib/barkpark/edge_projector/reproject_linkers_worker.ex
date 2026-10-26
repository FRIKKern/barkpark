defmodule Barkpark.EdgeProjector.ReprojectLinkersWorker do
  @moduledoc """
  Re-projects the documents that link to a target whose published row was just
  BORN (task-4ec7e38d85c07ab7; design: /papers/projector-inbound-edges-fix).

  When a target is unpublished or deleted, every `content_edges` row pointing
  at it goes (the `to_id` foreign key is `on_delete: :delete_all`, and
  `Projector.delete_record/2` drops inbound rows too). Publishing it again
  writes a NEW published row with a new pk, and `upsert_record/2` re-projects
  only the target's own outbound edges, so the linkers' edges stayed missing
  until each linker was saved again. A link written while the target was
  absent was lost the same way: `add_edges/2` cannot store an edge to a
  missing row.

  `EdgeProjector.Lifecycle` enqueues this job on `:after_publish` when the
  hook payload's `published_doc` is nil (first publish, re-publish after an
  unpublish, re-create after a delete). A publish over an existing published
  row keeps its pk and its inbound edges, so it enqueues nothing.

  ## Finding the linkers

  Live content, not `content_edges`, so a link written while the target was
  absent is found too. Published rows only (the projector skips drafts), in
  the target's own dataset, dataset_id, workspace and project. Two queries per
  page, so the indexed arms never fall back to a scan because of the third:

    * reference fields (`reference` and `arrayOf`, any schema in the dataset)
      holding the id bare or as `{_ref}`: `content @> …`, served by
      `documents_content_path_idx`; and a `_ref` anywhere, served by
      `documents_content_refs_idx` (the same expression, word for word);
    * richText wikilinks naming the id by `docId` or `target`, limited to the
      types that declare a richText field. The expression is the one
      /papers/references-body-links-design proposes for an index; until that
      index exists Postgres evaluates it per row of those types.

  Each linker is re-projected with `Projector.upsert_record/2`, which re-runs
  every extractor (core and plugin), so plugin kinds come back too.

  ## Bounded

  A page is at most `@page` linkers (`config :barkpark, #{inspect(__MODULE__)},
  page:` overrides it). More than a page enqueues a continuation keyed by the last
  pk handled. Runs on its own `:edge_linkers` queue (concurrency 1), unique per
  (target, type, dataset, scope, cursor), scheduled `@delay_seconds` out so
  the target's debounced unpublish/delete job (5 s) runs first.
  """
  use Oban.Worker,
    queue: :edge_linkers,
    max_attempts: 5,
    unique: [
      keys: [:_id, :type, :dataset, :workspace_id, :project_id, :after],
      states: [:available, :scheduled, :executing],
      period: 60
    ]

  require Logger
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.EdgeProjector.{Projector, ProjectorWorker}
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @page 200
  @delay_seconds 10

  # The `_ref` arm repeats `documents_content_refs_idx`'s expression.
  @refs_expr "jsonb_path_query_array(?, 'strict $.** \\? (exists(@._ref))._ref') \\?| ?"
  @wikilinks_expr "jsonb_path_query_array(?, 'strict $.** \\? (@.type == \"wikilink\").keyvalue() \\? (@.key == \"docId\" || @.key == \"target\").value') \\?| ?"

  @doc """
  Enqueue the re-projection for a target whose published row was just born.
  `doc` is the published row (`%Document{}`); returns `:ok` either way, since a
  failed enqueue must never fail the publish that fired it.
  """
  @spec enqueue(map()) :: :ok
  def enqueue(%Document{doc_id: doc_id, type: type, dataset: dataset} = doc)
      when is_binary(doc_id) and is_binary(type) and is_binary(dataset) do
    %{
      "_id" => DraftId.published_id(doc_id),
      "type" => type,
      "dataset" => dataset,
      "dataset_id" => doc.dataset_id,
      "workspace_id" => doc.workspace_id,
      "project_id" => doc.project_id
    }
    |> new(schedule_in: @delay_seconds)
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("EdgeProjector.ReprojectLinkersWorker: enqueue failed: #{inspect(reason)}")
        :ok
    end
  end

  def enqueue(_doc), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"_id" => id, "dataset" => dataset} = args})
      when is_binary(id) and is_binary(dataset) do
    page = Application.get_env(:barkpark, __MODULE__, []) |> Keyword.get(:page, @page)
    after_pk = Map.get(args, "after")
    schemas = Content.list_schemas(dataset, schema_opts(args))
    ids = [id, DraftId.draft_id(id)]

    {linkers, continue_after} =
      [
        reference_arm(args, schemas, ids, after_pk, page),
        wikilink_arm(args, schemas, ids, after_pk, page)
      ]
      |> merge_pages(page)

    project_opts = project_opts(args)

    Enum.each(linkers, fn doc ->
      {:ok, _} = Projector.upsert_record(ProjectorWorker.hydrate_task_edges(doc), project_opts)
    end)

    Logger.info(
      "EdgeProjector.ReprojectLinkersWorker: re-projected #{length(linkers)} linker(s) of " <>
        "#{id} in #{dataset}#{if continue_after, do: " (continuing)", else: ""}"
    )

    if continue_after,
      do: args |> Map.put("after", continue_after) |> new() |> Oban.insert()

    :ok
  end

  def perform(_job), do: {:cancel, :bad_args}

  # Each arm reads up to `page + 1` published linkers past the cursor, by pk.
  # An arm that returned the extra row has more behind it, so only pks up to
  # the smallest `page`-th pk of those arms are handled now and the
  # continuation starts after it. Exactly `page` linkers continue nowhere.
  defp merge_pages(arms, page) do
    cutoff =
      arms
      |> Enum.filter(&(length(&1) > page))
      |> Enum.map(&Enum.at(&1, page - 1).id)
      |> Enum.min(fn -> nil end)

    linkers =
      arms
      |> Enum.map(&Enum.take(&1, page))
      |> List.flatten()
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(is_nil(cutoff) or &1.id <= cutoff))
      |> Enum.sort_by(& &1.id)

    {linkers, cutoff}
  end

  defp reference_arm(args, schemas, ids, after_pk, page) do
    paths =
      for %{fields: fields} <- schemas,
          %{"name" => name, "type" => kind} when kind in ["reference", "arrayOf"] <- fields || [],
          is_binary(name),
          id <- ids,
          path <- [
            %{name => id},
            %{name => %{"_ref" => id}},
            %{name => [id]},
            %{name => [%{"_ref" => id}]}
          ],
          uniq: true,
          do: path

    linked =
      Enum.reduce(
        paths,
        dynamic([d], fragment(@refs_expr, d.content, ^ids)),
        fn path, acc -> dynamic([d], ^acc or fragment("? @> ?", d.content, type(^path, :map))) end
      )

    args
    |> linker_query(ids, after_pk, page)
    |> where(^linked)
    |> Repo.all()
  end

  defp wikilink_arm(args, schemas, ids, after_pk, page) do
    case for(
           %{name: t, fields: f} <- schemas,
           Enum.any?(f || [], &(&1["type"] == "richText")),
           do: t
         ) do
      [] ->
        []

      types ->
        args
        |> linker_query(ids, after_pk, page)
        |> where([d], d.type in ^types and fragment(@wikilinks_expr, d.content, ^ids))
        |> Repo.all()
    end
  end

  defp linker_query(args, ids, after_pk, page) do
    from(d in Document,
      where:
        d.dataset == ^args["dataset"] and d.doc_id not in ^ids and
          not like(d.doc_id, "drafts.%") and
          fragment(
            "? IS NOT DISTINCT FROM ?",
            d.dataset_id,
            type(^args["dataset_id"], :binary_id)
          ) and
          fragment(
            "? IS NOT DISTINCT FROM ?",
            d.workspace_id,
            type(^args["workspace_id"], :binary_id)
          ) and
          fragment(
            "? IS NOT DISTINCT FROM ?",
            d.project_id,
            type(^args["project_id"], :binary_id)
          ),
      order_by: [asc: d.id],
      limit: ^(page + 1)
    )
    |> then(fn q ->
      if after_pk, do: where(q, [d], d.id > type(^after_pk, :binary_id)), else: q
    end)
  end

  defp schema_opts(args) do
    []
    |> maybe_put(:workspace_id, args["workspace_id"])
    |> maybe_put(:project_id, args["project_id"])
  end

  # The same scope `Lifecycle.upsert_now/3` projects a published row with.
  defp project_opts(args) do
    ws = args["workspace_id"]

    [dataset: args["dataset"]]
    |> maybe_put(:workspace_id, ws)
    |> maybe_put(:project_id, args["project_id"])
    |> maybe_put(:require_workspace, if(is_nil(ws), do: Tenancy.multi_tenant?(), else: false))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
