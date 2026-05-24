defmodule BarkparkWeb.Integration.MediaTest do
  @moduledoc """
  Integration probe for the `/media/*` surface (Goal `barkpark-b1m`,
  Task `barkpark-upn`, gap #1 from `tmp/api-gap-analysis.md`).

  Pre-s7 coverage: none. `MediaController` was referenced only in
  `field_inputs_test.exs` (HEEx markup) and the route inventory.

  This file pins:

    * `POST /media/upload` with valid token + multipart file → 201 + JSON
    * `POST /media/upload` without auth → 401 halts before multipart parse
    * `POST /media/upload` with token but no `file` field → 400 envelope
    * `GET /media` lists uploaded files (returns `files` + `count`)
    * `GET /media/:id/meta` returns single-file metadata; unknown → 404
    * `GET /media/files/*path` serves bytes; unknown path → 404

  DB rows are rolled back by the SQL sandbox. Files written to disk by
  `Barkpark.Media.upload/2` outlive the sandbox — each test that triggers
  an upload tracks the resulting path and deletes it inline before
  returning. `async: false` because uploads share the `uploads/` directory
  with the dev server.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Media

  # 1×1 transparent PNG, encoded inline. ~70 bytes. No fixture file needed.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "media-integration",
      ["read", "write", "admin"]
    )

    # Drain the boot-time codelist seeder Task before grabbing the DB —
    # otherwise it can hog the sandbox connection and our setup blows up.
    drain_task_supervisor(30_000)

    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer barkpark-dev-token")
  end

  defp png_upload do
    png_bin = Base.decode64!(@png_b64)
    tmp_path = Path.join(System.tmp_dir!(), "barkpark-test-#{:rand.uniform(1_000_000)}.png")
    File.write!(tmp_path, png_bin)

    %Plug.Upload{
      path: tmp_path,
      filename: "pixel.png",
      content_type: "image/png"
    }
  end

  # Best-effort disk cleanup for an upload that the sandbox rollback can't
  # reach. Called inline at the end of each upload-touching test.
  defp rm_uploaded(%{"url" => "/media/files/" <> relative}),
    do: File.rm(Path.join(Media.upload_dir(), relative))

  defp upload_one!(conn) do
    conn
    |> authed()
    |> post(~p"/media/upload", %{"file" => png_upload()})
    |> json_response(201)
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "POST /media/upload" do
    test "with valid token + multipart file → 201 + JSON envelope", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> post(~p"/media/upload", %{"file" => png_upload()})

      assert resp.status == 201
      body = json_response(resp, 201)

      assert is_binary(body["id"])
      assert body["mimeType"] == "image/png"
      assert is_integer(body["size"])
      assert body["size"] > 0
      assert is_binary(body["url"])
      assert String.starts_with?(body["url"], "/media/files/")

      # File actually exists on disk.
      [_, relative] = String.split(body["url"], "/media/files/", parts: 2)
      assert File.exists?(Path.join(Media.upload_dir(), relative))

      rm_uploaded(body)
    end

    test "with session cookie (no Bearer header) → 201", %{conn: conn} do
      resp =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => "barkpark-dev-token"})
        |> post(~p"/media/upload", %{"file" => png_upload()})

      assert resp.status == 201
      body = json_response(resp, 201)
      assert is_binary(body["id"])
      rm_uploaded(body)
    end

    test "without auth → 401", %{conn: conn} do
      resp = post(conn, ~p"/media/upload", %{"file" => png_upload()})

      assert resp.status == 401
    end

    test "with auth but no `file` field → 400 envelope", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> post(~p"/media/upload", %{"not_file" => "nope"})

      assert resp.status == 400
      body = json_response(resp, 400)
      assert body["error"]["message"] =~ "missing 'file' field"
    end
  end

  describe "GET /media (index)" do
    test "returns uploaded files as JSON list with `count`", %{conn: conn} do
      created = upload_one!(conn)

      resp = get(conn, ~p"/media")
      assert resp.status == 200
      body = json_response(resp, 200)

      assert is_list(body["files"])
      assert is_integer(body["count"])
      assert body["count"] >= 1
      assert Enum.any?(body["files"], &(&1["id"] == created["id"]))

      rm_uploaded(created)
    end
  end

  describe "GET /media/:id/meta" do
    test "returns single-file metadata for a known id", %{conn: conn} do
      created = upload_one!(conn)

      resp = get(conn, ~p"/media/#{created["id"]}/meta")
      assert resp.status == 200

      body = json_response(resp, 200)
      assert body["id"] == created["id"]
      assert body["mimeType"] == "image/png"

      rm_uploaded(created)
    end

    test "unknown id → 404", %{conn: conn} do
      bogus = Ecto.UUID.generate()
      resp = get(conn, ~p"/media/#{bogus}/meta")
      assert resp.status == 404
    end
  end

  describe "GET /media/files/*path" do
    test "serves the file bytes back with the correct content-type", %{conn: conn} do
      created = upload_one!(conn)

      [_, relative] = String.split(created["url"], "/media/files/", parts: 2)

      resp = get(conn, "/media/files/#{relative}")
      assert resp.status == 200

      content_type =
        resp
        |> get_resp_header("content-type")
        |> Enum.map(&hd(String.split(&1, ";")))

      assert content_type == ["image/png"]
      assert byte_size(resp.resp_body) > 0

      rm_uploaded(created)
    end

    test "unknown path → 404", %{conn: conn} do
      resp = get(conn, "/media/files/2099/12/does-not-exist.png")
      assert resp.status == 404
    end
  end
end
