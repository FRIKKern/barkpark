defmodule BarkparkWeb.Live.ShareLinkRevocationTeardownTest do
  @moduledoc """
  task-972d97ffd2e468d9 — revoking or expiring a share link did not tear down
  an ALREADY-OPEN reader socket. `/s/<token>` and a fresh dead render went
  dark immediately on revoke (`Links.resolve/1` filters `revoked_at` +
  `expires_at` on every query), but a socket that had already mounted over
  the link kept streaming every live per-block update for the rest of its
  life — `PluginScopeSession.item_token_binds?/2`'s own comment said a
  revoked link "fails here on the next mount," and nothing ran it again
  while the socket stayed connected.

  ## The fix

  `PluginScopeSession.on_mount/4` now arms a periodic liveness re-check for
  every CONNECTED, anonymously item-share-granted mount: `Process.send_after/3`
  schedules `{BarkparkWeb.PluginScopeSession, :share_liveness_check}` to
  itself, and an `attach_hook/4` on `:handle_info` re-runs the EXACT SAME
  `confine_item_share/3` predicate mount already uses against the params and
  session captured at arm-time. Success re-arms the timer; failure reuses the
  module's own `deny/1` path (flash + full redirect), terminating the socket.
  `Links.resolve/1` already filters `expires_at` in its query, so expiry rides
  the identical mechanism — proven below rather than assumed.

  Tests send the message DIRECTLY (`send(view.pid, ...)`) rather than waiting
  out the real interval — exactly the idiom `studio_live_read_liveness_test.exs`
  uses for its own `:access_expiry_tick`.

  `async: true` — each test owns a fresh workspace/project/paper/link; no
  shared process-global state.
  """
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Sharing.Links
  alias Barkpark.Tenancy
  alias BarkparkWeb.PluginScopeSession

  @dataset "production"
  @original_body "ORIGINAL-BODY"
  @liveness_msg {BarkparkWeb.PluginScopeSession, :share_liveness_check}

  setup %{conn: conn} do
    ws = create_workspace!("revoke-teardown-ws-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "revoke-teardown-proj"})
    slug = "revoke-teardown-paper-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Revocation Teardown Paper",
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => @original_body}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    %{conn: conn, ws: ws, proj: proj, slug: slug}
  end

  defp mint_link!(ws, proj, ref_id) do
    {:ok, {raw, link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "paper",
        ref_id: ref_id,
        access: "read"
      })

    {raw, link}
  end

  defp paper_path(ws, proj, slug), do: "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}"

  defp append_block_op(id, text) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    }
  end

  describe "revoking the link tears down the already-open reader socket" do
    test "a live tick after revoke redirects the connected socket instead of streaming on", %{
      conn: conn,
      ws: ws,
      proj: proj,
      slug: slug
    } do
      {raw, link} = mint_link!(ws, proj, slug)

      {:ok, view, html} = live(conn, paper_path(ws, proj, slug) <> "?share=#{raw}")
      assert html =~ @original_body

      {:ok, _} = Links.revoke(link.id)

      # The revoke call itself does not touch the open socket — it is the
      # TICK that tears it down, not a broadcast from `revoke/1`. Asserting
      # this BEFORE the tick proves the teardown below is the liveness
      # mechanism, not some other side channel.
      assert Process.alive?(view.pid)

      send(view.pid, @liveness_msg)

      assert_redirect(view, "/login")
    end
  end

  describe "expiry tears down the socket through the SAME mechanism (no second code path)" do
    test "a live tick after expires_at has passed redirects the connected socket", %{
      conn: conn,
      ws: ws,
      proj: proj,
      slug: slug
    } do
      {raw, link} = mint_link!(ws, proj, slug)

      {:ok, view, html} = live(conn, paper_path(ws, proj, slug) <> "?share=#{raw}")
      assert html =~ @original_body

      # Advance the link PAST its expiry WITHOUT ever calling `revoke/1` — the
      # only door this opens is `Links.resolve/1`'s own `expires_at` filter,
      # which is the same query the revocation case above also fails through.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      {:ok, _} = link |> Ecto.Changeset.change(expires_at: past) |> Repo.update()

      send(view.pid, @liveness_msg)

      assert_redirect(view, "/login")
    end
  end

  describe "the tick is a no-op while the link stays valid" do
    test "an un-revoked, un-expired link survives the tick and keeps streaming per-block updates",
         %{conn: conn, ws: ws, proj: proj, slug: slug} do
      {raw, _link} = mint_link!(ws, proj, slug)

      {:ok, view, html} = live(conn, paper_path(ws, proj, slug) <> "?share=#{raw}")
      assert html =~ @original_body

      send(view.pid, @liveness_msg)
      # `render/1` is a synchronous round-trip, so it only returns once the
      # async tick above has already been processed by this same process's
      # mailbox (FIFO) — the same flush idiom `studio_live_read_liveness_test`
      # uses for its own tick.
      assert is_binary(render(view))
      :ok = refute_redirected(view, "/login")
      assert Process.alive?(view.pid)

      # PROVES the attached `:handle_info` hook did not swallow the stage for
      # everyone else: a REAL per-block delta, broadcast through the actual
      # `Content` write path BulldocsLive subscribes to, still reaches and
      # renders on this share-granted socket once the liveness hook is on it.
      {:ok, _} =
        Content.apply_paper_block_op(
          slug,
          append_block_op("b2", "LIVE-UPDATE-BODY"),
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      assert render(view) =~ "LIVE-UPDATE-BODY"
    end
  end

  describe "the tick is armed only for a CONNECTED share-granted mount" do
    test "a dead render schedules no timer; a connected mount attaches the hook", %{
      conn: conn,
      ws: ws,
      proj: proj,
      slug: slug
    } do
      {raw, _link} = mint_link!(ws, proj, slug)

      dead = get(conn, paper_path(ws, proj, slug) <> "?share=#{raw}")
      assert dead.status == 200

      session = PluginScopeSession.build(dead)
      params = %{"slug" => slug}

      disconnected = bare_socket()

      assert {:cont, disconnected_out} =
               PluginScopeSession.on_mount(:scope, params, session, disconnected)

      refute Map.has_key?(disconnected_out.assigns, :__plugin_scope_session_share_liveness__)

      assert {:cont, connected_out} =
               PluginScopeSession.on_mount(:scope, params, session, connected_bare_socket())

      assert Map.has_key?(connected_out.assigns, :__plugin_scope_session_share_liveness__)
    end
  end

  # `deny/1` puts a flash, so the socket needs the assigns a real mount carries.
  defp bare_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  # `attach_hook/4` (called only on the CONNECTED arm) requires the `:lifecycle`
  # private key a real mount always seeds before any `on_mount` hook runs
  # (`Phoenix.LiveView.Static`/`Channel` populate it ahead of the hook chain);
  # `bare_socket/0` alone omits it, so the connected-socket case needs it too.
  defp connected_bare_socket do
    %{bare_socket() | transport_pid: self(), private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}}
  end
end
