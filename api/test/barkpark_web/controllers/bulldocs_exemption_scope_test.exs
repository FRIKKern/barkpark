defmodule BarkparkWeb.BulldocsExemptionScopeTest do
  @moduledoc """
  task-98206e62ba0b3168: the publish wall's legacy exemption ledger is keyed
  `(doc_id, dataset)` with no workspace. A brand-new paper in workspace B whose
  slug matched another workspace's grandfathered paper skipped the whole wall
  (no label spine, no dedup), and B's passing publish deleted the other
  workspace's exemption row. The exemption now counts only for the document it
  grandfathered, in the caller's own workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, TenancyFixtures}
  alias Barkpark.Content.Exemptions

  @dataset "production"
  @path "/v1/plugins/bulldocs/papers"

  defp blocks(text) do
    [
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  setup do
    TenancyFixtures.ensure_default_scope!()

    # Default's grandfathered legacy paper: published, then snapshotted.
    {:ok, _} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{
          "slug" => "legacy-x",
          "blocks" => blocks("Default's legacy paper, published before the wall.")
        })
      )

    LabelFixtures.exempt!(["legacy-x"], @dataset)

    ws_b = TenancyFixtures.create_workspace!()
    _proj = TenancyFixtures.create_project!(ws_b, "default")
    raw = "exempt-scope-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "ws B admin", @dataset, ["admin"], ws_b.id)
    %{token: raw}
  end

  defp ingest(token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(@path, body)
  end

  test "a new paper in workspace B is not grandfathered by Default's same-slug row", %{
    token: token
  } do
    # No description, no tags: only an exemption could let this through.
    conn =
      ingest(token, %{
        "slug" => "legacy-x",
        "title" => "Brand new in B",
        "blocks" => blocks("A brand-new paper in workspace B, written after the wall.")
      })

    assert conn.status == 422, "B's unlabeled new paper passed the wall: #{conn.resp_body}"
  end

  test "workspace B's passing publish leaves Default's exemption row in place", %{token: token} do
    conn =
      ingest(
        token,
        LabelFixtures.paper_attrs(%{
          "slug" => "legacy-x",
          "title" => "Labeled new paper in B",
          "blocks" => blocks("A labeled paper in workspace B with its own description.")
        })
      )

    assert conn.status in 200..299, "fixture: B's labeled paper must publish: #{conn.resp_body}"
    assert Exemptions.member?("legacy-x", @dataset), "B's publish cleared Default's exemption"
  end
end
