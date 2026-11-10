defmodule BarkparkWeb.Studio.DeskEditorDialogsTest do
  @moduledoc """
  The Studio's dialogs while its editor is hosted in the desk's last pane
  (probe editing-w7, item 3). Measured in a browser at 1440 and 500 px
  against the plain Studio; what works there (History, delete guard,
  discard, the media library: open, focus inside, Tab trapped, Escape
  returns focus) is not repeated here. Two things differ from the Studio:

    * "Network shares" leaves the desk for the plain Studio
      (`StudioChrome.chrome_event/3` lets the event through to StudioLive
      only, so DeskLive's hook falls back to a navigation).
    * A `.modal-backdrop` dialog (the object dialog, "Open another") dims
      the editor pane only: the backdrop is `position: absolute; inset: 0`
      (root.html.heex, charter D52, which assumes no positioned ancestor),
      and the desk positions the pane it renders it in (`.dk .dk-edit`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Style

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "w7d_doc_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "W7 dialog docs",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "w7d-doc-#{n}"

    {:ok, _} =
      Content.create_document(type, %{"doc_id" => id, "title" => "W7 Dialog Doc"}, @dataset)

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    studio = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, studio: studio, base: studio <> "/_desk", type: type, id: id}
  end

  defp admin(conn) do
    raw = "desk-w7-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-w7", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(view, fun, tries \\ 25) do
    settle(view)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp open_desk(c) do
    {:ok, view, _html} = live(admin(c.conn), "#{c.base}/#{c.type};#{c.id}")
    settle(view)
    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  # ── Network shares ───────────────────────────────────────────────────────

  # BROKEN IN THE DESK: "Network shares" navigates to the plain Studio
  # (`?shares=open`) and drops the chain; the Studio opens it in place.
  @tag :desk_editor_red
  test "Network shares opens its dialog over the desk and keeps the chain", c do
    view = open_desk(c)

    result = render_click(view, "shares-open", %{})

    refute match?({:error, {_kind, %{to: _}}}, result),
           "shares-open left the desk: #{inspect(result)}"

    assert has_element?(view, "#shares-modal-dialog[role=dialog]")
  end

  # Control, green: the plain Studio opens the same dialog without leaving.
  test "Network shares opens its dialog in place in the plain Studio", c do
    {:ok, view, _html} = live(admin(c.conn), "#{c.studio}/open/#{c.type}/#{c.id}")
    settle(view)

    result = render_click(view, "shares-open", %{})

    assert is_binary(result), "shares-open navigated in the Studio: #{inspect(result)}"
    assert has_element?(view, "#shares-modal-dialog[role=dialog]")
  end

  # ── a modal backdrop drawn in the desk pane ─────────────────────────────

  # The declaration block of the rule whose selector is exactly `selector`.
  defp rule(css, selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) do
      [_, body] -> body
      nil -> ""
    end
  end

  # BROKEN IN THE DESK: "Open another" (and the object dialog) dims the
  # editor pane only. Its `.modal-backdrop` is `position: absolute; inset: 0`
  # and renders inside `section.dk-edit`, which the desk positions
  # (`.dk .dk-edit { position: relative }`), so the backdrop is the pane's
  # size, not the page's (browser: [640,101,1440,856] vs [0,0,1440,900]).
  @tag :desk_editor_red
  test "a modal backdrop opened in the editor pane is not boxed in by the pane", c do
    view = open_desk(c)

    view
    |> element(~s([data-pane-editing] [data-test-id="open-secondary-picker"]))
    |> render_click()

    assert has_element?(view, "section.dk-edit .modal-backdrop #secondary-picker-dialog")

    css = Style.sheet(%{}) |> rendered_to_string()
    body = rule(css, ".dk .dk-edit")

    refute body =~ ~r/position:\s*(relative|absolute|fixed|sticky)/,
           "the desk positions the pane the Studio's backdrop is drawn in " <>
             "(.dk .dk-edit {#{String.trim(body)}}), so the backdrop covers the pane, not the page"
  end
end
