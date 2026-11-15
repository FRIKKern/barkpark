defmodule BarkparkWeb.ChatHostIssueEnrollmentNullTest do
  @moduledoc """
  An owner's `POST /w/:slug/v1/chat-hosts/enrollments` with `capabilities`,
  `protocol_version` or `approved_roots` sent as JSON null answers a typed 422
  and inserts no row (task-7f0bd4bfa363eb60).

  `ChatHosts.issue_enrollment/2` reads each with `value(attrs, key, default)`,
  which uses the default only when the key is ABSENT. A key present with null
  came through as `nil`, which `validate_change/3` and `validate_number/3`
  skip, and the NOT NULL columns
  (`20260714150000_create_registered_chat_hosts.exs`) raised a Postgrex
  not_null_violation: a 500. The host-facing heartbeat and enroll got the same
  fix in task-2cd727c3405afd23 (`chat_host_null_capabilities_test.exs`).

  The shapes an owner sends today (the Studio form's name and roots, the
  docs' name-only body, an explicit `{}` or `1`) still answer 201.
  """
  use BarkparkWeb.ConnCase, async: true

  # Plugins-off: the studio_chat capability owns the chat routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @nullable ~w(capabilities protocol_version approved_roots)

  setup %{conn: conn} do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, workspace} = Tenancy.create_workspace(%{slug: "hien-#{suffix}", name: "HIEN"})
    {:ok, _project} = Tenancy.create_project(workspace, %{slug: "default", name: "Default"})

    {:ok, owner} =
      Auth.create_token("hien-owner-#{suffix}", "owner", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(workspace.id, owner.id, "owner")

    {:ok,
     conn: conn,
     workspace: workspace,
     path: "/w/#{workspace.slug}/v1/chat-hosts/enrollments",
     raw: "hien-owner-#{suffix}"}
  end

  defp post_json(conn, raw, path, body) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  describe "ChatHosts.issue_enrollment/2" do
    for field <- @nullable do
      test "#{field} nil is an {:error, changeset} on #{field}, not a raise", %{
        workspace: workspace
      } do
        field = String.to_existing_atom(unquote(field))

        assert {:error, %Ecto.Changeset{} = changeset} =
                 ChatHosts.issue_enrollment(workspace.id, %{:name => "x", field => nil})

        assert Keyword.has_key?(changeset.errors, field)
        assert ChatHosts.list_hosts(workspace.id) == []
      end
    end
  end

  describe "POST /w/:slug/v1/chat-hosts/enrollments" do
    for field <- @nullable do
      test "#{field} null answers 422 on #{field} and inserts no row", %{
        conn: conn,
        workspace: workspace,
        path: path,
        raw: raw
      } do
        body = %{"name" => "laptop", unquote(field) => nil}
        resp = post_json(conn, raw, path, body)

        assert %{"error" => %{"code" => "unprocessable", "fields" => fields}} =
                 json_response(resp, 422)

        assert fields[unquote(field)] == ["must not be null"]
        assert ChatHosts.list_hosts(workspace.id) == []
      end
    end

    test "the shapes an owner sends today still answer 201", %{
      conn: conn,
      workspace: workspace,
      path: path,
      raw: raw
    } do
      root = System.tmp_dir!()

      bodies = [
        # The Studio form (ChatHostsLive) and the controller tests.
        %{"name" => "form", "approved_roots" => [root]},
        # A name alone takes every default.
        %{"name" => "bare"},
        %{
          "name" => "explicit",
          "approved_roots" => [],
          "protocol_version" => 1,
          "capabilities" => %{}
        }
      ]

      for body <- bodies do
        assert %{"host" => %{"name" => name}} =
                 json_response(post_json(conn, raw, path, body), 201)

        assert name == body["name"]
      end

      assert workspace.id |> ChatHosts.list_hosts() |> length() == 3
    end
  end
end
