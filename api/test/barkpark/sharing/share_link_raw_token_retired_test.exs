defmodule Barkpark.Sharing.ShareLinkRawTokenRetiredTest do
  @moduledoc """
  `arpss-w8-bl-share-link-raw-token-at-rest` — the plaintext ShareLink token is
  RETIRED. RULED by team-lead 2026-09-02: "RETIRE the plaintext token column.
  links.ex:20 stores both the hash and the cleartext, and the migration's LAN
  premise is void on a shared install."

  `20260609150000_add_token_to_share_links.exs` added a `token` column so P7's
  `/s/<token>` link would be STABLE and RE-COPYABLE, justified from "a
  self-hosted/LAN context". On a multi-tenant install the readers of that column
  are not the readers of the shared content, so every row was a LIVE CREDENTIAL
  at rest and each serialising read path was one tenancy bug from handing a
  stranger working access. `20260904020000_drop_token_from_share_links.exs`
  drops it; the mint's `{:ok, {raw, link}}` is the one place a raw token exists.

  These tests pin the retirement at three depths, and the third is the one that
  makes the other two safe to ship:

    * THE SCHEMA — `:token` is not a field. Asserted on
      `__schema__(:fields)` rather than on a serialized body, because that is
      the fact a re-add would have to defeat: re-declaring the field turns this
      RED before any request is made.
    * THE WRITE — a freshly minted row, reloaded from the database, carries no
      plaintext anywhere in it. The raw IS returned by `create/1`, so the
      refute is over a value we hold and could have found.
    * THE READ (POSITIVE CONTROL) — a link still RESOLVES by its raw token
      after the column is gone. `resolve/1` always matched on `token_hash`, so
      no live `/s/<token>` URL stopped serving; without this control, "no
      plaintext at rest" would be satisfiable by a link that simply broke.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Sharing.Links
  alias Barkpark.Sharing.ShareLink

  setup do
    uniq = System.unique_integer([:positive])
    ws = create_workspace!("raw-retired-ws-#{uniq}")
    proj = create_project!(ws, "raw-retired-proj-#{uniq}")

    attrs = %{
      workspace_id: ws.id,
      project_id: proj.id,
      dataset: "production",
      kind: "doc",
      ref_type: "post",
      ref_id: "post-#{uniq}",
      access: "read"
    }

    %{attrs: attrs}
  end

  # ── THE SCHEMA ────────────────────────────────────────────────────────────

  test "ShareLink has no :token field — only the digest" do
    refute :token in ShareLink.__schema__(:fields)

    # NON-VACUITY: the schema is loaded and does carry the digest it resolves
    # on, so the refute above is about an ABSENT field, not an empty list.
    assert :token_hash in ShareLink.__schema__(:fields)
  end

  test "the changeset cannot cast a :token, so no caller can smuggle one back", %{attrs: attrs} do
    attrs =
      attrs
      |> Map.put(:token_hash, Links.hash_token("some-raw"))
      |> Map.put(:token, "smuggled-plaintext")

    changeset = ShareLink.changeset(%ShareLink{}, attrs)

    # NON-VACUITY: the changeset is otherwise VALID, so the dropped `:token` is
    # `cast/3` refusing an unknown field — not the whole map being rejected.
    assert changeset.valid?
    assert Map.has_key?(changeset.changes, :token_hash)
    refute Map.has_key?(changeset.changes, :token)

    # ...and it does not survive the insert either.
    {:ok, row} = Barkpark.Repo.insert(changeset)
    refute row |> Map.from_struct() |> Map.values() |> Enum.member?("smuggled-plaintext")
  end

  # ── THE WRITE ─────────────────────────────────────────────────────────────

  test "create/1 persists NO plaintext — the row reloaded from the DB has none", %{attrs: attrs} do
    {:ok, {raw, link}} = Links.create(attrs)

    # The raw really is a secret we are holding: if it were empty or nil the
    # refutes below would pass for the wrong reason.
    assert is_binary(raw) and byte_size(raw) > 16

    reloaded = Repo.reload!(link)

    refute :token in Map.keys(Map.from_struct(reloaded))
    refute reloaded |> Map.from_struct() |> Map.values() |> Enum.member?(raw)
    assert reloaded.token_hash == Links.hash_token(raw)

    # And the digest is not the secret: the row cannot be turned back into a URL.
    refute reloaded.token_hash == raw
  end

  test "the share_links TABLE has no token column at all", %{attrs: attrs} do
    {:ok, {_raw, _link}} = Links.create(attrs)

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns WHERE table_name = 'share_links' AND column_name = $1",
        ["token"]
      )

    assert count == 0

    # NON-VACUITY: the same query DOES find the digest column, so a typo in the
    # table name cannot make this pass.
    %{rows: [[hash_count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns WHERE table_name = 'share_links' AND column_name = $1",
        ["token_hash"]
      )

    assert hash_count == 1
  end

  # ── THE READ (POSITIVE CONTROL) ───────────────────────────────────────────

  test "a link still resolves by its raw token after the column is dropped", %{attrs: attrs} do
    {:ok, {raw, link}} = Links.create(attrs)

    assert {:ok, resolved} = Links.resolve(raw)
    assert resolved.id == link.id

    # ...and the refusals are unchanged: a wrong token is still not_found.
    assert Links.resolve(raw <> "x") == {:error, :not_found}
  end

  test "listing an item's links returns rows with no plaintext to serialise", %{attrs: attrs} do
    {:ok, {raw, link}} = Links.create(attrs)

    listed =
      Links.list_for(attrs.workspace_id, attrs.kind, attrs.ref_type, attrs.ref_id,
        project_id: attrs.project_id,
        dataset: attrs.dataset
      )

    # POSITIVE CONTROL: the listing found the row.
    assert Enum.map(listed, & &1.id) == [link.id]

    # The whole listing, serialised, contains the secret nowhere. This is the
    # structural half of arpss-w8's per-path fix: `list/2` cannot leak a
    # credential it was never handed.
    refute listed |> inspect(limit: :infinity) |> String.contains?(raw)
  end
end
