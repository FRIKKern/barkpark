defmodule BarkparkWeb.ChatHostDeclaredValuesTest do
  @moduledoc """
  An enroll or heartbeat that sends `protocol_version: 0` (or below), or an
  empty string for `capabilities` or `protocol_version`, answers a typed 422
  and changes nothing (task-7dfa8c4e8a410e96, findings F2 and F3 of the review
  of PR #26500). So does a `protocol_version` above the int4 column's range on
  enroll, heartbeat and the owner's issue: `validate_number/3` checked only
  `> 0`, and Postgrex raised `DBConnection.EncodeError`, a 500 (found in the
  review of PR #26515).

    * F2: `RegisteredHost.enrollment_complete_changeset/2` had no
      `validate_number/3`, so an enroll with `protocol_version: 0` answered
      201 and stored 0. The heartbeat and the owner's issue already refuse it.
    * F3: Ecto's `cast/4` swaps an empty value (`""`, or only whitespace) for
      the field's default before any validation runs. A heartbeat with
      `capabilities: ""` became `%{}`, which is valid, and the stored
      capabilities were reset to an empty map. The same swap set
      `protocol_version: ""` to 1, and on enroll replaced the capabilities the
      owner issued.

  The shipped Go host (`internal/chathost/client.go` `Enroll`/`Heartbeat`)
  always sends `protocol_version: 1` and the map `capabilities()` in
  `cmd/barkpark-chat-host/main.go` builds. Its exact bodies are pinned here as
  201 and 200, beside `{}` capabilities and an omitted key.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns /v1/chat-host.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # The fixture `cmd/barkpark-chat-host/capabilities_shape_test.go` holds the
  # binary's `capabilities()` to.
  @go_fixture Path.expand(
                "../../support/fixtures/chat_host_go_capabilities_bot_folders.json",
                __DIR__
              )

  # The protocol_version column is a Postgres integer (int4).
  @int4_max 2_147_483_647

  @caps %{
    "protocol_version" => 1,
    "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
  }

  @refused [
    {"protocol_version 0", %{"protocol_version" => 0}, "protocol_version"},
    {"protocol_version -1", %{"protocol_version" => -1}, "protocol_version"},
    {"protocol_version empty", %{"protocol_version" => ""}, "protocol_version"},
    {"protocol_version above int4", %{"protocol_version" => @int4_max + 1}, "protocol_version"},
    {"protocol_version far above int4", %{"protocol_version" => 99_999_999_999_999},
     "protocol_version"},
    {"capabilities empty", %{"capabilities" => ""}, "capabilities"},
    {"capabilities whitespace", %{"capabilities" => "  "}, "capabilities"}
  ]

  defp go_capabilities, do: @go_fixture |> File.read!() |> Jason.decode!()

  defp issue do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "hdv-#{suffix}", name: "HDV #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "declared-#{suffix}",
        approved_roots: [System.tmp_dir!()],
        capabilities: @caps
      })

    issued
  end

  defp enrolled do
    issued = issue()

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})

    {issued.host.id, credential}
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp heartbeat(conn, credential, body) do
    conn
    |> put_req_header("authorization", "Host #{credential}")
    |> post_json("/v1/chat-host/heartbeat", body)
  end

  defp stored(id) do
    id
    |> then(&Repo.get!(RegisteredHost, &1))
    |> Map.take([:capabilities, :protocol_version, :last_seen_at, :enrolled_at, :credential_hash])
  end

  describe "POST /v1/chat-host/enroll" do
    for {label, body, field} <- @refused do
      test "#{label} answers 422 on #{field}, enrolls nothing, and leaves the token usable",
           %{conn: conn} do
        issued = issue()
        before = stored(issued.host.id)

        resp =
          post_json(
            conn,
            "/v1/chat-host/enroll",
            Map.merge(
              %{"enrollment_token" => issued.enrollment_token, "protocol_version" => 1},
              unquote(Macro.escape(body))
            )
          )

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, unquote(field))
        assert stored(issued.host.id) == before
        assert before.enrolled_at == nil
        assert before.capabilities == @caps

        assert {:ok, %{credential: _}} =
                 ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})
      end
    end

    test "the Go host's exact enroll body answers 201 and stores its capabilities",
         %{conn: conn} do
      issued = issue()

      # internal/chathost/client.go Enroll: these four keys, protocol_version 1.
      body = %{
        "enrollment_token" => issued.enrollment_token,
        "approved_roots" => [System.tmp_dir!()],
        "protocol_version" => 1,
        "capabilities" => go_capabilities()
      }

      assert %{"credential" => credential} =
               json_response(post_json(conn, "/v1/chat-host/enroll", body), 201)

      assert is_binary(credential)
      row = stored(issued.host.id)
      assert row.capabilities == go_capabilities()
      assert row.protocol_version == 1
    end

    test "capabilities {} answers 201", %{conn: conn} do
      issued = issue()

      body = %{
        "enrollment_token" => issued.enrollment_token,
        "protocol_version" => 1,
        "capabilities" => %{}
      }

      assert json_response(post_json(conn, "/v1/chat-host/enroll", body), 201)
      assert stored(issued.host.id).capabilities == %{}
    end
  end

  describe "POST /v1/chat-host/heartbeat" do
    for {label, body, field} <- @refused do
      test "#{label} answers 422 on #{field} and changes nothing", %{conn: conn} do
        {id, credential} = enrolled()
        before = stored(id)

        resp =
          heartbeat(
            conn,
            credential,
            Map.merge(%{"protocol_version" => 1}, unquote(Macro.escape(body)))
          )

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, unquote(field))
        assert stored(id) == before
        assert before.capabilities == @caps
      end
    end

    test "the Go host's exact heartbeat body answers 200 and stores its capabilities",
         %{conn: conn} do
      {id, credential} = enrolled()

      # internal/chathost/client.go Heartbeat: these two keys, protocol_version 1.
      body = %{"protocol_version" => 1, "capabilities" => go_capabilities()}

      assert json_response(heartbeat(conn, credential, body), 200)
      assert stored(id).capabilities == go_capabilities()
    end

    test "capabilities {} answers 200", %{conn: conn} do
      {id, credential} = enrolled()

      assert json_response(
               heartbeat(conn, credential, %{"protocol_version" => 1, "capabilities" => %{}}),
               200
             )

      assert stored(id).capabilities == %{}
    end

    test "an omitted key keeps the stored value", %{conn: conn} do
      {id, credential} = enrolled()

      assert json_response(heartbeat(conn, credential, %{"protocol_version" => 1}), 200)
      assert stored(id).capabilities == @caps

      assert json_response(heartbeat(conn, credential, %{"capabilities" => @caps}), 200)
      assert stored(id).protocol_version == 1

      assert json_response(heartbeat(conn, credential, %{}), 200)
      row = stored(id)
      assert row.capabilities == @caps
      assert row.protocol_version == 1
    end

    test "the int4 maximum is still a protocol_version", %{conn: conn} do
      {id, credential} = enrolled()

      assert json_response(heartbeat(conn, credential, %{"protocol_version" => @int4_max}), 200)
      assert stored(id).protocol_version == @int4_max
    end
  end

  describe "POST /w/:slug/v1/chat-hosts/enrollments (owner)" do
    setup do
      ensure_default_scope!()
      suffix = System.unique_integer([:positive])
      {:ok, ws} = Tenancy.create_workspace(%{slug: "hdvo-#{suffix}", name: "HDVO #{suffix}"})
      {:ok, _project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      raw = "hdv-owner-#{suffix}"
      {:ok, owner} = Auth.create_token(raw, "owner", "production", ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")
      {:ok, workspace: ws, raw: raw, path: "/w/#{ws.slug}/v1/chat-hosts/enrollments"}
    end

    for version <- [@int4_max + 1, 99_999_999_999_999] do
      test "protocol_version #{version} answers 422 on protocol_version and inserts no row", %{
        conn: conn,
        workspace: ws,
        raw: raw,
        path: path
      } do
        resp =
          conn
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post_json(path, %{"name" => "big", "protocol_version" => unquote(version)})

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, "protocol_version")
        assert ChatHosts.list_hosts(ws.id) == []
      end
    end
  end
end
