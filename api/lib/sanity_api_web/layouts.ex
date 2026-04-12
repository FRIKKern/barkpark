defmodule SanityApiWeb.Layouts do
  use SanityApiWeb, :html
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
