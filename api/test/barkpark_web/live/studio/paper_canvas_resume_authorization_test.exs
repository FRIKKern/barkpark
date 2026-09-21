defmodule BarkparkWeb.Studio.PaperCanvasResumeAuthorizationTest do
  @moduledoc """
  THE INVARIANT, STATED WITHOUT ITS MECHANISM.

  A canvas lease may be reinstated on reconnect only for a principal whose
  CURRENT authority still admits writing THE PAPER BEING RESUMED. A lease
  issued under an authority that has since been revoked, narrowed or expired
  must not come back: the retained client-side ownership is discarded and the
  editor re-enters the frozen state, exactly as for a principal that never held
  one.

  Two halves of that sentence had no test.

  `BarkparkWeb.Studio.StudioLive.Shared.Paper.canvas_resume_authorized?/2` is
  the ONLY authorization input to the lease resume — `setup_paper_view/2` feeds
  it straight into `PaperCanvasLease.resume_socket/4`, where `authorized? != true`
  runs `reset_socket/1` (ownership discarded, `halt_mutation/3` left freezing
  every `paper-*` event) and `true` reinstates the signed claims. Two of its
  four clauses could be DELETED with the whole canvas / grant-door test set
  green (216 tests, 0 failures each):

    * the per-TARGET grant containment clause
      (`not grant_target_denied?(socket, type, doc_id)`), and
    * the read-only-pane clause (`not read_only_pane?(socket)`).

  WHY THE SUITE COULD NOT SEE THEM — and what this file does differently. Every
  existing caller of the lease supplies the `authorized?` boolean LITERALLY
  (`paper_canvas_lease_test.exs`): the boolean's CONSUMER is exhaustively
  pinned, its PRODUCER never called. And every LiveView test that reaches
  `setup_paper_view/2` mounts a MEMBER-graded socket at a `paper` pane, for
  which both clauses are inert BY CONSTRUCTION — a sibling clause always
  decides first, so the named clause never discriminates.

  So each case here is built so that EVERY OTHER CLAUSE PASSES, asserted
  mechanically rather than narrated: the case prints `write_denied?/1`,
  `grant_target_denied?/3` and the pane's own `editor_type` beside the doc's
  `type` before it asks the question. When the verdict is `false`, exactly one
  clause produced it.

  Each denial is paired with a POSITIVE CONTROL on the SAME fixture — the same
  socket, the same signed tokens, one field different — which resumes. Without
  it "did not resume" is satisfied by a lease that was never mintable.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Content, Repo}
  alias BarkparkWeb.PaperCanvasLease
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @owned_block "canvas-owned-table"
  @granted_slug "pcra-granted-doc"
  @other_slug "pcra-other-doc"

  # DERIVED, NOT LISTED. The read-only-pane clause fires for a blocks-doc that
  # is not a paper; naming "session" here would be a snapshot of a whitelist
  # that `Content.blocks_types/0` owns and may widen. Ask the whitelist.
  defp non_paper_blocks_type do
    case Enum.reject(Content.blocks_types(), &(&1 == Content.paper_type())) do
      [type | _] ->
        type

      [] ->
        flunk(
          "Content.blocks_types/0 holds only the paper type — the read-only pane " <>
            "clause has no reachable input and this case measures nothing"
        )
    end
  end

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # UNSHARED and NON-default: the Default workspace is an open public demo in
    # test, and a shared one would be graded by the share arm instead.
    ws = create_workspace!("pcra-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "pcra-proj")
    seed_paper_schema!(ws, proj)

    create_paper!(ws, proj, @granted_slug)
    create_paper!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED: with no `paper` schema in THIS workspace the desk
  # has no paper type and the editor pane never opens.
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

  # A paper carrying one DOCUMENT-level `table` block — a retained canvas
  # boundary, so `PaperCanvasLease.issue/4` can actually mint a signed token
  # for it. Without a mintable boundary every "did not resume" below would pass
  # because there was no lease at all.
  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "PCRA"},
      # A real content block, so `Papers.Hollow.hollow?/1` does not refuse the
      # write: the empty table below is structure, not payload.
      %{"id" => "p-1", "type" => "paragraph", "text" => "Canvas resume fixture body."},
      %{"id" => @owned_block, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}
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

  defp user_session(conn) do
    email = "pcra-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # A grant-graded socket with WIDE write: a PROJECT-scoped read+write grant
  # admits BOTH papers, so the per-target clause is satisfied at mount. The
  # narrowing happens later, mid-session, which is the event under test.
  defp wide_grantee_session(conn, ws, proj) do
    {user, conn} = user_session(conn)

    grant =
      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset
      })

    {user, conn, grant}
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp paper_blocks(paper), do: get_in(paper.content, ["blocks"]) || []

  # THE RECONNECT, BUILT FROM A REAL SIGNED LEASE.
  #
  # `issue_socket/5` mints the tokens the client would have been handed while it
  # owned the block; the returned socket is then rewound to the state
  # `prepare_socket/1` leaves a FRESH mount in (no tokens, no ownership, no
  # scope) carrying only the resume attempt the client sends back in its connect
  # params. That is a reconnect, not a rebuild — the difference matters, because
  # the rebuild path (`:none` + same scope) keeps state for an unrelated reason.
  defp reconnecting_socket(socket, paper) do
    blocks = paper_blocks(paper)
    owners = %{document: MapSet.new([@owned_block])}

    issued = PaperCanvasLease.issue_socket(socket, paper, owners, blocks, 1)
    tokens = issued.assigns.paper_canvas_lease_tokens

    # ANTI-VACUITY: a lease that was never minted cannot fail to resume. If the
    # boundary stops being retainable this REDS instead of passing silently.
    assert map_size(tokens) == 1,
           "no signed lease was minted for #{@owned_block} — every resume assertion " <>
             "below would pass vacuously"

    key = PaperCanvasLease.paper_key(PaperCanvasLease.scope(socket.assigns, paper))

    attempt = %{
      attempted?: true,
      malformed?: false,
      pending?: false,
      key: key,
      tokens: Map.values(tokens)
    }

    socket =
      socket
      |> Phoenix.Component.assign(:paper_canvas_resume_attempt, attempt)
      |> Phoenix.Component.assign(:paper_canvas_lease_tokens, %{})
      |> Phoenix.Component.assign(:paper_canvas_retained, nil)
      |> Phoenix.Component.assign(:paper_canvas_lease_key, nil)
      |> Phoenix.Component.assign(:paper_canvas_lease_scope, nil)
      |> Phoenix.Component.assign(:paper_canvas_resume_halt, false)
      |> Phoenix.Component.assign(:paper_canvas_resume_status, :none)

    {socket, blocks}
  end

  # The real wiring, in one line: the predicate under test produces the boolean,
  # the lease consumes it — the same composition `setup_paper_view/2` performs.
  defp resume(socket, paper, blocks) do
    PaperCanvasLease.resume_socket(
      socket,
      paper,
      blocks,
      Paper.canvas_resume_authorized?(socket, paper)
    )
  end

  # Every clause EXCEPT the one under test, read off the live socket. Returns the
  # doc so the caller reads as one sentence.
  defp assert_only_remaining_discriminator!(socket, paper, except) do
    if except != :paper_type do
      assert Map.get(paper, :type) == Content.paper_type(),
             "the paper-type clause would decide this case first"
    end

    if except != :write_denied do
      assert Paper.write_denied?(socket) == false,
             "the target-less write clause would decide this case first"
    end

    if except != :grant_target do
      assert Paper.grant_target_denied?(socket, Map.get(paper, :type), Map.get(paper, :doc_id)) ==
               false,
             "the grant-target clause would decide this case first"
    end

    if except != :read_only_pane do
      assert socket.assigns[:editor_type] == Content.paper_type(),
             "the read-only-pane clause would decide this case first"
    end

    :ok
  end

  # ── the authority narrowed mid-session ──────────────────────────────────────

  describe "a lease issued under an authority that has since been NARROWED" do
    test "is not reinstated on reconnect — the grant no longer admits THIS paper", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn, wide_grant} = wide_grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      socket = socket_of(view)
      paper = socket.assigns[:paper_doc]

      assert paper.doc_id == @other_slug
      # THE GRADE: grant-derived write, so the per-target clause is ARMED. A
      # membership-derived socket carries neither assign and the clause is
      # structurally inert — this case would then measure nothing.
      refute is_nil(socket.assigns[:caller_context])
      assert socket.assigns[:write_gate?] == true

      {reconnect, blocks} = reconnecting_socket(socket, paper)

      # THE NARROWING, mid-session: the project-wide write grant is replaced by
      # one naming a DIFFERENT doc. Write in this workspace survives; write of
      # THIS paper does not.
      Repo.delete!(wide_grant)

      bind_grant!(ws, user, %{capabilities: ["read"], project_id: proj.id})

      bind_grant!(ws, user, %{
        capabilities: ["read", "write"],
        project_id: proj.id,
        dataset: @dataset,
        type: Content.paper_type(),
        doc_id: @granted_slug
      })

      # Every OTHER clause still passes: the doc is a paper, the pane is a paper
      # pane, and the principal is still write-capable in general — `Caps.derive/1`
      # reports write: true because a doc-scoped grant auto-satisfies its own
      # type/doc_id at DESK granularity. Only the per-target question denies.
      assert_only_remaining_discriminator!(reconnect, paper, :grant_target)

      assert Paper.grant_target_denied?(reconnect, paper.type, paper.doc_id) == true

      refute Paper.canvas_resume_authorized?(reconnect, paper)

      resumed = resume(reconnect, paper, blocks)

      # THE INVARIANT'S OBSERVABLE: the retained client-side ownership is gone
      # and the lease was not reinstated.
      assert resumed.assigns.paper_canvas_retained == nil
      assert resumed.assigns.paper_canvas_lease_tokens == %{}
      refute resumed.assigns.paper_canvas_resume_status == :resumed
    end

    test "POSITIVE CONTROL — the same socket and the same signed lease, before the narrowing",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _wide_grant} = wide_grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)
      socket = socket_of(view)
      paper = socket.assigns[:paper_doc]

      {reconnect, blocks} = reconnecting_socket(socket, paper)

      # The wide grant is untouched, so the per-target clause admits.
      assert Paper.grant_target_denied?(reconnect, paper.type, paper.doc_id) == false
      assert Paper.canvas_resume_authorized?(reconnect, paper)

      resumed = resume(reconnect, paper, blocks)

      assert resumed.assigns.paper_canvas_resume_status == :resumed
      assert resumed.assigns.paper_canvas_retained.slug == @other_slug
      assert MapSet.member?(resumed.assigns.paper_canvas_retained.owners[:document], @owned_block)
      assert map_size(resumed.assigns.paper_canvas_lease_tokens) == 1
    end
  end

  # ── the pane is not the paper the lease names ───────────────────────────────

  describe "a pane holding a blocks-doc that is NOT a paper" do
    test "does not resume a paper canvas lease", %{conn: conn, ws: ws, proj: proj} do
      {user, conn} = user_session(conn)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      view = open_paper!(conn, ws, proj, @granted_slug)
      socket = socket_of(view)
      paper = socket.assigns[:paper_doc]

      {reconnect, blocks} = reconnecting_socket(socket, paper)

      # The pane's real doc type, as `Shared.rebuild_panes/1` assigns it, moved
      # to a non-paper blocks type — the only field that differs from the
      # control below.
      reconnect = Phoenix.Component.assign(reconnect, :editor_type, non_paper_blocks_type())

      # Every other clause passes: the LOADED doc is still a paper (so the
      # paper-type clause admits), the principal is a member (write-capable, no
      # grant grade at all, so the grant clause is inert).
      assert_only_remaining_discriminator!(reconnect, paper, :read_only_pane)

      refute Paper.canvas_resume_authorized?(reconnect, paper)

      resumed = resume(reconnect, paper, blocks)

      assert resumed.assigns.paper_canvas_retained == nil
      assert resumed.assigns.paper_canvas_lease_tokens == %{}
      refute resumed.assigns.paper_canvas_resume_status == :resumed
    end

    test "POSITIVE CONTROL — the same socket with the pane left on its paper", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {user, conn} = user_session(conn)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      view = open_paper!(conn, ws, proj, @granted_slug)
      socket = socket_of(view)
      paper = socket.assigns[:paper_doc]

      {reconnect, blocks} = reconnecting_socket(socket, paper)

      assert reconnect.assigns[:editor_type] == Content.paper_type()
      assert Paper.canvas_resume_authorized?(reconnect, paper)

      resumed = resume(reconnect, paper, blocks)

      assert resumed.assigns.paper_canvas_resume_status == :resumed
      assert resumed.assigns.paper_canvas_retained.slug == @granted_slug
      assert map_size(resumed.assigns.paper_canvas_lease_tokens) == 1
    end
  end
end
