defmodule BarkparkWeb.EndpointRequestLineTest do
  @moduledoc """
  Pins the HTTP/1 request-line ceiling written out in config/runtime.exs
  (pds-bl-bandit-request-line-ceiling). The value is Bandit's own default; the
  point of the pin is that changing it becomes a deliberate, reviewed edit, and
  that the 9_984-byte request-target law the comment states stays true.
  """
  use ExUnit.Case, async: true

  @ceiling 10_000

  test "the endpoint configures Bandit's HTTP/1 request-line ceiling explicitly" do
    http = Application.get_env(:barkpark, BarkparkWeb.Endpoint)[:http]
    http_1 = Keyword.get(http, :http_1_options, [])

    assert Keyword.get(http_1, :max_request_line_length) == @ceiling,
           "config/runtime.exs must set http_1_options max_request_line_length to #{@ceiling}"
  end

  test "a POST request target may be at most 9_984 bytes under that ceiling" do
    # METHOD + space, then TARGET, then " HTTP/1.1", then CRLF.
    overhead = byte_size("POST ") + byte_size(" HTTP/1.1") + byte_size("\r\n")
    assert @ceiling - overhead == 9_984
  end
end
