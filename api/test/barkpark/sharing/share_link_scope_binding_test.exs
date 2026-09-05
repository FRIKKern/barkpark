defmodule Barkpark.Sharing.ShareLinkScopeBindingTest do
  @moduledoc """
  task-2da739b78e938be0 — a ShareLink bound to no project is revocable by nothing.

  `Links.revoke_scope/3` is THE cascade: `Sharing.remove_share/3` calls it when an
  operator withdraws a section share, and it matches the
  `(workspace_id, project_id, dataset)` triple EXACTLY. An `l.project_id ==
  ^proj_id` comparison is NULL-valued — never true — for a row whose
  `project_id` is nil, so such a row is not a sibling-scope survivor the cascade
  deliberately spares: it is a row NO scope names and NO revocation an operator
  can perform will ever reach.

  `ShareLink.changeset/2` used to `validate_required` NEITHER tenant id and both
  columns are NULLABLE in `share_links`, so the row was persistable. The Studio
  door is the one that could supply the nil — `Shared.item_link_attrs/3` spells
  it `socket.assigns[:current_project] && …` — while the HTTP door
  (`ShareLinkController.mint/2`) resolves a `%Tenancy.Project{}` before it builds
  attrs and never could.

  These tests pin the remedy at three depths:

    * THE SHAPE — a workspace with no projects really does resolve to a nil
      `current_project`, and the Studio mint attrs really do carry `project_id:
      nil` for it. Without this the refusals below could be vacuous.
    * THE WRITE — `Links.create/1` (i.e. `ShareLink.changeset/2`, the one
      changeset BOTH doors cross) refuses it, and the Studio handler refuses it
      first with a reason. Non-vacuity: the same handler still mints when a
      project IS in context.
    * THE READ — a row that predates the changeset rule (inserted around it, as
      a legacy row would be) is inert: `revoke_scope/3` provably cannot reach it,
      so `resolve/1` refuses it instead.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Sharing.Links
  alias Barkpark.Sharing.ShareLink
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.StudioLive.Handlers.ItemShare
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"

  setup do
    uniq = System.unique_integer([:positive])

    # A workspace with NO projects — the shape `Shared.initial_project/1` and
    # `StudioChrome.project_for/1` (its byte-twin) both answer nil for, and the
    # only socket shape from which the Studio mint can hand `create/1` a nil.
    empty_ws = create_workspace!("unbound-empty-ws-#{uniq}")

    # A normal, fully-scoped workspace — the non-vacuity control.
    ws = create_workspace!("unbound-ws-#{uniq}")
    proj = create_project!(ws, "unbound-proj-#{uniq}")

    {:ok, token} =
      Auth.create_token(
        "unbound-admin-#{uniq}",
        "unbound project mint",
        @dataset,
        ["read", "write", "admin"]
      )

    # A real ADMIN seat in BOTH — `Caps.admin?/1` is `token_admin?` AND an
    # admin-conferring membership ROLE on the MOUNTED workspace, so without
    # these the handler would deny on admin and prove nothing about scope.
    {:ok, _} = TenancyAuth.create_membership(empty_ws.id, token.id, "admin")
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin")

    %{empty_ws: empty_ws, ws: ws, proj: proj, token: token}
  end

  defp item(ref_id), do: %{kind: "doc", ref_type: "paper", ref_id: ref_id, title: ref_id}

  defp socket(token, workspace, project, item) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        api_token: token,
        current_user: nil,
        current_workspace: workspace,
        current_project: project,
        dataset: @dataset,
        item_share: item,
        item_share_open: true,
        item_share_links: [],
        item_share_error: nil
      }
    }
  end

  defp links_in(ws_id, ref_id) do
    ShareLink
    |> where([l], l.workspace_id == ^ws_id and l.ref_id == ^ref_id)
    |> Repo.all()
  end

  # ── THE SHAPE ─────────────────────────────────────────────────────────────

  test "a workspace with no projects resolves to a nil current_project", %{empty_ws: empty_ws} do
    assert Shared.initial_project(empty_ws) == nil
  end

  test "the Studio mint attrs carry project_id: nil for that socket", %{
    empty_ws: empty_ws,
    token: token
  } do
    attrs = Shared.item_link_attrs(socket(token, empty_ws, nil, item("p1")), item("p1"), "read")

    assert attrs.workspace_id == empty_ws.id
    # THE nil the whole row is about — reported faithfully, never invented away.
    assert attrs.project_id == nil
  end

  # ── THE WRITE ─────────────────────────────────────────────────────────────

  test "REFUSED: Links.create/1 will not persist a link with a nil project_id", %{ws: ws} do
    attrs = %{
      workspace_id: ws.id,
      project_id: nil,
      dataset: @dataset,
      kind: "doc",
      ref_type: "paper",
      ref_id: "nil-project-ref",
      access: "read"
    }

    assert {:error, changeset} = Links.create(attrs)
    assert "can't be blank" in errors_on(changeset).project_id
    assert links_in(ws.id, "nil-project-ref") == []
  end

  test "REFUSED: Links.create/1 will not persist a link with a nil workspace_id", %{proj: proj} do
    attrs = %{
      workspace_id: nil,
      project_id: proj.id,
      dataset: @dataset,
      kind: "doc",
      ref_type: "paper",
      ref_id: "nil-workspace-ref",
      access: "read"
    }

    assert {:error, changeset} = Links.create(attrs)
    assert "can't be blank" in errors_on(changeset).workspace_id
  end

  test "REFUSED AT THE DOOR: an item-share mint with no :current_project mints nothing", %{
    empty_ws: empty_ws,
    token: token
  } do
    it = item("unbound-paper")

    {:noreply, out} =
      ItemShare.item_share_create(%{"access" => "read"}, socket(token, empty_ws, nil, it))

    assert out.assigns.item_share_error =~ "No project in context"
    assert links_in(empty_ws.id, "unbound-paper") == []
  end

  test "NON-VACUOUS: the same door still mints when a project IS in context", %{
    ws: ws,
    proj: proj,
    token: token
  } do
    it = item("bound-paper")

    {:noreply, out} =
      ItemShare.item_share_create(%{"access" => "read"}, socket(token, ws, proj, it))

    assert out.assigns.item_share_error == nil
    assert [%ShareLink{project_id: pid}] = links_in(ws.id, "bound-paper")
    assert pid == proj.id
  end

  # ── THE READ (rows that predate the changeset rule) ───────────────────────

  describe "a row already in the table with a nil project_id" do
    setup %{ws: ws} do
      raw = "legacy-unbound-#{System.unique_integer([:positive])}"

      # Inserted AROUND the changeset — exactly how a row minted before this
      # rule sits in `share_links` today. `Links.create/1` can no longer make one.
      row =
        Repo.insert!(%ShareLink{
          # Only the digest — the plaintext column was retired
          # (arpss-w8-bl-share-link-raw-token-at-rest). `resolve/1` has always
          # matched on the hash, so this legacy row is reached the same way.
          token_hash: Links.hash_token(raw),
          workspace_id: ws.id,
          project_id: nil,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: "legacy-unbound-ref",
          access: "read"
        })

      %{raw: raw, row: row}
    end

    test "THE DEFECT: the section-share cascade cannot reach it", %{
      ws: ws,
      proj: proj,
      row: row
    } do
      # The operator's ONLY revocation affordance for this scope, run at full
      # strength — and the unbound row is untouched by it.
      assert {:ok, _count} = Links.revoke_scope(ws.slug, proj.slug, @dataset)
      assert %ShareLink{revoked_at: nil} = Repo.get!(ShareLink, row.id)
    end

    test "THE CLAMP: it no longer resolves, so it serves nothing", %{raw: raw} do
      assert Links.resolve(raw) == {:error, :not_found}
    end

    test "NON-VACUOUS: a BOUND row under the same workspace still resolves", %{
      ws: ws,
      proj: proj
    } do
      {:ok, {bound_raw, _link}} =
        Links.create(%{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: "bound-resolves",
          access: "read"
        })

      assert {:ok, %ShareLink{ref_id: "bound-resolves"}} = Links.resolve(bound_raw)
    end
  end
end
