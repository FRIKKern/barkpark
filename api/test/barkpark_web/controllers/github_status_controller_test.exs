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

  # --- D18: the effective dataset is the caller's OWN token dataset -----------
  #
  # These drive the REAL Health module (no seam stub) so the controller's
  # token-scoping constraint is proven end to end: a foreign or blank
  # `?dataset=` can never widen the read past the bearer's own dataset. On main
  # (`Health.snapshot/1` discards its arg AND the controller forwards the raw
  # param) these FAIL — the caller sees the whole fleet.
  describe "token-dataset scoping (D18) — real Health, no seam" do
    alias Barkpark.Plugins.Github.Conflicts

    setup do
      key = Barkpark.Plugins.Github
      prev = Application.get_env(:barkpark, key)
      # Pin a repo so BOTH fixtures pass the repo filter — the isolation the test
      # observes is then purely the dataset constraint, not a repo coincidence.
      Application.put_env(:barkpark, key, repo: "acme/repo")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, key, prev),
          else: Application.delete_env(:barkpark, key)
      end)

      :ok
    end

    defp record!(dataset, issue) do
      {:ok, c} =
        Conflicts.record(%{
          repo: "acme/repo",
          issue: issue,
          doc_id: "gh-#{issue}",
          dataset: dataset,
          kind: "detached",
          detail: %{}
        })

      c
    end

    defp status_with_token(token_dataset, params) do
      build_conn()
      |> Plug.Conn.assign(:api_token, %{dataset: token_dataset})
      |> GithubStatusController.status(params)
    end

    test "a token scoped to dataset A does NOT receive dataset B even with a foreign ?dataset=B" do
      record!("alpha", 1)
      record!("beta", 2)
      record!("beta", 3)

      conn = status_with_token("alpha", %{"dataset" => "beta"})

      assert %{"ok" => true, "health" => health} = json_response(conn, 200)

      # conflicts pinned to the token's OWN dataset — B's two rows are invisible
      assert health["conflicts"]["total"] == 1
      assert health["conflicts"]["detached"] == 1
      assert Enum.map(health["conflicts"]["open"], & &1["dataset"]) == ["alpha"]

      # per-dataset lag rows are the token's dataset only
      assert Enum.map(health["datasets"], & &1["dataset"]) == ["alpha"]
    end

    test "a blank ?dataset= still pins to the token's own dataset (never whole-fleet)" do
      record!("alpha", 4)
      record!("beta", 5)

      conn = status_with_token("alpha", %{"dataset" => "   "})

      assert %{"health" => health} = json_response(conn, 200)
      assert health["conflicts"]["total"] == 1
      assert Enum.map(health["conflicts"]["open"], & &1["dataset"]) == ["alpha"]
    end

    test "a token with a nil dataset pins to production, never the caller's foreign param" do
      record!("production", 10)
      record!("beta", 11)

      conn = status_with_token(nil, %{"dataset" => "beta"})

      assert %{"health" => health} = json_response(conn, 200)
      assert health["conflicts"]["total"] == 1
      assert Enum.map(health["conflicts"]["open"], & &1["dataset"]) == ["production"]
    end
  end
end
