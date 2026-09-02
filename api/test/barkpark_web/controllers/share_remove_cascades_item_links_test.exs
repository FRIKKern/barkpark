defmodule BarkparkWeb.ShareRemoveCascadesItemLinksTest do
  @moduledoc """
  arpss-w8 — THE KILL SWITCH MUST KILL. `Barkpark.Sharing.remove_share/3` used
  to hard-revoke only the scoped-share EDIT TOKENS and never touch the
  `share_links` table, so every ITEM `/s/<token>` link minted under the removed
  scope kept serving. Those links are stable and re-copyable and may already sit
  in a chat or a document: an operator who removed a share believed access was
  withdrawn and it was not.

  RULED CASCADE (lead-security-r, orchestrator-delegated security lead,
  2026-09-02): removing a section share revokes every item ShareLink minted
  under the same `(workspace, project, dataset)` scope. Item links derive their
  authority from the section share they were minted under, so they fall with it.
  Revocation is fail-closed — a link that outlives the share it came from is a
  leak the operator cannot see.

  THE NEGATIVE ARMS ARE THE OTHER HALF OF THE RULING. The cascade matches the
  triple EXACTLY, so a link in a SIBLING PROJECT and a link in a SIBLING DATASET
  both keep serving 200. Without them the cascade could pass by revoking
  everything in sight, which is a different bug wearing this test's green.

  `async: false`: the module mutates the process-global `:barkpark, :shares` /
  `:shares_env` env (snapshotted and restored on_exit).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Media, Sharing}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing.{Links, ShareLink}

  import Barkpark.TenancyFixtures

  @dataset "production"
  @sibling_dataset "staging"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    # D13: shares are planted through `add_share/1`, never a bare put_env — any
    # later add/remove recomputes `:shares` from `shares_env() ++ list_stored()`
    # and would ERASE a put_env-planted fixture mid-test.
    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    ws = create_workspace!("cascade-ws")
    victim = create_project!(ws, "victim-proj")
    sibling = create_project!(ws, "sibling-proj")

    victim_scope = [workspace_id: ws.id, project_id: victim.id]
    sibling_scope = [workspace_id: ws.id, project_id: sibling.id]

    seed_post!(victim_scope, "victim-post", "Victim Post")
    seed_post!(sibling_scope, "sibling-post", "Sibling Post")

    # The sibling-DATASET arm rides a media link: a media serve is not dataset
    # filtered on read, so the link's own `dataset` is the only thing that can
    # exclude it from the cascade — which is exactly what is under test.
    sibling_ds_media = put_media!(ws, victim, @sibling_dataset)

    %{
      ws: ws,
      victim: victim,
      sibling: sibling,
      victim_scope: victim_scope,
      sibling_scope: sibling_scope,
      sibling_ds_media: sibling_ds_media
    }
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp seed_post!(scope, doc_id, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => doc_id, "title" => title}, @dataset, scope)

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)
  end

  defp put_media!(ws, proj, dataset) do
    name = "cascade-#{System.unique_integer([:positive])}.png"
    rel = "uploads/share-cascade-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "PNG-BYTES")
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: 9,
      dataset: dataset,
      workspace_id: ws.id,
      project_id: proj.id
    })
    |> Repo.insert!()
  end

  # Mints through the CONTEXT, not the HTTP door: the mint is not what is under
  # test here and the controller's admin ceremony would only add fixture surface
  # that can fail for reasons unrelated to the cascade.
  defp mint!(attrs) do
    {:ok, {raw, link}} = Links.create(attrs)
    {raw, link}
  end

  defp doc_link!(ws, proj, dataset, ref_id) do
    mint!(%{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: dataset,
      kind: "doc",
      ref_type: "post",
      ref_id: ref_id,
      access: "read"
    })
  end

  defp media_link!(ws, proj, dataset, media) do
    mint!(%{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: dataset,
      kind: "media",
      ref_id: media.id,
      access: "read"
    })
  end

  defp status_of(token), do: get(build_conn(), "/s/#{token}").status

  defp revoked_at(%ShareLink{id: id}), do: Repo.get!(ShareLink, id).revoked_at

  # ── THE CASCADE ───────────────────────────────────────────────────────────

  describe "remove_share/3 cascades into item links" do
    test "an item link under the removed scope is revoked and /s/:token 404s", %{
      ws: ws,
      victim: victim
    } do
      {:ok, _} = Sharing.add_share("#{ws.slug}/#{victim.slug}/#{@dataset}:docs:read")
      {token, link} = doc_link!(ws, victim, @dataset, "victim-post")

      # BEFORE: the link serves the bound document.
      assert status_of(token) == 200
      assert is_nil(revoked_at(link))

      assert {:ok, 1} = Sharing.remove_share(ws.slug, victim.slug, @dataset)

      # AFTER: the row is stamped and the public URL is indistinguishable from
      # a link that never existed.
      refute is_nil(revoked_at(link))
      assert status_of(token) == 404
      assert Links.resolve(token) == {:error, :not_found}
    end

    test "the cascade runs even when NO stored share row was deleted (removed: 0)", %{
      ws: ws,
      victim: victim
    } do
      # No `add_share/1` — the scope is env-only or already gone. This is the
      # path that most reads like a no-op, and gating the cascade on the delete
      # count is exactly how the hole would come back.
      {token, _link} = doc_link!(ws, victim, @dataset, "victim-post")
      assert status_of(token) == 200

      assert {:ok, 0} = Sharing.remove_share(ws.slug, victim.slug, @dataset)

      assert status_of(token) == 404
    end

    test "a second removal is idempotent and does not disturb an existing stamp", %{
      ws: ws,
      victim: victim
    } do
      {token, link} = doc_link!(ws, victim, @dataset, "victim-post")
      assert {:ok, 0} = Sharing.remove_share(ws.slug, victim.slug, @dataset)
      first = revoked_at(link)
      refute is_nil(first)

      assert {:ok, 0} = Sharing.remove_share(ws.slug, victim.slug, @dataset)
      assert revoked_at(link) == first
      assert status_of(token) == 404
    end
  end

  # ── THE NEGATIVE ARMS — other scopes survive ──────────────────────────────

  describe "links in OTHER scopes survive the removal" do
    test "a link in a SIBLING PROJECT still serves 200", %{
      ws: ws,
      victim: victim,
      sibling: sibling
    } do
      {:ok, _} = Sharing.add_share("#{ws.slug}/#{victim.slug}/#{@dataset}:docs:read")
      {victim_token, _} = doc_link!(ws, victim, @dataset, "victim-post")
      {sibling_token, sibling_link} = doc_link!(ws, sibling, @dataset, "sibling-post")

      assert status_of(victim_token) == 200
      assert status_of(sibling_token) == 200

      assert {:ok, 1} = Sharing.remove_share(ws.slug, victim.slug, @dataset)

      assert status_of(victim_token) == 404
      assert status_of(sibling_token) == 200
      assert is_nil(revoked_at(sibling_link))
    end

    test "a link in a SIBLING DATASET of the SAME project still serves 200", %{
      ws: ws,
      victim: victim,
      sibling_ds_media: media
    } do
      {:ok, _} = Sharing.add_share("#{ws.slug}/#{victim.slug}/#{@dataset}:docs,media:read")
      {victim_token, _} = doc_link!(ws, victim, @dataset, "victim-post")
      {staging_token, staging_link} = media_link!(ws, victim, @sibling_dataset, media)

      assert status_of(victim_token) == 200
      assert status_of(staging_token) == 200

      assert {:ok, 1} = Sharing.remove_share(ws.slug, victim.slug, @dataset)

      assert status_of(victim_token) == 404
      assert status_of(staging_token) == 200
      assert is_nil(revoked_at(staging_link))
    end

    test "removing an UNRESOLVABLE scope revokes nothing", %{ws: ws, victim: victim} do
      {token, link} = doc_link!(ws, victim, @dataset, "victim-post")

      assert {:ok, 0} = Sharing.remove_share("no-such-ws", "no-such-proj", @dataset)
      assert {:ok, 0} = Sharing.remove_share(ws.slug, "no-such-proj", @dataset)

      assert status_of(token) == 200
      assert is_nil(revoked_at(link))
    end
  end
end
