defmodule Barkpark.Content.ProposalsSeedDraftScopeTest do
  @moduledoc """
  THE proposals RAW-REPO SEAT (task-d507d3d83476b57d, ruling clause (d)).

  `Papers.Proposals.get_or_seed_draft/3` seeds a paper's `drafts.<slug>` twin
  from the published row with a raw `Document.changeset |> Repo.insert` that
  never passes `Content.Writer`, inheriting the published row's scope. Inherit
  is nil-skipping, so a nil-workspace paper seeded a nil-workspace DRAFT, which
  `Content.Scope.scope_to_workspace_including_global/3` makes readable by every
  tenant. CLASS (a): `propose_paper_blocks/5` is an agent-facing write whose
  `opts` always carry the caller's scope or principal, so the seeded draft is
  attributed through the classified door or the whole proposal is refused.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Papers, Writer}
  alias Barkpark.Content.Papers.Proposals
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  defp workspace_with_project! do
    ws = TenancyFixtures.create_workspace!()
    _ = TenancyFixtures.create_project!(ws, "default")
    ws
  end

  defp user_in!(workspaces) do
    user =
      Barkpark.AccountsFixtures.register_user(
        "prop-#{System.unique_integer([:positive])}@example.com"
      )

    for ws <- workspaces do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    end

    user
  end

  # A NIL-WORKSPACE published paper — the shape put_scope_attrs/2 never touched.
  defp nil_workspace_paper!(slug) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => slug,
      "type" => Papers.paper_type(),
      "dataset" => @dataset,
      "title" => "Proposals seat #{slug}",
      "status" => "published",
      "content" => %{
        "blocks" => [
          %{
            "id" => "intro",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Canonical prose."}]
          }
        ]
      },
      "rev" => Writer.generate_rev()
    })
    |> Repo.insert!()
  end

  defp ops(block_id) do
    [
      %{
        "op" => "append-block",
        "block" => %{
          "id" => block_id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "A proposed paragraph."}]
        }
      }
    ]
  end

  defp source(slug), do: %{"doc_id" => slug, "agent" => "agent-x"}

  test "the seeded draft carries the paper's workspace — never a NULL-workspace row" do
    ws = workspace_with_project!()
    user = user_in!([ws])

    paper = nil_workspace_paper!("prop-seat-scoped")
    src = nil_workspace_paper!("prop-seat-scoped-source")

    for doc <- [paper, src] do
      {:ok, _} = doc |> Ecto.Changeset.change(workspace_id: ws.id) |> Repo.update()
    end

    assert {:ok, _receipt} =
             Proposals.propose_paper_blocks(
               paper.doc_id,
               ops("prop-1"),
               source(src.doc_id),
               @dataset,
               workspace_id: ws.id,
               caller_context: %CallerContext{principal_type: :user, user_id: user.id}
             )

    {:ok, %Document{} = draft} =
      Content.get_document("drafts." <> paper.doc_id, Papers.paper_type(), @dataset,
        workspace_id: ws.id
      )

    assert draft.workspace_id == ws.id
    refute is_nil(draft.workspace_id)
  end

  test "the DOOR itself, at the shape this seat hands it: a nil-workspace source resolves" do
    ws = workspace_with_project!()
    user = user_in!([ws])
    paper = nil_workspace_paper!("prop-seat-door")

    assert {:ok, attrs} =
             Barkpark.Content.WriteScope.inherit_or_resolve_scope_attrs(
               %{"dataset" => @dataset},
               paper,
               caller_context: %CallerContext{principal_type: :user, user_id: user.id}
             )

    assert attrs["workspace_id"] == ws.id
  end

  test "an AMBIGUOUS principal is REFUSED by the door, not Defaulted" do
    ws_a = workspace_with_project!()
    ws_b = workspace_with_project!()
    user = user_in!([ws_a, ws_b])
    paper = nil_workspace_paper!("prop-seat-ambiguous")

    assert {:error, :workspace_scope_required} =
             Barkpark.Content.WriteScope.inherit_or_resolve_scope_attrs(
               %{"dataset" => @dataset},
               paper,
               caller_context: %CallerContext{principal_type: :user, user_id: user.id}
             )
  end

  test "REACHABILITY: a nil-workspace paper is not reachable from this seat's public entry" do
    ws = workspace_with_project!()
    user = user_in!([ws])

    paper = nil_workspace_paper!("prop-seat-unreachable")
    src = nil_workspace_paper!("prop-seat-unreachable-source")

    assert {:error, :not_found} =
             Proposals.propose_paper_blocks(
               paper.doc_id,
               ops("prop-1"),
               source(src.doc_id),
               @dataset,
               caller_context: %CallerContext{principal_type: :user, user_id: user.id}
             )

    assert {:error, :not_found} =
             Content.get_document("drafts." <> paper.doc_id, Papers.paper_type(), @dataset, [])
  end
end
