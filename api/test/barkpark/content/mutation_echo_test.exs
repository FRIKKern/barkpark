defmodule Barkpark.Content.MutationEchoTest do
  @moduledoc """
  Red-team HIGH regression: `apply_mutations` echoes each mutated document back
  in the batch result. Before the fix that echo used the `:internal`
  no-redaction sentinel — so a `patch` op (which merges server-side
  `existing.content` the caller never supplied) would return a private field's
  plaintext to a non-admin write caller, the same field a GET redacts.

  The fix renders every echo through the REAL caller + the type's schema. This
  test exercises the shared echo line via a `create` (no scope/draft plumbing
  needed); `patch.set` / `patch.unset` route through the identical line, and the
  per-field redaction itself is covered by `Barkpark.Content.EnvelopeTest`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @dataset "echo_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "profile",
        "title" => "Profile",
        "visibility" => "public",
        "fields" => [%{"name" => "salary", "type" => "string", "private" => true}]
      },
      @dataset
    )

    :ok
  end

  defp non_admin, do: CallerContext.from_token(%{id: "t-w", permissions: ["read", "write"]})
  defp admin, do: CallerContext.from_token(%{id: "t-a", permissions: ["read", "write", "admin"]})

  defp create_echo(id, opts) do
    mutation = %{
      "create" => %{
        "_id" => id,
        "_type" => "profile",
        "title" => "Ada",
        "content" => %{"salary" => "100000", "bio" => "hi"}
      }
    }

    {:ok, {_tx, [result]}} = Content.apply_mutations([mutation], @dataset, opts)
    result.document
  end

  test "a non-admin caller's mutation echo does NOT leak the private field" do
    doc = create_echo("c-nonadmin", caller_context: non_admin())
    refute Map.has_key?(doc, "salary")
    # non-private content still echoed (proves it isn't a blanket drop)
    assert doc["bio"] == "hi"
  end

  test "an admin caller's mutation echo DOES include the private field" do
    doc = create_echo("c-admin", caller_context: admin())
    assert doc["salary"] == "100000"
  end

  test "no caller_context (anonymous) fails closed — private field redacted" do
    doc = create_echo("c-anon", [])
    refute Map.has_key?(doc, "salary")
  end
end
