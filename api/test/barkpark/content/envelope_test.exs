defmodule Barkpark.Content.EnvelopeTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, SchemaDefinition}
  alias Barkpark.Crypto.FieldCipher

  setup do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "env-1",
          "title" => "Hello",
          "content" => %{"body" => "hi", "tags" => ["a"]}
        },
        "test"
      )

    %{doc: doc}
  end

  test "renders flat envelope with reserved underscore keys", %{doc: doc} do
    env = Envelope.render(doc)
    assert env["_id"] == doc.doc_id
    assert env["_type"] == "post"
    assert env["_rev"] == doc.rev
    assert env["_draft"] == true
    assert env["_publishedId"] == "env-1"
    assert env["title"] == "Hello"
    assert env["body"] == "hi"
    assert env["tags"] == ["a"]
    assert is_binary(env["_createdAt"])
    assert String.ends_with?(env["_createdAt"], "Z")
  end

  test "no nested `content` key in output", %{doc: doc} do
    env = Envelope.render(doc)
    refute Map.has_key?(env, "content")
    refute Map.has_key?(env, :content)
  end

  test "user fields cannot override reserved keys" do
    {:ok, d} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-2", "title" => "X", "content" => %{"_id" => "HIJACK"}},
        "test"
      )

    env = Envelope.render(d)
    assert env["_id"] == d.doc_id
    refute env["_id"] == "HIJACK"
  end

  # ── Phase 3: field-visibility redaction ─────────────────────────────────────

  defp schema_with(fields), do: %SchemaDefinition{name: "post", fields: fields}

  defp admin, do: %CallerContext{principal_type: :api_token, is_admin: true}

  test "no-private-fields case is byte-identical for a nil/anonymous caller", %{doc: doc} do
    # No schema => no per-field visibility declared => nothing to redact, so a
    # nil/anonymous caller still sees every (non-encrypted) field.
    base = Envelope.render(doc, nil, :internal)
    assert Envelope.render(doc, nil, nil) == base
    assert Envelope.render(doc) == base
  end

  test "nil caller FAILS CLOSED on a declared private field (WS-B root fix)", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "private" => true}])
    # A nil caller is now the most restrictive anonymous principal — the private
    # field is DROPPED, not passed through (the WS-B fail-open bug).
    refute Map.has_key?(Envelope.render(doc, schema, nil), "body")
    # The explicit :internal sentinel is the only full-content bypass.
    assert Envelope.render(doc, schema, :internal)["body"] == "hi"
    # Non-private fields survive even for the nil caller.
    assert Envelope.render(doc, schema, nil)["title"] == "Hello"
  end

  test "admin caller sees all fields including private ones", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "type" => "string", "private" => true}])
    env = Envelope.render(doc, schema, admin())
    assert env["body"] == "hi"
    assert env["title"] == "Hello"
  end

  test "non-admin caller is redacted from private fields", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "type" => "string", "private" => true}])
    env = Envelope.render(doc, schema, CallerContext.anonymous())
    refute Map.has_key?(env, "body")
    # Non-private fields and reserved keys survive.
    assert env["title"] == "Hello"
    assert env["tags"] == ["a"]
    assert env["_id"] == doc.doc_id
  end

  test "visibility=\"private\" redacts for non-admin", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "type" => "string", "visibility" => "private"}])
    refute Map.has_key?(Envelope.render(doc, schema, CallerContext.anonymous()), "body")
    assert Envelope.render(doc, schema, admin())["body"] == "hi"
  end

  test "encrypted fields default to private even without explicit private=true" do
    enc = FieldCipher.encrypt("ssn-9", "dataset:test")

    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-enc", "title" => "E", "content" => %{"ssn" => enc, "body" => "ok"}},
        "test"
      )

    # No schema at all — the ciphertext guard is schema-free.
    non_admin = Envelope.render(doc, nil, CallerContext.anonymous())
    refute Map.has_key?(non_admin, "ssn")
    assert non_admin["body"] == "ok"

    # Admin still sees the (undecrypted) ciphertext envelope.
    assert Envelope.render(doc, nil, admin())["ssn"] == enc

    # No caller context => FAIL CLOSED: the ciphertext is dropped (anonymous).
    refute Map.has_key?(Envelope.render(doc), "ssn")
    # The explicit :internal sentinel is the writer/full-content path.
    assert Envelope.render(doc, nil, :internal)["ssn"] == enc
  end

  test "visibility=\"owner_only\" redacts unless caller is owner/admin", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "type" => "string", "visibility" => "owner_only"}])
    # Phase 3 has no doc-owner column yet => conservative drop for any non-admin.
    refute Map.has_key?(Envelope.render(doc, schema, CallerContext.from_user("user_1")), "body")
    assert Envelope.render(doc, schema, admin())["body"] == "hi"
  end

  test "readable_by list allows specified callers only", %{doc: doc} do
    schema = schema_with([%{"name" => "body", "type" => "string", "readable_by" => ["user_123"]}])
    assert Envelope.render(doc, schema, CallerContext.from_user("user_123"))["body"] == "hi"
    refute Map.has_key?(Envelope.render(doc, schema, CallerContext.from_user("user_456")), "body")
  end

  test "readable_by matches an api token_id" do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-tok", "title" => "T", "content" => %{"body" => "hi"}},
        "test"
      )

    schema =
      schema_with([
        %{"name" => "body", "type" => "string", "private" => true, "readable_by" => ["tok-7"]}
      ])

    ctx = %CallerContext{principal_type: :api_token, token_id: "tok-7"}
    assert Envelope.render(doc, schema, ctx)["body"] == "hi"

    other = %CallerContext{principal_type: :api_token, token_id: "tok-8"}
    refute Map.has_key?(Envelope.render(doc, schema, other), "body")
  end

  test "unknown fields in envelope are kept (only schema-defined fields redacted)", %{doc: doc} do
    # Schema declares only `body` private; `tags` is undeclared => public.
    schema = schema_with([%{"name" => "body", "type" => "string", "private" => true}])
    env = Envelope.render(doc, schema, CallerContext.anonymous())
    refute Map.has_key?(env, "body")
    assert env["tags"] == ["a"]
    assert env["title"] == "Hello"
  end

  # ── field_readable?/3: the filter/order oracle guard (WS-B MEDIUM-4) ─────────

  test "field_readable? denies a private field to a non-admin caller" do
    schema = schema_with([%{"name" => "salary", "private" => true}])
    refute Envelope.field_readable?(schema, "salary", CallerContext.anonymous())
    refute Envelope.field_readable?(schema, "salary", CallerContext.from_user("u1"))
    assert Envelope.field_readable?(schema, "salary", admin())
  end

  test "field_readable? allows undeclared, promoted and reserved fields" do
    schema = schema_with([%{"name" => "salary", "private" => true}])
    ctx = CallerContext.anonymous()
    assert Envelope.field_readable?(schema, "tags", ctx)
    assert Envelope.field_readable?(schema, "title", ctx)
    assert Envelope.field_readable?(schema, "status", ctx)
    assert Envelope.field_readable?(schema, "_id", ctx)
  end

  test "field_readable? resolves a nested path against its top-level parent" do
    schema = schema_with([%{"name" => "meta", "private" => true}])
    ctx = CallerContext.anonymous()
    refute Envelope.field_readable?(schema, "meta.seo", ctx)
    refute Envelope.field_readable?(schema, "content.meta.seo", ctx)
  end

  test "field_readable? treats nil/:internal callers as unrestricted" do
    schema = schema_with([%{"name" => "salary", "private" => true}])
    assert Envelope.field_readable?(schema, "salary", nil)
    assert Envelope.field_readable?(schema, "salary", :internal)
  end

  # ── render_many_by_type: multi-type search surfaces (Phase 3 leak fix) ───────

  test "render_many_by_type drops a non-encrypted private field per doc.type", %{doc: post} do
    {:ok, author} =
      Content.create_document(
        "author",
        %{"doc_id" => "auth-1", "title" => "A", "content" => %{"ssn" => "123-45-6789"}},
        "test"
      )

    # Distinct schema per type: `post.body` private, `author.ssn` private. Neither
    # field is encrypted — the schema-free ciphertext guard alone would NOT drop them.
    resolver = fn
      "post" ->
        schema_with([%{"name" => "body", "type" => "string", "private" => true}])

      "author" ->
        %SchemaDefinition{name: "author", fields: [%{"name" => "ssn", "private" => true}]}

      _ ->
        nil
    end

    [post_env, author_env] =
      Envelope.render_many_by_type([post, author], resolver, CallerContext.anonymous())

    # Each private field dropped under its own type's schema.
    refute Map.has_key?(post_env, "body")
    refute Map.has_key?(author_env, "ssn")
    # Public fields survive on both.
    assert post_env["tags"] == ["a"]
    assert author_env["title"] == "A"
  end

  test "render_many_by_type leaves an admin unredacted", %{doc: post} do
    resolver = fn _ -> schema_with([%{"name" => "body", "private" => true}]) end
    [env] = Envelope.render_many_by_type([post], resolver, admin())
    assert env["body"] == "hi"
  end

  test "render_many_by_type resolves each distinct type exactly once (memoised)", %{doc: post} do
    {:ok, post2} =
      Content.create_document(
        "post",
        %{"doc_id" => "env-3", "title" => "Y", "content" => %{"body" => "yo"}},
        "test"
      )

    {:ok, agent} = Agent.start_link(fn -> [] end)

    resolver = fn type ->
      Agent.update(agent, fn calls -> [type | calls] end)
      schema_with([%{"name" => "body", "private" => true}])
    end

    Envelope.render_many_by_type([post, post2], resolver, CallerContext.anonymous())
    # Two "post" docs => the resolver is invoked once, not twice.
    assert Agent.get(agent, & &1) == ["post"]
  end
end
