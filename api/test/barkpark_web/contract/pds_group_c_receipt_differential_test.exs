defmodule BarkparkWeb.Contract.PDSGroupCReceiptDifferentialTest do
  @moduledoc """
  PDS Group C — receipt == stored row differentials.

  Every test here asserts the mechanical test the epic's law demands: the
  printed receipt (`ok: true`) is read back against the STORED ROW, and the
  negative arm asserts the row is STILL THERE when the receipt says 404.
  A response body alone is never evidence.

  Sites covered in this file:
    * search_controller.ex:316         delete_search_synonym (surface "documents")
    * v1/media_controller.ex:188       delete_search_synonym (surface "media")
    * SecretController.update/2         update (ciphertext + "set" audit row)
    * secret_controller.ex:80          delete (audit row is INSIDE the delete txn)
    * plugin_settings_controller.ex:53 update (settings map + "write" audit row)
    * PluginSettingsController.delete/2 delete (row gone + "delete" audit row)

  Every stored-row assertion reads Postgres DIRECTLY through `Repo`. Reading it
  back through a second HTTP endpoint would only prove receipt-vs-receipt: two
  sentences agreeing with each other is not a post-condition.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Plugins.{SettingsAudit, SettingsRecord}
  alias Barkpark.Repo
  alias Barkpark.Search.Synonym
  alias Barkpark.Secrets.{SecretAudit, SecretRecord}
  alias Barkpark.Vault

  @token "barkpark-pds-groupc-admin"

  setup do
    {:ok, _} = Auth.create_token(@token, "pds-groupc", "test", ["read", "write", "admin"])
    :ok
  end

  defp auth(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp create_synonym(conn, :documents, from, to) do
    resp =
      conn
      |> auth()
      |> post("/v1/data/search/test/synonyms", %{"from" => from, "to" => to})

    json_response(resp, 200)["result"]["id"]
  end

  defp create_synonym(conn, :media, from, to) do
    resp =
      conn
      |> auth()
      |> post("/v1/media/test/search/synonyms", %{"from" => from, "to" => to})

    json_response(resp, 200)["result"]["id"]
  end

  defp stored(id), do: Repo.get(Synonym, id)

  describe "Synonyms.delete/4 — one callee, two surfaces" do
    test "search surface: ok:true is read back — the row is GONE", %{conn: conn} do
      id = create_synonym(conn, :documents, "gc-doc-a", "target-a")
      assert %Synonym{surface: "documents"} = stored(id)

      body =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/data/search/test/synonyms/#{id}")
        |> json_response(200)

      assert body["ok"] == true
      assert stored(id) == nil, "receipt said ok:true but the synonym row survived"
    end

    test "media surface: ok:true is read back — the row is GONE", %{conn: conn} do
      id = create_synonym(conn, :media, "gc-med-a", "target-a")
      assert %Synonym{surface: "media"} = stored(id)

      body =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/media/test/search/synonyms/#{id}")
        |> json_response(200)

      assert body["ok"] == true
      assert stored(id) == nil, "receipt said ok:true but the synonym row survived"
    end

    test "cross-surface: media route must NOT delete a documents row, and says so",
         %{conn: conn} do
      id = create_synonym(conn, :documents, "gc-cross-1", "target-x")

      resp =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/media/test/search/synonyms/#{id}")

      assert resp.status == 404, "media surface deleted a documents-surface synonym"
      refute json_response(resp, 404)["ok"] == true

      row = stored(id)

      assert match?(%Synonym{surface: "documents"}, row),
             "404 receipt, but the documents row was destroyed anyway (#{inspect(row)})"
    end

    test "cross-surface, reversed: search route must NOT delete a media row",
         %{conn: conn} do
      id = create_synonym(conn, :media, "gc-cross-2", "target-y")

      resp =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/data/search/test/synonyms/#{id}")

      assert resp.status == 404, "search surface deleted a media-surface synonym"

      row = stored(id)

      assert match?(%Synonym{surface: "media"}, row),
             "404 receipt, but the media row was destroyed anyway (#{inspect(row)})"
    end
  end

  describe "Secrets.delete/2 — receipt covers BOTH halves of the transaction" do
    defp secret_row(name) do
      Repo.one(from(r in SecretRecord, where: r.name == ^name and is_nil(r.workspace_id)))
    end

    defp audit_actions(name) do
      Repo.all(
        from(a in SecretAudit,
          where: a.name == ^name and is_nil(a.workspace_id),
          select: a.action
        )
      )
    end

    test "ok:true means the secret is gone AND the delete audit row exists", %{conn: conn} do
      name = "gc_secret_alpha"

      assert conn
             |> auth()
             |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "gc-value-1111"}))
             |> Map.get(:status) == 200

      assert %SecretRecord{} = secret_row(name)

      body =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/secrets/#{name}")
        |> json_response(200)

      assert body["ok"] == true

      assert secret_row(name) == nil,
             "receipt said ok:true but the secrets row survived"

      assert "delete" in audit_actions(name),
             "receipt said ok:true but no delete audit row was written inside the txn"
    end

    test "404 means nothing happened — no audit row is fabricated", %{conn: conn} do
      name = "gc_secret_never_existed"

      resp =
        conn
        |> auth()
        |> delete("/v1/secrets/#{name}")

      assert resp.status == 404
      assert audit_actions(name) == [], "404 receipt, but an audit row was written anyway"
    end
  end

  describe "Secrets.put/3 — secret_controller.ex:67, the PUT receipt" do
    # The global tier encodes with `Barkpark.Vault` (secret_record.ex @moduledoc),
    # so the stored row is CIPHERTEXT. Decoding it here is what makes this a
    # post-condition on the VALUE and not merely on row presence.
    defp stored_secret_plaintext(name) do
      case secret_row(name) do
        nil -> :no_row
        %SecretRecord{value: bytes} -> Vault.decrypt(bytes)
      end
    end

    test "ok:true means the ciphertext decodes to the submitted value AND a set audit row exists",
         %{conn: conn} do
      name = "gc_secret_put_alpha"

      body =
        conn
        |> auth()
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "gc-put-value-2222"}))
        |> json_response(200)

      assert body["ok"] == true

      stored_value = stored_secret_plaintext(name)

      assert stored_value == {:ok, "gc-put-value-2222"},
             "receipt said ok:true but no secrets row holds that value (#{inspect(stored_value)})"

      assert "set" in audit_actions(name),
             "receipt said ok:true but no set audit row was written inside the txn"
    end

    test "a second ok:true means the row now holds the NEW value, not the stale one", %{
      conn: conn
    } do
      name = "gc_secret_put_beta"

      assert conn
             |> auth()
             |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "first-3333"}))
             |> Map.get(:status) == 200

      body =
        conn
        |> recycle()
        |> auth()
        |> put("/v1/secrets/#{name}", Jason.encode!(%{value: "second-4444"}))
        |> json_response(200)

      assert body["ok"] == true

      stored_value = stored_secret_plaintext(name)

      assert stored_value == {:ok, "second-4444"},
             "receipt said ok:true but the overwrite never reached the row (#{inspect(stored_value)})"

      # One row per name in the global tier — an overwrite must not fork it.
      assert Repo.aggregate(
               from(r in SecretRecord, where: r.name == ^name and is_nil(r.workspace_id)),
               :count
             ) == 1
    end
  end

  describe "Settings — plugin_settings_controller.ex:53 and :65" do
    defp settings_row(name), do: Repo.get(SettingsRecord, name)

    defp settings_audit_actions(name) do
      Repo.all(from(a in SettingsAudit, where: a.plugin_name == ^name, select: a.action))
    end

    test "PUT ok:true means the settings map is stored AND a write audit row exists", %{
      conn: conn
    } do
      name = "gc-plugin-alpha"
      settings = %{"api_key" => "gc-plugin-key-5555", "endpoint" => "https://example.invalid"}

      body =
        conn
        |> auth()
        |> put("/v1/plugins/settings/#{name}", Jason.encode!(%{settings: settings}))
        |> json_response(200)

      assert body["ok"] == true

      row = settings_row(name)

      assert match?(%SettingsRecord{settings: ^settings}, row),
             "receipt said ok:true but the plugin_settings row does not hold that map (#{inspect(row)})"

      assert "write" in settings_audit_actions(name),
             "receipt said ok:true but no write audit row was written inside the txn"
    end

    test "DELETE ok:true means the row is GONE AND a delete audit row exists", %{conn: conn} do
      name = "gc-plugin-beta"

      assert conn
             |> auth()
             |> put(
               "/v1/plugins/settings/#{name}",
               Jason.encode!(%{settings: %{"api_key" => "gc-plugin-key-6666"}})
             )
             |> Map.get(:status) == 200

      assert %SettingsRecord{} = settings_row(name)

      body =
        conn
        |> recycle()
        |> auth()
        |> delete("/v1/plugins/settings/#{name}")
        |> json_response(200)

      assert body["ok"] == true

      assert settings_row(name) == nil,
             "receipt said ok:true but the plugin_settings row survived"

      assert "delete" in settings_audit_actions(name),
             "receipt said ok:true but no delete audit row was written inside the txn"
    end

    test "DELETE 404 means nothing happened — no delete audit row is fabricated", %{conn: conn} do
      name = "gc-plugin-never-existed"

      resp =
        conn
        |> auth()
        |> delete("/v1/plugins/settings/#{name}")

      assert resp.status == 404

      refute "delete" in settings_audit_actions(name),
             "404 receipt, but a delete audit row was written anyway"
    end
  end
end
