defmodule BarkparkWeb.Studio.PdsW43GrantGradeDocEscalationTest do
  @moduledoc """
  pds-w43 — IS THE DOC-SCOPED WRITE ESCALATION STILL OPEN ON THE PAPER COMPONENT
  ROUTE FOR A `{:grant, ctx}` SOCKET? Answered BY RUN, in both directions.

  ## The hypothesis, restated

  `Access.admits_desk?/3` puts the GRANT'S OWN `type` and `doc_id` into the
  scope it validates, so a grant naming ONE doc self-satisfies at desk
  granularity and `Caps.derive/1` reports `write: true` for a grant-graded
  socket editing ANY doc on that desk. The EVENT route is contained by the
  per-event `Access.validate/3` narrowing `LiveScope.attach_write_gate/2`
  attaches. The paper COMPONENT route is not an event: `inner-change` →
  `send(self(), {:paper_op, op})` → `handle_info` → `Shared.Paper.paper_pane_op/2`.
  If that seam's only guard were `Caps.write_capable?/2` — which takes no target
  — a doc-scoped write grant would write a DIFFERENT paper on the same desk.

  ## VERDICT: the premise HOLDS, the escalation is REFUTED on this route

  Every clause of the premise is proven here by run, not conceded: the
  desk-level predicate DOES auto-satisfy, `Caps.write_capable?/2` DOES answer
  true on the second doc, and the target-aware predicate DISAGREES with both.
  The write is nevertheless refused, and the refusing check is named:
  `Shared.Paper.grant_target_denied?/3` → `grant_admits_target?/3` →
  `Access.validate/3` on the TARGET doc's own type + doc_id. That door is the
  merged pds-w44 remedy; this file is its adversarial re-derivation from the
  w43 hypothesis, arriving at the door from the escalation side.

  ## WHY THE w43 ATTEMPT WAS INCONCLUSIVE, AND WHY THIS ONE IS NOT

  The earlier attempt did not reproduce because `scope_to_grants/3` read
  narrowing HID the target doc: the write was a no-op for want of a loaded
  pane, which is INCONCLUSIVE, not safe. The fixture here gives the grantee a
  PROJECT-scoped READ grant beside the DOC-scoped WRITE grant, and READ REACH IS
  ASSERTED BEFORE EVERY PROBE — the pane carries the second doc and its editor
  component is in the DOM. A "stored bytes unchanged" here cannot be the
  no-op the earlier run mistook for containment.

  ## BOTH SEAMS THE ROW NAMES, AND WHO REFUSES AT EACH

  `paper_pane_op/2` (single op, `handle_info`) and `paper_ops/2` (canvas batch)
  are separate chokepoints — a batch reaches the second WITHOUT passing through
  the first. Both are driven. The batch additionally has a SECOND refuser: it is
  reached by the parent `handle_event("paper-ops", …)`, which the LiveScope hook
  DOES observe, so that route is refused before the seam is entered. The two
  refusals are told apart by `save_status`: `refuse_outside_grant/1` assigns
  "Read-only", the LiveScope halt branch touches no assign.

  ## ONE SIBLING SEAM IS NOT CLOSED — reported, not fixed here

  `Shared.do_autosave/2` (the `{:autosave_form, …}` `handle_info`) gates on
  `write_denied?/1` ALONE and never consults the target. The last case drives it
  on the very socket whose escalation the paper seams refuse and records what
  reaches the store. Its result is stated as the run found it. Any remedy is an
  `api/lib/barkpark_web/live/` change, which this task does not own.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Access, Accounts, Content}
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @block_id "fb-price"
  @orig %{"amount" => "299", "currency" => "NOK"}
  @escalated %{"amount" => "ESCALATED", "currency" => "NOK"}
  @legit %{"amount" => "LEGIT", "currency" => "NOK"}
  @granted_slug "w43esc-granted-doc"
  @other_slug "w43esc-other-doc"
  @outside_grant_flash "That action is outside your access grant's scope"
  @batch_block_id "b-w43esc-batch"
  @escalated_title "ESCALATED-BY-AUTOSAVE"

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT canvas editor, pinned — a canvas-off run renders no
    # `PaperFieldBlock`, and "the store did not change" would then pass for want
    # of a component rather than for want of authorization.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    ws = create_workspace!("w43esc-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w43esc-proj")
    seed_paper_schema!(ws, proj)

    create_paper!(ws, proj, @granted_slug)
    create_paper!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp seed_paper_schema!(ws, proj) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W43ESC"},
      %{
        "id" => @block_id,
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => @orig
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "blocks" => blocks,
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp stored_blocks(ws, proj, slug) do
    paper = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)
    get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []
  end

  # PERSISTED STATE, re-read from the store — never an assign.
  defp stored_value(ws, proj, slug) do
    ws
    |> stored_blocks(proj, slug)
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  defp stored_block_ids(ws, proj, slug) do
    ws |> stored_blocks(proj, slug) |> Enum.map(&Map.get(&1, "id"))
  end

  defp user_session(conn) do
    email = "w43esc-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # THE FIXTURE THE EARLIER ATTEMPT LACKED: read reach WIDER than write reach.
  # A project-scoped READ grant makes the second paper visible through
  # `scope_to_grants/3`; a doc-scoped WRITE grant names exactly ONE paper. That
  # gap is the whole hypothesis.
  defp grantee_session(conn, ws, proj) do
    {user, conn} = user_session(conn)

    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    write_grant =
      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset,
        type: "paper",
        doc_id: @granted_slug
      })

    {user, conn, write_grant}
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # THE ANTI-INCONCLUSIVE GUARD, and the reason this run is not the w43 one: the
  # second doc is really loaded and really editable in the DOM. Without this a
  # "stored bytes unchanged" is a no-op, not a containment.
  defp assert_read_reach!(view, slug) do
    assigns = socket_of(view).assigns
    assert assigns[:paper_doc].doc_id == slug
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    :ok
  end

  defp append_op(id) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "ESCALATED BATCH"}]
      }
    }
  end

  # THE REAL COMPONENT ROUTE — cid-targeted, exactly as the row specifies. The
  # write lands in a LATER `handle_info`; the trailing `render/1` drains it, so
  # the store is read AFTER the message, never before.
  defp inner_change(view, slug, params) do
    assert_read_reach!(view, slug)

    view
    |> with_target("#paper-fb-" <> @block_id)
    |> render_hook("inner-change", params)

    render(view)
    :ok
  end

  # The broad→narrow target the door builds for a doc, and the desk the
  # capability layer builds for the same mount.
  defp target_scope(ws, proj, slug) do
    %{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: @dataset,
      type: "paper",
      doc_id: slug
    }
  end

  defp desk_scope(ws, proj) do
    %{workspace_id: ws.id, project_id: proj.id, dataset: @dataset}
  end

  # ── 1. THE PREMISE, PROVEN — not conceded ───────────────────────────────────

  describe "the hypothesis's mechanism" do
    test "admits_desk?/3 auto-satisfies the grant's own doc_id, and write_capable?/2 says YES on the second doc",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, write_grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      assert_read_reach!(view, @other_slug)

      assigns = socket_of(view).assigns

      # THE GRADE the row specifies: a grant grade, NOT a share grade.
      refute is_nil(assigns[:caller_context])
      assert assigns[:share_access] == nil
      assert %Barkpark.Accounts.User{} = assigns[:current_user]

      # THE AUTO-SATISFACTION, read straight off the predicate: the desk carries
      # no type and no doc_id, and `admits_desk?/3` fills in the GRANT'S own
      # before validating. So a grant naming ONE doc admits the DESK.
      assert Access.admits_desk?(write_grant, :write, desk_scope(ws, proj)) == true

      # …and the capability layer inherits exactly that answer, on the doc the
      # grant does NOT name.
      caps = Caps.derive(socket_of(view))
      assert caps.write == true
      assert Caps.write_capable?(assigns, caps) == true

      # THE DISAGREEMENT THAT DECIDES THE TASK. The target-aware predicate — the
      # one that keeps the TARGET's real type and doc_id — refuses the same doc
      # the desk-level one admitted. Everything hangs on which one the seam
      # consults.
      assert Access.validate(write_grant, :write, target_scope(ws, proj, @other_slug)) !=
               :ok

      assert Access.validate(write_grant, :write, target_scope(ws, proj, @granted_slug)) ==
               :ok
    end
  end

  # ── 2. THE PROBE — the row's exact route ────────────────────────────────────

  describe "the paper COMPONENT route (inner-change → handle_info → paper_pane_op/2)" do
    test "REFUTED: stored(other) is unchanged, and the READ REACH that makes that meaningful is asserted",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      stored_before = stored_value(ws, proj, @other_slug)
      assert stored_before == @orig

      # `inner_change/3` asserts read reach FIRST — the pane holds the second
      # doc and its editor is in the DOM — so the result below cannot be the
      # INCONCLUSIVE no-op the w43 attempt hit.
      inner_change(view, @other_slug, @escalated)

      stored_after = stored_value(ws, proj, @other_slug)
      assert stored_after == @orig
      assert stored_before == stored_after

      # WHO REFUSED: `refuse_outside_grant/1`'s signature is the flash PLUS
      # `save_status: "Read-only"`; the LiveScope halt branch sets no assign.
      # This route is a `handle_info`, so it must be the seam's own door.
      assert flash_error(view) == @outside_grant_flash
      assert socket_of(view).assigns[:save_status] == "Read-only"

      # And the refusal did not spill onto the doc the grant DOES name.
      assert stored_value(ws, proj, @granted_slug) == @orig
    end
  end

  # ── 3. THE BATCH SEAM — the row's other chokepoint ──────────────────────────

  describe "the canvas BATCH seam (paper_ops/2)" do
    test "REFUTED at the seam itself: a batch aimed at the second doc leaves the store unchanged",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      assert_read_reach!(view, @other_slug)

      ids_before = stored_block_ids(ws, proj, @other_slug)
      refute @batch_block_id in ids_before

      # A batch reaches `paper_ops/2` WITHOUT passing through `paper_pane_op/2`,
      # so the seam is entered directly here — its own door is what answers.
      out = Paper.paper_ops(socket_of(view), [append_op(@batch_block_id)])

      assert stored_block_ids(ws, proj, @other_slug) == ids_before
      refute @batch_block_id in stored_block_ids(ws, proj, @other_slug)
      assert out.assigns.flash["error"] == @outside_grant_flash
      assert out.assigns.save_status == "Read-only"
    end

    test "and the parent EVENT route to the same seam is halted EARLIER, by the LiveScope hook",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      assert_read_reach!(view, @other_slug)

      baseline_status = socket_of(view).assigns[:save_status]
      refute baseline_status == "Read-only"
      ids_before = stored_block_ids(ws, proj, @other_slug)

      # "paper-ops" is a parent `handle_event`, which the
      # `:live_scope_write_scope` hook DOES observe — unlike the component
      # route. Same string, different producer, and the seam is never entered:
      # `save_status` is untouched.
      render_hook(view, "paper-ops", %{"ops" => [append_op(@batch_block_id)]})

      assert stored_block_ids(ws, proj, @other_slug) == ids_before
      assert flash_error(view) == @outside_grant_flash
      assert socket_of(view).assigns[:save_status] == baseline_status
    end
  end

  # ── 4. THE POSITIVE CONTROL — containment, not paralysis ────────────────────

  describe "the SAME grantee, WITHIN its grant" do
    test "writes through BOTH seams — so the refusals above are containment, not a dead editor",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @granted_slug)

      assert stored_value(ws, proj, @granted_slug) == @orig

      inner_change(view, @granted_slug, @legit)
      assert stored_value(ws, proj, @granted_slug) == @legit

      out = Paper.paper_ops(socket_of(view), [append_op(@batch_block_id)])
      assert @batch_block_id in stored_block_ids(ws, proj, @granted_slug)
      assert out.assigns.save_status == "Auto-saved"

      # The doc outside the grant never moved while all this succeeded.
      assert stored_value(ws, proj, @other_slug) == @orig
    end
  end

  # ── 5. THE SIBLING SEAM — reported, not remedied here ───────────────────────

  describe "Shared.do_autosave/2 — the OTHER handle_info write seam" do
    test "its only gate is target-BLIND: write_denied?/1 allows the very socket whose target no grant admits",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn, write_grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      assert_read_reach!(view, @other_slug)

      # The gate `do_autosave/2` consults, on the escalating socket…
      assert Paper.write_denied?(socket_of(view)) == false

      # …while every ACTIVE grant this user holds refuses the target.
      grants = Access.list_active_grants_for_grantee(user.id)
      assert write_grant.id in Enum.map(grants, & &1.id)

      refute Enum.any?(
               grants,
               &(Access.validate(&1, :write, target_scope(ws, proj, @other_slug)) == :ok)
             )

      # DRIVEN, not merely reasoned: the form-editor doc set to the paper the
      # grant does NOT name, exactly as a mount of that doc would leave it.
      doc = Content.get_paper(@other_slug, @dataset, workspace_id: ws.id, project_id: proj.id)

      socket =
        Phoenix.Component.assign(socket_of(view),
          editor_doc: doc,
          editor_type: "paper",
          editor_schema: nil,
          editor_form: %{}
        )

      out = Shared.do_autosave(socket, %{"title" => @escalated_title})

      # WHATEVER THIS RUN FOUND IS WHAT IS RECORDED. `save_status` distinguishes
      # the two outcomes exactly: "Saved" is `autosave_write/2` having reached
      # `Content.upsert_draft`, "Read-only" is `refuse_write_denied/1`.
      assert out.assigns.save_status == "Saved"

      # …and the escalated title is in the STORE, under the doc the grant does
      # not admit for write. This seam is NOT the one pds-w44 closed.
      saved_id = out.assigns.editor_doc.doc_id

      {:ok, persisted} =
        Content.get_document(saved_id, "paper", @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      assert {persisted.title, get_in(persisted.content, ["preview", "title"])} ==
               {@escalated_title, @escalated_title}
    end
  end
end
