defmodule BarkparkCloud.DataCase do
  @moduledoc """
  Setup for tests requiring access to the control plane's data layer.

  Enables the Ecto SQL sandbox so DB changes are reverted at the end of every
  test. Mirrors api/'s `Barkpark.DataCase` (minus the tenancy/plugin
  fixtures the control plane doesn't have). Tests that interact with the DB
  may run async via `use BarkparkCloud.DataCase, async: true`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias BarkparkCloud.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BarkparkCloud.DataCase
    end
  end

  setup tags do
    BarkparkCloud.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Sets up the sandbox based on the test tags."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(BarkparkCloud.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.register_user(%{password: "short"})
      assert "should be at least 12 character(s)" in errors_on(changeset).password
      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
