defmodule BarkparkWeb.Studio.StudioLiveValuerefWritebackTest do
  @moduledoc """
  lvw-t10 — the Studio edit-through affordance is SERVER-decided, never
  client-only. Driven through a real scoped Studio mount:

    * an authorized member (write token, target in scope) opening the
      shared-value inspector gets the EXPLICIT write control + the impact
      preview ("changes N docs" — in-scope referencers only);
    * a member of ANOTHER workspace inspecting the same target gets the
      denied note and NO write control at all — and a HOSTILE push of the
      confirm event (bypassing the missing UI) mutates nothing, because the
      handler re-authorizes through `ValueWriteback.writeback/6`;
    * a hostile confirm with NO panel open is a no-op.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("vwb-ws-a")
    proj_a = create_project!(ws_a, "vwb-pa")
    ws_b = create_workspace!("vwb-ws-b")
    proj_b = create_project!(ws_b, "vwb-pb")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "vwb_metric",
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [%{"name" => "launch_delay", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      Content.create_document(
        "vwb_metric",
        %{"_id" => "vwb-canon", "title" => "Launch metrics", "launch_delay" => "14 days"},
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      Content.publish_document("vwb-canon", "vwb_metric", @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      Content.create_document(
        "vwb_metric",
        %{"_id" => "vwb-referencer", "title" => "In-scope referencing paper"},
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      Content.publish_document("vwb-referencer", "vwb_metric", @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    [ok: _] =
      Content.add_edges(
        [%{from_id: "vwb-referencer", to_id: "vwb-canon", kind: "valueref"}],
        dataset: @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    conn_a = member_conn(conn, ws_a, "vwb-member-a")
    conn_b = member_conn(conn, ws_b, "vwb-member-b")

    {:ok, conn_a: conn_a, conn_b: conn_b, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp member_conn(conn, ws, label) do
    raw = "#{label}-#{System.unique_integer([:positive])}"

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: label,
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp studio_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp canon_value(ws, proj) do
    {:ok, doc} =
      Content.get_document("vwb-canon", "vwb_metric", @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc.content["launch_delay"]
  end

  test "authorized member gets the write control + in-scope impact preview", %{
    conn_a: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, studio_url(ws_a, proj_a))

    html =
      render_hook(view, "paper-valueref-inspect", %{
        "target" => "vwb-canon",
        "field" => "launch_delay"
      })

    assert html =~ ~s(data-test-id="valueref-writeback-modal")
    assert html =~ ~s(data-test-id="valueref-writeback-form")
    assert html =~ ~s(data-test-id="valueref-writeback-confirm")
    assert html =~ "14 days"
    # In-scope impact only: the one referencer, no denied note.
    assert html =~ "In-scope referencing paper"
    refute html =~ ~s(data-test-id="valueref-writeback-denied")
  end

  test "authorized confirm writes the canonical value through the guarded path", %{
    conn_a: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, studio_url(ws_a, proj_a))

    render_hook(view, "paper-valueref-inspect", %{
      "target" => "vwb-canon",
      "field" => "launch_delay"
    })

    view
    |> element(~s([data-test-id="valueref-writeback-form"]))
    |> render_submit(%{"value" => "21 days"})

    assert canon_value(ws_a, proj_a) == "21 days"
  end

  test "cross-scope member: affordance absent AND hostile confirm mutates nothing", %{
    conn_b: conn,
    ws_a: ws_a,
    proj_a: proj_a,
    ws_b: ws_b,
    proj_b: proj_b
  } do
    {:ok, view, _html} = live(conn, studio_url(ws_b, proj_b))

    # Inspecting workspace A's canonical doc from workspace B's Studio: the
    # panel opens but carries NO write control — the affordance is disabled
    # entirely (no impact preview, no current value, no form).
    html =
      render_hook(view, "paper-valueref-inspect", %{
        "target" => "vwb-canon",
        "field" => "launch_delay"
      })

    assert html =~ ~s(data-test-id="valueref-writeback-modal")
    assert html =~ ~s(data-test-id="valueref-writeback-denied")
    refute html =~ ~s(data-test-id="valueref-writeback-form")
    refute html =~ "14 days"
    refute html =~ "In-scope referencing paper"

    # A hostile client can still PUSH the confirm event without the UI —
    # the server-side re-check refuses it and the canonical row is untouched.
    render_hook(view, "valueref-writeback-confirm", %{"value" => "0 days"})

    assert canon_value(ws_a, proj_a) == "14 days"
  end

  test "hostile confirm with no panel open is a no-op", %{
    conn_a: conn,
    ws_a: ws_a,
    proj_a: proj_a
  } do
    {:ok, view, _html} = live(conn, studio_url(ws_a, proj_a))

    render_hook(view, "valueref-writeback-confirm", %{"value" => "0 days"})

    assert canon_value(ws_a, proj_a) == "14 days"
  end
end
