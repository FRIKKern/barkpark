defmodule Barkpark.Plugins.Bulldocs.EventDataset do
  @moduledoc """
  Which dataset a `paper_events` row belongs to, for a dataset-bound token
  (task-ad7114cdcb1200b9).

  A paper event carries no dataset of its own: new rows are written with a
  NULL `dataset_id`. It follows its paper, so the dataset is read from the
  paper documents (published or draft) that carry the event's `paper_slug` in
  the event's own workspace and project.

  ## Placement

    * every such paper is in ONE dataset: the event is in that dataset;
    * no such paper (a goal-only event with no `paper_slug`, a paper that is
      gone, or an event whose project differs from its paper's): the event is
      in the paper default dataset, where an unplaced paper lives;
    * the slug exists in TWO OR MORE datasets of the same workspace and
      project: the event cannot be attributed to either, so it is in none.
      Showing it to a bound token would leak one way or the other. Only
      unbound callers see it.

  `within/2` keeps the events placed in the given dataset.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, DraftId, Papers}
  alias Barkpark.Plugins.Bulldocs.Event
  alias Barkpark.Repo

  @doc "The events of `events` placed in `dataset` (see the module doc). One query."
  @spec within([%Event{}], String.t()) :: [%Event{}]
  def within([], _dataset), do: []

  def within(events, dataset) when is_list(events) and is_binary(dataset) do
    papers = papers_for(events)
    Enum.filter(events, &(placement(&1, papers) == [dataset]))
  end

  # No paper: the paper default dataset. Two or more datasets (a twin slug):
  # the list has more than one entry and equals no single dataset, so the event
  # stays hidden from every bound token.
  defp placement(event, papers) do
    case datasets_of(event, papers) do
      [] -> [Papers.paper_default_dataset()]
      datasets -> datasets
    end
  end

  defp papers_for(events) do
    slugs = for %Event{paper_slug: slug} when is_binary(slug) <- events, uniq: true, do: slug

    doc_ids = Enum.flat_map(slugs, &[&1, DraftId.draft_id(&1)])

    from(d in Document,
      where: d.type == "paper" and d.doc_id in ^doc_ids,
      select: {d.doc_id, d.workspace_id, d.project_id, d.dataset}
    )
    |> Repo.all()
  end

  defp datasets_of(%Event{paper_slug: slug} = event, papers) when is_binary(slug) do
    for {doc_id, workspace_id, project_id, dataset} <- papers,
        DraftId.published_id(doc_id) == slug,
        workspace_id == event.workspace_id,
        project_id == event.project_id,
        uniq: true,
        do: dataset
  end

  defp datasets_of(_event, _papers), do: []
end
