defmodule BarkparkWeb.ReturnTo do
  @moduledoc """
  The one check for a post-sign-in `return_to` path on this instance.

  Same-origin absolute paths only. Browsers treat `\\` like `/` and drop
  tab/CR/LF inside a URL, so `/\\evil.com` or `/<TAB>/evil.com` became the
  protocol-relative `//evil.com`: an open redirect after login
  (task-5ab7e3e4d678ec4c). Any backslash or control character is refused.
  The login page, the OIDC start and the SAML RelayState all use it.
  """

  @doc "`path` when it is a safe same-origin path, else nil."
  @spec safe_path(term()) :: String.t() | nil
  def safe_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.contains?(path, "\\") and not String.match?(path, ~r/[\x00-\x1f\x7f]/) do
      path
    else
      nil
    end
  end

  def safe_path(_), do: nil
end
