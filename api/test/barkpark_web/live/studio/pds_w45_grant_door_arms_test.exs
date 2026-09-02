defmodule BarkparkWeb.Studio.PdsW45GrantDoorArmsTest do
  @moduledoc """
  pds-w45 — THE ARMS OF THE MERGED GRANT DOOR ITS OWN SUITE NEVER DROVE, and a
  denial oracle that can NAME the door that refused.

  The wave-44 door (`Shared.Paper.grant_target_denied?/3`) is guarded by
  `pds_w44_grant_door_test.exs`, but every case there drives ONE socket shape:
  a live grantee mount, where `LiveScope.assign_grant_scope/2` and
  `LiveScope.attach_write_gate/2` BOTH fire, so `caller_context` and
  `write_gate?` are always set together. Three things were therefore never
  observed by a run.

  ## 1. `grant_graded?/1` is an OR, and only the both-set input was ever fed it

  The predicate is `caller_context != nil OR write_gate? == true`. Either
  disjunct ALONE arms the door, and a suite that only ever supplies both cannot
  tell a working OR from `and`, from `caller_context != nil`, or from
  `write_gate? == true`. This file feeds each disjunct in isolation and asserts
  the authorization outcome on PERSISTED BYTES.

  Constructing those two sockets means overriding one assign on a real mount,
  because the live route sets the pair atomically. That is the point: the arms
  are individually load-bearing (a future grade could set one without the
  other — `attach_write_gate/2` is called from `maybe_attach_readonly_gate/2`
  and `assign_grant_scope/2` from a different clause of the same mount), and
  an OR whose halves are never separated is an OR nobody has tested.

  ## 2. FAIL-CLOSED on an unresolvable target was reasoned, never run

  `write_target_scope/3` returns nil unless workspace id, project id, dataset,
  type AND doc_id are all present and well-typed, and `grant_admits_target?/3`
  maps that nil to `false` — DENY. No shipped case drove it.

  It has to be driven on a target the grant DOES admit, or the deny proves
  nothing: an already-outside doc is denied by containment whether the scope
  resolved or not. So the case below breaks the scope of the GRANTED doc — the
  one the wave-44 positive control proves is writable — and asserts the write
  stops.

  WHICH COMPONENT CAN BE BROKEN IS NOT FREE, and this is where the filing is
  wrong. It names "a missing dataset, project or doc field" as interchangeable.
  They are not: `Caps.derive/1` builds its desk scope from workspace + project +
  dataset, so blanking any of those three ALSO collapses `caps.write`, and
  `write_denied?/1` — the FIRST arm of `paper_pane_op/2`'s cond — answers before
  the grant door is ever consulted. A project-missing case is a genuine
  fail-closed DENY on persisted bytes but it is NOT a test of this arm. The doc
  fields (`type`, `doc_id`) are the only components `Caps.derive/1` does not
  read, so the doc-field case is the only one that reaches the arm. Both are
  below, each recording WHICH door refused, because a deny attributed to the
  wrong door is the failure this whole task is about.

  That case doubles as the missing `doc_field/2` totality case: its `paper_doc`
  is a BARE MAP with no `:type` key, the shape `doc_field/2` exists to survive.

  ## 3. THE FLASH ORACLE CANNOT NAME THE DOOR

  "That action is outside your access grant's scope" has TWO producers:
  `Shared.Paper.refuse_outside_grant/1` (this door, reached through
  `handle_info`) and the `:live_scope_write_scope` hook that
  `LiveScope.attach_write_gate/2` attaches to `:handle_event`. Asserting the
  string alone is circular — it assumes the very routing claim the test exists
  to prove.

  The signals DO differ. `refuse_outside_grant/1` also assigns
  `save_status: "Read-only"`; the LiveScope hook only puts the flash and halts,
  touching no other assign. So the pair (flash, save_status) names the producer,
  and the case below fires BOTH producers in one run — the same op through the
  parent `handle_event` and through the component's `handle_info` — and asserts
  the flashes are EQUAL (the oracle's blindness, demonstrated rather than
  argued) while the save_status signatures DIFFER.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @block_id "fb-price"
  @orig %{"amount" => "299", "currency" => "NOK"}
  @escalated %{"amount" => "ESCALATED", "currency" => "NOK"}
  @legit %{"amount" => "LEGIT", "currency" => "NOK"}
  @granted_slug "w45-granted-doc"
  @other_slug "w45-other-doc"
  @outside_grant_flash "That action is outside your access grant's scope"

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT canvas editor, pinned rather than inherited — a canvas-off run
    # renders no `PaperFieldBlock`, and every "the store did not change"
    # assertion would then pass VACUOUSLY.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # UNSHARED and NON-default, so the share grade cannot answer first and the
    # open public-demo posture of the Default workspace cannot leak in.
    ws = create_workspace!("w45-grant-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w45-proj")
    seed_paper_schema!(ws, proj)

    create_paper!(ws, proj, @granted_slug)
    create_paper!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED: with no `paper` schema row in THIS workspace the
  # desk has no paper type and the editor pane never opens.
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

  # One v2 `composite` field block — the kind that renders as a nested
  # `PaperFieldBlock` LiveComponent under both canvas settings.
  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W45"},
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

  # PERSISTED STATE, re-read from the store — never an assign, so every
  # assertion below is falsifiable in both directions.
  defp stored_value(ws, proj, slug) do
    paper = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)

    blocks =
      get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  defp user_session(conn) do
    email = "w45-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # The escalating population: a PROJECT-scoped READ grant (the read reach —
  # without it the grant-narrowed read hides the second doc and the pane never
  # loads) plus a DOC-scoped WRITE grant naming exactly ONE doc.
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
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  # The ids of the hooks attached to the parent socket's `:handle_event` stage —
  # how this file proves the SECOND flash producer is armed on the very socket
  # whose denial it attributes to the FIRST.
  defp handle_event_hook_ids(view) do
    view
    |> socket_of()
    |> Map.fetch!(:private)
    |> Map.fetch!(:lifecycle)
    |> Map.fetch!(:handle_event)
    |> Enum.map(& &1.id)
  end

  # The op `PaperFieldBlock.persist/2` sends — built here verbatim so the direct
  # door drives below carry the same payload the component route carries.
  defp patch_op(value) do
    %{"op" => "patch-block", "id" => @block_id, "patch" => %{"value" => value}}
  end

  # THE DOOR ITSELF, called with a socket this test controls. `paper_pane_op/2`
  # is the chokepoint every hook-invisible paper write reaches, so this observes
  # product code, not a copy of it.
  defp door(socket, value), do: Paper.paper_pane_op(socket, patch_op(value))

  # `with_target/2` on an id that is not in the DOM does NOT fail — the event
  # falls through to the parent, nothing is written, and "store unchanged" then
  # passes for the wrong reason.
  defp assert_editor_rendered!(view) do
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    :ok
  end

  # The REAL component route. `persist/2` does `send(self(), {:paper_op, …})`,
  # so the write lands in a LATER `handle_info`; the trailing `render/1` drains
  # it before the store is read.
  defp inner_change(view, params) do
    assert_editor_rendered!(view)

    view
    |> with_target("#paper-fb-" <> @block_id)
    |> render_hook("inner-change", params)

    render(view)
    :ok
  end

  # ── 1. the OR's two arms, fed one at a time ─────────────────────────────────

  describe "grant_graded?/1 — caller_context ALONE" do
    test "a socket with caller_context set and write_gate? UNSET is still denied — stored bytes UNCHANGED",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      # ONE assign overridden: the write-gate half of the OR is removed, so
      # `caller_context` is the ONLY thing that can arm the door.
      socket = Phoenix.Component.assign(socket_of(view), write_gate?: nil)

      refute is_nil(socket.assigns[:caller_context])
      assert socket.assigns[:write_gate?] == nil

      # NON-VACUITY, IN THE CASE ITSELF: the FIRST arm of `paper_pane_op/2`'s
      # cond must NOT answer, or the deny below would be the principal gate's
      # and this case would observe nothing of the grant door.
      assert Paper.write_denied?(socket) == false

      assert stored_value(ws, proj, @other_slug) == @orig

      out = door(socket, @escalated)

      # THE ORACLE: persisted bytes. A regression prints
      # `left: %{"amount" => "ESCALATED", "currency" => "NOK"}`.
      assert stored_value(ws, proj, @other_slug) == @orig
      assert out.assigns.save_status == "Read-only"
      assert out.assigns.flash["error"] == @outside_grant_flash
      assert stored_value(ws, proj, @granted_slug) == @orig
    end
  end

  describe "grant_graded?/1 — write_gate? ALONE" do
    test "a socket with write_gate? true and caller_context NIL is still denied — stored bytes UNCHANGED",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      # The mirror image. `grant_scoped_read` goes with `caller_context` — they
      # are assigned together by `assign_grant_scope/2` and read together by
      # `ScopeHelpers.scope_opts/1`, so removing one and keeping the other would
      # build a socket the product never makes and read narrowing this case is
      # not about.
      socket =
        Phoenix.Component.assign(socket_of(view), caller_context: nil, grant_scoped_read: nil)

      assert is_nil(socket.assigns[:caller_context])
      assert socket.assigns[:write_gate?] == true
      assert Paper.write_denied?(socket) == false

      assert stored_value(ws, proj, @other_slug) == @orig

      out = door(socket, @escalated)

      assert stored_value(ws, proj, @other_slug) == @orig
      assert out.assigns.save_status == "Read-only"
      assert out.assigns.flash["error"] == @outside_grant_flash
      assert stored_value(ws, proj, @granted_slug) == @orig
    end
  end

  # ── 2. fail-closed on an unresolvable target ────────────────────────────────

  describe "write_target_scope/3 fail-closed — the DOC FIELD the ladder needs" do
    test "a bare-map doc with NO :type denies the GRANT'S OWN doc — stored bytes UNCHANGED",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)

      # THE DOC THE GRANT NAMES — writable on this very socket (the control at
      # the end of this test writes it). Any other doc would be denied by
      # containment and the deny would say nothing about the fail-closed arm.
      view = open_paper!(conn, ws, proj, @granted_slug)

      # A BARE MAP with no `:type` — the shape `doc_field/2` exists to survive,
      # and the shape no case in the suite had. `type` therefore reaches
      # `write_target_scope/3` as nil, the ladder cannot be built, and
      # `grant_admits_target?/3` maps the nil to DENY.
      socket = Phoenix.Component.assign(socket_of(view), paper_doc: %{doc_id: @granted_slug})

      # The FIRST arm stays silent: this socket is write-capable, and the doc
      # fields are the only ladder components `Caps.derive/1` does not read.
      assert Paper.write_denied?(socket) == false

      assert stored_value(ws, proj, @granted_slug) == @orig

      out = door(socket, @escalated)

      assert stored_value(ws, proj, @granted_slug) == @orig
      assert out.assigns.save_status == "Read-only"
      assert out.assigns.flash["error"] == @outside_grant_flash

      # THE CONTROL, SAME SOCKET, SAME OP PAYLOAD, ONE DIFFERENCE: the real doc
      # struct. The write lands — so the deny above is attributable to the
      # missing field and to nothing else about this mount.
      control = door(socket_of(view), @legit)

      assert stored_value(ws, proj, @granted_slug) == @legit
      assert control.assigns.save_status == "Auto-saved"
    end
  end

  describe "write_target_scope/3 fail-closed — a missing PROJECT" do
    test "denies the GRANT'S OWN doc on persisted bytes, and the PRINCIPAL gate is what refuses",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @granted_slug)

      socket = Phoenix.Component.assign(socket_of(view), current_project: nil)

      assert stored_value(ws, proj, @granted_slug) == @orig

      out = door(socket, @escalated)

      # THE DENY IS REAL, on persisted bytes.
      assert stored_value(ws, proj, @granted_slug) == @orig

      # AND IT IS NOT THIS DOOR'S. `Caps.derive/1` builds its desk from
      # workspace + project + dataset, so blanking the project collapses
      # `caps.write` and `write_denied?/1` — the FIRST cond arm — answers first.
      # Recorded, not glossed: this is why the filing's "a missing dataset,
      # project or doc field" is not one case with three spellings, and why the
      # doc-field case above is the one that reaches the grant door.
      assert Paper.write_denied?(socket) == true
      assert out.assigns.flash["error"] != @outside_grant_flash
    end
  end

  # ── 3. the denial oracle, made able to name its door ────────────────────────

  describe "the outside-grant flash has TWO producers" do
    test "same string from both, and save_status is what tells them apart",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = grantee_session(conn, ws, proj)

      # PRODUCER B IS ARMED ON THIS SOCKET. `attach_write_gate/2` attached
      # `:live_scope_write_scope` to `:handle_event`. The wave-44 moduledoc
      # argues this hook cannot fire on the component route — but that argument
      # IS the claim under test, so its absence is not assumed here, it is
      # refuted: the hook is present, and it is about to fire on route A.
      parent_view = open_paper!(conn, ws, proj, @other_slug)
      assert :live_scope_write_scope in handle_event_hook_ids(parent_view)

      baseline_status = socket_of(parent_view).assigns[:save_status]
      refute baseline_status == "Read-only"

      # ROUTE A — the PARENT `handle_event`, which the hook DOES see. This is
      # producer B: `LiveScope.attach_write_gate/2`'s halt branch.
      render_hook(parent_view, "paper-op", patch_op(@escalated))

      flash_a = flash_error(parent_view)
      status_a = socket_of(parent_view).assigns[:save_status]

      assert stored_value(ws, proj, @other_slug) == @orig

      # ROUTE B — the component route, on a FRESH mount so route A's flash
      # cannot be mistaken for this one's. `persist/2` sends a `handle_info`, no
      # `handle_event` hook observes it, and producer A —
      # `Shared.Paper.refuse_outside_grant/1` — is what refuses.
      door_view = open_paper!(conn, ws, proj, @other_slug)
      inner_change(door_view, @escalated)

      flash_b = flash_error(door_view)
      status_b = socket_of(door_view).assigns[:save_status]

      assert stored_value(ws, proj, @other_slug) == @orig

      # THE OLD ORACLE'S BLINDNESS, DEMONSTRATED BY RUN rather than argued: two
      # different doors, one string.
      assert flash_a == @outside_grant_flash
      assert flash_b == @outside_grant_flash
      assert flash_a == flash_b

      # THE NEW ORACLE. `refuse_outside_grant/1` assigns `save_status:
      # "Read-only"` alongside the flash; the LiveScope hook's halt branch puts
      # the flash and touches nothing else. So the PAIR names the producer, and
      # a denial credited to the wrong door now REDS.
      assert status_a == baseline_status
      assert status_b == "Read-only"
      assert status_a != status_b
    end
  end
end
