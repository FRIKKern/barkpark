defmodule Barkpark.Plugins.OnixEdit.Routes do
  @moduledoc """
  Plugin-contributed routes.

  Four routes today, mounted at compile time by the host router's
  `plugin_routes/1` macro:

    * `/studio/onixedit/ping` — pilot route from G2 s4 (admin-only,
      default `auth: :admin`). Confirms the highway is wired up.
    * `/admin/onixedit/bokbasen` — operations console for Bokbasen
      publish submissions (Goal `barkpark-G3` s4, was
      `BarkparkWeb.Admin.BokbasenLive` at `/admin/bokbasen`). `auth: :ops`
      so the dedicated `ops` role can reach it without inheriting full
      admin.
    * `/admin/onixedit/staleness` — operations console for ONIX
      codelist drift (Goal `barkpark-G3` s4, was
      `BarkparkWeb.Admin.OnixeditStalenessLive` — same URL kept;
      lived in host namespace before this move).
    * `/v1/plugins/onixedit/export/:dataset/:id` — admin-only HTTP
      controller that streams a `book` document as ONIX 3.0 XML
      (Goal `barkpark-G3` s5, was
      `BarkparkWeb.OnixeditExportController`). `auth: :api` mounts it
      under the host's `[:api, :require_admin]` pipeline via the
      `plugin_routes(scope: :api)` callsite inside
      `scope "/v1/plugins"`. URL preserved.

  Path mounting: each plugin path is relative to the host scope that
  wraps the matching `plugin_routes/1` callsite. The pilot lives under
  `scope "/studio"` (admin scope, default `:admin` auth) → `/studio` +
  `/onixedit/ping`. The two consoles live under `scope "/admin"` (ops
  scope) → `/admin` + `/onixedit/<console>`. The export controller
  lives under `scope "/v1/plugins"` (api scope) → `/v1/plugins` +
  `/onixedit/export/:dataset/:id`.

  The old `/admin/bokbasen` URL is kept alive by a 301 redirect in
  `BarkparkWeb.Router` (back-compat per Goal `barkpark-G3` Q3 grill
  decision).

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.register_routes/1`
  behind the plugin facade — the callback delegates to `all/0`. The
  returned spec list is byte-identical to before.
  """

  @doc """
  The four route specs. Returned unchanged from the former
  `OnixEdit.register_routes/1` body (which ignored its `ctx` arg).
  """
  @spec all() :: [tuple()]
  def all do
    [
      {:live, "/onixedit/ping", Barkpark.Plugins.OnixEdit.PingLive, :index},
      {:live, "/onixedit/bokbasen", Barkpark.Plugins.OnixEdit.Web.BokbasenLive, :index,
       auth: :ops},
      {:live, "/onixedit/staleness", Barkpark.Plugins.OnixEdit.Web.StalenessLive, :index,
       auth: :ops},
      {:get, "/onixedit/export/:dataset/:id", Barkpark.Plugins.OnixEdit.Web.ExportController,
       :show, auth: :api}
    ]
  end
end
