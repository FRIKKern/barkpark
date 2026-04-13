defmodule BarkparkWeb.Layouts do
  use BarkparkWeb, :html
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
