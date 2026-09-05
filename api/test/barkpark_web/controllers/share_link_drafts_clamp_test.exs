defmodule BarkparkWeb.ShareLinkDraftsClampTest do
  @moduledoc """
  A share link's `ref_id` is a PUBLISHED id — on BOTH doors onto the surface.

  `share_link_controller.ex`'s moduledoc asserted this from the feature commit
  (b523b2e3a4, 2026-06-09) while nothing in that file checked the prefix: the
  normalisation existed only as an inline `String.replace_prefix/3` on the
  Studio LiveView door (`item_share.ex`), so the HTTP mint never had it. The
  clamp now lives at `Sharing.Links.published_ref_id/1`, the boundary BOTH doors
  cross.

  These tests exist to make a one-door repair impossible: every case binding the
  HTTP door has a Studio twin, and vice versa. A future change that fixes one
  and not the other reds here.
  """
  # sync: swaps node-global Application env (:barkpark, :shares) — one value for the whole node
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}
  alias Barkpark.Repo
  alias Barkpark.Sharing.{Links, ShareLink}
  alias BarkparkWeb.Studio.StudioLive.Handlers.ItemShare

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "sl-clamp-admin"

  @published_body "PUBLISHED-BODY-VISIBLE"
  @draft_secret "DRAFT-ONLY-SECRET-XYZZY"

  setup %{conn: conn} do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, admin_tok} =
      Auth.create_token(@admin, "sl-clamp", @dataset, ["read", "write", "admin"])

    ws = create_workspace!("clamp-ws")
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
    proj = create_project!(ws, "clamp-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # A PUBLISHED paper, then a dirty draft at drafts.<slug> carrying different
    # content — the state a paper sits in while somebody is editing it.
    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "clamp-paper",
          "title" => "Public Title",
          "content" =>
            Barkpark.LabelFixtures.with_registered_labels(
              %{"body_html" => "<h1>#{@published_body}</h1>"},
              @dataset
            )
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("clamp-paper", "paper", @dataset, scope)

    {:ok, draft} =
      Content.upsert_document(
        "paper",
        %{
          "doc_id" => "clamp-paper",
          "title" => "Draft Title",
          "content" =>
            Barkpark.LabelFixtures.with_registered_labels(
              %{"body_html" => "<h1>#{@draft_secret}</h1>"},
              @dataset
            )
        },
        @dataset,
        scope
      )

    # FIXTURE GUARD: without a real drafts. row every assertion below is vacuous
    # — a clamp trivially "holds" when there is no draft to resolve.
    assert draft.doc_id == "drafts.clamp-paper"

    Application.delete_env(:barkpark, :shares)

    %{
      conn: conn,
      ws: ws,
      proj: proj,
      admin_tok: admin_tok,
      scope: scope,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}"
    }
  end

  defp admin(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@admin}")
      |> put_req_header("content-type", "application/json")

  defp mint(conn, scope_str, ref_id) do
    conn
    |> admin()
    |> post("/v1/shares/links", %{
      scope: scope_str,
      kind: "doc",
      ref_type: "paper",
      ref_id: ref_id,
      access: "read"
    })
  end

  # ── the shared implementation ─────────────────────────────────────────────

  describe "Links.published_ref_id/1" do
    test "strips the prefix, leaves a clean id alone, and is total" do
      assert Links.published_ref_id("drafts.clamp-paper") == "clamp-paper"
      assert Links.published_ref_id("clamp-paper") == "clamp-paper"
      # Only a LEADING prefix — an id that merely contains the word is untouched.
      assert Links.published_ref_id("my-drafts.notes") == "my-drafts.notes"
      # Total: a non-binary comes back for the changeset to reject, never raises.
      assert Links.published_ref_id(nil) == nil
    end
  end

  # ── DOOR 1: the HTTP mint ─────────────────────────────────────────────────

  describe "HTTP mint" do
    test "persists the PUBLISHED id when handed a drafts.-prefixed ref", ctx do
      body = ctx.conn |> mint(ctx.scope_str, "drafts.clamp-paper") |> json_response(201)

      assert body["link"]["ref_id"] == "clamp-paper",
             "the mint stored a draft ref: #{inspect(body["link"])}"

      row = Repo.get_by!(ShareLink, workspace_id: ctx.ws.id)
      assert row.ref_id == "clamp-paper", "the ROW carries a draft ref: #{row.ref_id}"
    end

    test "refuses a paper that exists ONLY as a draft, rather than minting a dead link", ctx do
      {:ok, only_draft} =
        Content.upsert_document(
          "paper",
          %{
            "doc_id" => "never-published",
            "title" => "Only A Draft",
            "content" =>
              Barkpark.LabelFixtures.with_registered_labels(
                %{"body_html" => "<h1>#{@draft_secret}</h1>"},
                @dataset
              )
          },
          @dataset,
          ctx.scope
        )

      assert only_draft.doc_id == "drafts.never-published"

      # Existence is validated against the id that will actually be STORED, so
      # this is a 422 — not a 201 pointing at a published row that never existed.
      resp = mint(ctx.conn, ctx.scope_str, "drafts.never-published")
      assert resp.status == 422, "expected 422, got #{resp.status}: #{resp.resp_body}"

      refute Repo.get_by(ShareLink, workspace_id: ctx.ws.id),
             "a link row was persisted for a never-published paper"
    end

    test "an ordinary published ref is unaffected", ctx do
      body = ctx.conn |> mint(ctx.scope_str, "clamp-paper") |> json_response(201)
      assert body["link"]["ref_id"] == "clamp-paper"
    end
  end

  # ── DOOR 2: the Studio LiveView handler ───────────────────────────────────

  describe "Studio item-share handler" do
    test "opens the pane on the PUBLISHED id", %{ws: ws, admin_tok: admin_tok} do
      # `Caps.admin?/1` reads :api_token / :current_user — NOT a :caps assign. A
      # socket that merely LOOKED admin would send the handler down its flash
      # branch and the ref_id assertion below would prove nothing.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_workspace: ws,
          current_project: nil,
          current_user: nil,
          api_token: admin_tok,
          dataset: @dataset
        }
      }

      {:noreply, out} =
        ItemShare.item_share_open(
          %{"kind" => "doc", "ref-type" => "paper", "ref-id" => "drafts.clamp-paper"},
          socket
        )

      # GATE CONTROL: if the admin check had failed we would be on the flash
      # branch with no :item_share at all, and the next assertion is vacuous.
      assert out.assigns[:item_share_open] == true,
             "the socket did not pass Caps.admin?/1 — this control proves nothing"

      assert out.assigns.item_share.ref_id == "clamp-paper"
    end
  end

  # ── the READ path: rows minted BEFORE the clamp existed ───────────────────

  describe "already-issued links" do
    setup ctx do
      # Insert a row DIRECTLY, bypassing create/1 — this is what a link minted
      # before the clamp landed looks like at rest. Fixing only the write path
      # would leave every one of these live.
      raw = "legacy" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      row =
        Repo.insert!(%ShareLink{
          workspace_id: ctx.ws.id,
          project_id: ctx.proj.id,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: "drafts.clamp-paper",
          access: "read",
          # Only the digest — the plaintext column was retired
          # (arpss-w8-bl-share-link-raw-token-at-rest). `resolve/1` has always
          # matched on the hash, so `raw` still reaches this row.
          token_hash: Links.hash_token(raw)
        })

      assert row.ref_id == "drafts.clamp-paper"
      Map.put(ctx, :legacy_token, raw)
    end

    test "an anonymous /s/:token does not resolve the draft", ctx do
      # A BARE conn — no token, no session, no share header. Anonymous.
      anon = Phoenix.ConnTest.build_conn() |> get("/s/#{ctx.legacy_token}")

      assert anon.status in [200, 302], "unexpected status #{anon.status}"

      if anon.status == 302 do
        [loc] = Plug.Conn.get_resp_header(anon, "location")

        refute loc =~ "drafts.clamp-paper", "the redirect still carries the draft id: #{loc}"

        followed = Phoenix.ConnTest.build_conn() |> get(loc)
        refute followed.resp_body =~ @draft_secret, "the scoped reader served draft bytes"
      else
        refute anon.resp_body =~ @draft_secret, "the static render served draft bytes"
      end
    end
  end

  # ── arpss-w8-bl-links-context-boundary-predicate: ONE predicate, both doors ─

  describe "Links.revoke_scoped/2" do
    setup ctx do
      body = ctx.conn |> mint(ctx.scope_str, "clamp-paper") |> json_response(201)
      Map.put(ctx, :link_id, body["link"]["id"])
    end

    test "a foreign-workspace admin cannot revoke, and the denial is a plain not_found", ctx do
      other_ws = create_workspace!("clamp-other-ws")

      {:ok, foreign_tok} =
        Auth.create_token("sl-clamp-foreign", "sl-clamp-f", @dataset, ["read", "write", "admin"])

      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(other_ws.id, foreign_tok.id, "admin")

      assert Links.revoke_scoped(foreign_tok, ctx.link_id) == {:error, :not_found}

      # Byte-identical to a missing row — no existence oracle.
      assert Links.revoke_scoped(foreign_tok, Ecto.UUID.generate()) == {:error, :not_found}
      # And no 500 from an uncast :binary_id.
      assert Links.revoke_scoped(foreign_tok, "not-a-uuid") == {:error, :not_found}
      assert Links.revoke_scoped(nil, ctx.link_id) == {:error, :not_found}

      refute Repo.get!(ShareLink, ctx.link_id).revoked_at, "the link was revoked anyway"
    end

    test "the workspace's own admin revokes through the same function", ctx do
      assert {:ok, revoked} = Links.revoke_scoped(ctx.admin_tok, ctx.link_id)
      assert revoked.revoked_at
    end

    test "a socket's principal LIST is accepted, so the Studio door shares the predicate", ctx do
      # The socket shape: an api_token session and/or a logged-in account. The
      # HTTP door passes a bare principal; that is the only difference between
      # them, and it is why ONE function can serve both.
      assert Links.workspace_admin?([nil, ctx.admin_tok], ctx.ws.id)
      refute Links.workspace_admin?([nil, nil], ctx.ws.id)
      refute Links.workspace_admin?([ctx.admin_tok], nil)
    end
  end
end
