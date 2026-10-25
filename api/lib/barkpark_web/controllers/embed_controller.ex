defmodule BarkparkWeb.EmbedController do
  @moduledoc """
  `GET /v1/embed/canvas`: where an embedder loads the paper canvas from
  (task-c57dd84f98c1296c).

  A studio on another origin loads `<bp-paper-canvas>` from this Barkpark:
  `bp-paper-editor.bundle.js` (about 1 MB) and three stylesheets. The plain
  `/assets/<name>` URLs answer `no-cache`, so every document page asked for all
  four again. This route names them under their content hash
  (`BarkparkWeb.StaticAssets.path/1`), which `BarkparkWeb.Plugs.StaticAssets`
  serves as `immutable` for a year: the embedder asks here (cheap, `no-cache`)
  and then loads each file once per deploy that changes it.

  The plain URLs keep working as before, so an embedder that never asks here is
  unaffected. A name whose file is missing comes back as its plain URL.
  """
  use BarkparkWeb, :controller

  alias BarkparkWeb.StaticAssets

  @script "bp-paper-editor.bundle.js"
  @styles ["bp-paper-editor.css", "bp-paper-editor-shell.css", "bp-paper-surface.css"]

  def canvas(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> json(%{
      script: StaticAssets.path(@script),
      styles: Enum.map(@styles, &StaticAssets.path/1)
    })
  end
end
