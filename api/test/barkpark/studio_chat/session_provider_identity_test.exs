defmodule Barkpark.StudioChat.SessionProviderIdentityTest do
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.Session

  @session_id "11111111-1111-4111-8111-111111111111"
  @host_id "22222222-2222-4222-8222-222222222222"

  test "omitted identity preserves the legacy Claude managed session contract" do
    changeset = Session.create_changeset(%Session{}, %{id: @session_id})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :provider) == "claude"
    assert Ecto.Changeset.get_field(changeset, :execution_target) == "managed"
    assert Ecto.Changeset.get_field(changeset, :execution_host_id) == nil
    assert Ecto.Changeset.get_field(changeset, :provider_session_id) == @session_id
  end

  test "explicit registered-host identity round trips through the create changeset" do
    changeset =
      Session.create_changeset(%Session{}, %{
        id: @session_id,
        provider: "codex",
        execution_target: "registered_host",
        execution_host_id: @host_id
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :provider) == "codex"
    assert Ecto.Changeset.get_field(changeset, :execution_target) == "registered_host"
    assert Ecto.Changeset.get_field(changeset, :execution_host_id) == @host_id
    assert Ecto.Changeset.get_field(changeset, :provider_session_id) == nil
  end

  test "registered-host Claude identity stays unset until the host runtime reports it" do
    changeset =
      Session.create_changeset(%Session{}, %{
        id: @session_id,
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: @host_id
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :provider_session_id) == nil
  end

  test "invalid providers and target/host combinations fail before persistence" do
    invalid_provider =
      Session.create_changeset(%Session{}, %{id: @session_id, provider: "other"})

    managed_with_host =
      Session.create_changeset(%Session{}, %{
        id: @session_id,
        execution_target: "managed",
        execution_host_id: @host_id
      })

    registered_without_host =
      Session.create_changeset(%Session{}, %{
        id: @session_id,
        execution_target: "registered_host"
      })

    refute invalid_provider.valid?
    assert "is invalid" in errors_on(invalid_provider).provider
    refute managed_with_host.valid?
    assert "must be empty for managed execution" in errors_on(managed_with_host).execution_host_id
    refute registered_without_host.valid?

    assert "is required for registered-host execution" in errors_on(registered_without_host).execution_host_id
  end

  test "the Cloud sandbox binding is a distinct field, unset at create (charter D137)" do
    # The binding is stamped POST-create by the runtime seam (a swallowed
    # bp_sandbox frame), never at session birth — so a fresh session carries no
    # sandbox id and the create changeset does not cast it.
    assert %Session{cloud_sandbox_id: nil} = %Session{}

    changeset = Session.create_changeset(%Session{}, %{id: @session_id})
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :cloud_sandbox_id) == nil

    # It is independent of the write-once provider identity: setting the sandbox
    # binding on a struct never touches provider_session_id and vice-versa.
    assert %Session{cloud_sandbox_id: "sbx-1", provider_session_id: nil} =
             %Session{cloud_sandbox_id: "sbx-1"}
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.fetch!(String.to_existing_atom(key)) |> to_string()
      end)
    end)
  end
end
