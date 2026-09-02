defmodule BarkparkWeb.Studio.StudioAutosaveTargetCheckTest do
  @moduledoc """
  `Shared.do_autosave/2` — THE THIRD HOOK-INVISIBLE WRITE DOOR, now target-aware.

  ## The defect this file pins

  Wave 42 gave `do_autosave/2` a PRINCIPAL gate (`Paper.write_denied?/1`) and
  wave 44 gave the paper seams a TARGET gate (`Paper.grant_target_denied?/3`).
  `do_autosave/2` got only the first. The two questions are not the same
  question:

  * `Access.admits_desk?/3` OVERWRITES the requested scope's `:type`/`:doc_id`
    with the GRANT'S OWN before validating (its documented job — a desk names
    neither), so a grant naming ONE doc self-satisfies against the whole DESK.
  * `Caps.derive/1` inherits exactly that answer, so `write_denied?/1` is
    `false` for a grant-graded socket editing ANY doc on that desk.
  * `Access.validate/3` on the TARGET's real type + doc_id DISAGREES.

  So the principal gate allowed, and `autosave_write/2` ran
  `Content.upsert_draft` on a doc no active grant admits for write. Reproduced
  by a pds-w43 run on `origin/main`: `save_status: "Saved"` and
  `title == "ESCALATED-BY-AUTOSAVE"` read back from the store.

  `{:autosave_form, form}` (studio_live.ex) is a `handle_INFO`, so
  `LiveScope.attach_write_gate/2` — an `attach_hook(_, :handle_event, _)` —
  never observes it. That is the same structural argument that motivated the
  wave-44 door; this seam is the third instance of it.

  ## The oracle is STORED BYTES, and the reachability is asserted first

  `upsert_draft/6` writes the DRAFT row (`DraftId.draft_id(published_id)`), not
  the published one, so "the published paper is unchanged" would pass VACUOUSLY
  either way. Every assertion here reads that draft row back from the store.

  Read reach is asserted BEFORE the probe (`paper_doc.doc_id` is the second doc
  and its editor component is in the DOM), so a "nothing was written" cannot be
  the `scope_to_grants/3` read-narrowing no-op that made the first w43 attempt
  INCONCLUSIVE. And `write_denied?/1 == false` is asserted on the same socket,
  so the refusal is provably the TARGET arm and not the principal one.

  Containment, not paralysis: the same grantee still autosaves the doc its
  grant DOES name, and a MEMBER-graded socket (no `caller_context`, no
  `write_gate?`) is byte-identical — `grant_target_denied?/3` returns `false`
  there without loading a grant.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Access, Accounts, Content}
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @block_id "fb-price"
  @orig %{"amount" => "299", "currency" => "NOK"}
  @granted_slug "w21auto-granted-doc"
  @other_slug "w21auto-other-doc"
  @outside_grant_flash "That action is outside your access grant's scope"
  @escalated_title "ESCALATED-BY-AUTOSAVE"
  @legit_title "LEGIT-BY-AUTOSAVE"
  @member_title "MEMBER-BY-AUTOSAVE"

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # THE DEFAULT canvas editor, pinned rather than inherited — a canvas-off run
    # renders no `PaperFieldBlock`, and the read-reach guard below would then
    # fail for want of a component rather than for want of authorization.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    # An UNSHARED, NON-default workspace: unshared so no share grade can answer
    # first, non-default because the Default workspace is an open public demo
    # in test.
    ws = create_workspace!("w21auto-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "w21auto-proj")
    seed_paper_schema!(ws, proj)

    create_paper!(ws, proj, @granted_slug)
    create_paper!(ws, proj, @other_slug)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED: without a `paper` schema row in THIS workspace
  # the desk has no paper type and the editor pane never opens.
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
      %{"id" => "h-1", "type" => "heading", "text" => "W21AUTO"},
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

  # ── THE STORE ORACLE ────────────────────────────────────────────────────────
  #
  # `do_autosave/2` → `autosave_write/2` → `Content.upsert_draft/6` writes the
  # DRAFT row for the published slug. Reading the PUBLISHED row would be
  # vacuous: it is unchanged whether the seam refused or wrote.

  defp draft_row(ws, proj, slug) do
    Content.get_document(DraftId.draft_id(slug), "paper", @dataset,
      workspace_id: ws.id,
      project_id: proj.id
    )
  end

  defp draft_title(ws, proj, slug) do
    case draft_row(ws, proj, slug) do
      {:ok, doc} -> doc.title
      {:error, _} -> nil
    end
  end

  defp published_title(ws, proj, slug) do
    paper = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)
    paper && paper.title
  end

  defp user_session(conn) do
    email = "w21auto-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # READ REACH WIDER THAN WRITE REACH — the whole shape of the defect. A
  # project-scoped READ grant makes BOTH papers visible through
  # `scope_to_grants/3`; the WRITE grant names exactly ONE.
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

  # A MEMBERSHIP-graded socket: no grant anywhere, so `grant_graded?/1` is false
  # and the new arm must be inert.
  defp member_session(conn, ws) do
    {user, conn} = user_session(conn)
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")
    {user, conn}
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  # THE ANTI-INCONCLUSIVE GUARD: the target doc is really loaded and really
  # rendered. Without it, "the store did not change" is a no-op, not a refusal.
  defp assert_read_reach!(view, slug) do
    assigns = socket_of(view).assigns
    assert assigns[:paper_doc].doc_id == slug
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    :ok
  end

  # The assigns a mount of `slug` in the form editor leaves behind — the shape
  # `{:autosave_form, form}` finds when it lands.
  defp with_editor_doc(socket, ws, proj, slug) do
    doc = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: proj.id)

    Phoenix.Component.assign(socket,
      editor_doc: doc,
      editor_type: "paper",
      editor_schema: nil,
      editor_form: %{}
    )
  end

  defp target_scope(ws, proj, slug) do
    %{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: @dataset,
      type: "paper",
      doc_id: slug
    }
  end

  # ── 1. THE ESCALATION, REFUSED ──────────────────────────────────────────────

  describe "do_autosave/2 on a doc no grant admits for write" do
    test "REFUSES: nothing reaches the store, and the refusal is the TARGET arm, not the principal one",
         %{conn: conn, ws: ws, proj: proj} do
      {user, conn, write_grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @other_slug)

      # The doc IS reachable for READ — so a "nothing written" below is a
      # refusal, not the read-narrowing no-op.
      assert_read_reach!(view, @other_slug)

      socket = socket_of(view)

      # THE GRADE: a grant grade, not a share grade and not a membership.
      refute is_nil(socket.assigns[:caller_context])
      assert socket.assigns[:share_access] == nil
      assert %Barkpark.Accounts.User{} = socket.assigns[:current_user]

      # THE PRINCIPAL GATE ALONE WOULD HAVE ALLOWED THIS. Both halves asserted,
      # so the refusal below cannot be `write_denied?/1` in disguise.
      assert Paper.write_denied?(socket) == false
      assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true

      # …while the TARGET-aware predicate refuses, on every ACTIVE grant held.
      grants = Access.list_active_grants_for_grantee(user.id)
      assert write_grant.id in Enum.map(grants, & &1.id)

      refute Enum.any?(
               grants,
               &(Access.validate(&1, :write, target_scope(ws, proj, @other_slug)) == :ok)
             )

      # The seam has written nothing yet.
      assert draft_row(ws, proj, @other_slug) == {:error, :not_found}
      published_before = published_title(ws, proj, @other_slug)

      out =
        socket
        |> with_editor_doc(ws, proj, @other_slug)
        |> Shared.do_autosave(%{"title" => @escalated_title})

      # THE REFUSAL, in the vocabulary the sibling doors already speak:
      # `refuse_outside_grant/1` is the flash PLUS an honest `save_status`.
      # NOT "Saved".
      assert out.assigns.save_status == "Read-only"
      assert out.assigns.flash["error"] == @outside_grant_flash

      # THE STORE, RE-READ: no draft row was created at all…
      assert draft_row(ws, proj, @other_slug) == {:error, :not_found}
      assert draft_title(ws, proj, @other_slug) == nil

      # …and the published row never moved either.
      assert published_title(ws, proj, @other_slug) == published_before
      refute published_title(ws, proj, @other_slug) == @escalated_title

      # The refusal left the editor pointed at the doc it was pointed at — the
      # seam did not swap `editor_doc` for a freshly-minted draft.
      assert out.assigns.editor_doc.doc_id == @other_slug

      # And it did not spill onto the doc the grant DOES name.
      assert draft_row(ws, proj, @granted_slug) == {:error, :not_found}
    end
  end

  # ── 2. CONTAINMENT, NOT PARALYSIS ───────────────────────────────────────────

  describe "the SAME grantee, on the doc its grant DOES name" do
    test "still autosaves: save_status is Saved and the escalated title's legit twin is in the store",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn, _grant} = grantee_session(conn, ws, proj)
      view = open_paper!(conn, ws, proj, @granted_slug)
      assert_read_reach!(view, @granted_slug)

      assert draft_row(ws, proj, @granted_slug) == {:error, :not_found}

      out =
        view
        |> socket_of()
        |> with_editor_doc(ws, proj, @granted_slug)
        |> Shared.do_autosave(%{"title" => @legit_title})

      assert out.assigns.save_status == "Saved"
      refute out.assigns.flash["error"] == @outside_grant_flash

      # STORED, not merely assigned.
      assert draft_title(ws, proj, @granted_slug) == @legit_title

      {:ok, persisted} = draft_row(ws, proj, @granted_slug)
      assert get_in(persisted.content, ["preview", "title"]) == @legit_title

      # The doc outside the grant never moved while that succeeded.
      assert draft_row(ws, proj, @other_slug) == {:error, :not_found}
    end
  end

  # ── 3. INERT OFF THE GRANT PATH ─────────────────────────────────────────────

  describe "a MEMBERSHIP-graded socket" do
    test "is untouched by the new arm: an admin member autosaves the same doc the grantee could not",
         %{conn: conn, ws: ws, proj: proj} do
      {_user, conn} = member_session(conn, ws)
      view = open_paper!(conn, ws, proj, @other_slug)
      assert_read_reach!(view, @other_slug)

      socket = socket_of(view)

      # The two assigns that mean "this write descends from a GRANT" are both
      # absent — so `grant_target_denied?/3` short-circuits without a query.
      assert socket.assigns[:caller_context] == nil
      refute socket.assigns[:write_gate?] == true
      assert Paper.grant_target_denied?(socket, "paper", @other_slug) == false

      out =
        socket
        |> with_editor_doc(ws, proj, @other_slug)
        |> Shared.do_autosave(%{"title" => @member_title})

      assert out.assigns.save_status == "Saved"
      assert draft_title(ws, proj, @other_slug) == @member_title
    end
  end
end
