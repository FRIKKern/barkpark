defmodule Barkpark.ApplicationManagedBootTest do
  # C083 slice 6: a managed instance refuses offline boots, and its coordinator
  # starts after SchemaBootstrap (pre-open schema writes) and before Oban.
  use ExUnit.Case, async: false

  alias Barkpark.Application, as: App

  @plugin_children [{Task.Supervisor, name: :c083_plugin_sentinel}]

  test "seed and one-shot boots are refused only when admission is enabled" do
    for mode <- [:seed, :one_shot] do
      assert_raise ArgumentError, ~r/refuses a #{inspect(mode)} boot/, fn ->
        App.refuse_managed_offline_boot!(mode, enabled: true, instance_id: "x")
      end

      assert :ok == App.refuse_managed_offline_boot!(mode, [])
      assert :ok == App.refuse_managed_offline_boot!(mode, enabled: false)
    end

    assert :ok == App.refuse_managed_offline_boot!(:full, enabled: true, instance_id: "x")
  end

  test "the coordinator sits after SchemaBootstrap and before Oban in the full tree" do
    previous = Application.get_env(:barkpark, :write_admission)

    Application.put_env(:barkpark, :write_admission,
      enabled: true,
      instance_id: "c083-order",
      journal: "/tmp/c083-order.dets"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)
    end)

    children = App.child_specs(@plugin_children, Application.fetch_env!(:barkpark, Oban), [], [])

    index = fn pred -> Enum.find_index(children, pred) end
    schema = index.(&(&1 == Barkpark.SchemaBootstrap))
    gate = index.(&match?({Barkpark.ManagedRuntime.WriteAdmission, _}, &1))
    oban = index.(&match?({Oban, _}, &1))

    assert schema != nil and gate != nil and oban != nil
    assert schema < gate and gate < oban
  end
end
