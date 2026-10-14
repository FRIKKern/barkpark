defmodule BarkparkWeb.EndpointRequestLineTest do
  @moduledoc """
  Pins the HTTP/1 request-line ceiling written out in config/runtime.exs
  (pds-bl-bandit-request-line-ceiling). It is 32_768 bytes, above Bandit's
  default of 10_000, so every GET `@sanity/client` sends fits. The point of the
  pin is that changing it is a deliberate, reviewed edit, and that the target
  sizes the comment states stay true. `GroqGetLengthTest` sends real requests
  through Bandit at and past the ceiling.
  """
  use ExUnit.Case, async: true

  @ceiling 32_768

  test "the endpoint configures Bandit's HTTP/1 request-line ceiling explicitly" do
    http = Application.get_env(:barkpark, BarkparkWeb.Endpoint)[:http]
    http_1 = Keyword.get(http, :http_1_options, [])

    assert Keyword.get(http_1, :max_request_line_length) == @ceiling,
           "config/runtime.exs must set http_1_options max_request_line_length to #{@ceiling}"
  end

  test "a GET request target may be 32_753 bytes and a POST target 32_752" do
    # METHOD + space, then TARGET, then " HTTP/1.1", then CRLF.
    tail = byte_size(" HTTP/1.1") + byte_size("\r\n")
    assert @ceiling - byte_size("GET ") - tail == 32_753
    assert @ceiling - byte_size("POST ") - tail == 32_752
  end
end
