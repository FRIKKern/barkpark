defmodule Barkpark.Content.EnvelopeAuthorEmailSealTest do
  @moduledoc """
  MERGE SEAL (arpss wave 3, author-email PII): the demo seed's author schema
  declares `private: true` on its `email` field, and the Envelope chokepoint
  redacts it fail-closed for every non-admin caller.

  Unlike the wave-3 verifier probe (which pinned a probe-local schema copy),
  every test here reads the REAL seed — `Barkpark.Seeds.Demo.seed/1` into the
  sandboxed DB, then the stored `author` `SchemaDefinition` row and the seeded
  `a1` author document — so a drift in the seed itself reds this file.

  THE SCOPE LINE (what keeps this a field clamp, not a corpus projection):
  `Map.delete(env_unsealed, "email") == env_sealed` — removing the declaration
  changes EXACTLY the email key; every sibling field renders byte-identical
  for the anonymous caller. `schema.visibility` is untouched ("public" is
  asserted below).

  MUTATION ARM: the "attr stripped => email leaks again" test proves the
  `private: true` declaration is the load-bearing byte — remove it from the
  seed and the anon-drop assertions here go red.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.{CallerContext, Document, Envelope, SchemaDefinition}
  alias Barkpark.Repo

  @siblings ~w(name slug bio avatar role title)

  setup do
    # capture_io: the seed profile narrates via IO.puts — keep test output clean
    ExUnit.CaptureIO.capture_io(fn ->
      scope = Barkpark.Seeds.Shared.ensure_default_scope()
      Barkpark.Seeds.Demo.seed(scope)
    end)

    schema = Repo.get_by!(SchemaDefinition, name: "author")
    doc = Repo.get_by!(Document, doc_id: "a1", type: "author")
    %{schema: schema, doc: doc}
  end

  # The stored author schema with the email `private` declaration REMOVED —
  # the mutation arm's "seed without the seal" world, derived from the real
  # row (never a test-local schema copy).
  defp strip_email_private(%SchemaDefinition{} = schema) do
    fields =
      Enum.map(schema.fields, fn
        %{"name" => "email"} = f -> Map.delete(f, "private")
        f -> f
      end)

    %{schema | fields: fields}
  end

  test "the stored seed declares private: true on email — and ONLY on email", %{schema: schema} do
    email_field = Enum.find(schema.fields, &(&1["name"] == "email"))
    assert email_field, "seeded author schema lost its email field"
    assert email_field["private"] == true

    # Scope line, declaration side: no sibling gained a visibility attr and the
    # SCHEMA-level visibility is untouched — this is a field clamp, nothing else.
    for f <- schema.fields, f["name"] != "email" do
      refute f["private"], "sibling #{f["name"]} must not be private"
      refute f["visibility"], "sibling #{f["name"]} must not carry visibility"
    end

    assert schema.visibility == "public"
  end

  test "anonymous render drops email; siblings byte-identical (THE SCOPE LINE)",
       %{schema: schema, doc: doc} do
    env_sealed = Envelope.render(doc, schema, nil)
    env_unsealed = Envelope.render(doc, strip_email_private(schema), nil)

    refute Map.has_key?(env_sealed, "email")

    # THE SCOPE LINE: the declaration changes exactly one key. Removing email
    # from the unsealed world reproduces the sealed envelope byte-for-byte.
    assert Map.delete(env_unsealed, "email") == env_sealed

    for k <- @siblings do
      assert env_sealed[k] == env_unsealed[k], "sibling #{k} changed under the seal"
    end

    # The seeded document really carries the payload the seal hides.
    assert env_unsealed["title"] == "Knut Melvaer"
    assert env_unsealed["role"] == "admin"
  end

  test "MUTATION ARM: stripping the attr reds the anon-drop — email leaks again",
       %{schema: schema, doc: doc} do
    env = Envelope.render(doc, strip_email_private(schema), CallerContext.anonymous())
    assert env["email"] == "knut@sanity.io"
  end

  test "explicit anonymous CallerContext is dropped too (nil is not special-cased)",
       %{schema: schema, doc: doc} do
    env = Envelope.render(doc, schema, CallerContext.anonymous())
    refute Map.has_key?(env, "email")
    assert env["role"] == "admin"
  end

  test "non-admin AUTHENTICATED caller also loses email (fail closed)",
       %{schema: schema, doc: doc} do
    ctx = %CallerContext{principal_type: :user, user_id: "user-1", is_admin: false}
    env = Envelope.render(doc, schema, ctx)
    refute Map.has_key?(env, "email")
    assert env["role"] == "admin"
  end

  test "admin caller still sees the email (no operator regression)",
       %{schema: schema, doc: doc} do
    ctx = %CallerContext{principal_type: :api_token, is_admin: true}
    env = Envelope.render(doc, schema, ctx)
    assert env["email"] == "knut@sanity.io"
  end

  test "filter/order oracle sealed: field_readable? refuses email for anon", %{schema: schema} do
    # The declaration seals BOTH chokepoints — render/3 above, and the
    # WHERE/ORDER oracle here (envelope.ex field_readable?/3 reads schema
    # attrs only, which is why a drop_field? value-sniffing branch would NOT
    # have sealed this leg).
    refute Envelope.field_readable?(schema, "email", CallerContext.anonymous())
    refute Envelope.field_readable?(schema, "email", nil)

    # Contrast leg: the refusal is attr-driven, not a blanket anon deny — a
    # public sibling stays filterable for the same anonymous caller.
    assert Envelope.field_readable?(schema, "bio", CallerContext.anonymous())

    # Non-admin authenticated callers are refused too; admins are not.
    refute Envelope.field_readable?(schema, "email", %CallerContext{
             principal_type: :user,
             user_id: "user-1",
             is_admin: false
           })

    assert Envelope.field_readable?(schema, "email", %CallerContext{
             principal_type: :api_token,
             is_admin: true
           })
  end
end
