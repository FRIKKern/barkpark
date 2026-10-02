defmodule Barkpark.Plugins.Github.LinkFence do
  @moduledoc """
  The pre-write fence that keeps `content.github` (the mirror link, see
  `Barkpark.Plugins.Github.Link`) a SERVER-OWNED field (r4a async authz sweep).

  The mirror jobs trust the link completely: `RetireJob` closes
  `link["repo"]#link["issue"]` when a task is deleted, and `MirrorJob` PATCHes
  (or, on unpublish, closes) `link["issue"]` in the mirror repo — both with the
  instance GitHub App's token. Nothing reserved the field, so any writer of a
  task could hand-write `content.github = %{"repo" => "victim/repo", "issue" =>
  N}` through the raw mutate door, Studio or `/v1/tasks`, and then delete or
  publish the task to make the App close or rewrite an issue it never created.

  The fence refuses a user-door write that ADDS or CHANGES the link. The
  plugin's own writers (`Link.put/4`, `Intake`, `Adopt`, `Projects` — all
  stamped `source: :github`) and replication (`:sync`) pass. Leaving the link
  untouched always passes, so an ordinary task edit is unaffected; REMOVING it
  passes too, because that can only stop a mirror, never aim one.
  """

  alias Barkpark.Plugins.Github.Link

  # The doors a person or an API client writes through. Every other source is
  # server code (the plugin itself, replication, workers).
  @user_sources [:api, :studio, :cli, "api", "studio", "cli"]

  @spec check(String.t(), map(), String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def check("task", attrs, dataset, doc_id, prev_doc, opts) when is_map(attrs) do
    source = Keyword.get(opts, :source, :api)
    new_link = incoming_link(attrs)

    cond do
      source not in @user_sources -> :ok
      is_nil(new_link) -> :ok
      new_link == Link.get(prev_doc) -> :ok
      # The first draft edit of a PUBLISHED mirrored task has no draft row yet
      # (`prev_doc` is nil), but carries the published row's link verbatim.
      new_link in twin_links(doc_id, dataset, opts) -> :ok
      true -> {:error, {:invalid_task_content, forged_link_error()}}
    end
  end

  def check(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # The link as this write would store it: nested under `content`, or as a
  # top-level key a flat envelope folds into content later.
  defp incoming_link(attrs) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    candidate =
      (is_map(content) && (Map.get(content, "github") || Map.get(content, :github))) ||
        Map.get(attrs, "github") || Map.get(attrs, :github)

    if is_map(candidate), do: stringify(candidate)
  end

  # The links already stored on this task's published and draft rows. Read only
  # when a user write carries a link that differs from `prev_doc`'s.
  defp twin_links(doc_id, dataset, opts) when is_binary(doc_id) do
    published = Barkpark.Content.published_id(doc_id)

    for id <- [published, Barkpark.Content.draft_id(published)],
        {:ok, doc} <- [Barkpark.Content.get_document(id, "task", dataset, opts)],
        link = Link.get(doc),
        is_map(link),
        do: link
  end

  defp twin_links(_doc_id, _dataset, _opts), do: []

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp forged_link_error do
    %{
      "github" => [
        "is written only by the GitHub bridge; a task write may keep or remove it, " <>
          "never add or change it"
      ]
    }
  end
end
