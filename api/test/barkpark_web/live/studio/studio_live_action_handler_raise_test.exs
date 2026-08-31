defmodule BarkparkWeb.Studio.StudioLiveActionHandlerRaiseTest do
  @moduledoc """
  Regression coverage for `wb-api-studio-action-handler-crash-guard`.

  `DocActions.dispatch_action/5` used to call a plugin-owned action handler
  with no try/rescue and no catch — unlike every sibling dispatch in this
  tree (`Plugins.Registry.ResolverChain.safe_resolver_call/4`). A raising or
  throwing handler propagated straight out of the LiveView process and killed
  the user's whole Studio session.

  A SECOND, independent bug lived in the same call chain:
  `Handlers.Schema.confirm_modal_real/1`'s inner `case` matched only
  `{:ok, _}` and `{:error, _}` — any other return (`:ok`, a bare map, `nil`)
  raised `CaseClauseError`.

  Three scenarios, each registered as a fake plugin action handler via
  `Barkpark.RegistryCase` (no production plugin is touched):

    1. a handler that `raise/1`s
    2. a handler that `throw/1`s
    3. a handler that returns a non-`{:ok,_}`/non-`{:error,_}` value

  Each drives the real `schema_action` → `confirm-modal-real` event path
  through a mounted Studio LiveView and asserts the process survives with an
  error flash, and that a `Logger.warning` naming the action is emitted —
  the failure must be visible, not merely absorbed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Plugins.Registry

  @dataset "production"

  # `Barkpark.Plugins.Registry` is a process-global singleton (same
  # constraint documented on `Barkpark.RegistryCase`, which this test can't
  # `use` directly alongside `BarkparkWeb.ConnCase` — both are
  # `ExUnit.CaseTemplate`s). Mirrors that template's setup/on_exit inline so
  # the fake plugins registered below never leak into sibling tests.
  setup do
    Application.delete_env(:barkpark, :plugins)
    Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Registry.reset()
    end)

    :ok
  end

  # Bare modules (no `plugin.json` on disk, same pattern as
  # `registry_resolver_test.exs`) — each contributes exactly one action
  # handler via the resolver form so `Plugins.Registry.collect_action_handlers/1`
  # surfaces it to `DocActions.dispatch_action/5` without touching any
  # production plugin.
  defmodule RaisingHandlerPlugin do
    def resolve_action_handlers(prev, _ctx) do
      Map.put(prev, "stub-raise", fn _doc_id, _dataset, _mode ->
        raise RuntimeError, "boom from stub-raise"
      end)
    end
  end

  defmodule ThrowingHandlerPlugin do
    def resolve_action_handlers(prev, _ctx) do
      Map.put(prev, "stub-throw", fn _doc_id, _dataset, _mode ->
        throw(:stub_throw_boom)
      end)
    end
  end

  defmodule BadReturnHandlerPlugin do
    def resolve_action_handlers(prev, _ctx) do
      Map.put(prev, "stub-bad-return", fn _doc_id, _dataset, _mode -> :ok end)
    end
  end

  defp register_stub(module, plugin_name) do
    :ok = Registry.register(module, %{"plugin_name" => plugin_name})
  end

  defp schema_with_action(action_name) do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "actions" => [
            %{
              "name" => action_name,
              "label" => "Stub action",
              "kind" => "modal",
              "modal" => %{
                "title" => "Run stub action?",
                "body" => "Confirm to run the stub action.",
                "steps" => ["dryrun", "real"]
              }
            }
          ]
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "stub-doc", "title" => "Stub", "content" => %{}},
        @dataset
      )

    :ok
  end

  defp open_confirm_modal_and_run_real(conn, action_name) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/stub-doc"))

    _html = render_click(view, "schema_action", %{"name" => action_name})
    html = render_click(view, "confirm-modal-real", %{})

    {view, html}
  end

  describe "a handler that raises" do
    setup %{conn: conn} do
      register_stub(RaisingHandlerPlugin, "stub-raise-plugin")
      schema_with_action("stub-raise")
      {:ok, conn: conn}
    end

    test "the LiveView survives, shows an error flash, and logs a warning", %{conn: conn} do
      {view, html} =
        capture_log_and_assert_warning("stub-raise", fn ->
          open_confirm_modal_and_run_real(conn, "stub-raise")
        end)

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
      assert html =~ "stub-raise failed"
    end
  end

  describe "a handler that throws" do
    setup %{conn: conn} do
      register_stub(ThrowingHandlerPlugin, "stub-throw-plugin")
      schema_with_action("stub-throw")
      {:ok, conn: conn}
    end

    test "the LiveView survives via the catch arm, not just rescue", %{conn: conn} do
      {view, html} =
        capture_log_and_assert_warning("stub-throw", fn ->
          open_confirm_modal_and_run_real(conn, "stub-throw")
        end)

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
      assert html =~ "stub-throw failed"
    end
  end

  describe "a handler that returns a non-{:ok,_}/{:error,_} value" do
    setup %{conn: conn} do
      register_stub(BadReturnHandlerPlugin, "stub-bad-return-plugin")
      schema_with_action("stub-bad-return")
      {:ok, conn: conn}
    end

    test "confirm_modal_real shows an error flash instead of CaseClauseError", %{conn: conn} do
      {view, html} = open_confirm_modal_and_run_real(conn, "stub-bad-return")

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
      assert html =~ "stub-bad-return failed"
    end
  end

  # Runs `fun` under `with_log/1` and asserts the captured log names
  # `action_name` at warning level — the crash must be visible, not merely
  # absorbed. Returns `fun`'s result.
  defp capture_log_and_assert_warning(action_name, fun) do
    {result, log} = with_log(fun)

    assert log =~ action_name
    assert log =~ "[warning]"

    result
  end
end
