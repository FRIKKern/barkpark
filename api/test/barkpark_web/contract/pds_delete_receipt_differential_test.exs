defmodule BarkparkWeb.Contract.PDSDeleteReceiptDifferentialTest do
  @moduledoc """
  PDS wave 39 — the six DELETE receipts that answered with the REQUEST.

  THE LAW, not the shape: a receipt lies when the value it emits does not
  DESCEND FROM THE WRITE RETURN. Each of these six sites discarded a `{:ok, row}`
  it was already handed and echoed a path param instead, so the printed sentence
  could not change if the store said the opposite.

  Sites covered (all repaired by RENDERING the row the callee already returns —
  zero callee widening was needed):

    * schema_controller.ex:62      DELETE /v1/schemas/:dataset/:name
    * legacy_controller.ex:96      DELETE /api/documents/:type/:id
    * media_controller.ex:365      DELETE /media/:id
    * share_controller.ex:141      DELETE /v1/shares/tokens/:token_id
    * share_link_controller.ex:221 DELETE /v1/shares/links/:id
    * webhook_controller.ex:53     DELETE /v1/webhooks/:dataset/:id

  THE DIFFERENTIAL, which is the whole point: every test asserts a field the
  REQUEST CANNOT PRODUCE — a store-assigned binary_id, the store's `rev`, the
  store's generated filename, the store's `revoked_at` stamp. Revert any receipt
  to its old request-echoing form and the key is simply absent, so the assertion
  reds. A test that passes over both the old and the new shape proves nothing.

  Stored state is read DIRECTLY through `Repo` (the Group C precedent in
  `pds_group_c_receipt_differential_test.exs`): reading it back through a second
  HTTP endpoint would only prove receipt-vs-receipt.

  ## The EIGHT literal-only sites this row also names — disposed, 2026-08-02

  Re-derived at 974d412ca. None is repaired here: every one lives in a
  controller OUTSIDE this slice's file set, and two other wave-39 slices are
  live in these same trees. Follow-up filed as `pds-w39-literal-receipt-residue`.

    * `app_token_controller.ex:141` (self-revoke) — OUT OF SCOPE, REPAIRABLE.
      `Auth.revoke_token/1` returns `{:ok, %ApiToken{}}` with `revoked_at`
      stamped and the controller discards it. This is the IDENTICAL callee and
      the IDENTICAL one-line repair applied to `share_controller.ex:141` here.
    * `app_token_controller.ex:164` (admin revoke-by-raw) — OUT OF SCOPE,
      REPAIRABLE. Same callee, same discarded row. Its `:184` sibling already
      obeys the law (`%{revoked_count: Auth.revoke_app_tokens_for_email/2}`).
    * `plugin_settings_controller.ex:53` (update) — OUT OF SCOPE, REPAIRABLE.
      `Settings.put/3` returns `{:ok, _rec}`; the row is discarded for a literal.
    * `plugin_settings_controller.ex:65` (delete) — OUT OF SCOPE, NEEDS CALLEE
      WIDENING. `Settings.delete/2` returns a bare `:ok` — there is no row to
      render, so the honest repair widens the callee. Its post-condition is
      already pinned against the store by the Group C differential file.
    * `secret_controller.ex:67` (update) — OUT OF SCOPE, REPAIRABLE.
      `Secrets.put/3` returns `{:ok, _rec}`, discarded. A repair must render the
      record's NON-SECRET fields only (never the ciphertext).
    * `secret_controller.ex:80` (delete) — OUT OF SCOPE, NEEDS CALLEE WIDENING.
      `Secrets.delete/3` returns a bare `:ok`. Group C already pins its
      post-condition against the store.
    * `webauthn_controller.ex:170` (step_up) — NO REPAIR NEEDED. Re-derived, it
      ALREADY obeys the law: `fresh_until` is computed from
      `session.mfa_verified_at`, the value `Accounts.stamp_session_mfa/1` just
      WROTE. The `ok: true` key is a literal, but the receipt as a whole already
      descends from the write return. Do not "fix" this one.
    * `webauthn_controller.ex:212` (delete credential) — OUT OF SCOPE, NEEDS
      CALLEE WIDENING. `Webauthn.delete_credential/2` returns a bare `:ok`.

  ## The census disposition — deliberately LEFT ALONE, 2026-08-02

  `scripts/pds-elixir-receipt-census.exs` files these six under
  `:status_only_receipt` across EIGHT `@routed_excluded` rows (the scoped `/w/:…`
  mirrors of Schema/Webhook delete are separate rows). That CLASS ASSIGNMENT is
  still CORRECT after this repair: the class predicate is "reaches no `ok: true`
  receipt this lens can see and carries no roster anchor", and these receipts
  still emit `%{deleted: …}` / `%{revoked: …}` — the lens still cannot key them.

  What is now STALE is the class PROSE, which says the routed action "claims
  success by STATUS alone". For these eight rows that sentence is no longer true:
  they now claim success with a value that descends from the write return. The
  census is not in this slice's file set and is hot with other wave-39 work, so
  it is NOT edited here — the correction is filed on
  `pds-w39-literal-receipt-residue` rather than left silent.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing.{Links, ShareLink}
  alias Barkpark.Webhooks.Webhook

  @admin "pds-w39-delete-receipt-admin"

  # 1x1 transparent PNG, inline — no fixture file needed (mirrors media_test.exs).
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, admin_token} = Auth.create_token(@admin, "pds-w39", "test", ["read", "write", "admin"])
    # The struct is returned as context (rather than recovered later through
    # `Auth.verify_token/1`) so the share-link receipt test can grant this admin
    # a membership in the workspace it acts on — see that test's own note.
    {:ok, admin_token: admin_token}
  end

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  # ── schema_controller.ex:62 ────────────────────────────────────────────────

  describe "DELETE /v1/schemas/:dataset/:name" do
    test "the receipt carries the DELETED ROW's store-assigned id, not the name it was asked for",
         %{conn: conn} do
      name = uniq("pdsw39schema")

      {:ok, _} =
        Content.upsert_schema(%{"name" => name, "title" => "W39", "fields" => []}, "test")

      stored =
        Repo.one(from(s in SchemaDefinition, where: s.name == ^name and s.dataset == "test"))

      assert %SchemaDefinition{} = stored
      # The proof field: a binary_id the request never carries.
      assert is_binary(stored.id)

      body = conn |> admin() |> delete("/v1/schemas/test/#{name}") |> json_response(200)

      assert body["deleted"] == name

      assert body["id"] == stored.id,
             "receipt did not descend from the write return — it echoed the :name path param"

      assert body["dataset"] == "test"

      assert Repo.get(SchemaDefinition, stored.id) == nil,
             "receipt reported a delete but the schema row survived"
    end
  end

  # ── legacy_controller.ex:96 ───────────────────────────────────────────────

  describe "DELETE /api/documents/:type/:id" do
    test "the receipt carries the DELETED ROW's rev, not the id it was asked for", %{conn: conn} do
      doc_id = uniq("pdsw39doc")

      {:ok, _} =
        Content.create_document("post", %{"_id" => doc_id, "title" => "W39"}, "production")

      stored = Repo.one(from(d in Document, where: d.doc_id == ^"drafts.#{doc_id}"))
      assert %Document{} = stored
      # The proof field: the store's own rev, generated at write time.
      assert is_binary(stored.rev)

      body =
        conn |> admin() |> delete("/api/documents/post/drafts.#{doc_id}") |> json_response(200)

      assert body["deleted"] == "drafts.#{doc_id}"

      assert body["rev"] == stored.rev,
             "receipt did not descend from the write return — it echoed the :id path param"

      assert body["type"] == "post"

      assert Repo.get(Document, stored.id) == nil,
             "receipt reported a delete but the document row survived"
    end
  end

  # ── media_controller.ex:365 ───────────────────────────────────────────────

  describe "DELETE /media/:id" do
    test "the receipt carries the DELETED ROW's stored filename, not the id it was asked for",
         %{conn: conn} do
      created =
        conn
        |> admin()
        |> post("/media/upload", %{"file" => png_upload()})
        |> json_response(201)

      id = created["id"]
      stored = Repo.get(MediaFile, id)
      assert %MediaFile{} = stored
      # The proof field: the STORED filename, which the uploader never chose (it
      # is generated) and which the DELETE request cannot carry.
      assert is_binary(stored.filename)

      body = conn |> admin() |> delete("/media/#{id}") |> json_response(200)

      assert body["deleted"] == id

      assert body["filename"] == stored.filename,
             "receipt did not descend from the write return — it echoed the :id path param"

      assert Repo.get(MediaFile, id) == nil,
             "receipt reported a delete but the media row survived"

      rm_uploaded(created)
    end
  end

  # ── share_controller.ex:141 ───────────────────────────────────────────────

  describe "DELETE /v1/shares/tokens/:token_id" do
    test "the receipt's `revoked` descends from the stamped row, not from a literal `true`",
         %{conn: conn} do
      {:ok, token} = Auth.create_token(uniq("pdsw39share"), "w39-share", "test", ["read"])
      assert is_nil(token.revoked_at)

      body = conn |> admin() |> delete("/v1/shares/tokens/#{token.id}") |> json_response(200)

      after_row = Repo.get(ApiToken, token.id)
      refute is_nil(after_row.revoked_at), "receipt said revoked but revoked_at was never stamped"

      assert body["revoked"] == true
      assert body["token_id"] == token.id

      assert body["revoked_at"] == DateTime.to_iso8601(after_row.revoked_at),
             "receipt did not descend from the write return — `revoked: true` was a literal"
    end
  end

  # ── share_link_controller.ex:221 ──────────────────────────────────────────

  describe "DELETE /v1/shares/links/:id" do
    test "the receipt's `revoked` descends from the stamped row, not from a literal `true`",
         %{conn: conn, admin_token: admin_token} do
      ws = create_workspace!(uniq("w39ws"))
      proj = create_project!(ws, uniq("w39proj"))

      # FIXTURE REPAIR (arpss-w8): revoking a link now requires an ADMIN
      # MEMBERSHIP in the LINK's own workspace. `create_token/4` homes @admin in
      # the seeded `default` workspace and `create_workspace!/1` writes no
      # membership, so this admin was a stranger to the workspace it revokes in.
      # Zero production change — this is a receipt-shape pin, not a tenancy test.
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_token.id, "admin")

      {:ok, {_raw, link}} =
        Links.create(%{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset: "production",
          kind: "media",
          ref_id: Ecto.UUID.generate(),
          access: "read"
        })

      assert is_nil(link.revoked_at)

      body = conn |> admin() |> delete("/v1/shares/links/#{link.id}") |> json_response(200)

      after_row = Repo.get(ShareLink, link.id)
      refute is_nil(after_row.revoked_at), "receipt said revoked but revoked_at was never stamped"

      assert body["revoked"] == true
      assert body["id"] == link.id

      assert body["revoked_at"] == DateTime.to_iso8601(after_row.revoked_at),
             "receipt did not descend from the write return — `revoked: true` was a literal"
    end
  end

  # ── webhook_controller.ex:53 ──────────────────────────────────────────────

  describe "DELETE /v1/webhooks/:dataset/:id" do
    test "the receipt carries the DELETED ROW's name, not the id it was asked for", %{conn: conn} do
      name = uniq("w39 hook ")

      created =
        conn
        |> admin()
        |> post(
          "/v1/webhooks/test",
          Jason.encode!(%{
            name: name,
            url: "http://example.com/w39",
            events: ["create"],
            types: ["post"]
          })
        )
        |> json_response(201)

      id = created["webhook"]["id"]
      stored = Repo.get(Webhook, id)
      assert %Webhook{} = stored

      body = conn |> admin() |> delete("/v1/webhooks/test/#{id}") |> json_response(200)

      assert body["deleted"] == id

      assert body["name"] == stored.name,
             "receipt did not descend from the write return — it echoed the :id path param"

      assert Repo.get(Webhook, id) == nil,
             "receipt reported a delete but the webhook row survived"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp png_upload do
    tmp = Path.join(System.tmp_dir!(), "pds-w39-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    %Plug.Upload{path: tmp, filename: "pixel.png", content_type: "image/png"}
  end

  # The sandbox rolls back the row; the BYTES on disk outlive it.
  defp rm_uploaded(%{"url" => "/media/files/" <> relative}),
    do: File.rm(Path.join(Media.upload_dir(), relative))

  defp rm_uploaded(_), do: :ok
end
