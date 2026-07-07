defmodule BarkparkWeb.GithubStatusControllerTest do
  @moduledoc """
  Wave 6 — the status controller's param read + read-only health passthrough.

  Drives the controller ACTION directly and injects the Health snapshot through
  the documented seam (`config :barkpark, :github_status_fun`), so this test
  isolates exactly what the controller owns: read the optional `dataset` filter,
  forward it to Health, and wrap the snapshot in `{ok: true, health: …}` at 200.
  The real Health module (Postgres + Oban queue reads) is exercised by its own
  test. The controller NEVER mutates — a read-only endpoint.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.GithubStatusController

  setup do
    on_exit(fn -> Application.delete_env(:barkpark, :github_status_fun) end)
    :ok
  end

  # Inject a stub Health snapshot that records the dataset filter it was called
  # with and returns `snapshot`.
  defp stub_status(snapshot) do
    test = self()

    Application.put_env(:barkpark, :github_status_fun, fn dataset ->
      send(test, {:status_called, dataset})
      snapshot
    end)
  end

  defp status(params) do
    build_conn() |> GithubStatusController.status(params)
  end

  describe "read-only health snapshot" do
    test "wraps the snapshot in {ok, health} at 200" do
      snapshot = %{
        "conflicts" => %{"out_of_band_edit" => 2, "detached" => 1},
        "cursor_lag" => %{"production" => 5},
        "queue_depth" => 3
      }

      stub_status(snapshot)

      conn = status(%{})

      assert %{"ok" => true, "health" => ^snapshot} = json_response(conn, 200)
      # No filter given → dataset forwarded as nil (whole-fleet view).
      assert_received {:status_called, nil}
    end

    test "forwards the ?dataset= filter to the health snapshot" do
      stub_status(%{"queue_depth" => 0})

      conn = status(%{"dataset" => "staging"})

      assert json_response(conn, 200)
      assert_received {:status_called, "staging"}
    end

    test "coerces a blank ?dataset= to nil (whole-fleet view)" do
      stub_status(%{"queue_depth" => 0})

      conn = status(%{"dataset" => "   "})

      assert json_response(conn, 200)
      assert_received {:status_called, nil}
    end

    test "answers 200 with an empty snapshot when the plugin is dark" do
      # A dark plugin still answers — an operator can always ask "is anything
      # wired?" and get a truthful (possibly empty) health map.
      stub_status(%{})

      conn = status(%{})

      assert %{"ok" => true, "health" => %{}} = json_response(conn, 200)
    end
  end
end
