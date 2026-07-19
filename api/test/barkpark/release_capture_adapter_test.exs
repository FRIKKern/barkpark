defmodule Barkpark.CycleFleet.ReleaseCaptureAdapterTest do
  use ExUnit.Case, async: false

  alias Barkpark.CycleFleet.ReleaseCaptureAdapter
  alias Barkpark.CycleFleet.ReleaseCaptureAdapter.Production

  test "public smoke loads its configured adapter after a cold boot" do
    previous = Application.get_env(:barkpark, :cycle_release_capture_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :cycle_release_capture_adapter, previous),
        else: Application.delete_env(:barkpark, :cycle_release_capture_adapter)

      Code.ensure_loaded!(Production)
    end)

    Application.put_env(:barkpark, :cycle_release_capture_adapter, Production)
    :code.purge(Production)
    :code.delete(Production)

    refute Code.loaded?(Production)

    refute ReleaseCaptureAdapter.public_smoke(%{}) ==
             {:error, :public_release_smoke_unavailable}

    assert Code.loaded?(Production)
  end
end
