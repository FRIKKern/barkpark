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
