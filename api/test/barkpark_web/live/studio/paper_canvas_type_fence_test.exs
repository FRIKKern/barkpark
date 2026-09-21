defmodule BarkparkWeb.Studio.PaperCanvasTypeFenceTest do
  @moduledoc """
  THE INVARIANT, STATED WITHOUT ITS MECHANISM.

  Only a document that IS a paper may reinstate the paper canvas lease. A
  document of any other blocks type — whatever else that type is allowed to do,
  and however it reached the paper pane — must not come back owning canvas
  blocks: the retained client-side ownership is discarded and no signed lease
  token is handed back, exactly as for a document that never held one. A
  document whose type cannot be read at all is treated the same way: the
  admission is affirmative, so an unreadable type is a refusal and not a pass.

  That sentence names no function and no line on purpose. It is a statement
  about DOCUMENTS, not about a conjunct, so widening the blocks-type whitelist
  cannot satisfy it by arithmetic: every new type that is not the paper type
  falls under the same refusal, and this file asks the whitelist for its
  members rather than listing them.

  WHY IT NEEDS A TEST OF ITS OWN. The type admission is the ONLY type fence on
  a live two-document path. The blocks-type whitelist deliberately admits a
  second type, and the Studio pane builder opens that second type in the SAME
  pane, with the same paper view, by design — so nothing upstream of the canvas
  lease refuses it. Every existing canvas-lease fixture builds a paper, so the
  suite has arms on the PRINCIPAL axis (write capability, per-target grant
  containment, the pane's own type) and no arm on the DOCUMENT-TYPE axis at
  all: remove the type admission and the whole relevant suite stays green.

  HOW EACH CASE IS BUILT. Both arms share ONE socket — one workspace, one
  membership, one live paper pane — and ONE signed lease minted from a real
  retained boundary. The two documents handed to the authorization question are
  the same map with ONE key different: `:type`. Every other input that could
  decide the case is asserted admitting MECHANICALLY before the question is
  asked (the principal's write capability, the per-target grant question for
  THIS document, and the pane's own document type), so when the verdict is a
  refusal, exactly one input produced it.

  Each refusal is paired with a POSITIVE CONTROL on the SAME fixture — same
  socket, same signed tokens, one key different — which resumes. Without it
  "did not resume" is satisfied by a lease that was never mintable.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Content}
  alias BarkparkWeb.PaperCanvasLease
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @owned_block "canvas-owned-table"
  @paper_slug "pctf-paper-doc"

  # DERIVED, NOT LISTED. Asking the whitelist rather than writing "session"
  # means widening it cannot quietly leave this file measuring a type that no
  # longer exists — and an EMPTY population is a flunk, not a silent pass, so
  # the case can never become vacuous by the whitelist narrowing to one type.
  defp non_paper_blocks_type do
    case Enum.reject(Content.blocks_types(), &(&1 == Content.paper_type())) do
      [type | _] ->
        type

      [] ->
        flunk(
          "Content.blocks_types/0 holds only the paper type — no non-paper document " <>
            "can reach the paper canvas lease and this case measures nothing"
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
    ws = create_workspace!("pctf-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "pctf-proj")
    seed_paper_schema!(ws, proj)
    create_paper!(ws, proj, @paper_slug)

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
  # boundary, so `PaperCanvasLease.issue/4` can actually mint a signed token for
  # it. Without a mintable boundary every "did not resume" below would pass
  # because there was no lease at all.
  defp create_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "PCTF"},
      %{"id" => "p-1", "type" => "paragraph", "text" => "Canvas type-fence fixture body."},
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

  defp member_session(conn, ws) do
    email = "pctf-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp doc_blocks(doc), do: get_in(Map.get(doc, :content), ["blocks"]) || []

  # THE TWO ARMS, ONE MAP APART. Both documents are the loaded document as a
  # plain map; they differ in the value at `:type` and in NOTHING else — same
  # id, same workspace, same project, same content, same blocks.
  defp doc_as_map(doc) when is_struct(doc), do: Map.from_struct(doc)
  defp doc_as_map(doc) when is_map(doc), do: doc

  defp doc_typed(doc, type), do: Map.put(doc_as_map(doc), :type, type)

  # The THIRD state, which is neither of the two values: a document map carrying
  # no `:type` key at all. Nothing in the map says what it is.
  defp doc_untyped(doc), do: Map.delete(doc_as_map(doc), :type)

  # THE RECONNECT, BUILT FROM A REAL SIGNED LEASE.
  #
  # `issue_socket/5` mints the tokens the client would have been handed while it
  # owned the block; the returned socket is then rewound to the state a FRESH
  # mount is left in (no tokens, no ownership, no scope) carrying only the
  # resume attempt the client sends back in its connect params. That is a
  # reconnect, not a rebuild.
  #
  # The lease is minted against the SAME document the arm later presents, so the
  # attempt's key matches the scope it is checked against and the arms cannot
  # differ by a key mismatch instead of by the question under test.
  defp reconnecting_socket(socket, doc) do
    blocks = doc_blocks(doc)
    owners = %{document: MapSet.new([@owned_block])}

    issued = PaperCanvasLease.issue_socket(socket, doc, owners, blocks, 1)
    tokens = issued.assigns.paper_canvas_lease_tokens

    # ANTI-VACUITY: a lease that was never minted cannot fail to resume. If the
    # boundary stops being retainable this REDS instead of passing silently.
    assert map_size(tokens) == 1,
           "no signed lease was minted for #{@owned_block} — every resume assertion " <>
             "below would pass vacuously"

    attempt = %{
      attempted?: true,
      malformed?: false,
      pending?: false,
      key: PaperCanvasLease.paper_key(PaperCanvasLease.scope(socket.assigns, doc)),
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
  # the lease consumes it — the same composition the paper view performs.
  defp resume(socket, doc, blocks) do
    PaperCanvasLease.resume_socket(
      socket,
      doc,
      blocks,
      Paper.canvas_resume_authorized?(socket, doc)
    )
  end

  # EVERY OTHER INPUT, READ OFF THE LIVE SOCKET FOR THIS DOCUMENT. Asserted, not
  # narrated: when the verdict below is a refusal, the document's own type is
  # the only thing left that could have produced it.
  defp assert_only_the_document_type_can_decide!(socket, doc) do
    assert Paper.write_denied?(socket) == false,
           "the target-less write input would decide this case first"

    assert Paper.grant_target_denied?(socket, Map.get(doc, :type), Map.get(doc, :doc_id)) ==
             false,
           "the per-target grant input would decide this case first"

    assert socket.assigns[:editor_type] == Content.paper_type(),
           "the pane's own document type would decide this case first"

    :ok
  end

  describe "a document that is not a paper" do
    test "does not reinstate the paper canvas lease, on a socket that admits everything else",
         %{conn: conn, ws: ws, proj: proj} do
      conn = member_session(conn, ws)
      view = open_paper!(conn, ws, proj, @paper_slug)
      socket = socket_of(view)
      loaded = socket.assigns[:paper_doc]

      other_type = non_paper_blocks_type()

      # THE REACH, PINNED. The second blocks type is the one the pane builder
      # opens in this very pane; if it ever leaves the whitelist the reach claim
      # in this file's header is void and this REDS rather than measuring a
      # type nobody can produce.
      assert Content.blocks_type?("session"),
             "the live two-document path this file measures needs a session document"

      assert other_type != Content.paper_type()

      doc = doc_typed(loaded, other_type)
      {reconnect, blocks} = reconnecting_socket(socket, doc)

      assert_only_the_document_type_can_decide!(reconnect, doc)

      refute Paper.canvas_resume_authorized?(reconnect, doc)

      resumed = resume(reconnect, doc, blocks)

      # THE INVARIANT'S OBSERVABLE: no retained ownership, no lease token, and
      # the resume did not happen.
      assert resumed.assigns.paper_canvas_retained == nil
      assert resumed.assigns.paper_canvas_lease_tokens == %{}
      refute resumed.assigns.paper_canvas_resume_status == :resumed
    end

    test "POSITIVE CONTROL — the same socket and the same fixture, as a paper", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      conn = member_session(conn, ws)
      view = open_paper!(conn, ws, proj, @paper_slug)
      socket = socket_of(view)
      loaded = socket.assigns[:paper_doc]

      doc = doc_typed(loaded, Content.paper_type())
      {reconnect, blocks} = reconnecting_socket(socket, doc)

      assert_only_the_document_type_can_decide!(reconnect, doc)

      assert Paper.canvas_resume_authorized?(reconnect, doc)

      resumed = resume(reconnect, doc, blocks)

      assert resumed.assigns.paper_canvas_resume_status == :resumed
      assert resumed.assigns.paper_canvas_retained.slug == @paper_slug
      assert MapSet.member?(resumed.assigns.paper_canvas_retained.owners[:document], @owned_block)
      assert map_size(resumed.assigns.paper_canvas_lease_tokens) == 1
    end
  end

  describe "a document whose type cannot be read at all" do
    test "is refused on the same socket — the admission is affirmative, not a two-value choice",
         %{conn: conn, ws: ws, proj: proj} do
      conn = member_session(conn, ws)
      view = open_paper!(conn, ws, proj, @paper_slug)
      socket = socket_of(view)
      loaded = socket.assigns[:paper_doc]

      # The lease is minted against the PAPER, so a real signed token exists and
      # the refusal below cannot be "there was nothing to resume".
      {reconnect, blocks} = reconnecting_socket(socket, doc_typed(loaded, Content.paper_type()))

      doc = doc_untyped(loaded)

      refute Map.has_key?(doc, :type),
             "the arm is only about the ABSENT key — a key present and nil is the other case"

      assert_only_the_document_type_can_decide!(reconnect, doc)

      # THE PREDICATE ITSELF, over the third state. A refusal here is what makes
      # the admission total rather than proved on a two-value enumeration.
      refute Paper.canvas_resume_authorized?(reconnect, doc)

      resumed = resume(reconnect, doc, blocks)

      assert resumed.assigns.paper_canvas_retained == nil
      assert resumed.assigns.paper_canvas_lease_tokens == %{}
      refute resumed.assigns.paper_canvas_resume_status == :resumed
    end
  end
end
