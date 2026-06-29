defmodule Barkpark.Content.EncryptionTest do
  @moduledoc """
  Phase 2 (core-auth) — field encryption wired into the content write path.

  Proves the load-bearing invariants:

    * `encrypted: true` parses onto the Field struct (defaults `false`).
    * `Encryption.encrypt_marked/3` encrypts ONLY marked fields, recursing into
      composite subfields and arrayOf items; idempotent; never crashes on a
      schema miss.
    * Ciphertext-at-rest: a raw SQL read of `documents.content` returns the
      `_bpenc` envelope, never the plaintext.
    * No read-path auto-decrypt — a normal read returns ciphertext.
    * `Content.reveal_fields/4` decrypts ONLY for an admin caller; non-admin and
      anonymous get `:error`; a tampered envelope fails closed.
    * DEK rotation is transparent (old ciphertext still reveals).
    * No behaviour change when nothing is marked encrypted.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Encryption, SchemaDefinition}
  alias Barkpark.Crypto.{DataKeys, FieldCipher}
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.Repo

  @dataset "test"

  # ── helpers ────────────────────────────────────────────────────────────────

  defp unique_type(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp insert_schema!(type, fields) do
    {:ok, schema} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => type,
        "title" => type,
        "dataset" => @dataset,
        "fields" => fields
      })
      |> Repo.insert()

    schema
  end

  # A flat schema with one plaintext + one encrypted leaf field.
  defp vault_schema! do
    type = unique_type("vault")

    schema =
      insert_schema!(type, [
        %{"name" => "name", "type" => "string"},
        %{"name" => "secret", "type" => "string", "encrypted" => true}
      ])

    {type, schema}
  end

  defp raw_content(%Document{id: id}) do
    %{rows: [[content]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT content FROM documents WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    case content do
      bin when is_binary(bin) -> Jason.decode!(bin)
      map -> map
    end
  end

  # ── Field-struct parsing ─────────────────────────────────────────────────────

  describe "Field struct — encrypted attribute" do
    test "parses encrypted: true onto the Field struct" do
      {:ok, parsed} =
        SchemaDefinition.parse(%{
          "fields" => [%{"name" => "secret", "type" => "string", "encrypted" => true}]
        })

      assert [%SchemaDefinition.Field{name: "secret", encrypted: true}] = parsed.fields
    end

    test "defaults encrypted to false when the attribute is omitted (legacy schema)" do
      {:ok, parsed} =
        SchemaDefinition.parse(%{"fields" => [%{"name" => "title", "type" => "string"}]})

      assert [%SchemaDefinition.Field{name: "title", encrypted: false}] = parsed.fields
    end

    test "encrypted: true survives on composite subfields and arrayOf `of`" do
      {:ok, parsed} =
        SchemaDefinition.parse(%{
          "fields" => [
            %{
              "name" => "creds",
              "type" => "composite",
              "fields" => [
                %{"name" => "user", "type" => "string"},
                %{"name" => "password", "type" => "string", "encrypted" => true}
              ]
            },
            %{
              "name" => "tokens",
              "type" => "arrayOf",
              "of" => %{"type" => "string", "encrypted" => true}
            }
          ]
        })

      [%{type: "composite", fields: subfields}, %{type: "arrayOf", of: of}] = parsed.fields
      assert Enum.find(subfields, &(&1.name == "password")).encrypted == true
      assert Enum.find(subfields, &(&1.name == "user")).encrypted == false
      assert of.encrypted == true
    end
  end

  # ── encrypt_marked/3 (pure, schema-resolved) ─────────────────────────────────

  describe "Encryption.encrypt_marked/3" do
    test "encrypts marked fields and leaves unmarked fields plaintext" do
      {type, _schema} = vault_schema!()

      out = Encryption.encrypt_marked(%{"name" => "db", "secret" => "hunter2"}, type, @dataset)

      assert out["name"] == "db"
      assert FieldCipher.encrypted?(out["secret"])
      assert {:ok, "hunter2"} = FieldCipher.decrypt(out["secret"], "dataset:" <> @dataset)
    end

    test "is idempotent — re-encrypting an envelope is byte-identical" do
      {type, _schema} = vault_schema!()
      once = Encryption.encrypt_marked(%{"secret" => "s"}, type, @dataset)
      twice = Encryption.encrypt_marked(once, type, @dataset)
      assert once == twice
    end

    test "adds no key when the marked field is absent from content" do
      {type, _schema} = vault_schema!()
      assert Encryption.encrypt_marked(%{"name" => "x"}, type, @dataset) == %{"name" => "x"}
    end

    test "returns content unchanged on a schema-resolution miss (unknown type)" do
      content = %{"secret" => "still-plain"}
      assert Encryption.encrypt_marked(content, "no_such_type_zzz", @dataset) == content
    end

    test "no behaviour change when the schema marks nothing encrypted" do
      type = unique_type("plain")
      insert_schema!(type, [%{"name" => "title", "type" => "string"}])
      content = %{"title" => "hello"}
      assert Encryption.encrypt_marked(content, type, @dataset) == content
    end

    test "encrypts a marked subfield inside a composite, leaving siblings plaintext" do
      type = unique_type("composite")

      insert_schema!(type, [
        %{
          "name" => "creds",
          "type" => "composite",
          "fields" => [
            %{"name" => "user", "type" => "string"},
            %{"name" => "password", "type" => "string", "encrypted" => true}
          ]
        }
      ])

      out =
        Encryption.encrypt_marked(
          %{"creds" => %{"user" => "admin", "password" => "s3cret"}},
          type,
          @dataset
        )

      assert out["creds"]["user"] == "admin"
      assert FieldCipher.encrypted?(out["creds"]["password"])

      assert {:ok, "s3cret"} =
               FieldCipher.decrypt(out["creds"]["password"], "dataset:" <> @dataset)
    end

    test "encrypts each item of an arrayOf whose `of` is marked encrypted" do
      type = unique_type("arr")

      insert_schema!(type, [
        %{
          "name" => "tokens",
          "type" => "arrayOf",
          "of" => %{"type" => "string", "encrypted" => true}
        }
      ])

      out = Encryption.encrypt_marked(%{"tokens" => ["t1", "t2", "t3"]}, type, @dataset)

      assert length(out["tokens"]) == 3
      assert Enum.all?(out["tokens"], &FieldCipher.encrypted?/1)

      assert ["t1", "t2", "t3"] ==
               Enum.map(out["tokens"], fn env ->
                 {:ok, v} = FieldCipher.decrypt(env, "dataset:" <> @dataset)
                 v
               end)
    end
  end

  # ── Bound-block encryption — projection cannot leak plaintext ────────────────

  describe "bound-block encryption (projection chokepoint)" do
    # A bound block carries the editable plaintext that
    # `PortableDoc.Projection.project` copies VERBATIM into content[fieldName].
    # The chokepoint must encrypt that block value too, else a downstream
    # re-projection (sheets / edges / lifecycle / backfill) overwrites the
    # ciphertext envelope with plaintext.
    defp vault_with_block(secret) do
      %{
        "name" => "db",
        "secret" => secret,
        "blocks" => [
          %{"id" => "b1", "type" => "field-string", "fieldName" => "secret", "value" => secret},
          %{"id" => "b2", "type" => "paragraph", "value" => "free body"}
        ]
      }
    end

    test "encrypt_marked encrypts the BOUND BLOCK value, not just the projected key" do
      {type, _schema} = vault_schema!()
      out = Encryption.encrypt_marked(vault_with_block("hunter2"), type, @dataset)

      assert FieldCipher.encrypted?(out["secret"])

      [bound, free] = out["blocks"]
      assert bound["fieldName"] == "secret"
      assert FieldCipher.encrypted?(bound["value"])
      assert {:ok, "hunter2"} = FieldCipher.decrypt(bound["value"], "dataset:" <> @dataset)

      # A FREE block (no fieldName) is never touched.
      assert free["value"] == "free body"
    end

    test "re-projecting encrypted blocks keeps content[fieldName] ciphertext (no leak)" do
      {type, _schema} = vault_schema!()
      encrypted = Encryption.encrypt_marked(vault_with_block("hunter2"), type, @dataset)

      # Simulate ANY downstream write path re-deriving the projected index from
      # the stored blocks. Because the block value is now an envelope, projection
      # copies ciphertext — the defect's overwrite-with-plaintext is gone.
      reprojected = Projection.project(encrypted, encrypted["blocks"])

      assert FieldCipher.encrypted?(reprojected["secret"])
      refute reprojected["secret"] == "hunter2"
      assert {:ok, "hunter2"} = FieldCipher.decrypt(reprojected["secret"], "dataset:" <> @dataset)
    end

    test "no marked field → blocks pass through byte-identical" do
      type = unique_type("plain")
      insert_schema!(type, [%{"name" => "title", "type" => "string"}])

      content = %{
        "title" => "hello",
        "blocks" => [
          %{"id" => "b1", "type" => "field-string", "fieldName" => "title", "value" => "hello"}
        ]
      }

      assert Encryption.encrypt_marked(content, type, @dataset) == content
    end

    test "publish copies an already-ciphertext draft → published row stays ciphertext-at-rest" do
      {type, _schema} = vault_schema!()

      {:ok, _draft} =
        Content.upsert_document(
          type,
          %{"doc_id" => "pubsec", "title" => "vault", "content" => vault_with_block("hunter2")},
          @dataset
        )

      {:ok, published} = Content.publish_document("pubsec", type, @dataset)

      # The lifecycle copy path (Document.changeset of draft.content) never
      # re-encrypts; it must inherit ciphertext for BOTH the projected key and
      # the bound block — so plaintext can never reach the published row.
      raw = raw_content(published)
      assert raw["secret"]["_bpenc"] == 1

      bound = Enum.find(raw["blocks"], &(&1["fieldName"] == "secret"))
      assert bound["value"]["_bpenc"] == 1

      encoded = Jason.encode!(raw)
      refute String.contains?(encoded, "hunter2")
    end
  end

  # ── Write path: ciphertext-at-rest + round-trip reveal ───────────────────────

  describe "write path — ciphertext-at-rest" do
    test "create_document persists the marked field as a ciphertext envelope" do
      {type, _schema} = vault_schema!()

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => "v1",
            "title" => "vault",
            "content" => %{"name" => "db", "secret" => "hunter2"}
          },
          @dataset
        )

      # The returned (inserted) row carries ciphertext, not plaintext.
      assert FieldCipher.encrypted?(doc.content["secret"])

      # Raw SQL: the on-disk envelope never contains the plaintext.
      raw = raw_content(doc)
      assert raw["secret"]["_bpenc"] == 1
      refute String.contains?(Jason.encode!(raw["secret"]), "hunter2")
      assert raw["name"] == "db"
    end

    test "a normal read returns ciphertext — NO read-path auto-decrypt" do
      {type, _schema} = vault_schema!()

      {:ok, created} =
        Content.create_document(
          type,
          %{"doc_id" => "v2", "title" => "vault", "content" => %{"secret" => "topsecret"}},
          @dataset
        )

      {:ok, read} = Content.get_document(created.doc_id, type, @dataset)
      assert FieldCipher.encrypted?(read.content["secret"])
      refute read.content["secret"] == "topsecret"
    end

    test "upsert_document also encrypts marked fields at rest" do
      {type, _schema} = vault_schema!()

      {:ok, doc} =
        Content.upsert_document(
          type,
          %{"doc_id" => "v3", "title" => "vault", "content" => %{"secret" => "via-upsert"}},
          @dataset
        )

      assert raw_content(doc)["secret"]["_bpenc"] == 1
    end
  end

  # ── reveal_fields/4 authorization + round-trip ───────────────────────────────

  describe "Content.reveal_fields/4" do
    setup do
      {type, schema} = vault_schema!()

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => "rv",
            "title" => "vault",
            "content" => %{"name" => "db", "secret" => "hunter2"}
          },
          @dataset
        )

      {:ok, stored} = Content.get_document(doc.doc_id, type, @dataset)
      %{type: type, schema: schema, stored: stored}
    end

    test "admin reveal decrypts marked fields to plaintext", %{schema: schema, stored: stored} do
      admin = %CallerContext{principal_type: :api_token, is_admin: true}
      assert {:ok, revealed} = Content.reveal_fields(stored, schema, @dataset, admin)
      assert revealed.content["secret"] == "hunter2"
      assert revealed.content["name"] == "db"
    end

    test "non-admin caller is denied (still sees ciphertext)", %{schema: schema, stored: stored} do
      non_admin = %CallerContext{principal_type: :api_token, roles: ["read"], is_admin: false}
      assert :error = Content.reveal_fields(stored, schema, @dataset, non_admin)
      assert FieldCipher.encrypted?(stored.content["secret"])
    end

    test "anonymous caller is denied", %{schema: schema, stored: stored} do
      assert :error = Content.reveal_fields(stored, schema, @dataset, CallerContext.anonymous())
    end

    test "tampered envelope fails closed → :error", %{schema: schema, stored: stored} do
      env = stored.content["secret"]
      <<h::binary-size(10), byte, rest::binary>> = Base.decode64!(env["v"])
      bad_v = Base.encode64(<<h::binary, Bitwise.bxor(byte, 1), rest::binary>>)
      tampered_content = Map.put(stored.content, "secret", %{env | "v" => bad_v})
      doc = %{stored | content: tampered_content}

      admin = %CallerContext{principal_type: :api_token, is_admin: true}
      assert :error = Content.reveal_fields(doc, schema, @dataset, admin)
    end

    test "round-trip: write → read sees ciphertext → admin reveal sees plaintext", %{
      schema: schema,
      stored: stored
    } do
      assert FieldCipher.encrypted?(stored.content["secret"])
      admin = %CallerContext{principal_type: :api_token, is_admin: true}

      assert {:ok, %{content: %{"secret" => "hunter2"}}} =
               Content.reveal_fields(stored, schema, @dataset, admin)
    end
  end

  # ── DEK rotation transparency ────────────────────────────────────────────────

  describe "DEK rotation" do
    test "old ciphertext (k=1) still reveals after a new key (k=2) is activated" do
      {type, schema} = vault_schema!()

      {:ok, created} =
        Content.create_document(
          type,
          %{"doc_id" => "rot", "title" => "vault", "content" => %{"secret" => "old-value"}},
          @dataset
        )

      {:ok, stored} = Content.get_document(created.doc_id, type, @dataset)
      assert stored.content["secret"]["k"] == 1

      {2, _new} = DataKeys.rotate_dek("dataset:" <> @dataset)

      admin = %CallerContext{principal_type: :api_token, is_admin: true}

      assert {:ok, %{content: %{"secret" => "old-value"}}} =
               Content.reveal_fields(stored, schema, @dataset, admin)
    end
  end
end
