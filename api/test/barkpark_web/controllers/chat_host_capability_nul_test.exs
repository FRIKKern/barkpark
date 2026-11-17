defmodule BarkparkWeb.ChatHostCapabilityNulTest do
  @moduledoc """
  Declared capabilities holding U+0000 (task-214ecfd6ffe27b56, from the review
  of PR #26693).

  The named failure mode: Postgres refuses U+0000 in jsonb (22P05).
  `RegisteredHost` checked a provider `version` and each `operations` item for
  size only, so a capabilities map holding U+0000 reached the store and
  raised: enroll and heartbeat answered 500. The Go host retries a 5xx
  heartbeat, and a heartbeat that never lands means the host can never renew
  its leases. The owner's issue, which takes the same map, answered 500 too.

  The capabilities validator now refuses U+0000 anywhere in the map with the
  typed 422 the other capability errors answer (`code: "unprocessable"`,
  `fields.capabilities`), and nothing is stored. Values the shipped host sends
  today are pinned beside it as 201 and 200.
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

  @nul <<0>>

  @caps %{
    "protocol_version" => 1,
    "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
  }

  @refused [
    {"a claude version", %{"version" => "2.1.0" <> @nul}},
    {"an operations item", %{"operations" => ["send_turn" <> @nul]}}
  ]

  defp caps_with(metadata),
    do: put_in(@caps, ["providers", "claude"], Map.merge(@caps["providers"]["claude"], metadata))

  defp issue do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "hcn-#{suffix}", name: "HCN #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "nul-#{suffix}",
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

  defp stored(id),
    do:
      Repo.get!(RegisteredHost, id)
      |> Map.take([:capabilities, :last_seen_at, :enrolled_at, :credential_hash])

  defp assert_refused(resp) do
    assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
             json_response(resp, 422)

    assert Map.has_key?(fields, "capabilities")
  end

  describe "POST /v1/chat-host/enroll" do
    for {label, metadata} <- @refused do
      test "U+0000 in #{label} answers 422, enrolls nothing, and leaves the token usable",
           %{conn: conn} do
        issued = issue()
        before = stored(issued.host.id)

        conn
        |> post_json("/v1/chat-host/enroll", %{
          "enrollment_token" => issued.enrollment_token,
          "protocol_version" => 1,
          "capabilities" => caps_with(unquote(Macro.escape(metadata)))
        })
        |> assert_refused()

        assert stored(issued.host.id) == before
        assert before.enrolled_at == nil

        assert {:ok, %{credential: _}} =
                 ChatHosts.enroll(issued.enrollment_token, %{"capabilities" => @caps})
      end
    end
  end

  describe "POST /v1/chat-host/heartbeat" do
    for {label, metadata} <- @refused do
      test "U+0000 in #{label} answers 422 and changes nothing", %{conn: conn} do
        {id, credential} = enrolled()
        before = stored(id)

        conn
        |> heartbeat(credential, %{
          "protocol_version" => 1,
          "capabilities" => caps_with(unquote(Macro.escape(metadata)))
        })
        |> assert_refused()

        assert stored(id) == before

        # The host is not locked out: its next clean heartbeat lands.
        assert json_response(heartbeat(conn, credential, %{"capabilities" => @caps}), 200)
      end
    end
  end

  describe "POST /w/:slug/v1/chat-hosts/enrollments (owner)" do
    setup do
      ensure_default_scope!()
      suffix = System.unique_integer([:positive])
      {:ok, ws} = Tenancy.create_workspace(%{slug: "hcno-#{suffix}", name: "HCNO #{suffix}"})
      {:ok, _project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      raw = "hcn-owner-#{suffix}"
      {:ok, owner} = Auth.create_token(raw, "owner", "production", ["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")
      {:ok, workspace: ws, raw: raw, path: "/w/#{ws.slug}/v1/chat-hosts/enrollments"}
    end

    test "U+0000 in the issued capabilities answers 422 and inserts no row", %{
      conn: conn,
      workspace: ws,
      raw: raw,
      path: path
    } do
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post_json(path, %{
        "name" => "nul-caps",
        "capabilities" => caps_with(%{"version" => "1" <> @nul})
      })
      |> assert_refused()

      assert ChatHosts.list_hosts(ws.id) == []
    end

    # task-164da10964d8a38b: name and approved_roots are text columns, so
    # U+0000 in either raised 22021, a 500 on this route.
    for {field, body} <- [
          {"name", %{"name" => "build" <> @nul <> "box"}},
          {"approved_roots", %{"name" => "roots", "approved_roots" => ["/tmp/a" <> @nul <> "b"]}}
        ] do
      test "U+0000 in the issued #{field} answers 422 on #{field} and inserts no row", %{
        conn: conn,
        workspace: ws,
        raw: raw,
        path: path
      } do
        resp =
          conn
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post_json(path, unquote(Macro.escape(body)))

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert Map.has_key?(fields, unquote(field))
        assert ChatHosts.list_hosts(ws.id) == []
      end
    end

    test "a name and roots an owner sends today are stored as sent", %{
      conn: conn,
      raw: raw,
      path: path
    } do
      for {name, i} <-
            Enum.with_index([
              "build box",
              "byggeboks 🐕‍🦺 שלום",
              <<1>>,
              <<0x7F>>,
              "�",
              "the literal \\u0000"
            ]) do
        roots = [System.tmp_dir!(), "/tmp/a b/🐕/#{i}", "/tmp/" <> name]

        resp =
          conn
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post_json(path, %{"name" => name, "approved_roots" => roots})

        assert %{"host" => host} = json_response(resp, 201)
        stored = Repo.get!(RegisteredHost, host["id"])
        assert {stored.name, stored.approved_roots} == {name, roots}
      end
    end
  end

  describe "values a host sends today" do
    @kept [
      "2.1.0 (Claude Code)",
      "codex-cli 0.144.1",
      "v1 🐕‍🦺 שלום",
      "tab\tthere",
      <<1>>,
      <<0x7F>>,
      "�",
      "the literal \\u0000"
    ]

    test "a version and operations items without U+0000 are stored as sent", %{conn: conn} do
      issued = issue()
      caps = caps_with(%{"version" => "2.1.0 (Claude Code)", "operations" => @kept})

      resp =
        post_json(conn, "/v1/chat-host/enroll", %{
          "enrollment_token" => issued.enrollment_token,
          "protocol_version" => 1,
          "capabilities" => caps
        })

      assert %{"credential" => credential} = json_response(resp, 201)
      assert stored(issued.host.id).capabilities == caps

      for version <- @kept do
        caps = caps_with(%{"version" => version})
        assert json_response(heartbeat(conn, credential, %{"capabilities" => caps}), 200)
        assert stored(issued.host.id).capabilities == caps
      end
    end
  end
end
