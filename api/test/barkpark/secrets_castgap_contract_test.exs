defmodule Barkpark.SecretsCastgapContractTest do
  @moduledoc """
  CONTRACT WITNESS (connectors W22, D199): the `Barkpark.Secrets` read/write
  functions take `scope` as a RAW binary and thread it straight into an Ecto
  query against a `:binary_id` column — a non-UUID binary raises
  `Ecto.Query.CastError` (the binary_id CastError gotcha), which the HTTP
  surface would serve as a 500.

  These tests are GREEN TODAY and document that context-layer contract: the
  context deliberately does NOT self-protect against garbage binaries (a
  binary IS a plausible workspace id per the D193 scope typespec — validating
  every call would tax the hot `ingest_token/0` path). The HTTP boundary is
  therefore responsible for guarding request-derived workspace ids with
  `Barkpark.Repo.uuid_or_nil/1` BEFORE calling into Secrets — see
  `BarkparkWeb.SecretController.resolve_scope/1` and the forged-assigns test
  in `scoped_secret_controller_test.exs`.

  If a future change makes the context self-validating (folding a non-UUID
  into the fail-closed arm), these assertions flip — update the controller
  guard's rationale in the same commit rather than deleting the witness.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Secrets

  @garbage "not-a-uuid"

  test "get/2 raises Ecto.Query.CastError on a non-UUID scope binary" do
    assert_raise Ecto.Query.CastError, fn -> Secrets.get("ingest_token", @garbage) end
  end

  test "reveal/2 raises Ecto.Query.CastError on a non-UUID scope binary" do
    assert_raise Ecto.Query.CastError, fn ->
      Secrets.reveal("ingest_token", scope: @garbage)
    end
  end

  test "put/3 raises Ecto.Query.CastError on a non-UUID scope binary (no self-protection)" do
    assert_raise Ecto.Query.CastError, fn ->
      Secrets.put("castgap_probe", "value", scope: @garbage)
    end
  end

  test "delete/2 raises Ecto.Query.CastError on a non-UUID scope binary" do
    assert_raise Ecto.Query.CastError, fn ->
      Secrets.delete("ingest_token", scope: @garbage)
    end
  end

  test "list/1 raises Ecto.Query.CastError on a non-UUID scope binary" do
    assert_raise Ecto.Query.CastError, fn -> Secrets.list(@garbage) end
  end
end
