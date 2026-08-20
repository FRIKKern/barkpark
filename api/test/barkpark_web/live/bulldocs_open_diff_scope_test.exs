defmodule BarkparkWeb.BulldocsOpenDiffScopeTest do
  @moduledoc """
  Cross-tenant IDOR guard for the public bulldocs paper reader's `open-diff`
  handle_event (Wave 6 LiveView authz + render-safety sweep).

  THE LEAK (CONFIRMED, confidentiality). The reader's `open-diff` event carries
  client-supplied `from`/`to` event UUIDs. Before this fix they were passed
  straight to `Events.get_event/1` — a bare, UNSCOPED `Repo.get(Event, uuid)`
  with no workspace/project/paper filter — and the resulting `payload_html`
  was rendered into the diff modal. An anonymous socket on ANY public paper
  could therefore push a foreign workspace's event UUID over the established
  socket and read that event's payload_html. (XSS is dead here — TextDiff
  escapes every line — so this is confidentiality only.)

  THE FIX (`bulldocs_live.ex`, fail-closed). `open-diff` now requires BOTH ids
  to be members of `socket.assigns.rail_events` — the paper's OWN rail, already
  workspace-scoped at mount by `load_rail_events/1` via
  `Events.list_for_goal(goal_id, paper_scope_opts(paper))`. A foreign id is not
  on the paper's rail, so it resolves to the existing "no longer exists" flash
  and NO foreign payload renders. `reader_scope(socket)` is nil on this flat
  public surface, so rail membership — not scope threading — is the fence.

  MUTATION PROOF. Reverting the rail-membership guard (letting the foreign id
  reach `Events.get_event/1` directly) makes
  `test "a foreign event off the paper's rail cannot be diffed ..."` RED: the
  foreign payload renders into the modal and the flash never fires.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events

  @foreign_secret "FOREIGN-SECRET-PAYLOAD-42"

  defp seed_public_paper(slug, goal_id) do
    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: ~s(<section id="block-1"><h1>Rail paper</h1></section>),
          goal_id: goal_id,
          event_type: "plan-written"
        })
      )

    # Return the paper EXACTLY as the public reader resolves it, so its
    # `workspace_id` matches the workspace the rail (load_rail_events/1) is
    # scoped to at mount.
    Content.get_public_paper(slug)
  end

  defp seed_event(goal_id, slug, type, payload, workspace_id, project_id \\ nil) do
    {:ok, event} =
      Events.create_event(%{
        "goal_id" => goal_id,
        "paper_slug" => slug,
        "event_type" => type,
        "payload_html" => payload,
        "workspace_id" => workspace_id,
        "project_id" => project_id
      })

    event
  end

  describe "open-diff cross-tenant scope (Default-workspace public paper)" do
    setup do
      slug = "open-diff-scope-#{System.unique_integer([:positive])}"
      goal_id = "rail-goal-#{System.unique_integer([:positive])}"

      # upsert_paper stamps the paper (and its auto-created plan-written event)
      # with the resolved public workspace; the rail is scoped to THAT
      # workspace, so the extra rail events must carry the paper's own
      # `workspace_id` to land on the rail load_rail_events/1 builds at mount.
      paper = seed_public_paper(slug, goal_id)

      # Two events on THIS paper's own rail — stamped with the paper's OWN
      # workspace AND project so they match the rail scope
      # (paper_scope_opts/1 = [workspace_id: …, project_id: …]).
      own_a =
        seed_event(
          goal_id,
          slug,
          "snapshot-a",
          "<p>OWN-RAIL-ALPHA</p>",
          paper.workspace_id,
          paper.project_id
        )

      own_b =
        seed_event(
          goal_id,
          slug,
          "snapshot-b",
          "<p>OWN-RAIL-BETA</p>",
          paper.workspace_id,
          paper.project_id
        )

      # A foreign-workspace event on a DIFFERENT goal — never on this rail.
      foreign_ws = create_workspace!()

      foreign =
        seed_event(
          "foreign-goal-#{System.unique_integer([:positive])}",
          "foreign-plan",
          "secret-snapshot",
          "<p>#{@foreign_secret}</p>",
          foreign_ws.id
        )

      %{slug: slug, own_a: own_a, own_b: own_b, foreign: foreign}
    end

    test "a foreign event off the paper's rail cannot be diffed — no leak, flash fires",
         %{conn: conn, slug: slug, own_a: own_a, foreign: foreign} do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      # Push open-diff with one legitimate own-rail id and one FOREIGN id, over
      # the anonymous socket — exactly the IDOR probe.
      html = render_hook(view, "open-diff", %{"from" => own_a.id, "to" => foreign.id})

      # The foreign payload NEVER renders into the diff modal.
      refute html =~ @foreign_secret

      assigns = :sys.get_state(view.pid).socket.assigns
      # The modal stays closed and the diff html is never built from foreign data.
      refute assigns.diff_open
      refute (assigns.diff_html || "") =~ @foreign_secret
      # The existing "no longer exists" flash is what a foreign id resolves to.
      assert assigns.flash["error"] == "One of the selected events no longer exists."
    end

    # SYMMETRY ARM. The test above probes a foreign `to` with a legitimate `from`,
    # so it only ever exercises the `to` fence — mutation-proven: deleting ONLY the
    # `from` fence leaves that test GREEN while the `from` arm leaks again. Both
    # ids are client-supplied and independently attacker-controlled, so each fence
    # needs its own arm or half the guard can be removed silently.
    test "a foreign event as the FROM id is fenced too — the other half of the guard",
         %{conn: conn, slug: slug, own_b: own_b, foreign: foreign} do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      html = render_hook(view, "open-diff", %{"from" => foreign.id, "to" => own_b.id})

      refute html =~ @foreign_secret

      assigns = :sys.get_state(view.pid).socket.assigns
      refute assigns.diff_open
      refute (assigns.diff_html || "") =~ @foreign_secret
      assert assigns.flash["error"] == "One of the selected events no longer exists."
    end

    test "two events on the paper's own rail still diff — the modal renders both payloads",
         %{conn: conn, slug: slug, own_a: own_a, own_b: own_b} do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      html = render_hook(view, "open-diff", %{"from" => own_a.id, "to" => own_b.id})

      # Both own-rail payloads render (HTML-escaped by TextDiff, so the text
      # survives even though the tags are neutralized).
      assert html =~ "OWN-RAIL-ALPHA"
      assert html =~ "OWN-RAIL-BETA"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.diff_open
    end
  end

  describe "open-diff back-compat (NULL-workspace pre-tenancy paper)" do
    # A genuinely NULL-workspace paper is NOT reachable on the PUBLIC reader at
    # all: `get_public_paper/2` pins the seeded Default workspace and uses the
    # fail-closed `scope_to_workspace/3` (workspace-only, NULL excluded), so a
    # NULL-workspace row 404s rather than leaking onto the public surface — a
    # STRONGER protection than this rail fence. What the rail fence must not
    # break is the UNSCOPED rail branch it depends on: for a NULL-workspace
    # paper `paper_scope_opts(paper)` yields [] and `load_rail_events/1` reads
    # `Events.list_for_goal(goal_id, [])` UNSCOPED, so the paper's own
    # NULL-workspace events ARE on the rail it builds — and therefore pass the
    # membership fence (which admits exactly the rail's own ids, proven diffable
    # end-to-end by the same-rail test above).
    test "a NULL-workspace paper's own events land on its unscoped rail (fence admits them)" do
      goal_id = "null-goal-#{System.unique_integer([:positive])}"
      slug = "null-ws-plan-#{System.unique_integer([:positive])}"

      # Pre-tenancy rail events: NULL workspace_id.
      n_a = seed_event(goal_id, slug, "snap-a", "<p>NULL-RAIL-ALPHA</p>", nil)
      n_b = seed_event(goal_id, slug, "snap-b", "<p>NULL-RAIL-BETA</p>", nil)

      # The exact read load_rail_events/1 performs for a NULL-workspace paper
      # (paper_scope_opts(paper) == []). Both own ids are on the rail, so the
      # open-diff membership fence (MapSet of rail_events ids) admits them.
      rail_ids = goal_id |> Events.list_for_goal([]) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(rail_ids, n_a.id)
      assert MapSet.member?(rail_ids, n_b.id)
    end
  end
end
