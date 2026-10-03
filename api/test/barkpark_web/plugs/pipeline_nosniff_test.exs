defmodule BarkparkWeb.Plugs.PipelineNosniffTest do
  @moduledoc """
  task-4a882dcfb3cd44bc — four API pipelines never mounted `Plugs.ApiSecurityHeaders`,
  so their responses (refusals included) carried no `x-content-type-options:
  nosniff` and no `referrer-policy`: `:media_mutate` (`POST /media/upload`),
  `:api_local`, `:ingest` (the plugin `auth: :ingest` bucket — sheets
  import/export) and `:github_webhook`. Every other API pipeline has it.

  Each pipeline now runs the plug FIRST, so even a response the next plug
  halts (401/403) carries the headers. The assertion is on whatever status
  each door answers — the header is the claim, not the status.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  for {label, method, path} <- [
        {"media_mutate", :post, "/media/upload"},
        {"api_local", :get, "/v1/data/local/search/production?q=x"},
        {"ingest", :post, "/v1/plugins/sheets/import"},
        {"github_webhook", :post, "/v1/plugins/github/webhook"}
      ] do
    test "the :#{label} pipeline answers with nosniff + referrer-policy" do
      conn = dispatch(scoped_conn(), @endpoint, unquote(method), unquote(path), %{})

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"],
             "#{unquote(label)} answered #{conn.status} without nosniff"

      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
    end
  end
end
