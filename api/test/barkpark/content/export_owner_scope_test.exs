defmodule Barkpark.Content.ExportOwnerScopeTest do
  @moduledoc """
  `Content.Export.export_stream/2` narrows `owner_scoped` types exactly as the
  query path does (task-5bd361033523a8c1).

  `Content.Query` runs every owner_scoped read through `Scope.scope_to_owner/2`
  (`maybe_scope_to_owner/4`). The export stream applied workspace and grant
  scope but no owner narrowing, so a USER principal (a session grantee) that
  `/v1/data/query` narrows to her own rows exported every user's rows of an
  owner_scoped type. Tokens and admins are unchanged (scope_to_owner is a no-op
  for them), unowned rows stay visible, and non-owner_scoped types are untouched.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @dataset "test"
  @owned_type "export_secret_note"
  @open_type "export_open_post"

  setup do
    for {name, owner_scoped} <- [{@owned_type, true}, {@open_type, false}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "owner_scoped" => owner_scoped,
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @dataset
        )
    end

    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    create!(@owned_type, "note-a", user(a))
    create!(@owned_type, "note-b", user(b))
    create!(@owned_type, "note-unowned", token())
    create!(@open_type, "post-b", user(b))

    %{a: a, b: b}
  end

  defp user(id), do: [caller_context: CallerContext.from_user(id, roles: [])]

  defp token,
    do: [caller_context: %CallerContext{principal_type: :api_token, token_id: "tok-export"}]

  defp admin,
    do: [
      caller_context: %CallerContext{principal_type: :user, user_id: "admin-x", is_admin: true}
    ]

  # The ownership fixtures name no workspace (instance-wide), as owner_scoped_test does.
  defp create!(type, doc_id, opts) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => doc_id},
        @dataset,
        [instance_wide: true] ++ opts
      )
  end

  defp exported(opts) do
    {:ok, ids} =
      Repo.transaction(fn ->
        @dataset
        |> Content.export_stream(opts)
        |> Enum.map(&(&1["_id"] || &1[:_id]))
      end)

    ids
    |> Enum.map(&String.replace_prefix(&1, "drafts.", ""))
    |> Enum.filter(&(&1 in ~w(note-a note-b note-unowned post-b)))
    |> Enum.sort()
  end

  test "a user principal exports her own and unowned rows of an owner_scoped type, never another user's",
       %{a: a} do
    assert exported(user(a)) == ~w(note-a note-unowned post-b)
    assert exported(user(a) ++ [type: @owned_type]) == ~w(note-a note-unowned)
  end

  test "the other user sees the mirror image", %{b: b} do
    assert exported(user(b)) == ~w(note-b note-unowned post-b)
  end

  test "tokens and admins still export every row (scope_to_owner is a no-op for them)" do
    assert exported(token()) == ~w(note-a note-b note-unowned post-b)
    assert exported(admin()) == ~w(note-a note-b note-unowned post-b)
  end
end
