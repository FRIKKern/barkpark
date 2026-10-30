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

  ## Who can link to the target

  Before any `documents` read, the worker asks the dataset's schemas which
  types could hold a link to the target's type (`linker_plan/2`):

    * a `reference` field, or an `arrayOf` of one, at any depth, whose
      `refType`/`to` names the target's type, names no type, or is
      `refTypeTolerant`;
    * a `richText` field at any depth, since a wikilink names any document.

  No such type means nothing can link to the target, and the job ends after
  that one schema read. A catalogue import that publishes a thousand rows of a
  type nothing references costs a thousand schema reads and no table scan.

  ## Finding the linkers

  Live content, not `content_edges`, so a link written while the target was
  absent is found too. Published rows only (the projector skips drafts), in
  the target's own dataset, dataset_id, workspace and project, and only of the
  types the plan names. Two queries per page:

    * reference fields holding the id bare or as `{_ref}`: `content @> …`,
      served by `documents_content_path_idx`; and a `_ref` anywhere, served by
      `documents_content_refs_idx` (the same expression, word for word);
    * richText wikilinks naming the id by `docId` or `target`, served by
      `documents_content_wikilinks_idx` (the same expression, word for word).

  Each query matches inside a MATERIALIZED CTE and only then orders by pk and
  takes a page. The earlier form put `ORDER BY id LIMIT 201` on the match
  itself, and Postgres walked the primary key, testing every row, hoping to
  fill the page early. A new target has no linkers, so the walk covered the
  whole table and hit the 30 s `statement_timeout`; gyl ran 1621 of those back
  to back on 2026-10-30 after a catalogue import (task-86521536b09a85e6).

  Each linker is re-projected with `Projector.upsert_record/2`, which re-runs
  every extractor (core and plugin), so plugin kinds come back too.

  ## A timeout cancels

  The lookup runs under its own `statement_timeout` (`@lookup_timeout_ms`,
  `config :barkpark, #{inspect(__MODULE__)}, lookup_timeout_ms:` overrides
  it). A cancelled statement logs one warning naming the target and cancels
  the job: a retry would run the same slow statement again.

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
  @lookup_timeout_ms 10_000

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
    schemas = Content.list_schemas(dataset, schema_opts(args))

    case linker_plan(schemas, args["type"]) do
      %{ref_types: [], wikilink_types: []} -> :ok
      plan -> reproject(args, id, dataset, plan)
    end
  end

  def perform(_job), do: {:cancel, :bad_args}

  defp reproject(args, id, dataset, plan) do
    config = Application.get_env(:barkpark, __MODULE__, [])
    page = Keyword.get(config, :page, @page)
    timeout = Keyword.get(config, :lookup_timeout_ms, @lookup_timeout_ms)
    after_pk = Map.get(args, "after")
    ids = [id, DraftId.draft_id(id)]

    {:ok, {linkers, continue_after}} =
      Repo.with_statement_timeout(timeout, fn ->
        [
          reference_arm(args, plan, ids, after_pk, page),
          wikilink_arm(args, plan, ids, after_pk, page)
        ]
        |> merge_pages(page)
      end)

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
  rescue
    e in Postgrex.Error ->
      if match?(%{postgres: %{code: :query_canceled}}, e) do
        Logger.warning(
          "EdgeProjector.ReprojectLinkersWorker: linker lookup for #{id} in #{dataset} " <>
            "passed its statement_timeout; cancelled, not retried"
        )

        {:cancel, :statement_timeout}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Which schemas in `schemas` could hold a link to a document of `type`.

  Returns the top-level reference field names (`ref_fields`, for the
  `content @> …` arm), the types with such a field at any depth (`ref_types`,
  for the `_ref` arm) and the types with a `richText` field at any depth
  (`wikilink_types`). Both type lists empty means nothing can link to `type`.
  A nil `type` counts every reference field.
  """
  @spec linker_plan([map()], String.t() | nil) :: %{
          ref_fields: [String.t()],
          ref_types: [String.t()],
          wikilink_types: [String.t()]
        }
  def linker_plan(schemas, type) do
    for %{name: name, fields: fields} <- schemas,
        is_binary(name),
        reduce: %{ref_fields: [], ref_types: [], wikilink_types: []} do
      acc ->
        fields = List.wrap(fields)
        top = for %{"name" => f} = field <- fields, is_binary(f), holds_ref?(field, type), do: f
        refs? = Enum.any?(fields, &nested?(&1, fn f -> holds_ref?(f, type) end))
        rich? = Enum.any?(fields, &nested?(&1, fn f -> match?(%{"type" => "richText"}, f) end))

        %{
          ref_fields: Enum.uniq(acc.ref_fields ++ top),
          ref_types: if(refs?, do: [name | acc.ref_types], else: acc.ref_types),
          wikilink_types: if(rich?, do: [name | acc.wikilink_types], else: acc.wikilink_types)
        }
    end
  end

  # `pred` holds for `field` or for a field nested in it: an object's
  # `fields`, or an `arrayOf`'s `of` (a map, or Sanity's list of members).
  defp nested?(field, pred) when is_map(field) do
    pred.(field) or
      Enum.any?(
        List.wrap(field["fields"]) ++ List.wrap(field["of"]),
        &nested?(&1, pred)
      )
  end

  defp nested?(_field, _pred), do: false

  # A `reference`, or an `arrayOf` of one, that can point at `type`: it names
  # `type` in `refType` or `to`, names no type, or is `refTypeTolerant`.
  defp holds_ref?(%{"type" => "reference"} = field, type), do: targets?(field, type)

  defp holds_ref?(%{"type" => "arrayOf", "of" => of} = field, type) do
    Enum.any?(List.wrap(of), fn
      %{"type" => "reference"} = member ->
        field["refTypeTolerant"] == true or targets?(member, type)

      _ ->
        false
    end)
  end

  defp holds_ref?(_field, _type), do: false

  defp targets?(field, type) do
    named =
      (List.wrap(field["refType"]) ++ for(%{"type" => t} <- List.wrap(field["to"]), do: t))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    field["refTypeTolerant"] == true or named == [] or is_nil(type) or type in named
  end

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

  defp reference_arm(_args, %{ref_types: []}, _ids, _after_pk, _page), do: []

  defp reference_arm(args, %{ref_types: types, ref_fields: fields}, ids, after_pk, page) do
    paths =
      for name <- fields,
          id <- ids,
          path <- [
            %{name => id},
            %{name => %{"_ref" => id}},
            %{name => [id]},
            %{name => [%{"_ref" => id}]}
          ],
          do: path

    linked =
      Enum.reduce(
        paths,
        dynamic([d], fragment(@refs_expr, d.content, ^ids)),
        fn path, acc -> dynamic([d], ^acc or fragment("? @> ?", d.content, type(^path, :map))) end
      )

    linker_page(args, types, ids, after_pk, page, linked)
  end

  defp wikilink_arm(_args, %{wikilink_types: []}, _ids, _after_pk, _page), do: []

  defp wikilink_arm(args, %{wikilink_types: types}, ids, after_pk, page) do
    linked = dynamic([d], fragment(@wikilinks_expr, d.content, ^ids))
    linker_page(args, types, ids, after_pk, page, linked)
  end

  # The match runs in a MATERIALIZED CTE, so Postgres evaluates it on its own,
  # through the content indexes, before it orders by pk and takes a page. With
  # `ORDER BY id LIMIT` on the match itself, Postgres walked the primary key
  # and tested every row, which never ends early for a target with no linkers.
  defp linker_page(args, types, ids, after_pk, page, linked) do
    matches =
      from(d in Document,
        where:
          d.dataset == ^args["dataset"] and d.type in ^types and d.doc_id not in ^ids and
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
        where: ^linked,
        select: %{id: d.id}
      )
      |> then(fn q ->
        if after_pk, do: where(q, [d], d.id > type(^after_pk, :binary_id)), else: q
      end)

    from(m in "reproject_linker_matches",
      order_by: m.id,
      limit: ^(page + 1),
      select: type(m.id, :binary_id)
    )
    |> with_cte("reproject_linker_matches", as: ^matches, materialized: true)
    |> Repo.all()
    |> case do
      [] -> []
      pks -> Repo.all(from(d in Document, where: d.id in ^pks, order_by: [asc: d.id]))
    end
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
