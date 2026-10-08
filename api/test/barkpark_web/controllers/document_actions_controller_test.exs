defmodule BarkparkWeb.DocumentActionsControllerTest do
  @moduledoc """
  `GET/POST /w/:ws/p/:proj/v1/data/doc/:dataset/:type/:doc_id/actions[/:name]`
  (task-bd311f4b5ea2b3b8) — the HTTP twin of the editor-header action bar
  `BarkparkWeb.Studio.StudioLive.DocActions` resolves/dispatches today ONLY
  through the LiveView socket.

  Registers a fake plugin action handler via `Barkpark.Plugins.Registry`
  (same idiom `studio_live_action_handler_raise_test.exs` uses) instead of
  exercising OnixEdit/Bokbasen — this suite is about the HTTP plumbing, not
  any one plugin's business logic.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Registry
  alias Barkpark.Tenancy

  @dataset "doc-actions-test"

  # Process-global singleton — same reset discipline
  # `studio_live_action_handler_raise_test.exs` and `Barkpark.RegistryCase`
  # use, inlined here because `ConnCase` and `RegistryCase` are both
  # `ExUnit.CaseTemplate`s and can't both be `use`d.
  setup do
    Application.delete_env(:barkpark, :plugins)
    Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Registry.reset()
    end)

    :ok
  end

  defmodule StubActionPlugin do
    def resolve_action_handlers(prev, _ctx) do
      prev
      |> Map.put("stub-ok", fn _doc_id, _dataset, mode ->
        case mode do
          :dryrun -> {:ok, %{kind: :xml, xml: "<ok/>", summary: %{valid: true}}}
          :real -> {:ok, %{status: %{state: "done"}, job: nil}}
        end
      end)
      |> Map.put("stub-fail-dryrun", fn _doc_id, _dataset, :dryrun ->
        {:error, {:xsd_invalid, ["line 1: bad element"]}}
      end)
    end
  end

  defp register_stub! do
    :ok = Registry.register(StubActionPlugin, %{"plugin_name" => "stub-action-plugin"})
  end

  defp schema_with_actions(ws, proj) do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "actions" => [
            %{"name" => "stub-ok", "label" => "Stub OK", "kind" => "modal", "icon" => "check"},
            %{
              "name" => "stub-fail-dryrun",
              "label" => "Stub fail",
              "kind" => "modal",
              "icon" => "x"
            }
          ]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    :ok
  end

  defp create_post!(ws, proj, doc_id) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "Target"},
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc
  end

  defp admin_setup! do
    ws = create_workspace!()
    proj = create_project!(ws)
    register_stub!()
    schema_with_actions(ws, proj)

    raw = "doc-actions-admin-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    {:ok, token} = Barkpark.Auth.create_token(raw, "admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "admin", "api_token")

    %{ws: ws, proj: proj, raw: raw}
  end

  defp member_setup! do
    ws = create_workspace!()
    proj = create_project!(ws)
    register_stub!()
    schema_with_actions(ws, proj)

    raw = "doc-actions-member-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    {:ok, token} = Barkpark.Auth.create_token(raw, "member", @dataset, ["read", "write"])
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")

    %{ws: ws, proj: proj, raw: raw}
  end

  defp as(conn, raw), do: put_req_header(conn, "authorization", "Bearer #{raw}")

  defp actions_path(ws, proj, doc_id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/doc/#{@dataset}/post/#{doc_id}/actions"

  describe "GET .../actions" do
    test "an admin token lists the doc's resolved actions, built-ins and schema-declared" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "ga-1")

      resp =
        scoped_conn() |> as(raw) |> get(actions_path(ws, proj, doc.doc_id)) |> json_response(200)

      names = Enum.map(resp["actions"], & &1["name"])
      assert "stub-ok" in names
      assert "stub-fail-dryrun" in names
      # A built-in editor-header action (never schema-declared) proves the
      # LISTING calls the SAME full resolver LiveView uses, not just the
      # schema's static array.
      assert "delete-doc" in names

      stub = Enum.find(resp["actions"], &(&1["name"] == "stub-ok"))
      assert stub["label"] == "Stub OK"
      assert stub["kind"] == "modal"
      assert stub["icon"] == "check"
    end

    test "a member (non-admin) token is refused" do
      %{ws: ws, proj: proj, raw: raw} = member_setup!()
      doc = create_post!(ws, proj, "ga-2")

      resp = scoped_conn() |> as(raw) |> get(actions_path(ws, proj, doc.doc_id))
      assert resp.status == 403
    end

    test "an unresolvable document answers 404, not a 500" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()

      resp = scoped_conn() |> as(raw) |> get(actions_path(ws, proj, "no-such-doc"))
      assert resp.status == 404
    end
  end

  describe "POST .../actions/:name" do
    test "dryrun then real on a real registered handler, preview and result both present" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "pa-1")
      path = actions_path(ws, proj, doc.doc_id) <> "/stub-ok"

      dryrun =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "dryrun"}))
        |> json_response(200)

      assert dryrun["preview"]["kind"] == "xml"
      assert dryrun["preview"]["xml"] == "<ok/>"

      real =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "real"}))
        |> json_response(200)

      assert real["result"]["status"]["state"] == "done"
      # `job: nil` (an Oban.Job struct in production) must survive the JSON
      # round-trip without 500ing the response — the whole point of the
      # generic sanitizer.
      assert Map.has_key?(real["result"], "job")
    end

    test "a dry-run failure comes back as a 200 preview, not an HTTP error" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "pa-2")
      path = actions_path(ws, proj, doc.doc_id) <> "/stub-fail-dryrun"

      resp =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "dryrun"}))
        |> json_response(200)

      assert resp["preview"]["kind"] == "error"
      assert resp["preview"]["message"] =~ "ONIX failed XSD validation"
    end

    test "an unknown action name answers 404 unknown_action" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "pa-3")
      path = actions_path(ws, proj, doc.doc_id) <> "/not-a-real-action"

      resp =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "dryrun"}))

      body = json_response(resp, 404)
      assert body["error"]["code"] == "unknown_action"
      assert body["error"]["message"] =~ "not-a-real-action"
    end

    test "a built-in UI action (no registered handler) also answers 404 unknown_action, " <>
           "same as a LiveView phx-click would find" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "pa-4")
      path = actions_path(ws, proj, doc.doc_id) <> "/publish"

      resp =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "dryrun"}))

      body = json_response(resp, 404)
      assert body["error"]["code"] == "unknown_action"
    end

    test "a malformed mode is refused before dispatch" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      doc = create_post!(ws, proj, "pa-5")
      path = actions_path(ws, proj, doc.doc_id) <> "/stub-ok"

      resp =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "sideways"}))

      body = json_response(resp, 422)
      assert body["error"]["code"] == "malformed_mode"
    end

    test "a member (non-admin) token is refused" do
      %{ws: ws, proj: proj, raw: raw} = member_setup!()
      doc = create_post!(ws, proj, "pa-6")
      path = actions_path(ws, proj, doc.doc_id) <> "/stub-ok"

      resp =
        scoped_conn()
        |> as(raw)
        |> put_req_header("content-type", "application/json")
        |> post(path, Jason.encode!(%{"mode" => "dryrun"}))

      assert resp.status == 403
    end
  end

  describe "draft-first targeting" do
    test "a bare id resolving to its OWN open draft lists the draft's actions, " <>
           "and the draft's published twin is visible to the resolver (discard-draft offered)" do
      %{ws: ws, proj: proj, raw: raw} = admin_setup!()
      scope = [workspace_id: ws.id, project_id: proj.id]

      # `Content.create_document/4` always forces the new row's id to
      # `drafts.<id>` ("New docs are always created as drafts" —
      # `Content.Writer`), so the FIRST create here is already the draft.
      {:ok, draft_1} =
        Content.create_document(
          "post",
          %{"doc_id" => "pd-1", "title" => "Target"},
          @dataset,
          scope
        )

      assert draft_1.doc_id == "drafts.pd-1"

      # Publish it: copies draft -> bare "pd-1", deletes the draft row.
      {:ok, _published} = Content.publish_document("pd-1", "post", @dataset, scope)

      # Edit again: a SECOND create at the same bare id forces a fresh
      # `drafts.pd-1`, which now coexists with the published "pd-1" row from
      # the line above — the exact "draft with a published twin" shape
      # `has_published_twin` gates on.
      {:ok, _draft_2} =
        Content.create_document(
          "post",
          %{"doc_id" => "pd-1", "title" => "Target (editing)"},
          @dataset,
          scope
        )

      # The BARE (published) id in the URL — `edit_target/4` must redirect to
      # the open draft internally, same as the Studio editor and
      # `?perspective=raw` both do for this exact doc_id shape.
      resp =
        scoped_conn() |> as(raw) |> get(actions_path(ws, proj, "pd-1")) |> json_response(200)

      names = Enum.map(resp["actions"], & &1["name"])
      assert "stub-ok" in names
      # `discard-draft` is gated on `has_published_twin` (draft AND a
      # published row both existing) — its presence proves
      # `load_doc_assigns/4` resolved the DRAFT (not the published row) and
      # separately found its published twin, the exact pairing
      # `default_doc_actions/2` needs to offer it.
      assert "discard-draft" in names
    end
  end
end
