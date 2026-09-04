defmodule BarkparkWeb.PaperAttributionTest do
  @moduledoc """
  Edit-on-the-link slice 4 (task-e99a8e946f80f52c, epic task-a19eeb215f653529),
  criterion 1: *"Each op applied via the reader carries the principal and it is
  visible on the paper revision history."*

  Two halves, and the second is the one that was actually missing.

  **Carries the principal.** `BulldocsLive.Edit` builds a `CallerContext` from
  the socket and stamps the attribution actor on it, so the op path knows who
  is writing. Proved per principal: a write token records
  `actor_kind: "api_token"` plus the token's own id, an account session records
  `"user"` plus the user id.

  **Visible on the revision history.** Before this slice
  `apply_paper_block_op/4` wrote NO revision at all — the block-op path saved
  history only for a caller passing `:revision_action`, and nobody on the
  reader did. So an edit made on a shared link left the paper changed and
  version history silent. The reader now opts in, and these tests read the row
  back through the SURFACED history read (`Content.list_revisions/4`, behind
  `GET /v1/data/history/...`) rather than by querying the table, so a row that
  exists but is not visible still reds.

  The anonymous arm is asserted where it actually lives: the slice-2 gate. An
  anonymous viewer never reaches the op path, so there is no anonymous revision
  to attribute — the proof is that no revision appears at all.

  `async: false` — the Default scope is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.BulldocsLive.Edit
  alias BarkparkWeb.PaperActor

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()
    slug = "eol-attr-#{System.unique_integer([:positive])}"
    seed_block_paper!(slug)

    %{conn: conn, slug: slug, default_ws: default_ws, default_proj: default_proj}
  end

  defp seed_block_paper!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Attribution probe",
          "blocks" => [
            %{"id" => "b-head", "type" => "heading", "text" => "Attribution probe", "level" => 1},
            %{
              "id" => "b-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body text"}]
            },
            %{
              "id" => "b-extra",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Spare block"}]
            }
          ]
        })
      )

    paper
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  defp write_token!(conn) do
    raw = "eol-attr-writer-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "eol attr writer", @dataset, ["read", "write"])
    {token, as_token(conn, raw)}
  end

  defp user_session!(conn, memberships) do
    email = "attr-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- memberships do
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # THE READ SURFACE, not the table. `Content.list_revisions/4` is what
  # `GET /v1/data/history/:dataset/:type/:doc_id` serves.
  defp history(slug), do: Content.list_revisions(slug, "paper", @dataset, limit: 50)

  # The rows THIS slice produced. Seeding the fixture with `upsert_paper/1`
  # already leaves a "create" row (`save_upsert_revision`), which is history
  # working correctly and not what these tests are about.
  defp reader_history(slug), do: Enum.filter(history(slug), &(&1.action == "edit-on-link"))

  defp edit_body(view, text) do
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "b-body",
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    })
  end

  defp block_text(slug, id) do
    case Content.get_public_paper(slug, @dataset) do
      %{content: %{"blocks" => blocks}} ->
        blocks
        |> Enum.find(&(Map.get(&1, "id") == id))
        |> case do
          %{"content" => [%{"value" => value} | _]} -> value
          other -> other
        end

      _ ->
        nil
    end
  end

  describe "an api token editing on the link" do
    test "the revision history names the token, by kind and id", %{conn: conn, slug: slug} do
      {token, conn} = write_token!(conn)

      assert reader_history(slug) == []

      {:ok, view, _html} = live(conn, "/papers/#{slug}")
      assert assigns_of(view).can_edit? == true

      edit_body(view, "Edited by a token")

      assert block_text(slug, "b-body") == "Edited by a token"

      assert [rev] = reader_history(slug)
      assert rev.actor_kind == "api_token"
      assert rev.actor_id == token.id
      # The action says HOW the edit arrived, which is the distinction the
      # slice exists to make visible.
      assert rev.action == "edit-on-link"
      # The snapshot is the post-edit content, not an empty attribution stub.
      assert rev.content["blocks"] |> Enum.any?(&(&1["id"] == "b-body"))
    end

    test "every accepted op leaves its own attributed row", %{conn: conn, slug: slug} do
      {token, conn} = write_token!(conn)
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      edit_body(view, "First")
      edit_body(view, "Second")
      edit_body(view, "Third")

      rows = reader_history(slug)
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.actor_kind == "api_token"))
      assert Enum.all?(rows, &(&1.actor_id == token.id))
    end

    test "an op the paper REFUSES writes no revision", %{conn: conn, slug: slug} do
      {_token, conn} = write_token!(conn)
      {:ok, view, _html} = live(conn, "/papers/#{slug}")

      # No such block — the op path returns an error before any write.
      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-does-not-exist",
        "patch" => %{"content" => [%{"type" => "text", "value" => "nope"}]}
      })

      assert reader_history(slug) == []
      assert block_text(slug, "b-body") == "Original body text"
    end
  end

  describe "an account session editing on the link" do
    test "the revision history names the user, by kind and id", %{
      conn: conn,
      slug: slug,
      default_ws: default_ws
    } do
      {user, conn} = user_session!(conn, [{default_ws, "member"}])

      {:ok, view, _html} = live(conn, "/papers/#{slug}")
      assert assigns_of(view).can_edit? == true

      edit_body(view, "Edited by a user")

      assert [rev] = reader_history(slug)
      assert rev.actor_kind == "user"
      assert rev.actor_id == user.id
      # The label carries the human identity the reader already resolved.
      assert rev.actor_label == user.email
      # The legacy single-column actor stays in step rather than going quiet.
      assert rev.actor_user_id == user.id
    end
  end

  describe "an anonymous viewer" do
    test "never reaches the op path, so there is nothing to attribute", %{
      conn: conn,
      slug: slug
    } do
      {:ok, view, _html} = live(conn, "/papers/#{slug}")
      assert assigns_of(view).can_edit? == false

      render_hook(view, "paper-op", %{
        "op" => "patch-block",
        "id" => "b-body",
        "patch" => %{"content" => [%{"type" => "text", "value" => "hijacked"}]}
      })

      # The slice-2 gate refused it: same copy, no write, no history.
      assert (assigns_of(view).flash || %{})["error"] == Edit.denial()
      assert block_text(slug, "b-body") == "Original body text"
      assert reader_history(slug) == []
    end
  end

  describe "the actor mapping itself" do
    test "each viewer kind maps to one storage vocabulary term" do
      assert PaperActor.from_viewer(%{kind: :user, id: "u1", label: "a@b.c"}) ==
               %{kind: "user", id: "u1", label: "a@b.c"}

      assert PaperActor.from_viewer(%{kind: :token, id: "t1", label: "ci"}) ==
               %{kind: "api_token", id: "t1", label: "ci"}

      assert PaperActor.from_viewer(%{kind: :share, grant: :item, id: "s1"}) ==
               %{kind: "share", id: "s1", label: nil}

      assert PaperActor.from_viewer(%{kind: :anonymous}) == PaperActor.anonymous()
      # Total: an unknown shape is under-attributed, never mis-attributed.
      assert PaperActor.from_viewer(%{kind: :something_new, id: "x"}) == PaperActor.anonymous()
      assert PaperActor.from_viewer(nil) == PaperActor.anonymous()
    end

    test "the actor stamp never widens access" do
      share = CallerContext.with_actor(CallerContext.anonymous(), %{kind: "share", id: "s1"})

      # Named on the row...
      assert CallerContext.actor_stamp(share) == %{
               actor_kind: "share",
               actor_id: "s1",
               actor_label: nil
             }

      # ...and still the anonymous principal for every access decision.
      assert share.principal_type == :anonymous
      assert share.is_admin == false
      assert share.user_id == nil
    end

    test "an unstamped context still yields an honest triple" do
      assert CallerContext.actor_stamp(CallerContext.anonymous()) == %{
               actor_kind: "anonymous",
               actor_id: nil,
               actor_label: nil
             }

      assert CallerContext.actor_stamp(%CallerContext{principal_type: :user, user_id: "u9"}) ==
               %{actor_kind: "user", actor_id: "u9", actor_label: nil}

      assert CallerContext.actor_stamp(%CallerContext{principal_type: :api_token, token_id: "t9"}) ==
               %{actor_kind: "api_token", actor_id: "t9", actor_label: nil}

      # A caller that never learned about attribution passes no context at all.
      assert CallerContext.actor_stamp_from_opts([]) == %{
               actor_kind: "anonymous",
               actor_id: nil,
               actor_label: nil
             }
    end
  end
end
