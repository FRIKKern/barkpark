defmodule BarkparkWeb.GithubAdoptControllerTest do
  @moduledoc """
  Wave 4 — the adopt controller's param read + status mapping.

  Drives the controller ACTION directly and injects the Adopt call through the
  documented seam (`config :barkpark, :github_adopt_fun`), so this test isolates
  exactly what the controller owns: read `:id` + `dataset`, forward to Adopt,
  and map its result to an honest status (200 / 404 / 409 / 422). The full
  router→token→Adopt→ledger path is exercised by the Adopt service test + the
  plugin manifest test.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.GithubAdoptController

  setup do
    on_exit(fn -> Application.delete_env(:barkpark, :github_adopt_fun) end)
    :ok
  end

  # Inject a stub Adopt that records its call and returns `result`.
  defp stub_adopt(result) do
    test = self()

    Application.put_env(:barkpark, :github_adopt_fun, fn id, dataset, opts ->
      send(test, {:adopt_called, id, dataset, opts})
      result
    end)
  end

  defp adopt(params, conn \\ build_conn()) do
    GithubAdoptController.adopt(conn, params)
  end

  describe "status mapping" do
    test "adopted → 200 {ok, task, state}" do
      stub_adopt({:ok, %{doc_id: "gh-42"}})

      conn = adopt(%{"id" => "gh-42", "dataset" => "production"})

      assert %{"ok" => true, "task" => "gh-42", "state" => "adopted"} = json_response(conn, 200)
      # The controller threads ScopeHelpers.scope_opts(conn) (D15), not a
      # hardcoded []. A flat/unscoped conn carries no workspace/project assigns,
      # so the scope keys are absent (nil-safe → seeded-Default at the service).
      assert_received {:adopt_called, "gh-42", "production", opts}
      assert Keyword.get(opts, :workspace_id) == nil
      assert Keyword.get(opts, :project_id) == nil
    end

    test "defaults the dataset to production when absent" do
      stub_adopt({:ok, %{}})

      conn = adopt(%{"id" => "gh-7"})

      assert json_response(conn, 200)
      assert_received {:adopt_called, "gh-7", "production", _opts}
    end

    test "threads the resolved tenant scope into the adopt seam (D15)" do
      stub_adopt({:ok, %{doc_id: "gh-99"}})

      # Simulate the scoped /w/:ws/p/:proj mirror: the ResolveWorkspace /
      # ResolveProject plugs have set the resolved workspace/project assigns.
      # `scope_opts/1` must lift them into the Adopt call so a non-default-tenant
      # intake is loaded and written under its OWN scope.
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_workspace, %{id: "ws-abc"})
        |> Plug.Conn.assign(:current_project, %{id: "proj-xyz"})

      _conn = adopt(%{"id" => "gh-99", "dataset" => "production"}, conn)

      assert_received {:adopt_called, "gh-99", "production", opts}
      assert Keyword.get(opts, :workspace_id) == "ws-abc"
      assert Keyword.get(opts, :project_id) == "proj-xyz"
    end

    test "not_intake → 409" do
      stub_adopt({:error, :not_intake})

      conn = adopt(%{"id" => "gh-9"})

      assert %{"error" => %{"code" => "not_intake"}} = json_response(conn, 409)
    end

    test "not_found → 404" do
      stub_adopt({:error, :not_found})

      conn = adopt(%{"id" => "gh-nope"})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "any other error → 422" do
      stub_adopt({:error, :boom})

      conn = adopt(%{"id" => "gh-5"})

      assert %{"error" => %{"code" => "adopt_failed"}} = json_response(conn, 422)
    end
  end
end
