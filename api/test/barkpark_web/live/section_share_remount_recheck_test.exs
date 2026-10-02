defmodule BarkparkWeb.Live.SectionShareRemountRecheckTest do
  @moduledoc """
  LiveView authz sweep (r4a): a REVOKED section share kept opening the scoped
  paper reader over the socket.

  `PluginScopeSession.confine_item_share/3` re-resolves an ITEM link on every
  mount, but for an anonymous SECTION share (`share_public` with no item token)
  it returned `:cont` without asking `Sharing.shared?/4` again. The signed
  session from one dead render therefore kept admitting socket mounts — a
  `live_redirect`, a reconnect, or a join replaying the session (accepted for
  about 14 days) — to any paper in that workspace/project after the owner
  removed the share.

  The fix re-checks the section share on every mount (and on the existing
  liveness tick), the same way item links are re-checked.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}

  @dataset "production"
  @first_slug "sec-recheck-first"
  @other_slug "sec-recheck-other"
  @other_body "SECTION-REVOKED-LEAK"

  setup %{conn: conn} do
    Barkpark.SharingFixtures.snapshot_shares!()

    ws = create_workspace!("sec-recheck-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "sec-recheck-proj"})

    seed_paper!(ws, proj, @first_slug, "FIRST")
    seed_paper!(ws, proj, @other_slug, @other_body)

    Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/#{@dataset}:papers:read")

    %{conn: conn, ws: ws, proj: proj}
  end

  defp seed_paper!(ws, proj, slug, body) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => slug,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => body}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )
  end

  defp paper_path(ws, proj, slug), do: "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}"

  test "after the section share is removed, the old session cannot mount another paper", ctx do
    dead = get(ctx.conn, paper_path(ctx.ws, ctx.proj, @first_slug))
    assert dead.status == 200, "fixture: the section share must grant the dead render"

    Barkpark.SharingFixtures.clear_shares!()

    # The replayed signed session joins with another paper's URL — what a
    # live_redirect, a reconnect or a hand-rolled join does. No plug runs.
    forged = %{dead | request_path: paper_path(ctx.ws, ctx.proj, @other_slug), query_string: ""}

    case live(forged) do
      {:ok, _view, html} ->
        refute html =~ @other_body,
               "a revoked section share still opened a paper over the socket"

      {:error, {:redirect, %{to: to}}} ->
        assert to =~ "/login"
    end
  end

  test "while the section share stands, the socket still reaches every paper (control)", ctx do
    dead = get(ctx.conn, paper_path(ctx.ws, ctx.proj, @first_slug))
    forged = %{dead | request_path: paper_path(ctx.ws, ctx.proj, @other_slug), query_string: ""}

    assert {:ok, _view, html} = live(forged)
    assert html =~ @other_body
  end
end
