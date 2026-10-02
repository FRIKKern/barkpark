defmodule Barkpark.EtsCacheOwnershipTest do
  # task-45913114e6d4ffbe: these caches were created lazily by whichever process
  # touched them first, so they died with that process (a request, a Task, an
  # async test) and a sibling's next :ets call raised ArgumentError. Each is now
  # created in Barkpark.Application.start/2, beside the CorpusSlots table that
  # already follows this rule, and so shares that table's long-lived owner.
  use ExUnit.Case, async: true

  @app_owned [
    :barkpark_dek_cache,
    :barkpark_tenancy_default_scope_cache,
    :barkpark_codelists_alias_cache
  ]

  test "each cache is owned by the application-start process, like the CorpusSlots table" do
    boot_owner = :ets.info(Barkpark.Content.Graph.CorpusSlots.table(), :owner)

    assert is_pid(boot_owner) and Process.alive?(boot_owner)

    for table <- @app_owned do
      assert :ets.whereis(table) != :undefined, "#{table} does not exist after boot"
      assert :ets.info(table, :owner) == boot_owner, "#{table} is owned by a caller, not the app"
    end
  end
end
