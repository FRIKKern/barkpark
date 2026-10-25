defmodule BarkparkWeb.Studio.StudioConnectHandoffTest do
  @moduledoc """
  The connected Studio mount takes the panes its own dead render built,
  only when nothing they were read from has changed (task-cca3c6d48e57097e).

  Every fixture here is synthetic. The principal is an API token seated in a
  non-default workspace, which is how the gyldendal-no workspace is opened.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ConnectHandoff

  @dataset "production"

  setup %{conn: conn} do
    prior = Application.get_env(:barkpark, :studio_connect_handoff)
    Application.put_env(:barkpark, :studio_connect_handoff, true)
    on_exit(fn -> Application.put_env(:barkpark, :studio_connect_handoff, prior) end)

    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "handoff-#{suffix}", name: "Handoff"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "handoff-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "handoff", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "gadget",
          "title" => "Gadget",
          "icon" => "book",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, doc} =
      Content.create_document(
        "gadget",
        %{"doc_id" => "gadget-one", "title" => "Synthetic gadget one", "status" => "published"},
        @dataset,
        scope
      )

    me = self()
    handler = "connect-handoff-test-#{suffix}"

    :telemetry.attach(
      handler,
      [:barkpark, :studio, :connect_handoff],
      fn _event, _measure, meta, _ -> send(me, {:handoff, meta.result}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/gadget/#{doc.doc_id}"

    {:ok, conn: conn, url: url, scope: scope, ws: ws}
  end

  # The handoff process has handled every announcement sent to it so far.
  defp settle_handoff, do: :sys.get_state(ConnectHandoff)

  test "the connected mount takes the dead render's panes", %{conn: conn, url: url} do
    {:ok, view, html} = live(conn, url)

    assert_received {:handoff, :hit}
    assert html =~ ~s(value="Synthetic gadget one")
    assert render(view) =~ "Synthetic gadget one"
  end

  test "the handed-over render matches a render that read afresh", %{conn: conn, url: url} do
    {:ok, view, _html} = live(conn, url)
    assert_received {:handoff, :hit}
    with_handoff = view |> element("#editor-form") |> render()

    Application.put_env(:barkpark, :studio_connect_handoff, false)
    {:ok, view2, _html} = live(conn, url)
    without = view2 |> element("#editor-form") |> render()

    assert with_handoff == without
  end

  test "a document written between the dead render and the connect is shown", %{
    conn: conn,
    url: url,
    scope: scope
  } do
    conn = get(conn, url)
    assert html_response(conn, 200) =~ "Synthetic gadget one"

    {:ok, _} =
      Content.create_document(
        "gadget",
        %{"doc_id" => "gadget-two", "title" => "Synthetic gadget two", "status" => "published"},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "gadget",
        %{"doc_id" => "gadget-one", "title" => "Synthetic gadget renamed"},
        @dataset,
        scope
      )

    settle_handoff()
    {:ok, view, _html} = live(conn)

    assert_received {:handoff, :stale}
    html = render(view)
    assert html =~ "Synthetic gadget two"
    assert html =~ "Synthetic gadget renamed"
  end

  test "a reconnect of the same page reads afresh", %{conn: conn, url: url} do
    conn = get(conn, url)
    {:ok, _view, _html} = live(conn)
    assert_received {:handoff, :hit}

    {:ok, _view, _html} = live(conn)
    assert_received {:handoff, :none}
  end

  describe "build/4 with hand-built sockets" do
    setup %{ws: ws} do
      ctx = %CallerContext{principal_type: :api_token, token_id: Ecto.UUID.generate()}
      opts = [workspace_id: ws.id, caller_context: ctx]
      {:ok, ctx: ctx, opts: opts}
    end

    defp socket(id, ws, opts) do
      %Phoenix.LiveView.Socket{
        id: id,
        transport_pid: Keyword.get(opts, :transport_pid),
        assigns: %{__changed__: %{}, current_workspace: ws, dataset: @dataset}
      }
    end

    defp connected(id, ws), do: socket(id, ws, transport_pid: self())

    defp build_with(socket, opts, value) do
      Process.delete({ConnectHandoff, :tried})
      ConnectHandoff.build(socket, opts, {:args, opts}, fn -> value end)
    end

    test "another principal on the same socket id builds its own", %{ws: ws, opts: opts} do
      id = "phx-handoff-#{System.unique_integer([:positive])}"
      assert build_with(socket(id, ws, []), opts, :dead) == :dead

      other = %CallerContext{principal_type: :api_token, token_id: Ecto.UUID.generate()}
      other_opts = Keyword.put(opts, :caller_context, other)

      assert build_with(connected(id, ws), other_opts, :fresh) == :fresh
      assert_received {:handoff, :mismatch}
    end

    test "a caller with grants is never stored", %{ws: ws, opts: opts, ctx: ctx} do
      id = "phx-handoff-#{System.unique_integer([:positive])}"
      granted = Keyword.put(opts, :caller_context, %{ctx | grants: [%{id: "g"}]})

      assert build_with(socket(id, ws, []), granted, :dead) == :dead
      assert build_with(connected(id, ws), granted, :fresh) == :fresh
      refute_received {:handoff, _}
    end

    test "a grant-scoped or anonymous read is never stored", %{ws: ws, opts: opts} do
      for bad <- [
            Keyword.put(opts, :grant_scoped, true),
            Keyword.put(opts, :only_doc_ids, ["a"]),
            Keyword.put(opts, :caller_context, CallerContext.anonymous())
          ] do
        id = "phx-handoff-#{System.unique_integer([:positive])}"
        assert build_with(socket(id, ws, []), bad, :dead) == :dead
        assert build_with(connected(id, ws), bad, :fresh) == :fresh
      end

      refute_received {:handoff, _}
    end

    test "only the first rebuild of a connected socket may take an entry", %{ws: ws, opts: opts} do
      id = "phx-handoff-#{System.unique_integer([:positive])}"
      assert build_with(socket(id, ws, []), opts, :dead) == :dead

      Process.delete({ConnectHandoff, :tried})

      assert ConnectHandoff.build(connected(id, ws), opts, {:args, opts}, fn -> :fresh end) ==
               :dead

      # A new entry under the same id, then a second rebuild in the same
      # connected process: it is not asked for.
      assert ConnectHandoff.build(socket(id, ws, []), opts, {:args, opts}, fn -> :dead2 end) ==
               :dead2

      assert ConnectHandoff.build(connected(id, ws), opts, {:args, opts}, fn -> :fresh end) ==
               :fresh
    end

    test "off by config, nothing is stored", %{ws: ws, opts: opts} do
      Application.put_env(:barkpark, :studio_connect_handoff, false)
      id = "phx-handoff-#{System.unique_integer([:positive])}"
      assert build_with(socket(id, ws, []), opts, :dead) == :dead
      Application.put_env(:barkpark, :studio_connect_handoff, true)
      assert build_with(connected(id, ws), opts, :fresh) == :fresh
      assert_received {:handoff, :none}
    end
  end
end
