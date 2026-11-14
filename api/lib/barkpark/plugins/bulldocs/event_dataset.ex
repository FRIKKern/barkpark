defmodule Barkpark.Plugins.Bulldocs.EventDataset do
  @moduledoc """
  Which dataset a `paper_events` row belongs to, for a dataset-bound token
  (task-ad7114cdcb1200b9).

  A paper event carries no dataset of its own: new rows are written with a
  NULL `dataset_id`. It follows its paper, so the dataset is read from the
  paper documents (published or draft) that carry the event's `paper_slug` in
  the event's own workspace and project.

  `within/2` keeps an event only when every such paper is in the given
  dataset. An event with no paper slug, with no paper left, or whose slug
  exists in another dataset of the same workspace and project as well, has no
  single dataset and is not kept: a bound token is held to its dataset, so an
  event that cannot be placed there is not shown to it.
  """

  import Ecto.Query

  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Plugins.Bulldocs.Event
  alias Barkpark.Repo

  @doc "The events of `events` that belong to `dataset` alone. One query."
  @spec within([%Event{}], String.t()) :: [%Event{}]
  def within([], _dataset), do: []

  def within(events, dataset) when is_list(events) and is_binary(dataset) do
    papers = papers_for(events)
    Enum.filter(events, &(datasets_of(&1, papers) == [dataset]))
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
