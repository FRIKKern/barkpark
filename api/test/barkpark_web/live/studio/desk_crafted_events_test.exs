defmodule BarkparkWeb.Studio.DeskCraftedEventsTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 6: the desk page passes the events it does
  not own to the Studio's handlers. Sent by hand, with no document open or
  with params the page's own controls never send, they must not take the
  page down.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-crafted-#{System.unique_integer([:positive])}"
    perms = ~w(read write admin)
    {:ok, _} = Barkpark.Auth.create_token(raw, "desk-crafted", "production", perms, ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio/_desk"}
  end

  @events [
    {"select-sort", %{}},
    {"select-sort", %{"sort" => "title"}},
    {"select-sort", %{"sort" => "title", "type" => "post"}},
    {"new-document", %{}},
    {"new-document", %{"type" => "post"}},
    {"new-document", %{"type" => "no_such_type"}},
    {"desk-list-more", %{}},
    {"desk-list-more", %{"type" => "post"}},
    {"select-ref", %{}},
    {"select-ref", %{"field" => "author", "id" => "x"}},
    {"select-ref", %{"field" => "author", "value" => "x"}}
  ]

  for {{event, params}, n} <- Enum.with_index(@events) do
    @tag capture_log: true
    test "#{event} ##{n} by hand leaves the page alive", %{conn: conn, base: base} do
      for url <- [base, base <> "/post"] do
        {:ok, view, _html} = live(conn, url)
        render_async(view, 5_000)

        try do
          view
          |> element("#desk-panes")
          |> render_hook(unquote(event), unquote(Macro.escape(params)))
        catch
          :exit, _ -> :ok
        end

        assert Process.alive?(view.pid), "#{unquote(event)} on #{url}"
      end
    end
  end
end
