defmodule BarkparkWeb.Studio.PdsW41CapsComponentGateTest do
  @moduledoc """
  pds-w41-caps-component-gate — a LiveComponent-targeted event bypasses EVERY
  socket-level `:handle_event` hook, so the Studio `Caps` deny-gate never sees
  it.

  MECHANISM (source, not prose): `Phoenix.LiveView.Channel` branches on the
  incoming payload's `"cid"` into its inner component-event path, which runs
  `Phoenix.LiveView.Lifecycle.handle_event/3` on the COMPONENT socket. The
  parent's hook list lives on the PARENT socket and is never consulted — so
  `Caps.attach/1`'s `:studio_caps_gate`, and equally `LiveScope`'s and
  `StudioChrome`'s hooks, are structurally unreachable from a `phx-target`ed
  event. A fourth `attach_hook` cannot close this; the capability has to travel
  INTO the component as a prop.

  HONEST SCOPE: this is "any principal `Caps` denies write" — a read-only
  api_token or a read-only member. NOT "anonymous", NOT "the internet": a
  principal-LESS socket is the intentionally-open public-demo posture and this
  test does not touch it. The blast radius beyond sheets (the `paper_field_block`
  and `tree_codelist_field` components) is UNMEASURED and out of scope here.

  `async: false` — sheet sessions are globally-registered processes reading
  through the SQL sandbox in shared mode, same as the sibling SheetGrid suite.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @readonly "pds-w41-readonly"
  @admin "pds-w41-admin"

  setup %{conn: conn} do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()

    # A READ-ONLY api token. `create_token` auto-memberships it on the Default
    # workspace, so it IS a member — but its permission array is ["read"], so
    # the write arm of `Caps.derive/1` is false. This is the principal the
    # disclosure is about; it is authenticated, not anonymous.
    {:ok, _} = Auth.create_token(@readonly, "pds w41 readonly", @dataset, ["read"])
    {:ok, _} = Auth.create_token(@admin, "pds w41 admin", @dataset, ["read", "write", "admin"])

    {:ok, conn: conn}
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp seed_sheet_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp create_sheet!(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "Data", "cells" => cells}]}
        },
        @dataset
      )

    doc
  end

  defp token_open!(conn, token, slug) do
    {:ok, view, html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))

    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  # The A1 cell as PERSISTED STATE would report it. A live session's memory is
  # authoritative when one exists; with no session the stored document is the
  # truth. Reading both ways is what makes the assertion falsifiable in either
  # direction — a write that starts a session is caught, and so is one that
  # never does.
  defp persisted_a1(slug) do
    cells =
      case Session.peek(slug, @dataset) do
        {:ok, content} ->
          get_in(content, ["tabs", Access.at(0), "cells"]) || %{}

        {:error, :no_session} ->
          get_in(stored_content(slug), ["tabs", Access.at(0), "cells"]) || %{}
      end

    Map.get(cells, "A1")
  end

  # The stored row for the sheet, draft-or-published — the session persists into
  # whichever one the editor is holding, so BOTH are read.
  defp stored_content(slug) do
    import Ecto.Query

    Barkpark.Content.Document
    |> where([d], d.doc_id in ^[slug, "drafts." <> slug] and d.type == "sheet")
    |> Barkpark.Repo.all()
    |> Enum.map(& &1.content)
    |> Enum.find(%{}, &is_map/1)
  end

  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"]

  # ── 1. the bypass: the SAME event, two routes, one socket ───────────────────

  describe "component-targeted events vs the socket-level Caps gate" do
    test "SAME event string: HALTED at the LiveView level, and GATED through phx-target", %{
      conn: conn
    } do
      # Classification is not the variable — `edit-commit` is unclassified, so
      # the default-DENY tier requires admin. The read-only token is not admin.
      assert Caps.classify("edit-commit") == :deny

      create_sheet!("pds-w41-bypass", %{"A1" => %{"v" => "orig"}})
      {view, target, _html} = token_open!(conn, @readonly, "pds-w41-bypass")

      # Route A — straight at the LiveView. The socket-level hook sees it and
      # halts; StudioLive has no `edit-commit` head at all, so reaching a
      # handler here would crash rather than pass silently.
      render_hook(view, "edit-commit", %{"value" => "1337", "move" => "none"})
      assert flash_error(view) == "You don't have access to do that."
      assert persisted_a1("pds-w41-bypass") == %{"v" => "orig"}

      # Route B — the SAME event string, same socket, targeted at the component.
      # The parent's hook list is never consulted on this path; only the
      # capability prop stands between this principal and persisted state.
      render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
      render_hook(target, "edit-commit", %{"value" => "1337", "move" => "none"})

      # NON-VACUOUS: the absence of the write, read back from persisted state.
      # Revert only the `write_capable={...}` prop at the SheetGrid callsite and this
      # assertion fails NAMING the persisted value — bound to a variable so the
      # failure prints `left: %{"v" => 1337}` rather than a custom message.
      after_component_event = persisted_a1("pds-w41-bypass")
      assert after_component_event == %{"v" => "orig"}
    end

    test "the whole read-side of the grid still mounts for the denied principal", %{conn: conn} do
      create_sheet!("pds-w41-read", %{"A1" => %{"v" => "orig"}})
      {_view, _target, html} = token_open!(conn, @readonly, "pds-w41-read")

      # Denied WRITE is not denied READ — the grid renders its content.
      assert html =~ "orig"
    end

    test "a second write head is gated too — `bar-commit` cannot route around it", %{conn: conn} do
      create_sheet!("pds-w41-bar", %{"A1" => %{"v" => "orig"}})
      {_view, target, _html} = token_open!(conn, @readonly, "pds-w41-bar")

      render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
      render_hook(target, "bar-commit", %{"value" => "1337", "move" => "none"})

      assert persisted_a1("pds-w41-bar") == %{"v" => "orig"}
    end
  end

  # ── 2. the guard is a CAPABILITY, not a blanket read-only ───────────────────

  describe "write-capable principals are unaffected" do
    test "an admin token still writes through the component", %{conn: conn} do
      create_sheet!("pds-w41-admin", %{"A1" => %{"v" => "orig"}})
      {view, target, _html} = token_open!(conn, @admin, "pds-w41-admin")

      render_hook(target, "cell-click", %{"ref" => "A1", "shift" => false})
      render_hook(target, "edit-commit", %{"value" => "1337", "move" => "none"})

      assert persisted_a1("pds-w41-admin") == %{"v" => 1337}
      assert render(view) =~ ~s(data-v="1337")
    end
  end
end
