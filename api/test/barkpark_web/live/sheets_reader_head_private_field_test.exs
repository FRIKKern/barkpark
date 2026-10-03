defmodule BarkparkWeb.SheetsReaderHeadPrivateFieldTest do
  @moduledoc """
  task-29d4e572eb42683b — the public `/sheets/:slug` reader's og/twitter head
  must not print a field the tenant's `sheet` schema declares private.

  Measured on the WIRE BYTES of the dead render (unfurlers run no JS): a
  published sheet whose `description` is declared `private: true` is fetched
  anonymously and the response body must not carry the value — not in
  `og:description`, not in `twitter:description`, not in JSON-LD, nowhere.

  A REGRESSION PIN, not a fix: it is green on main because
  `SheetsReaderLive.mount/3` runs `seal/1` (Envelope.redact under the
  anonymous caller and the tenant `sheet` schema) BEFORE
  `ShareMeta.manifest/4` reads the content. The CONTROL below proves the head
  does print `description` once the field is public, so the refute is not
  vacuous. MUTATION-CHECKED: dropping the mount's seal reds the private test (1/2).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @dataset "production"
  @slug "shead-private"
  @secret "Confidential sheet summary zq41"

  setup do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "tabs", "type" => "array"},
            %{"name" => "description", "type" => "text", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => @slug,
          "title" => "Budget sheet",
          "content" => %{
            "description" => @secret,
            "tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => "hello"}}}]
          }
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(@slug, "sheet", @dataset, scope)
    :ok
  end

  test "ANONYMOUS /sheets/:slug: the head and body never carry the private description",
       %{conn: conn} do
    html = conn |> get("/sheets/#{@slug}") |> html_response(200)

    # CONTROL: this is the sheet's own page, head included.
    assert html =~ "Budget sheet"
    assert html =~ ~s(property="og:title")

    refute html =~ @secret
  end

  test "CONTROL: with description PUBLIC the head does print it (the refute is not vacuous)",
       %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "tabs", "type" => "array"},
            %{"name" => "description", "type" => "text"}
          ]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    html = conn |> get("/sheets/#{@slug}") |> html_response(200)
    assert html =~ @secret
  end
end
