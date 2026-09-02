defmodule BarkparkWeb.BulldocsPreGateBadgeTest do
  @moduledoc """
  The pre-gate badge on the LIVE public reader (`/papers/:slug`) — the surface
  the ruling's readers actually see. `pre_gate_register_test.exs` proves the
  rule through the pure render path; this proves the reader stream feeds it.

  The refused fixture is planted with a direct `Repo.insert!` because the
  write path (`upsert_paper` → the gate) refuses it — which is the whole point
  of the register: these rows predate the gate.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.PreGateRegister
  alias Barkpark.Repo

  @register_id "agent-flight-recorder-charter"
  @outsider_id "heggemsnes-act"

  @refused_table %{
    "type" => "table",
    "id" => "block-5",
    "header" => ["Moment", "What is stored"],
    "rows" => [[[%{"type" => "text", "value" => "claim"}], [%{"type" => "text", "value" => "x"}]]]
  }

  @healed_table %{
    "type" => "table",
    "id" => "block-5",
    "head" => ["Moment", "What is stored"],
    "rows" => [[[%{"type" => "text", "value" => "claim"}], [%{"type" => "text", "value" => "x"}]]]
  }

  defp blocks(table) do
    [
      %{"type" => "heading", "id" => "b1", "level" => 1, "text" => "Planted paper"},
      %{"type" => "byline", "id" => "b2", "items" => ["planted", "2026-07-17"]},
      table
    ]
  end

  defp plant!(slug, table) do
    dataset = Content.paper_default_dataset()

    %{id: ws_id} =
      Barkpark.Tenancy.get_default_workspace() ||
        flunk("no Default workspace seeded — the public reader resolves only within it")

    content =
      Barkpark.LabelFixtures.with_registered_labels(
        %{"blocks" => blocks(table), "style" => "article"},
        dataset
      )

    %Document{}
    |> Document.changeset(%{
      "doc_id" => slug,
      "type" => "paper",
      "dataset" => dataset,
      "workspace_id" => ws_id,
      "title" => "Planted #{slug}",
      "status" => "published",
      "content" => content,
      "rev" => "planted-" <> slug
    })
    |> Repo.insert!()
  end

  setup do
    assert PreGateRegister.loaded?(), "register absent — this PR lands after #15234"
    :ok
  end

  test "a register id the gate still refuses wears the badge under the byline", %{conn: conn} do
    plant!(@register_id, @refused_table)
    {:ok, view, _dead} = live(conn, "/papers/#{@register_id}")
    rendered = render(view)

    assert rendered =~ ~s(data-block-id="pre-gate-badge")
    assert rendered =~ ~s(class="bp-pregate bp-pregate--neutral bp-pregate--tucked")
    assert rendered =~ "Published before the block gate"

    # Under the byline: the badge's stream item follows the byline's.
    {byline_at, _} = :binary.match(rendered, ~s(data-block-id="b2"))
    {badge_at, _} = :binary.match(rendered, ~s(data-block-id="pre-gate-badge"))
    {table_at, _} = :binary.match(rendered, ~s(data-block-id="block-5"))
    assert byline_at < badge_at and badge_at < table_at
  end

  test "a non-register paper with the same refused blocks wears none", %{conn: conn} do
    plant!(@outsider_id, @refused_table)
    {:ok, view, _dead} = live(conn, "/papers/#{@outsider_id}")
    refute render(view) =~ "bp-pregate"
  end

  test "a healed register id wears none — no register edit needed", %{conn: conn} do
    plant!(@register_id, @healed_table)
    {:ok, view, _dead} = live(conn, "/papers/#{@register_id}")
    rendered = render(view)
    assert rendered =~ "Planted paper"
    refute rendered =~ "bp-pregate"
  end
end
