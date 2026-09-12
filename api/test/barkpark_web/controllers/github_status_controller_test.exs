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

  # Inject a stub Health snapshot that records the SCOPE FILTER it was called
  # with and returns `snapshot`. The filter is a keyword carrying `:dataset` (the
  # D18 token pin) and `:workspace_ids` (the w9 membership fence).
  defp stub_status(snapshot) do
    test = self()

    Application.put_env(:barkpark, :github_status_fun, fn filter ->
      send(test, {:status_called, filter})
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
      # No token, no param → dataset nil, and the membership fence is the EMPTY
      # list (fail-closed), never nil: `nil` is Health's "no fence" sentinel and
      # would hand a principal with no memberships the whole fleet.
      assert_received {:status_called, filter}
      assert Keyword.fetch!(filter, :dataset) == nil
      assert Keyword.fetch!(filter, :workspace_ids) == []
    end

    test "forwards the ?dataset= filter to the health snapshot" do
      stub_status(%{"queue_depth" => 0})

      conn = status(%{"dataset" => "staging"})

      assert json_response(conn, 200)
      assert_received {:status_called, filter}
      assert Keyword.fetch!(filter, :dataset) == "staging"
    end

    test "coerces a blank ?dataset= to nil (whole-fleet view)" do
      stub_status(%{"queue_depth" => 0})

      conn = status(%{"dataset" => "   "})

      assert json_response(conn, 200)
      assert_received {:status_called, filter}
      assert Keyword.fetch!(filter, :dataset) == nil
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

  # --- w9: the membership fence, end to end over a REAL bearer ----------------
  #
  # The D18 block above pins to the token's dataset STRING. That was never
  # isolation: a dataset slug is unique per project, so two workspaces both own a
  # `"production"`. These drive the real Health with a real `%ApiToken{}` whose
  # membership row exists, and prove the row belonging to the OTHER workspace —
  # same repo, same dataset string — does not come back.
  describe "workspace membership fence (w9) — real Health, real token" do
    alias Barkpark.Auth.ApiToken
    alias Barkpark.Plugins.Github.Conflicts
    alias Barkpark.Repo
    alias Barkpark.Tenancy

    setup do
      key = Barkpark.Plugins.Github
      prev = Application.get_env(:barkpark, key)
      Application.put_env(:barkpark, key, repo: "acme/repo")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, key, prev),
          else: Application.delete_env(:barkpark, key)
      end)

      :ok
    end

    defp token!(label) do
      Repo.insert!(%ApiToken{
        token_hash: "hash-#{label}-#{System.unique_integer([:positive])}",
        label: label,
        dataset: "production",
        permissions: ["read"],
        kind: "api"
      })
    end

    defp owned_workspace!(token) do
      slug = "w9-#{System.unique_integer([:positive])}"
      {:ok, ws} = Tenancy.create_workspace_with_owner(%{slug: slug, name: slug}, token)
      ws
    end

    defp record_in!(workspace_id, dataset, issue) do
      {:ok, c} =
        Conflicts.record(%{
          repo: "acme/repo",
          issue: issue,
          doc_id: "gh-#{issue}",
          dataset: dataset,
          workspace_id: workspace_id,
          kind: "detached",
          detail: %{}
        })

      c
    end

    test "a bearer in workspace A does not see workspace B's conflicts under the SAME dataset" do
      token_a = token!("a")
      token_b = token!("b")
      ws_a = owned_workspace!(token_a)
      ws_b = owned_workspace!(token_b)

      mine = record_in!(ws_a.id, "production", 9001)
      theirs = record_in!(ws_b.id, "production", 9002)

      conn =
        build_conn()
        |> Plug.Conn.assign(:api_token, token_a)
        |> GithubStatusController.status(%{})

      assert %{"ok" => true, "health" => health} = json_response(conn, 200)

      ids = Enum.map(health["conflicts"]["open"], & &1["id"])
      assert mine.id in ids
      refute theirs.id in ids
    end
  end
end
