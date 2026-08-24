defmodule BarkparkWeb.Integration.V1MediaGovernanceTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Media
  alias Barkpark.Media.Storage.SignedUrl
  alias Barkpark.Plugins.Media.Assets

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    # Own, non-colliding token. The seeded `barkpark-dev-token` (raw value)
    # carries the label "dev-studio"; minting the same raw value here would
    # hit the unique token_hash constraint and silently leave the seeded
    # "dev-studio" label in place, so `checkedOutBy` came back "dev-studio".
    # A dedicated raw token makes the asserted "dev" label deterministic.
    Auth.create_token(
      "governance-dev-token",
      "dev",
      "v1-media-governance",
      ["read", "write", "admin"]
    )

    Auth.create_token("other-editor-token", "other-editor", "production", ["read", "write"])

    drain_task_supervisor(30_000)

    {:ok, other_token: "other-editor-token"}
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer governance-dev-token")

  defp other_editor(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "gov-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: "pixel.png",
      content_type: "image/png"
    }
  end

  defp upload_asset(conn) do
    conn
    |> authed()
    |> post(~p"/v1/media/production/upload", %{"file" => png_upload()})
    |> json_response(201)
  end

  defp cleanup(%{"result" => %{"id" => id, "path" => path}}) do
    File.rm(Path.join(Media.upload_dir(), path))
    Media.Renditions.delete_for_file(id)
    Assets.delete_for_blob(id, "production")
  end

  describe "delivery access control" do
    test "private asset requires auth to download", %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"bp_visibility" => "private"})
      |> json_response(200)

      url = created["result"]["originalUrl"]

      assert build_conn() |> get(url) |> Map.get(:status) == 403

      assert build_conn() |> authed() |> get(url) |> Map.get(:status) == 200

      cleanup(created)
    end

    test "token visibility accepts signed URLs without auth", %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"bp_visibility" => "token"})
      |> json_response(200)

      url = created["result"]["originalUrl"]
      assert build_conn() |> get(url) |> Map.get(:status) == 403

      signed = SignedUrl.sign(url, id)

      assert build_conn() |> get(signed) |> Map.get(:status) == 200

      cleanup(created)
    end
  end

  # SPLIT FROM ONE TEST INTO TWO (task-d55b02001cf589f0).
  #
  # This block used to hold a SINGLE test, "returns signed delivery URLs for
  # token assets", whose request went out WITHOUT `authed()` — the only request
  # in this file that did. `conn_case.ex` hands out a bare `build_conn()`, so it
  # carried no Authorization header at all: the test asserted, and kept GREEN,
  # that an ANONYMOUS caller is minted a valid `SignedUrl` for a `token` asset.
  # It was the repro, standing in the suite as a specification.
  #
  # A single test could not survive the fix honestly. Adding `authed()` to it
  # would have kept a passing assertion while deleting the only evidence anyone
  # had ever asked the anonymous question. So it is now a PAIR that cannot both
  # pass on a broken surface: the positive names its credential, and the
  # negative is what the positive is worth.
  describe "appendRequestSecret" do
    test "returns signed delivery URLs for token assets — for an AUTHORISED caller",
         %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"bp_visibility" => "token"})
      |> json_response(200)

      resp =
        conn
        |> authed()
        |> get(~p"/v1/media/production/#{id}?appendRequestSecret=true")
        |> json_response(200)

      assert resp["result"]["originalUrl"] =~ "_="
      assert resp["result"]["visibility"] == "token"

      # The signature is not decorative: it is what makes the bytes reachable.
      assert build_conn() |> get(resp["result"]["originalUrl"]) |> Map.get(:status) == 200

      cleanup(created)
    end

    test "mints NOTHING for an anonymous caller", %{conn: conn} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      conn
      |> authed()
      |> patch(~p"/v1/media/production/#{id}", %{"bp_visibility" => "token"})
      |> json_response(200)

      resp = build_conn() |> get(~p"/v1/media/production/#{id}?appendRequestSecret=true")

      assert resp.status == 403,
             "an anonymous caller read a token asset: #{resp.status} #{resp.resp_body}"

      cleanup(created)
    end
  end

  describe "checkout" do
    test "checkout and undo-checkout flow", %{conn: conn, other_token: other_token} do
      created = upload_asset(conn)
      id = created["result"]["id"]

      checked_out =
        conn
        |> authed()
        |> post(~p"/v1/media/production/#{id}/checkout")
        |> json_response(200)

      assert checked_out["result"]["asset"]["checkedOutBy"] == "dev"

      conflict =
        conn
        |> other_editor(other_token)
        |> post(~p"/v1/media/production/#{id}/checkout")

      assert conflict.status == 409

      released =
        conn
        |> authed()
        |> post(~p"/v1/media/production/#{id}/undo-checkout")
        |> json_response(200)

      assert released["result"]["asset"]["checkedOutBy"] in [nil, ""]

      cleanup(created)
    end

    test "checked-out asset blocks metadata edit for other editors", %{
      conn: conn,
      other_token: other_token
    } do
      created = upload_asset(conn)
      id = created["result"]["id"]

      conn
      |> authed()
      |> post(~p"/v1/media/production/#{id}/checkout")
      |> json_response(200)

      resp =
        conn
        |> other_editor(other_token)
        |> patch(~p"/v1/media/production/#{id}", %{"title" => "Blocked"})

      assert resp.status == 403

      cleanup(created)
    end
  end
end
