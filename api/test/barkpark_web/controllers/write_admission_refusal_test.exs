defmodule BarkparkWeb.WriteAdmissionRefusalTest do
  # C083 slice 6: refused route groups (D-managed-writers) answer 503 while held,
  # before any controller runs; reads pass; reopen admits.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-refusal-http-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "refusal-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  @schema %{"name" => "held_post", "title" => "Held", "visibility" => "public", "fields" => []}

  test "held refuses schema CRUD and webhook create with 503, reads pass, reopen admits", %{
    conn: conn,
    gate: gate
  } do
    holder = hold(gate)

    resp = conn |> authed() |> post("/v1/schemas/test", Jason.encode!(@schema))
    assert resp.status == 503
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "storage_unavailable"
    assert body["error"]["reason"] == "write_admission_admission_closed"
    assert {:error, :not_found} = Barkpark.Content.get_schema("held_post", "test")

    resp = conn |> authed() |> post("/v1/webhooks/test", Jason.encode!(%{"url" => "https://x"}))
    assert resp.status == 503

    resp = conn |> authed() |> get("/v1/schemas/test")
    assert resp.status == 200

    send(holder, :release)
    assert_receive {:released, :ok}

    resp = conn |> authed() |> post("/v1/schemas/test", Jason.encode!(@schema))
    assert resp.status in 200..299, resp.resp_body
    assert Admission.status(gate).pending == 0
  end

  defp hold(gate) do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, :held, ticket} =
          Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

        send(parent, :held)

        receive do
          :release -> send(parent, {:released, Admission.reopen(gate, ticket)})
        end
      end)

    assert_receive :held
    holder
  end
end
