defmodule BarkparkWeb.Plugs.BrowserCsp do
  @moduledoc """
  Sets the tailored, script-blocking Content-Security-Policy for the root-layout
  browser surfaces (`:browser`, `:scoped_browser`, `:shared_studio_browser`) and
  assigns the matching per-request `:csp_nonce`, atomically.

  Runs AFTER `:put_secure_browser_headers` in each pipeline and REPLACES the
  `content-security-policy` header (`put_resp_header`). The pipeline's
  `put_secure_browser_headers` still carries a static CSP map — that map is what
  Sobelow's syntactic `Config.CSP` check credits (a downstream plug is invisible
  to it, see `BarkparkWeb.CSP`); this plug supplies the real per-request value
  (the nonce a static map cannot carry).

  The assigned `:csp_nonce` is read by the root layout + reader layouts as
  `nonce={@csp_nonce}` on every inline `<script>`, so header and scripts always
  share one nonce. On the paper-reader path `PaperReaderCsp` runs later and
  overwrites both — that surface keeps its own (narrower) policy.
  """

  @behaviour Plug

  import Plug.Conn

  alias BarkparkWeb.CSP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = CSP.nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", CSP.studio_policy(nonce))
  end
end
