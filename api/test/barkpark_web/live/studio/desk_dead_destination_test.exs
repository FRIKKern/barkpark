defmodule BarkparkWeb.Studio.DeskDeadDestinationTest do
  @moduledoc """
  spd-w18-bl-select-detects-dead-destination — a desk row whose DESTINATION
  raises must not look like a no-op.

  The seam, verbatim from the row: `Handlers.Scope.select/2` only assigns
  `focus_pane_idx` and `push_patch`es. `push_patch/2` is fire-and-forget — it
  returns a socket, never a verdict — so when the destination raised, the
  LiveView process died, the patch was never acknowledged, the client silently
  re-mounted the OLD url, and the click produced NO url change, NO aria-current
  move and NO message. Measured live: 8s of nothing on the deployed build while
  `/studio/rest` returned 500 (spd-w18-nil-icon-500 closed that particular 500;
  the SEAM is what this pins).

  THE FAULT INJECTION is the real-world shape, not a test hook: a desk row's
  destination raises because the DATA behind it is a shape the code does not
  expect. `schema_definitions.fields` is written to the JSON string
  `"not-a-list"` straight through SQL (bypassing the changeset, exactly as a
  corrupt/hand-edited row would arrive), so opening a document of that type
  raises while `handle_params/3` builds the destination — the same family that
  produced the nil-icon 500.

  RED before the fix: `render_click` on the row EXITS (the LiveView process
  crashes) and nothing is rendered. GREEN after: the failure is a named state —
  a flash naming the row the user clicked — and the desk does NOT claim to have
  opened the document (no aria-current on the dead row).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "dead-dest-ws"
  @proj_slug "dead-dest-proj"
  @dataset "dead-dest-ds"
  @doc_title "Ada Lovelace"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "DeadDestWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "DeadDestProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "DeadDest"})

    raw = "dead-dest-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "dead-dest", "production", ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, doc} =
      Content.create_document(
        "author",
        %{"title" => @doc_title, "status" => "published"},
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, doc: doc}
  end

  # Corrupt the type's schema row so BUILDING THE DESTINATION raises. Written
  # through raw SQL on purpose: the changeset would refuse it, and the point is
  # a row that is already wrong by the time Studio reads it.
  defp break_the_destination! do
    %{num_rows: 1} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE schema_definitions SET fields = $1::jsonb WHERE name = 'author' AND dataset = $2",
        [Jason.encode!("not-a-list"), @dataset]
      )
  end

  # The row's CLICKABLE tag as rendered (`pane_doc_item`'s `.bp-doc-row-body`,
  # which carries `aria-current="true"` when the pane says the document is
  # open), so "does the desk claim this opened?" is asked of the actual markup
  # and not of a guessed attribute order. Returns nil when the row is gone — the
  # caller asserts presence first, so an absent row can never pass as "not
  # current".
  defp doc_row_tag(html, doc_id) do
    case Regex.run(~r/<button[^>]*phx-value-id="#{Regex.escape(doc_id)}"[^>]*>/, html) do
      [tag] -> tag
      _ -> nil
    end
  end

  # The list row is keyed by the PUBLISHED doc id; a draft's `doc_id` carries a
  # "drafts." prefix that never reaches the DOM.
  defp row_id(doc), do: String.replace_prefix(doc.doc_id, "drafts.", "")

  defp studio_path(suffix),
    do: "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio" <> suffix

  test "a desk row whose destination raises renders a NAMED failure, not silence",
       %{conn: conn, doc: doc} do
    {:ok, view, html} = live(conn, studio_path("/author"))

    # The row is there and is not selected yet — the click below is a real one.
    assert html =~ @doc_title
    assert tag = doc_row_tag(html, row_id(doc))
    refute tag =~ "aria-current"
    assert html =~ ~s(data-reason="nothing_selected")

    break_the_destination!()

    after_click = view |> element("#doc-#{row_id(doc)} .bp-doc-row-body") |> render_click()

    # THE NAMED STATE. Both halves of the failing shape are refuted here: there
    # IS a message, and it NAMES the row that failed. Asserted on the FLASH
    # element itself — the title also appears in the row, so a bare `=~ title`
    # over the page would pass with no notice at all.
    assert [_] =
             Regex.run(
               ~r/<div class="flash flash-error"[^>]*>\s*Could not open \x{201C}#{Regex.escape(@doc_title)}\x{201D}/u,
               after_click
             )

    # …and the desk does not pretend the document opened: the dead row is still
    # rendered and wears NO aria-current, so what the surface claims matches
    # what actually loaded.
    assert after_tag = doc_row_tag(after_click, row_id(doc))
    refute after_tag =~ "aria-current"
    assert after_click =~ ~s(data-reason="nothing_selected")
  end

  test "a desk row whose destination is HEALTHY still opens it (the rescue swallows nothing)",
       %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, studio_path("/author"))

    after_click = view |> element("#doc-#{row_id(doc)} .bp-doc-row-body") |> render_click()

    refute after_click =~ "Could not open"
    assert tag = doc_row_tag(after_click, row_id(doc))
    assert tag =~ ~s(aria-current="true")
  end
end
