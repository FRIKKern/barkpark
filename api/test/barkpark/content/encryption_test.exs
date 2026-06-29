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

      {:ok, out} =
        Encryption.encrypt_marked(%{"name" => "db", "secret" => "hunter2"}, type, @dataset)

      assert out["name"] == "db"
      assert FieldCipher.encrypted?(out["secret"])
      assert {:ok, "hunter2"} = FieldCipher.decrypt(out["secret"], "dataset:" <> @dataset)
    end

    test "is idempotent — re-encrypting an envelope is byte-identical" do
      {type, _schema} = vault_schema!()
      {:ok, once} = Encryption.encrypt_marked(%{"secret" => "s"}, type, @dataset)
      {:ok, twice} = Encryption.encrypt_marked(once, type, @dataset)
      assert once == twice
    end

    test "adds no key when the marked field is absent from content" do
      {type, _schema} = vault_schema!()
      assert {:ok, %{"name" => "x"}} = Encryption.encrypt_marked(%{"name" => "x"}, type, @dataset)
    end

    test "returns content unchanged on a schema-resolution miss (unknown type)" do
      content = %{"secret" => "still-plain"}
      assert {:ok, ^content} = Encryption.encrypt_marked(content, "no_such_type_zzz", @dataset)
    end

    test "no behaviour change when the schema marks nothing encrypted" do
      type = unique_type("plain")
      insert_schema!(type, [%{"name" => "title", "type" => "string"}])
      content = %{"title" => "hello"}
      assert {:ok, ^content} = Encryption.encrypt_marked(content, type, @dataset)
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

      {:ok, out} =
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

      {:ok, out} = Encryption.encrypt_marked(%{"tokens" => ["t1", "t2", "t3"]}, type, @dataset)

      assert length(out["tokens"]) == 3
      assert Enum.all?(out["tokens"], &FieldCipher.encrypted?/1)

      assert ["t1", "t2", "t3"] ==
               Enum.map(out["tokens"], fn env ->
                 {:ok, v} = FieldCipher.decrypt(env, "dataset:" <> @dataset)
                 v
               end)
    end
  end

  # ── HIGH-3: fail closed — a marked field is NEVER persisted as plaintext ─────

  describe "fail-closed when a marked field cannot be sealed (HIGH-3)" do
    # A schema that FAILS strict whole-schema parse (a sibling field missing
    # `type` — the exact pre-hardening leak trigger) but whose encrypted field is
    # itself well-formed. The lenient per-field pass MUST still seal the secret.
    defp partial_parse_schema! do
      type = unique_type("partial")

      insert_schema!(type, [
        %{"name" => "secret", "type" => "string", "encrypted" => true},
        # No `type` → breaks the STRICT parse that pre-hardening fell open on.
        %{"name" => "broken"}
      ])

      type
    end

    test "strict-parse failure still seals the encrypted field (partial-parse robustness)" do
      type = partial_parse_schema!()

      assert {:ok, out} =
               Encryption.encrypt_marked(
                 %{"secret" => "hunter2", "broken" => "x"},
                 type,
                 @dataset
               )

      assert FieldCipher.encrypted?(out["secret"])
      refute out["secret"] == "hunter2"
      assert {:ok, "hunter2"} = FieldCipher.decrypt(out["secret"], "dataset:" <> @dataset)
      # The unparseable sibling carries no secret → left untouched.
      assert out["broken"] == "x"
    end

    test "REJECTS when an ENCRYPTED-marked field cannot be parsed/sealed" do
      type = unique_type("badsecret")
      # The encrypted field ITSELF is malformed (no `type`) → cannot be processed.
      insert_schema!(type, [%{"name" => "secret", "encrypted" => true}])

      assert {:error, {:encryption_failed, %{unprocessable_fields: fields}}} =
               Encryption.encrypt_marked(%{"secret" => "hunter2"}, type, @dataset)

      assert "secret" in fields
    end

    test "no-op when strict parse fails but NO field is marked encrypted" do
      type = unique_type("plainbroken")
      insert_schema!(type, [%{"name" => "title", "type" => "string"}, %{"name" => "broken"}])
      content = %{"title" => "hello", "broken" => "x"}
      assert {:ok, ^content} = Encryption.encrypt_marked(content, type, @dataset)
    end

    test "create_document REJECTS (no plaintext-at-rest) when the marked field cannot be sealed" do
      type = unique_type("badsecret")
      insert_schema!(type, [%{"name" => "secret", "encrypted" => true}])

      assert {:error, {:encryption_failed, _}} =
               Content.create_document(
                 type,
                 %{"doc_id" => "leak1", "title" => "x", "content" => %{"secret" => "hunter2"}},
                 @dataset
               )

      # The leak path now REJECTS — nothing was persisted, so no plaintext at rest.
      assert {:error, :not_found} = Content.get_document("leak1", type, @dataset)
    end

    test "create_document with a partial-parse schema still persists ciphertext-at-rest" do
      type = partial_parse_schema!()

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => "partial1",
            "title" => "x",
            "content" => %{"secret" => "hunter2", "broken" => "y"}
          },
          @dataset
        )

      raw = raw_content(doc)
      assert raw["secret"]["_bpenc"] == 1
      refute String.contains?(Jason.encode!(raw), "hunter2")
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
      {:ok, out} = Encryption.encrypt_marked(vault_with_block("hunter2"), type, @dataset)

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
      {:ok, encrypted} = Encryption.encrypt_marked(vault_with_block("hunter2"), type, @dataset)

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

      assert {:ok, ^content} = Encryption.encrypt_marked(content, type, @dataset)
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

  # ── Paper (Bulldocs) write path — the SECOND write surface into ──────────────
  # documents.content. upsert_paper / apply_paper_block_op(s) call
  # Document.changeset → Repo directly (not Writer), so they must thread the SAME
  # encryption chokepoint or a paper-type schema marking a field `encrypted: true`
  # leaks plaintext-at-rest through the streaming editor.
  describe "paper write path — ciphertext-at-rest (BlockOps chokepoint)" do
    # The paper type is hardcoded "paper" in BlockOps, so the schema must be
    # named "paper". Use a unique dataset per test to keep the {name,dataset}
    # schemas distinct across the async:false suite.
    defp paper_schema!(dataset) do
      {:ok, schema} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "paper",
          "title" => "paper",
          "dataset" => dataset,
          "fields" => [%{"name" => "secret", "type" => "string", "encrypted" => true}]
        })
        |> Repo.insert()

      schema
    end

    defp paper_enc_dataset, do: "paper_enc_#{System.unique_integer([:positive])}"

    test "upsert_paper encrypts the projected key AND the bound block value at rest" do
      dataset = paper_enc_dataset()
      paper_schema!(dataset)

      {:ok, doc} =
        Content.upsert_paper(%{
          "slug" => "vault-paper",
          "dataset" => dataset,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "field-string",
              "fieldName" => "secret",
              "value" => "hunter2"
            },
            %{"id" => "b2", "type" => "paragraph", "value" => "free body"}
          ]
        })

      raw = raw_content(doc)

      # The PROJECTED bound-field index is an envelope (not plaintext).
      assert raw["secret"]["_bpenc"] == 1

      # The BOUND BLOCK value is an envelope too — else a later re-projection
      # (streaming op / lifecycle) would overwrite the index with plaintext.
      bound = Enum.find(raw["blocks"], &(&1["fieldName"] == "secret"))
      assert bound["value"]["_bpenc"] == 1

      # Reveal still round-trips to plaintext.
      assert {:ok, "hunter2"} =
               FieldCipher.decrypt(raw["secret"], "dataset:" <> dataset)

      # No plaintext anywhere in the on-disk content (the body_html cache redacts
      # the encrypted bound block to "", so the rendered HTML never leaks it).
      refute String.contains?(Jason.encode!(raw), "hunter2")
    end

    test "apply_paper_block_op keeps the bound field ciphertext-at-rest (streaming editor)" do
      dataset = paper_enc_dataset()
      paper_schema!(dataset)

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => "stream-vault",
          "dataset" => dataset,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "field-string",
              "fieldName" => "secret",
              "value" => "first"
            }
          ]
        })

      # Edit the bound field through the streaming op path — a fresh PLAINTEXT
      # value arrives and MUST be encrypted before it lands. (Also exercises the
      # render of a stored envelope-valued block: the prior op left "secret" as a
      # ciphertext map, and rendering body_html over it must not crash.)
      op = %{"op" => "patch-block", "id" => "b1", "patch" => %{"value" => "second"}}

      assert {:ok, _frame} = Content.apply_paper_block_op("stream-vault", op, dataset)

      {:ok, doc} = Content.get_document("stream-vault", "paper", dataset)
      raw = raw_content(doc)

      assert raw["secret"]["_bpenc"] == 1
      bound = Enum.find(raw["blocks"], &(&1["fieldName"] == "secret"))
      assert bound["value"]["_bpenc"] == 1

      assert {:ok, "second"} = FieldCipher.decrypt(raw["secret"], "dataset:" <> dataset)
      refute String.contains?(Jason.encode!(raw), "second")
    end

    test "no behaviour change when the paper schema marks nothing encrypted" do
      dataset = paper_enc_dataset()

      {:ok, schema} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "paper",
          "title" => "paper",
          "dataset" => dataset,
          "fields" => [%{"name" => "secret", "type" => "string"}]
        })
        |> Repo.insert()

      _ = schema

      {:ok, doc} =
        Content.upsert_paper(%{
          "slug" => "plain-paper",
          "dataset" => dataset,
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "field-string",
              "fieldName" => "secret",
              "value" => "visible"
            }
          ]
        })

      raw = raw_content(doc)
      # No marked field → stored verbatim (additive / no-behaviour-change).
      assert raw["secret"] == "visible"

      bound = Enum.find(raw["blocks"], &(&1["fieldName"] == "secret"))
      assert bound["value"] == "visible"
    end
  end
end
