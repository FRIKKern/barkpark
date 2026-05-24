defmodule Barkpark.Media.EventsTest do
  use ExUnit.Case, async: false

  alias Barkpark.Media.Events
  alias Barkpark.Media.MediaFile

  setup do
    original = Application.get_env(:barkpark, :media_webhooks)
    on_exit(fn -> Application.put_env(:barkpark, :media_webhooks, original) end)
    :ok
  end

  test "dispatch delivers signed payload to configured endpoint" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-barkpark-signature") != []
      assert Plug.Conn.get_req_header(conn, "x-barkpark-timestamp") != []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["event"] == "media.processed"
      Plug.Conn.resp(conn, 200, "")
    end)

    Application.put_env(:barkpark, :media_webhooks,
      endpoints: [
        %{
          url: "http://127.0.0.1:#{bypass.port}/hook",
          secret: "hook-secret",
          events: ["media.processed"]
        }
      ]
    )

    file = %MediaFile{
      id: Ecto.UUID.generate(),
      dataset: "production",
      path: "2026/05/a.png",
      mime_type: "image/png",
      filename: "a.png",
      original_name: "a.png"
    }

    Events.dispatch("production", "media.processed", file, nil)
    drain_tasks()
  end

  defp drain_tasks do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      Process.sleep(20)

      case Task.Supervisor.children(Barkpark.TaskSupervisor) do
        [] -> :done
        _ -> :wait
      end
    end)
    |> Enum.find_value(deadline, fn
      :done -> :ok
      :wait -> if System.monotonic_time(:millisecond) >= deadline, do: :timeout, else: nil
    end)
  end
end
