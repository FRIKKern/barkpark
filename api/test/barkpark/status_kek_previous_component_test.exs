defmodule Barkpark.StatusKekPreviousComponentTest do
  @moduledoc """
  /status.json must SURFACE a malformed BARKPARK_KEK_PREVIOUS entry.

  A boot log line alone is theatre: nobody reads it, which is the exact failure
  mode this lane already proved with the Logger level. `config/runtime.exs`
  records a machine-readable verdict under `Barkpark.Crypto.LocalKek`'s
  `:kek_previous_audit`; `Barkpark.Status.kek_previous_component/0` republishes
  it on the public status payload, where an unattended owner (or their uptime
  monitor, with no bearer token) actually looks.

  The load-bearing property these tests pin: a FAILED READ of the audit can
  never render as a healthy box.
  """
  # async: false — mutates application env read by Status.health/0.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Status
  alias BarkparkWeb.StatusController

  setup do
    prev = Application.get_env(:barkpark, Barkpark.Crypto.LocalKek, [])
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Crypto.LocalKek, prev) end)

    put_audit = fn audit ->
      Application.put_env(
        :barkpark,
        Barkpark.Crypto.LocalKek,
        Keyword.put(prev, :kek_previous_audit, audit)
      )
    end

    drop_audit = fn ->
      Application.put_env(
        :barkpark,
        Barkpark.Crypto.LocalKek,
        Keyword.delete(prev, :kek_previous_audit)
      )
    end

    {:ok, put_audit: put_audit, drop_audit: drop_audit}
  end

  defp kek_component(body), do: Enum.find(body["components"], &(&1["name"] == "kek_previous"))

  describe "the four audit states are distinguishable" do
    test "checked and clean is operational with NO detail", %{put_audit: put_audit} do
      put_audit.(%{checked: true, discarded: 0, positions: []})

      assert Status.kek_previous_component() ==
               %{component: :kek_previous, status: :operational, detail: nil}

      # And the JSON projection drops the key entirely — the one silent arm.
      assert StatusController.component_json(Status.kek_previous_component()) ==
               %{name: :kek_previous, status: :operational}
    end

    test "discarded entries are degraded and NAME count + 1-based positions", %{
      put_audit: put_audit
    } do
      put_audit.(%{checked: true, discarded: 2, positions: [1, 3]})
      component = Status.kek_previous_component()

      assert component.status == :degraded
      assert component.detail =~ "BARKPARK_KEK_PREVIOUS: 2 malformed entries"
      assert component.detail =~ "positions 1, 3"
    end

    test "a single discarded entry reads in the singular", %{put_audit: put_audit} do
      put_audit.(%{checked: true, discarded: 1, positions: [2]})
      component = Status.kek_previous_component()

      assert component.status == :degraded
      assert component.detail =~ "1 malformed entry"
      assert component.detail =~ "position 2"
      refute component.detail =~ "positions"
    end

    test "checked: false is operational but SAYS it did not apply", %{put_audit: put_audit} do
      put_audit.(%{checked: false, discarded: 0, positions: []})
      component = Status.kek_previous_component()

      assert component.status == :operational
      assert component.detail =~ "not applicable"
      assert component.detail =~ "BARKPARK_KEK is unset"
      # NOT confusable with the clean arm, whose detail is nil.
      refute component.detail == nil
    end

    test "a MISSING audit is degraded and says UNKNOWN, never healthy", %{drop_audit: drop_audit} do
      drop_audit.()
      component = Status.kek_previous_component()

      # THE POINT: a failed read of the field must not look like a healthy box.
      assert component.status == :degraded
      assert component.detail =~ "audit is MISSING"
      assert component.detail =~ "UNKNOWN"
    end

    test "a config shape that is not a keyword list does not 500 the page" do
      Application.put_env(:barkpark, Barkpark.Crypto.LocalKek, %{key: "nonsense"})
      component = Status.kek_previous_component()

      assert component.status == :degraded
      assert component.detail =~ "audit is MISSING"
    end
  end

  describe "the finding reaches /status.json" do
    test "a malformed entry is published, naming count and positions but NEVER the entry", %{
      conn: conn,
      put_audit: put_audit
    } do
      put_audit.(%{checked: true, discarded: 1, positions: [2]})

      body = conn |> get("/status.json") |> json_response(200)
      component = kek_component(body)

      assert component["status"] == "degraded"
      assert component["detail"] =~ "1 malformed entry"
      assert component["detail"] =~ "position 2"
      # Key material is never echoed: the payload carries positions, not values.
      refute component["detail"] =~ "="
      # A degraded component drags the overall verdict down, so a monitor that
      # only reads `status` still notices.
      assert body["status"] == "degraded"
    end

    test "a clean box publishes the component with no detail at all", %{
      conn: conn,
      put_audit: put_audit
    } do
      put_audit.(%{checked: true, discarded: 0, positions: []})

      body = conn |> get("/status.json") |> json_response(200)

      assert kek_component(body) == %{"name" => "kek_previous", "status" => "operational"}
      assert body["status"] == "operational"
    end

    test "a MISSING audit surfaces on the payload as degraded", %{
      conn: conn,
      drop_audit: drop_audit
    } do
      drop_audit.()

      body = conn |> get("/status.json") |> json_response(200)

      assert kek_component(body)["status"] == "degraded"
      assert kek_component(body)["detail"] =~ "UNKNOWN"
    end
  end
end
