defmodule Barkpark.Content.OwnerScopedTest do
  @moduledoc """
  Phase 4 (core-auth) — row/ownership ACL.

  Proves the INVARIANT: on an `owner_scoped: true` type, user A can never read
  user B's documents through ANY read entry point (single get, list, search,
  tag, alias, batch-by-id); admins and api-tokens see all; unowned (NULL
  owner_id) docs stay visible to everyone; and a non-owner_scoped type is
  byte-identical to today (no isolation, owner_id never stamped).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document}

  @dataset "test"
  @owned_type "secret_note"
  @open_type "post"

  setup do
    # An owner_scoped type and a plain (non-owner_scoped) type, same dataset.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @owned_type,
          "title" => "Secret Note",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @open_type,
          "title" => "Post",
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    # owner_id / user_id are :binary_id (UUID) — mirror real user-row ids.
    user_a = Ecto.UUID.generate()
    user_b = Ecto.UUID.generate()

    %{user_a: user_a, user_b: user_b}
  end

  # ── caller-context opts builders ──────────────────────────────────────────

  defp user_opts(user_id, roles \\ []),
    do: [caller_context: CallerContext.from_user(user_id, roles: roles)]

  defp admin_opts,
    do: [
      caller_context: %CallerContext{principal_type: :user, user_id: "admin-1", is_admin: true}
    ]

  defp token_opts,
    do: [caller_context: %CallerContext{principal_type: :api_token, token_id: "tok-1"}]

  defp anon_opts, do: [caller_context: CallerContext.anonymous()]

  # ── create helpers ────────────────────────────────────────────────────────

  defp create_owned(type, attrs, opts) do
    {:ok, doc} = Content.create_document(type, attrs, @dataset, opts)
    doc
  end

  defp ids(docs), do: docs |> Enum.map(& &1.doc_id) |> MapSet.new()

  # ════════════════════════════════════════════════════════════════════════
  # owner_id stamping on the write path
  # ════════════════════════════════════════════════════════════════════════

  describe "write-path owner_id stamping" do
    test "a non-admin user write stamps owner_id = the user's id", %{user_a: a} do
      doc = create_owned(@owned_type, %{"title" => "a-note"}, user_opts(a))
      assert Repo.get!(Document, doc.id).owner_id == a
    end

    test "an api-token write on an owner_scoped type leaves owner_id NULL (unowned)" do
      doc = create_owned(@owned_type, %{"title" => "tok-note"}, token_opts())
      assert Repo.get!(Document, doc.id).owner_id == nil
    end

    test "a user write on a NON-owner_scoped type never stamps owner_id", %{user_a: a} do
      doc = create_owned(@open_type, %{"title" => "open"}, user_opts(a))
      assert Repo.get!(Document, doc.id).owner_id == nil
    end

    test "a non-admin user cannot spoof owner_id to another user via attrs", %{
      user_a: a,
      user_b: b
    } do
      doc = create_owned(@owned_type, %{"title" => "spoof", "owner_id" => b}, user_opts(a))
      assert Repo.get!(Document, doc.id).owner_id == a
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # get_document/4 — single-doc isolation
  # ════════════════════════════════════════════════════════════════════════

  describe "get_document/4 isolation on an owner_scoped type" do
    setup %{user_a: a} do
      owned = create_owned(@owned_type, %{"title" => "a-secret"}, user_opts(a))
      unowned = create_owned(@owned_type, %{"title" => "shared"}, token_opts())
      %{owned: owned, unowned: unowned}
    end

    test "owner reads own doc", %{owned: owned, user_a: a} do
      assert {:ok, _} = Content.get_document(owned.doc_id, @owned_type, @dataset, user_opts(a))
    end

    test "a different user gets not_found for another user's doc", %{owned: owned, user_b: b} do
      assert {:error, :not_found} =
               Content.get_document(owned.doc_id, @owned_type, @dataset, user_opts(b))
    end

    test "admin reads any owner's doc", %{owned: owned} do
      assert {:ok, _} = Content.get_document(owned.doc_id, @owned_type, @dataset, admin_opts())
    end

    test "api-token reads any owner's doc (token sees all)", %{owned: owned} do
      assert {:ok, _} = Content.get_document(owned.doc_id, @owned_type, @dataset, token_opts())
    end

    test "anonymous cannot read an owned doc", %{owned: owned} do
      assert {:error, :not_found} =
               Content.get_document(owned.doc_id, @owned_type, @dataset, anon_opts())
    end

    test "unowned doc is visible to everyone", %{unowned: u, user_b: b} do
      assert {:ok, _} = Content.get_document(u.doc_id, @owned_type, @dataset, user_opts(b))
      assert {:ok, _} = Content.get_document(u.doc_id, @owned_type, @dataset, anon_opts())
      assert {:ok, _} = Content.get_document(u.doc_id, @owned_type, @dataset, token_opts())
    end

    test "no caller_context FAILS CLOSED on an owned doc (LOW-12)", %{owned: owned, unowned: u} do
      # A read that threads NO caller_context (an absent context, not a trusted
      # one) must NOT see another owner's row — fail closed, identical to
      # anonymous. Previously this returned the owned doc (fail-open).
      assert {:error, :not_found} = Content.get_document(owned.doc_id, @owned_type, @dataset, [])
      # Unowned (NULL owner_id) rows stay visible to a context-less read.
      assert {:ok, _} = Content.get_document(u.doc_id, @owned_type, @dataset, [])
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # list_documents/3 — collection isolation
  # ════════════════════════════════════════════════════════════════════════

  describe "list_documents/3 scoping" do
    setup %{user_a: a, user_b: b} do
      a1 = create_owned(@owned_type, %{"title" => "a1"}, user_opts(a))
      a2 = create_owned(@owned_type, %{"title" => "a2"}, user_opts(a))
      b1 = create_owned(@owned_type, %{"title" => "b1"}, user_opts(b))
      shared = create_owned(@owned_type, %{"title" => "shared"}, token_opts())
      %{a1: a1, a2: a2, b1: b1, shared: shared}
    end

    test "user A sees only own + unowned", ctx do
      %{user_a: a, a1: a1, a2: a2, shared: shared} = ctx
      got = ids(Content.list_documents(@owned_type, @dataset, user_opts(a)))
      assert got == ids([a1, a2, shared])
    end

    test "user B sees only own + unowned", ctx do
      %{user_b: b, b1: b1, shared: shared} = ctx
      got = ids(Content.list_documents(@owned_type, @dataset, user_opts(b)))
      assert got == ids([b1, shared])
    end

    test "admin sees all", ctx do
      %{a1: a1, a2: a2, b1: b1, shared: shared} = ctx
      got = ids(Content.list_documents(@owned_type, @dataset, admin_opts()))
      assert got == ids([a1, a2, b1, shared])
    end

    test "api-token sees all", ctx do
      %{a1: a1, a2: a2, b1: b1, shared: shared} = ctx
      got = ids(Content.list_documents(@owned_type, @dataset, token_opts()))
      assert got == ids([a1, a2, b1, shared])
    end

    test "anonymous sees only unowned", ctx do
      %{shared: shared} = ctx
      got = ids(Content.list_documents(@owned_type, @dataset, anon_opts()))
      assert got == ids([shared])
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # non-owner_scoped type — byte-identical (no isolation)
  # ════════════════════════════════════════════════════════════════════════

  describe "non-owner_scoped type is byte-identical" do
    test "all callers see every doc regardless of writer", %{user_a: a, user_b: b} do
      p_a = create_owned(@open_type, %{"title" => "by-a"}, user_opts(a))
      p_b = create_owned(@open_type, %{"title" => "by-b"}, user_opts(b))

      for opts <- [user_opts(a), user_opts(b), admin_opts(), token_opts(), anon_opts(), []] do
        got = ids(Content.list_documents(@open_type, @dataset, opts))
        assert got == ids([p_a, p_b])
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # search / tag / alias / batch read entry points
  # ════════════════════════════════════════════════════════════════════════

  describe "search_documents_by_title/5 isolation" do
    test "title search is isolated per user", %{user_a: a, user_b: b} do
      create_owned(@owned_type, %{"title" => "Zephyr A"}, user_opts(a))
      create_owned(@owned_type, %{"title" => "Zephyr B"}, user_opts(b))

      a_hits = Content.search_documents_by_title("Zephyr", @owned_type, @dataset, user_opts(a))
      assert Enum.map(a_hits, & &1.title) == ["Zephyr A"]

      b_hits = Content.search_documents_by_title("Zephyr", @owned_type, @dataset, user_opts(b))
      assert Enum.map(b_hits, & &1.title) == ["Zephyr B"]

      anon_hits = Content.search_documents_by_title("Zephyr", @owned_type, @dataset, anon_opts())
      assert anon_hits == []
    end
  end

  describe "Content.search_documents/3 (full-text retriever) isolation" do
    test "full-text search drops another user's owned rows", %{user_a: a, user_b: b} do
      create_owned(@owned_type, %{"title" => "Quokka A"}, user_opts(a))
      create_owned(@owned_type, %{"title" => "Quokka B"}, user_opts(b))
      create_owned(@owned_type, %{"title" => "Quokka shared"}, token_opts())

      titles = fn opts ->
        {hits, _total, _meta} =
          Content.search_documents("Quokka", @dataset, [perspective: :raw] ++ opts)

        hits |> Enum.map(& &1.title) |> Enum.sort()
      end

      assert titles.(user_opts(a)) == ["Quokka A", "Quokka shared"]
      assert titles.(user_opts(b)) == ["Quokka B", "Quokka shared"]
      assert titles.(anon_opts()) == ["Quokka shared"]
      # admin / api-token see every owner's row.
      assert titles.(admin_opts()) == ["Quokka A", "Quokka B", "Quokka shared"]
      assert titles.(token_opts()) == ["Quokka A", "Quokka B", "Quokka shared"]
    end
  end

  describe "docs_with_tag/4 isolation" do
    test "tag read is isolated per user", %{user_a: a, user_b: b} do
      create_owned(@owned_type, %{"title" => "ta", "tags" => ["shared-tag"]}, user_opts(a))
      create_owned(@owned_type, %{"title" => "tb", "tags" => ["shared-tag"]}, user_opts(b))

      a_docs = Content.docs_with_tag("shared-tag", @owned_type, @dataset, user_opts(a))
      assert Enum.map(a_docs, & &1.title) == ["ta"]

      b_docs = Content.docs_with_tag("shared-tag", @owned_type, @dataset, user_opts(b))
      assert Enum.map(b_docs, & &1.title) == ["tb"]
    end
  end

  describe "resolve_doc_by_title_or_alias/4 isolation" do
    test "wikilink resolution respects ownership", %{user_a: a, user_b: b} do
      create_owned(@owned_type, %{"title" => "Anchor"}, user_opts(a))

      assert %Document{title: "Anchor"} =
               Content.resolve_doc_by_title_or_alias(
                 "Anchor",
                 @owned_type,
                 @dataset,
                 user_opts(a)
               )

      assert Content.resolve_doc_by_title_or_alias(
               "Anchor",
               @owned_type,
               @dataset,
               user_opts(b)
             ) == nil
    end
  end

  describe "get_documents_by_ids/3 isolation (typeless batch)" do
    test "batch fetch drops rows the caller may not read", %{user_a: a, user_b: b} do
      owned = create_owned(@owned_type, %{"title" => "owned-by-a"}, user_opts(a))
      shared = create_owned(@owned_type, %{"title" => "shared"}, token_opts())
      ids_list = [owned.doc_id, shared.doc_id]

      a_map = Content.get_documents_by_ids(ids_list, @dataset, user_opts(a))
      assert Map.keys(a_map) |> MapSet.new() == MapSet.new(ids_list)

      b_map = Content.get_documents_by_ids(ids_list, @dataset, user_opts(b))
      assert Map.keys(b_map) == [shared.doc_id]

      token_map = Content.get_documents_by_ids(ids_list, @dataset, token_opts())
      assert Map.keys(token_map) |> MapSet.new() == MapSet.new(ids_list)

      anon_map = Content.get_documents_by_ids(ids_list, @dataset, anon_opts())
      assert Map.keys(anon_map) == [shared.doc_id]
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Content.owner_scoped?/3 helper
  # ════════════════════════════════════════════════════════════════════════

  describe "owner_scoped?/3" do
    test "true for an owner_scoped type, false otherwise / for a missing schema" do
      assert Content.owner_scoped?(@owned_type, @dataset) == true
      assert Content.owner_scoped?(@open_type, @dataset) == false
      assert Content.owner_scoped?("nope_missing", @dataset) == false
    end
  end
end
