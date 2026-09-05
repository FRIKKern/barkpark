defmodule BarkparkWeb.Studio.PdsW44GrantDoorTest do
  @moduledoc """
  pds-w44-grant-door-narrowing (PDS-D644) — a DOC-SCOPED write grant used to
  write a DIFFERENT paper on the same desk, through the door a `:handle_event`
  hook cannot see.

  MECHANISM (derived from source, not transcribed). A signed-in NON-MEMBER
  holding an ACTIVE write grant that names ONE doc mounts an UNSHARED
  workspace, so `LiveScope.authorize_read/4` grades the socket `{:grant, ctx}`:
  `caller_context` is assigned, `has_write_grant?/2` is true (the grant confers
  write SOMEWHERE in the workspace, validated against its OWN scope), so
  `attach_write_gate/2` (live_scope.ex:286) sets `write_gate?: true` and
  attaches `:live_scope_write_scope` — an `attach_hook(_, :handle_event, _)`.
  That hook IS the per-target narrowing: `write_target_permitted?/4` resolves
  the event's target scope and requires `Access.validate(grant, :write, target)`
  on some grant.

  It never fires on the paper editor's component route. `PaperFieldBlock.persist/2`
  sends a `:paper_op` message to the parent, which lands
  in `StudioLive`'s `handle_INFO` → `Shared.Paper.paper_op/2` → `write_denied?/1`
  (shared/paper.ex:98-100) → `Caps.write_capable?/2`. No `handle_event` hook —
  parent socket or component socket — observes a `handle_info`, so
  `Access.validate/3` was never consulted and the door's only predicate was
  `Caps.write_capable?/2`, which takes NO doc argument and answers `true` here
  (correctly: the grant really does confer write in this workspace).

  WHY NOT WIDEN THE PREDICATE. `Caps.write_capable?/2` is shared with the
  SheetGrid capability PROP (components.ex:1787) and has no target to reason
  about. The narrowing travels into the DOOR instead: `grant_target_denied?/3`
  in `Shared.Paper`, armed ONLY when write descends from a GRANT.

  WHY NOT `Access.admits_desk?/3`. access.ex:329-336 OVERWRITES the requested
  scope's `:type`/`:doc_id` with the GRANT'S OWN before validating — that is
  precisely what lets a doc-scoped grant self-satisfy against any desk. The
  door calls `Access.validate/3` (access.ex:292) with the target doc's real
  type + doc_id.

  THE ORACLE IS STORED BYTES. Every assertion reads the persisted document back
  from the store — never a flash, never a "no session started" predicate (the
  shipped `sheets_reader_live_test.exs` uses `Session.whereis(...) == nil`,
  which is VACUOUS the moment a session exists).

  NON-VACUITY, BY SUBSTITUTION ON THE SHIPPED MODULE (pds-w45). This block once
  asserted against a TEST-LOCAL re-implementation of the pre-fix door — a private
  function in THIS file returning the literal `false` — a tautology over a
  literal, which observed no product code at all: flipping that literal reddened
  the assertion with `shared/paper.ex` byte-identical. Its only other assertion
  was a verbatim copy of test 2's oracle, so the block was one tautology plus one
  duplicate and never showed the escalation LANDING. It is now a real
  substitution: the case reads
  `shared/paper.ex` from disk, substitutes the door expression at
  `grant_target_denied?/3` out of the source, recompiles the module IN-VM, and
  asserts the escalated bytes REACH THE STORE — the hand mutation wave 44's
  reviewer ran is now reproduced by the merging artifact. `assert mutant !=
  original` is the load-bearing substitution guard: a source reformat that misses
  the target REDS instead of silently proving nothing.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}

  @dataset "production"
  @block_id "fb-price"
  @orig %{"amount" => "299", "currency" => "NOK"}
  @escalated %{"amount" => "ESCALATED", "currency" => "NOK"}
  @legit %{"amount" => "LEGIT", "currency" => "NOK"}
  @granted_slug "w44-granted-doc"
  @other_slug "w44-other-doc"
  @outside_grant_flash "That action is outside your access grant's scope"

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT canvas editor, pinned rather than inherited — the legacy
    # per-block editor needs `paper-toggle-edit`, and a grant-graded socket's
    # write gate would halt it, so a canvas-off run would render no component
    # and every "the store did not change" assertion would pass VACUOUSLY.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # An UNSHARED, NON-default workspace. Unshared so the share arm cannot
    # answer first (that grade is #9332's subject, not this one); non-default
    # because the Default workspace is an open public-demo in test.
    ws = create_workspace!("w44-grant-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w44-proj")
    seed_paper_schema!(ws, proj)

    create_paper!(ws, proj, @granted_slug)
    create_paper!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED: without a `paper` schema row in THIS workspace
  # the desk has no paper type and the editor pane never opens — the suite
  # would then assert against a pane that was not there.
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

  # A paper carrying ONE v2 `composite` field block — the block kind that
  # renders as a nested `PaperFieldBlock` LiveComponent (a canvas run BOUNDARY),
  # so this component is its editor under both canvas settings.
  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W44"},
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

  # The composite block's value as PERSISTED STATE reports it — read back from
  # the store, never from an assign, so the assertion is falsifiable both ways.
  defp stored_value(ws, proj, slug) do
    paper = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)

    blocks =
      get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  defp user_session(conn) do
    email = "w44-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # THE ESCALATING POPULATION, end to end:
  #   * a PROJECT-scoped READ grant — the READ REACH. Without it the
  #     grant-narrowed read (`Content.Scope.scope_to_grants/3`) hides the second
  #     doc, the pane never loads, and a "store unchanged" assertion would prove
  #     nothing.
  #   * a DOC-scoped WRITE grant naming exactly ONE doc — the write source that
  #     `Access.admits_desk?/3` auto-satisfies at desk granularity, so
  #     `Caps.derive/1` reports `write: true` on EVERY doc of the desk.
  defp grantee_session(conn, ws, proj) do
    {user, conn} = user_session(conn)

    bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

    bind_grant!(ws, user, %{
      capabilities: ["read", "write"],
      project_id: proj.id,
      dataset: @dataset,
      type: "paper",
      doc_id: @granted_slug
    })

    {user, conn}
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp paper_rev(view), do: socket_of(view).assigns.paper_rev
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # THE ANTI-VACUITY GUARD. `with_target/2` on an id that is not in the DOM does
  # NOT fail — the event falls through to the parent, which writes nothing, and
  # "store unchanged" then passes for the wrong reason.
  defp assert_editor_rendered!(view) do
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    :ok
  end

  # The REAL route: the phx-targeted component event, then a parent round-trip.
  # `persist/2` does `send(self(), {:paper_op, …})`, so the write happens in a
  # LATER `handle_info`; reading the store straight after `render_hook/3` reads
  # it BEFORE the message is drained and reports a false "no write".
  defp inner_change(view, params) do
    assert_editor_rendered!(view)

    target = with_target(view, "#paper-fb-" <> @block_id)
    render_hook(target, "inner-change", params)

    render_hook(target, "inner-flush", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "values" => params
    })

    render(view)
    :ok
  end

  # ── 1. the grade, reproduced from the live socket ───────────────────────────

  describe "a signed-in NON-MEMBER with a DOC-scoped write grant" do
    test "mounts a DIFFERENT doc as {:grant, ctx} with write_gate? and caps.write true", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      assigns = socket_of(view).assigns

      # THE GRADE: the armed one. caller_context is set (so reads ARE narrowed)
      # and write_gate? is true (so the per-EVENT narrowing is attached) — and
      # there is no read-only posture, so #9332's `readonly_posture?/1` arm is
      # silent here. This is a different bypass.
      refute is_nil(assigns[:caller_context])
      assert assigns[:write_gate?] == true
      assert assigns[:share_access] == nil
      assert assigns[:readonly_gate?] == nil
      assert %Barkpark.Accounts.User{} = assigns[:current_user]

      # READ REACH on the NON-granted doc — required, or the write below would
      # be a no-op against an unloaded pane.
      assert assigns[:paper_doc].doc_id == @other_slug
      assert_editor_rendered!(view)

      # `Caps.derive/1` still says write: true, because `admits_desk?/3`
      # auto-satisfies the grant's own type/doc_id at desk granularity. The door
      # must not ask it about the TARGET — it has no target to be asked about.
      caps = BarkparkWeb.Studio.Caps.derive(socket_of(view))
      assert caps.write == true
      assert BarkparkWeb.Studio.Caps.write_capable?(assigns, caps) == true
    end

    test "is DENIED writing the NON-granted doc — stored bytes UNCHANGED", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      before_write = stored_value(ws, proj, @other_slug)
      assert before_write == @orig

      inner_change(view, @escalated)

      # THE ORACLE: the persisted document, re-read. A regression prints
      # `left: %{"amount" => "ESCALATED", "currency" => "NOK"}`.
      stored_non_granted_doc = stored_value(ws, proj, @other_slug)
      assert stored_non_granted_doc == @orig
      assert flash_error(view) == @outside_grant_flash

      # And the doc the grant DOES name is untouched by the refused attempt.
      assert stored_value(ws, proj, @granted_slug) == @orig
    end
  end

  # ── 2. the grantee still writes the doc its grant names ─────────────────────

  describe "positive control — the SAME socket at the GRANTED doc" do
    test "writes, and the stored bytes CHANGE", %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @granted_slug)

      before_write = stored_value(ws, proj, @granted_slug)
      assert before_write == @orig

      inner_change(view, @legit)

      after_write = stored_value(ws, proj, @granted_slug)
      assert after_write == @legit
      assert before_write != after_write
    end
  end

  # ── 3. membership-derived write is untouched ────────────────────────────────

  describe "positive control — write from MEMBERSHIP, not a grant" do
    test "a plain MEMBER (role write, no admin) writes an arbitrary doc on the desk", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn} = user_session(conn)
      # `member` is the built-in role whose actions are exactly `read write`
      # (tenancy/auth.ex:55-59) — write from MEMBERSHIP, never from a grant.
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      view = open_paper!(conn, ws, proj, @other_slug)
      assigns = socket_of(view).assigns

      # The member arm answers first: NO grant grade at all, so the new door arm
      # is structurally unreachable for this socket — no grant load, no denial.
      assert is_nil(assigns[:caller_context])
      assert assigns[:write_gate?] == nil

      inner_change(view, @legit)

      stored_member_write = stored_value(ws, proj, @other_slug)
      assert stored_member_write == @legit
    end
  end

  # ── 4. non-vacuity by SUBSTITUTION ON THE SHIPPED MODULE ────────────────────

  # The door's own source, on disk. Read at run time and recompiled IN-VM, so the
  # oracle below observes PRODUCT CODE — not a copy of it kept in this file. A
  # test-local re-implementation of the pre-fix door would be a tautology over a
  # literal: it would red when the literal is flipped and stay green when
  # `paper.ex` is gutted, which is precisely backwards.
  @door_path Path.expand(
               "../../../../lib/barkpark_web/live/studio/studio_live/shared/paper.ex",
               __DIR__
             )
  @door_module BarkparkWeb.Studio.StudioLive.Shared.Paper

  # `grant_target_denied?/3`'s whole body (paper.ex:152) — the arm pds-w44 added.
  # Substituting it for the constant `false` restores the PRE-FIX door exactly:
  # `paper_pane_op/2`'s cond is left with only the target-less `write_denied?/1`.
  @door_expression "grant_graded?(socket.assigns) and not grant_admits_target?(socket, type, doc_id)"
  @door_substitution "false"

  describe "NON-VACUITY" do
    test "the door arm SUBSTITUTED OUT of shared/paper.ex admits the escalation it refuses", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      original = File.read!(@door_path)
      mutant = String.replace(original, @door_expression, @door_substitution, global: false)

      # THE SUBSTITUTION GUARD, LOAD-BEARING — do not trim this as noise. If
      # `paper.ex` is reformatted (the expression wrapped across lines, the arm
      # renamed) the replace becomes a no-op, the "mutant" compiles the SHIPPED
      # door, and every assertion below would pass while proving NOTHING. This
      # assert turns that silent vacuity into a RED that names its own cause.
      #
      # AND IT COUNTS, because `global: false` takes the FIRST occurrence: `mutant
      # != original` proves only that SOMETHING was replaced, not that the DOOR
      # was. If a refactor introduces an earlier textual match, the first form
      # would stay green while mutating a site that is not the door. The
      # expression occurs exactly ONCE in `paper.ex` today; pinning that is what
      # makes "the first occurrence" and "the door" the same sentence.
      assert length(String.split(original, @door_expression)) - 1 == 1,
             "the door expression #{inspect(@door_expression)} occurs " <>
               "#{length(String.split(original, @door_expression)) - 1} time(s) in " <>
               "#{@door_path}, not exactly once. `global: false` substitutes the FIRST " <>
               "occurrence, so more than one makes this case mutate an unknown site and " <>
               "none makes it mutate nothing. Re-derive the expression from " <>
               "grant_target_denied?/3 — do NOT relax this guard to a mere != check."

      assert mutant != original,
             "substitution missed its target in #{@door_path}: the door expression " <>
               "#{inspect(@door_expression)} is no longer present verbatim. Re-derive it " <>
               "from grant_target_denied?/3 — do NOT delete this guard."

      prev_conflict = Code.get_compiler_option(:ignore_module_conflict)

      # RESTORE THE PRISTINE MODULE whatever happens below — including a failed
      # assertion, which raises. Registered BEFORE the mutant is loaded so the
      # recompile runs even if `compile_string/2` itself raises.
      on_exit(fn ->
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          Code.compile_string(original, @door_path)
        after
          Code.put_compiler_option(:ignore_module_conflict, prev_conflict)
        end
      end)

      # try/after, NOT a bare put + put: a raise mid-compile would otherwise
      # leave `:ignore_module_conflict` globally TRUE for the rest of the suite,
      # silently swallowing genuine module-conflict warnings in every later test.
      #
      # THE MUTANT COMPILE IS LOUD, AND EVERY WARNING IS EXPECTED — counted from
      # the run, not guessed: 10, all downstream of the arm becoming the literal
      # `false`. 3 unused variables (`socket`, `type`, `doc_id`, now unread by
      # `grant_target_denied?/3`), 4 now-unreachable functions
      # (`write_target_scope/3`, `grant_graded?/1`, `grant_admits_target?/3`,
      # `active_grants/1`), and 3 "this clause in cond will never match" — one at
      # EACH of the door's three call sites (paper.ex:233, :306, :716), which is
      # itself the type checker confirming the substitution reached all of them.
      # They do not fail the run. A reviewer seeing them has found the
      # substitution working, not a bug.
      try do
        Code.put_compiler_option(:ignore_module_conflict, true)
        [{@door_module, _bin} | _] = Code.compile_string(mutant, @door_path)
      after
        Code.put_compiler_option(:ignore_module_conflict, prev_conflict)
      end

      # `Shared.Paper` is reached only by REMOTE call from `StudioLive`, so a
      # LiveView mounted after this point runs the mutant with no stale-code risk.
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      assert stored_value(ws, proj, @other_slug) == @orig

      inner_change(view, @escalated)

      # THE ORACLE, INVERTED: with the shipped arm substituted out, the escalated
      # bytes LAND. That is the escalation #9377 closed, reproduced by run — and
      # it is the assertion the shipped door's own test (:280) proves CANNOT
      # happen. One file, both directions, same oracle.
      assert stored_value(ws, proj, @other_slug) == @escalated
      refute flash_error(view) == @outside_grant_flash
    end
  end
end
