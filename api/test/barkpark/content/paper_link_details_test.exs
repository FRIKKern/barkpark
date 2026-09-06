defmodule Barkpark.Content.PaperLinkDetailsTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Document

  @dataset "paper-link-details-test"

  test "deep-resolves published Paper metadata in one scoped document query" do
    workspace = create_workspace!()
    project = create_project!(workspace)
    other_project = create_project!(workspace)

    insert_doc!("live-paper", "Live published title", workspace.id, project.id,
      content: %{
        "description" => "Fresh published description",
        "event_type" => "release",
        "rev" => "content-rev"
      },
      rev: "row-rev"
    )

    insert_doc!("draft-paper", "Draft title", workspace.id, project.id, status: "draft")
    insert_doc!("other-project", "Other project", workspace.id, other_project.id)
    insert_doc!("wrong-type", "Not a Paper", workspace.id, project.id, type: "post")

    blocks = [
      %{
        "type" => "figure",
        "arbitrary-slot" => [
          %{
            "type" => "paper-links",
            "refs" => [
              %{"slug" => " live-paper "},
              %{slug: "live-paper"},
              "draft-paper",
              %{"slug" => "other-project"},
              %{"slug" => "wrong-type"}
            ]
          }
        ]
      }
    ]

    {details, queries} =
      capture_document_queries(fn ->
        Content.Papers.resolve_paper_link_details(blocks, @dataset,
          workspace_id: workspace.id,
          project_id: project.id,
          published_only: true,
          caller_context: %{admin?: true},
          grant_doc_ids: ["draft-paper", "other-project"]
        )
      end)

    assert Map.keys(details) == ["live-paper"]

    assert %{
             title: "Live published title",
             description: "Fresh published description",
             event_type: "release",
             rev: "content-rev",
             updated_at: updated_at
           } = details["live-paper"]

    assert is_binary(updated_at)
    assert queries == 1

    assert Content.Papers.paper_link_refs(blocks) == [
             "live-paper",
             "draft-paper",
             "other-project",
             "wrong-type"
           ]
  end

  test "fails closed unless a workspace and published-only gate are explicit" do
    block = %{"type" => "paper-links", "refs" => [%{"slug" => "target"}]}

    assert Content.Papers.resolve_paper_link_details([block], @dataset, published_only: true) ==
             %{}

    assert Content.Papers.resolve_paper_link_details([block], @dataset,
             workspace_id: Ecto.UUID.generate()
           ) == %{}
  end

  defp insert_doc!(doc_id, title, workspace_id, project_id, opts \\ []) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: Keyword.get(opts, :type, "paper"),
      dataset: @dataset,
      title: title,
      status: Keyword.get(opts, :status, "published"),
      content: Keyword.get(opts, :content, %{}),
      rev: Keyword.get(opts, :rev, Barkpark.Content.Writer.generate_rev()),
      workspace_id: workspace_id,
      project_id: project_id
    })
  end

  defp capture_document_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and String.contains?(metadata[:query] || "", ~s(FROM "documents")) do
          send(test_pid, ref)
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_queries(ref, 0)}
  end

  defp drain_queries(ref, count) do
    receive do
      ^ref -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
