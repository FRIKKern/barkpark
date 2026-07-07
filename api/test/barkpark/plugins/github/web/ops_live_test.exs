defmodule Barkpark.Plugins.Github.Web.OpsLiveTest do
  @moduledoc """
  The read-only `:ops` sync-health console at `/admin/github`: it paints
  `Github.Health.snapshot/1` (per-dataset cursor/lag/pending panel + mirror
  queue depth + open conflicts grouped by kind) and exposes exactly ONE control
  — a per-row Resolve button wired to the already-built `Conflicts.resolve/1`.
  Everything else is read-only. Gated `:ops` (admin), never public/anonymous.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Github.Conflicts

  @admin_token "github-ops-admin-test-token"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "github ops admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  defp seed_conflict(kind, issue, opts \\ []) do
    {:ok, c} =
      Conflicts.record(%{
        repo: Keyword.get(opts, :repo, "FRIKKern/barkpark"),
        issue: issue,
        doc_id: Keyword.get(opts, :doc_id, "gh-#{issue}"),
        dataset: "production",
        kind: kind,
        detail: %{}
      })

    c
  end

  describe "mount + render" do
    test "paints the header, the per-dataset panel and the mirror queue panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ "GitHub Sync"
      # per-dataset panel — default dataset is "production"
      assert html =~ ~s(data-role="github-dataset")
      assert html =~ "production"
      assert html =~ "cursor"
      assert html =~ "lag"
      # mirror queue panel
      assert html =~ ~s(data-role="github-queue")
      assert html =~ "github_mirror"
    end

    test "shows the 'plugin not provisioned' banner when the bridge is dark", %{conn: conn} do
      # no GitHub creds are configured in the test env → active: false
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ ~s(data-role="github-health-inactive")
      assert html =~ "not provisioned"
    end

    test "renders the empty-state when there are zero open conflicts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ ~s(data-role="github-health-empty")
      refute html =~ ~s(data-role="github-resolve")
    end

    test "groups open conflicts by kind with counts + a Resolve button per row", %{conn: conn} do
      edit = seed_conflict("out_of_band_edit", 101)
      det = seed_conflict("detached", 102)

      {:ok, _view, html} = live(conn, "/admin/github")

      refute html =~ ~s(data-role="github-health-empty")

      # both kinds render as groups
      assert html =~ ~s(data-kind="out_of_band_edit")
      assert html =~ ~s(data-kind="detached")

      # the counts panel reflects one of each
      assert html =~ ~s(data-role="github-conflict-counts")

      # each open row carries the issue ref + a Resolve button keyed by id
      assert html =~ "FRIKKern/barkpark#101"
      assert html =~ "FRIKKern/barkpark#102"
      assert html =~ ~s(data-role="github-resolve")
      assert html =~ ~s(phx-value-id="#{edit.id}")
      assert html =~ ~s(phx-value-id="#{det.id}")
    end
  end

  describe "resolve control" do
    test "clicking Resolve clears that conflict and it drops out of the console", %{conn: conn} do
      keep = seed_conflict("out_of_band_edit", 201)
      drop = seed_conflict("detached", 202)

      {:ok, view, _html} = live(conn, "/admin/github")

      html =
        view
        |> element(~s(tr[data-conflict-id="#{drop.id}"] button[data-role="github-resolve"]))
        |> render_click()

      # the resolved row is gone; the other survives
      refute html =~ ~s(data-conflict-id="#{drop.id}")
      assert html =~ ~s(data-conflict-id="#{keep.id}")

      # and it's actually resolved in the side table
      assert Enum.map(Conflicts.list(), & &1.id) == [keep.id]
    end

    test "resolving the last conflict reveals the empty-state", %{conn: conn} do
      only = seed_conflict("dedup_refused", 301)

      {:ok, view, _html} = live(conn, "/admin/github")

      html =
        view
        |> element(~s(tr[data-conflict-id="#{only.id}"] button[data-role="github-resolve"]))
        |> render_click()

      assert html =~ ~s(data-role="github-health-empty")
      assert Conflicts.list() == []
    end
  end

  describe "gating" do
    test "an anonymous (no-token) request never reaches the console" do
      # No :ops on_mount admin gate satisfied → the LiveView must not mount for
      # an anonymous conn (redirect away, never a 200 render).
      assert {:error, {:redirect, _}} = live(build_conn(), "/admin/github")
    end
  end
end
