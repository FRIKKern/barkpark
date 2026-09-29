defmodule BarkparkWeb.WriteAdmissionHoldControllerTest do
  # C083: the trusted hold endpoint. Operator-gated; the hold is owned by the
  # Holder process, answers while held, reconciles duplicates, and reopen
  # advances the generation so the old capability refuses.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.Holder

  @admin "barkpark-hold-admin"
  @junior "barkpark-hold-junior"
  @path "/v1/admin/write-admission/hold"

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)
    {:ok, _} = Auth.create_token(@admin, "hold-admin", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior, "hold-junior", "test", ["read", "write"])

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-hold-http-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "hold-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)
    holder = start_supervised!(Holder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate, holder: holder}
  end

  defp as(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "hold, status, refusal while held, reconcile, reopen, stale capability", %{
    conn: conn,
    gate: gate
  } do
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert resp.status == 200, resp.resp_body
    view = Jason.decode!(resp.resp_body)
    cap = view["capability"]
    assert view["phase"] == "held"
    assert view["operation"] == "switch"
    assert is_integer(view["generation"])
    assert is_binary(view["boot"])
    assert Admission.status(gate).phase == :held

    # An admin write elsewhere is refused while held; the hold endpoint still answers.
    resp = conn |> as(@admin) |> post("/v1/schemas/test", Jason.encode!(%{"name" => "x"}))
    assert resp.status == 503
    resp = conn |> as(@admin) |> get("#{@path}/#{cap}")
    assert Jason.decode!(resp.resp_body)["phase"] == "held"

    # Same operation reconciles to the same capability; another is refused.
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert Jason.decode!(resp.resp_body)["capability"] == cap
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "other"}))
    assert resp.status == 409

    resp = conn |> as(@admin) |> delete("#{@path}/#{cap}")
    assert resp.status == 200, resp.resp_body
    reopened = Jason.decode!(resp.resp_body)
    assert reopened["phase"] == "open"
    assert reopened["generation"] == view["generation"] + 1
    assert Admission.status(gate).phase == :open

    resp = conn |> as(@admin) |> delete("#{@path}/#{cap}")
    assert resp.status == 404
    resp = conn |> as(@admin) |> get("#{@path}/#{cap}")
    assert resp.status == 404
  end

  test "a lost holder leaves recovery_required; explicit recovery reopens with a fresh generation",
       %{
         conn: conn,
         gate: gate,
         holder: holder
       } do
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert resp.status == 200, resp.resp_body
    held = Jason.decode!(resp.resp_body)

    # The Holder dies (a restart of the owning process); the coordinator keeps the instance blocked.
    Process.unlink(holder)
    Process.exit(holder, :kill)
    # The test supervisor restarts it, as the serving tree would; the fresh Holder owns nothing.
    next = await_holder(holder)
    assert Process.alive?(next)
    assert Admission.status(gate).phase == :recovery_required

    resp = conn |> as(@admin) |> get("/v1/admin/write-admission")
    assert resp.status == 200, resp.resp_body
    view = Jason.decode!(resp.resp_body)
    assert view["phase"] == "recovery_required"
    assert view["generation"] == held["generation"]
    assert view["pending"] == 0
    assert view["held"] == nil

    resp = conn |> as(@admin) |> get("#{@path}/#{held["capability"]}")
    assert resp.status == 404
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch-2"}))
    assert resp.status == 409

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => view["generation"] + 1, "pending" => 0})
      )

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "admission_closed"

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => view["generation"], "pending" => 1})
      )

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "recovery_refused"

    resp =
      conn
      |> as(@admin)
      |> post("/v1/admin/write-admission/recover", Jason.encode!(%{"generation" => "1"}))

    assert resp.status == 400

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => view["generation"], "pending" => 0})
      )

    assert resp.status == 200, resp.resp_body
    recovered = Jason.decode!(resp.resp_body)
    assert recovered["phase"] == "open"
    assert recovered["generation"] == view["generation"] + 1
    assert Admission.status(gate).phase == :open

    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch-3"}))
    assert resp.status == 200, resp.resp_body

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => recovered["generation"], "pending" => 0})
      )

    assert resp.status == 409
  end

  test "a writer that dies while closing leaves an uncertain root; recovery names its count", %{
    conn: conn,
    gate: gate
  } do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _ticket} = Admission.checkout(gate)
        send(parent, :admitted)
        receive do: (:die -> :ok)
      end)

    assert_receive :admitted
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert resp.status == 202, resp.resp_body
    assert Jason.decode!(resp.resp_body)["phase"] == "closing"

    send(writer, :die)
    await_phase(gate, :recovery_required)
    resp = conn |> as(@admin) |> get("/v1/admin/write-admission")
    view = Jason.decode!(resp.resp_body)
    assert view["phase"] == "recovery_required"
    assert view["pending"] == 1
    assert view["writers"] == 0
    assert view["dead_writers"] == 1
    assert view["held"] == "switch"

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => view["generation"], "pending" => 0})
      )

    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["reason"] == "write_admission_unreconciled"

    resp =
      conn
      |> as(@admin)
      |> post(
        "/v1/admin/write-admission/recover",
        Jason.encode!(%{"generation" => view["generation"], "pending" => 1})
      )

    assert resp.status == 200, resp.resp_body
    assert %{phase: :open, pending: 0} = Admission.status(gate)

    assert Jason.decode!(
             conn
             |> as(@admin)
             |> get("/v1/admin/write-admission")
             |> Map.get(:resp_body)
           )["held"] == nil
  end

  defp await_phase(gate, phase, waited \\ 0) do
    case Admission.status(gate).phase do
      ^phase -> :ok
      _ when waited > 2_000 -> flunk("phase never became #{phase}")
      _ -> :timer.sleep(20) && await_phase(gate, phase, waited + 20)
    end
  end

  defp await_holder(old, waited \\ 0) do
    case Process.whereis(Holder) do
      pid when is_pid(pid) and pid != old -> pid
      _ when waited > 2_000 -> flunk("the Holder was not restarted")
      _ -> :timer.sleep(20) && await_holder(old, waited + 20)
    end
  end

  test "non-admin is forbidden; a missing operation is a bad request", %{conn: conn} do
    resp = conn |> as(@junior) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert resp.status == 403
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{}))
    assert resp.status == 400
  end

  test "disabled admission answers 503 feature_not_configured", %{conn: conn} do
    Application.put_env(:barkpark, :write_admission, enabled: false)
    resp = conn |> as(@admin) |> post(@path, Jason.encode!(%{"operation" => "switch"}))
    assert resp.status == 503
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "feature_not_configured"
  end
end
