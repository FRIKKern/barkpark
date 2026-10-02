defmodule BarkparkCloud.TelemetryTapTest do
  @moduledoc """
  `BarkparkCloud.TelemetryTap` keeps the `:telemetry` handler table — and the
  `persistent_term` behind it — untouched while tests run. These tests pin that it
  does, and that it behaves like `:telemetry.attach/4` from a test's side. The
  last test reds any cloud test that goes back to `:telemetry.attach` directly.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.TelemetryTap

  @event [:barkpark_cloud, :registry, :admin_token_withheld]

  defp emit(marker), do: :telemetry.execute(@event, %{count: 1}, %{tap_marker: marker})

  defp listen(id, marker) do
    test = self()

    TelemetryTap.attach(
      id,
      @event,
      fn
        event, measurements, %{tap_marker: m} = meta, config when m == marker ->
          send(test, {:tap, id, event, measurements, meta, config, self()})

        _event, _measurements, _meta, _config ->
          :ok
      end,
      :cfg
    )
  end

  test "a registered handler runs in the EMITTING process with telemetry's four arguments" do
    marker = make_ref()
    id = {__MODULE__, marker}
    assert :ok = listen(id, marker)

    emitter = Task.async(fn -> emit(marker) end)
    Task.await(emitter)

    assert_receive {:tap, ^id, @event, %{count: 1}, %{tap_marker: ^marker}, :cfg, pid}
    assert pid == emitter.pid

    assert :ok = TelemetryTap.detach(id)
    emit(marker)
    refute_receive {:tap, ^id, _, _, _, _, _}
  end

  test "attach and detach return what :telemetry.attach/4 and detach/1 return" do
    marker = make_ref()
    id = {__MODULE__, marker}
    assert :ok = listen(id, marker)
    assert {:error, :already_exists} = listen(id, marker)
    assert :ok = TelemetryTap.detach(id)
    assert {:error, :not_found} = TelemetryTap.detach(id)
  end

  test "registering and removing a handler never touches the :telemetry handler table" do
    before = :telemetry.list_handlers([])
    marker = make_ref()
    id = {__MODULE__, marker}

    :ok = listen(id, marker)
    during = :telemetry.list_handlers([])
    :ok = TelemetryTap.detach(id)

    assert during == before,
           "TelemetryTap.attach/4 changed the :telemetry handler table — every change " <>
             "is a persistent_term replace, the call that timed out under CI load"

    assert :telemetry.list_handlers([]) == before
  end

  test "an event the tap was not started with is refused, not silently never fired" do
    assert_raise ArgumentError, ~r/not listening to \[:barkpark_cloud, :r4d_never\]/, fn ->
      TelemetryTap.attach(
        {__MODULE__, make_ref()},
        [:barkpark_cloud, :r4d_never],
        fn _, _, _, _ -> :ok end,
        nil
      )
    end
  end

  test "a handler that raises is removed, as :telemetry removes one, and the others still run" do
    marker = make_ref()
    bad = {__MODULE__, :bad, marker}
    good = {__MODULE__, :good, marker}

    :ok =
      TelemetryTap.attach(
        bad,
        @event,
        fn
          _, _, %{tap_marker: m}, _ when m == marker -> raise "boom"
          _, _, _, _ -> :ok
        end,
        nil
      )

    :ok = listen(good, marker)

    log = capture_log(fn -> emit(marker) end)
    assert log =~ "failed and was removed"
    assert_receive {:tap, ^good, _, _, _, _, _}

    assert {:error, :not_found} = TelemetryTap.detach(bad)
    assert :ok = TelemetryTap.detach(good)
  end

  test "no cloud test calls :telemetry.attach/attach_many/detach directly" do
    root = Path.expand("..", __DIR__)
    self_path = Path.expand(__ENV__.file)

    offenders =
      for path <- Path.wildcard(Path.join(root, "**/*.{ex,exs}")),
          Path.expand(path) != self_path,
          not String.ends_with?(path, "support/telemetry_tap.ex"),
          source = read_raw!(path),
          Regex.match?(~r/:telemetry\.(attach|attach_many|detach)\(/, source),
          do: Path.relative_to(path, root)

    assert offenders == [],
           """
           These cloud test files call :telemetry.attach/attach_many/detach directly:

             #{Enum.join(offenders, "\n  ")}

           Each call replaces the persistent_term behind the handler table; under CI load
           the call to :telemetry_handler_table timed out (5 s) in eight jobs. Use
           BarkparkCloud.TelemetryTap.attach/4 and detach/1 — same arguments, same returns.
           """
  end

  # `:raw`, so the scan never queues behind other async tests' IO on file_server_2.
  defp read_raw!(path) do
    {:ok, fd} = :file.open(path, [:read, :raw, :binary])

    try do
      read_all(fd, [])
    after
      :file.close(fd)
    end
  end

  defp read_all(fd, acc) do
    case :file.read(fd, 1_048_576) do
      {:ok, chunk} -> read_all(fd, [acc | chunk])
      :eof -> IO.iodata_to_binary(acc)
    end
  end
end
