defmodule Barkpark.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Barkpark.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Barkpark.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Barkpark.DataCase
    end
  end

  setup tags do
    Barkpark.DataCase.setup_sandbox(tags)
    Barkpark.DataCase.ensure_default_tenancy()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Barkpark.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Guarantee the seeded Default Workspace/Project exist inside the per-test
  sandbox. The backfill migration (20260527110200) seeds them at the schema
  level, so this is a no-op read in the normal case — but a per-test sandbox
  that started before/without that committed data gets them created here, so
  the flat back-compat (Default-scope) reads and the tenancy fixtures behave.
  Idempotent: only inserts when absent.
  """
  def ensure_default_tenancy do
    _ = Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
