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

  test "nil schema or caller_context skips redaction (backward compat)", %{doc: doc} do
    base = Envelope.render(doc)
    assert Envelope.render(doc, nil, nil) == base
    # A schema present but no caller still skips redaction.
    assert Envelope.render(doc, schema_with([%{"name" => "body", "private" => true}]), nil) ==
             base
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

    # No caller context => internal/writer path keeps the ciphertext.
    assert Envelope.render(doc)["ssn"] == enc
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
      "post" -> schema_with([%{"name" => "body", "type" => "string", "private" => true}])
      "author" -> %SchemaDefinition{name: "author", fields: [%{"name" => "ssn", "private" => true}]}
      _ -> nil
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
