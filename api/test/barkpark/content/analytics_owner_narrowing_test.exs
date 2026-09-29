defmodule Barkpark.Content.AnalyticsOwnerNarrowingTest do
  @moduledoc """
  task-188996c5008f4299 — `Analytics.type_census/2` and the row/ownership ACL.

  THE SUBJECT HAS TO BE ARMED HERE. `owner_scoped` is a CONSUMER-SET schema
  flag and NO plugin in this repo declares it, so a test written against an
  existing type would exercise the `owner_scoped?/3 == false` arm and pass
  whether or not the clamp exists — a green with no subject. Every test below
  therefore DECLARES a fixture type carrying `owner_scoped: true`, seeds
  documents under two distinct owners, and asserts on the …Rest count the
  Studio desk renders from this census.

  The detector is "a member's Rest count for an owner_scoped type is THEIR
  rows, not every owner's": delete the `maybe_scope_to_owner/4` line from
  `type_census/2` and it fails 2 == 4.

  The non-owner-scoped arms are the fence: this PR closes the OWNERSHIP
  boundary only, and a type that never opted in must stay byte-identical.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Analytics, CallerContext}

  @dataset "test"
  @owned_type "census_secret_note"
  @open_type "census_post"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @owned_type,
          "title" => "Census Secret Note",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @open_type,
          "title" => "Census Post",
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    %{user_a: Ecto.UUID.generate(), user_b: Ecto.UUID.generate()}
  end

  defp user_opts(uid), do: [caller_context: CallerContext.from_user(uid, roles: [])]
  defp anon_opts, do: [caller_context: CallerContext.anonymous()]

  defp admin_opts,
    do: [
      caller_context: %CallerContext{
        principal_type: :user,
        user_id: Ecto.UUID.generate(),
        is_admin: true
      }
    ]

  defp token_opts,
    do: [caller_context: %CallerContext{principal_type: :api_token, token_id: "tok-census"}]

  # Instance-wide writes (no workspace) — the ownership stamp needs a principal
  # but this suite tests ownership, not tenancy. Same class-(c) declaration as
  # `Barkpark.Content.OwnerScopedTest`.
  defp seed(type, title, opts) do
    {:ok, doc} =
      Content.create_document(type, %{"title" => title}, @dataset, [instance_wide: true] ++ opts)

    doc
  end

  defp count_for(type, opts) do
    case Enum.find(Analytics.type_census(@dataset, opts), &(&1.type == type)) do
      nil -> 0
      %{total: total} -> total
    end
  end

  describe "an owner_scoped type's …Rest census count" do
    test "a member counts THEIR rows, not every owner's", %{user_a: a, user_b: b} do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "a-2", user_opts(a))
      seed(@owned_type, "b-1", user_opts(b))
      seed(@owned_type, "b-2", user_opts(b))

      # THE DETECTOR. Without the clamp this reads 4 — every owner's documents.
      assert count_for(@owned_type, user_opts(a)) == 2
      assert count_for(@owned_type, user_opts(b)) == 2
    end

    test "the unowned base stays visible to every owner", %{user_a: a, user_b: b} do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "b-1", user_opts(b))
      # An api-token write on an owner_scoped type leaves owner_id NULL.
      seed(@owned_type, "shared", token_opts())

      assert count_for(@owned_type, user_opts(a)) == 2
      assert count_for(@owned_type, user_opts(b)) == 2
    end

    test "anonymous sees only the unowned base", %{user_a: a} do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "shared", token_opts())

      assert count_for(@owned_type, anon_opts()) == 1
    end

    test "a census with NO caller_context fails CLOSED to the unowned base", %{user_a: a} do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "shared", token_opts())

      assert count_for(@owned_type, []) == 1
    end

    test "an admin and an api-token still see every owner's rows", %{user_a: a, user_b: b} do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "b-1", user_opts(b))

      assert count_for(@owned_type, admin_opts()) == 2
      assert count_for(@owned_type, token_opts()) == 2
    end
  end

  describe "the fence: a NON-owner_scoped type is byte-identical" do
    test "every caller counts every row of a type that never opted in", %{user_a: a, user_b: b} do
      seed(@open_type, "o-1", user_opts(a))
      seed(@open_type, "o-2", user_opts(b))
      seed(@open_type, "o-3", token_opts())

      assert count_for(@open_type, user_opts(a)) == 3
      assert count_for(@open_type, user_opts(b)) == 3
      assert count_for(@open_type, anon_opts()) == 3
      assert count_for(@open_type, []) == 3
    end

    test "an owner_scoped type in the census does not narrow its non-scoped neighbour", %{
      user_a: a,
      user_b: b
    } do
      seed(@owned_type, "a-1", user_opts(a))
      seed(@owned_type, "b-1", user_opts(b))
      seed(@open_type, "o-1", user_opts(a))
      seed(@open_type, "o-2", user_opts(b))

      # The clamp is a PER-TYPE predicate. A whole-query clamp
      # (`maybe_scope_to_owner_any/4`'s fail-closed shape) would read 1 here.
      assert count_for(@open_type, user_opts(a)) == 2
      assert count_for(@owned_type, user_opts(a)) == 1
    end
  end
end
