defmodule BarkparkWeb.Contract.UnauthorizedHintCredentialTest do
  @moduledoc """
  A 401 must never name a credential the route does not accept
  (task-57081836b628df35, criterion 0).

  THE DEFECT THIS PINS. `Barkpark.Content.Errors.put_hint/1` dispatches on the
  `code` STRING ALONE — no module, no conn, no route — so ONE `@hints` entry is
  served at EVERY emitter of that code. `"unauthorized"` has eleven emitters
  through `BarkparkWeb.ErrorResponse.emit_custom/5`, and they want between them
  an HMAC webhook signature, an ingest shared secret, a media-processing
  callback token, a login session, and an IdP assertion. The table entry read
  "Send a valid token via the Authorization: Bearer header; tokens are
  dataset-scoped", so ten of the eleven refusals sent the caller to fetch a
  credential their route would refuse again — and, on the routes that refuse an
  api token outright, sent them to the one credential guaranteed to fail.

  A CODE-KEYED TABLE HAS NO INSTANCES, ONLY CODES TIMES CALL SITES. So this
  test does not check a string; it checks an INVARIANT over emit sites: for
  each 401 emitter, the hint on the wire names no credential kind outside that
  route's accepted set. Two arms hold it — the table default names NO kind at
  all (safe everywhere, which is what the OIDC/SAML/social emitters rely on),
  and a route that CAN name its own credential passes one through
  `emit_custom/6`, which wins over the default.

  "Bearer" is deliberately NOT in the vocabulary below: it is a TRANSPORT
  (`Authorization: Bearer <x>`), not a credential kind. Three different
  credential kinds in this tree ride it.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Errors
  alias BarkparkWeb.ErrorResponse

  # Credential KINDS a refusal can name, and the text that names each. Regexes,
  # not a word list, because a kind is named many ways ("api token",
  # "dataset-scoped" both point at the same credential).
  @credential_vocabulary %{
    bearer_api_token: ~r/api token|dataset-scoped/i,
    login_session: ~r/login session|user_session|session cookie|session token/i,
    webhook_signature: ~r/webhook secret|signature/i,
    ingest_token: ~r/ingest token/i,
    media_callback_token: ~r/media processing callback token/i
  }

  # The hint the table carried before this change. Kept as a MUTATION FIXTURE:
  # it is what the credential-agnostic arm is agnostic RELATIVE TO, and feeding
  # it to the detector proves the detector can still see a defect.
  @credential_specific_default "Send a valid token via the Authorization: Bearer header; tokens are dataset-scoped."

  defp kinds_named(text) when is_binary(text) do
    for {kind, re} <- @credential_vocabulary, Regex.match?(re, text), do: kind
  end

  defp body(%Plug.Conn{} = conn), do: Jason.decode!(conn.resp_body)["error"]

  defp conn(method \\ "GET", path \\ "/") do
    Plug.Test.conn(method, path)
    |> Plug.Conn.put_private(:phoenix_endpoint, BarkparkWeb.Endpoint)
  end

  # {label, accepted kinds, fn -> conn}. The accepted set is read from the
  # plug's own gate, not from its prose.
  defp emitters do
    [
      {"GithubWebhookSignature (HMAC only — no token, no session)", [:webhook_signature],
       fn ->
         BarkparkWeb.Plugs.GithubWebhookSignature.call(conn("POST", "/github/webhook"), [])
       end},
      {"RequireIngestToken (ingest shared secret OR admin api token)",
       [:ingest_token, :bearer_api_token],
       fn -> BarkparkWeb.Plugs.RequireIngestToken.call(conn("POST", "/v1/ingest"), []) end},
      {"RequireMediaProcessingCallbackToken (one instance secret; refuses an api token)",
       [:media_callback_token],
       fn ->
         BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken.call(
           conn("POST", "/v1/media/d/processing/1/callback"),
           []
         )
       end},
      {"RequirePrincipalUser (login session OR an OWNED api token)",
       [:login_session, :bearer_api_token],
       fn -> BarkparkWeb.Plugs.RequirePrincipalUser.call(conn("GET", "/v1/tasks/mine"), []) end},
      {"RequireUserSession (a login session only)", [:login_session],
       fn ->
         conn("GET", "/v1/auth/me")
         |> Plug.Test.init_test_session(%{})
         |> BarkparkWeb.Plugs.RequireUserSession.call([])
       end}
    ]
  end

  describe "the code-keyed default is credential-agnostic" do
    test "the @hints \"unauthorized\" entry names no credential kind at all" do
      hint =
        ErrorResponse.emit_custom(conn(), 401, "unauthorized", "nope")
        |> body()
        |> Map.fetch!("hint")

      assert kinds_named(hint) == [],
             """
             The code-keyed "unauthorized" hint is served verbatim at every emitter of
             that code (Errors.put_hint/1 dispatches on the code string alone), so it
             may not name a credential kind — it would be wrong at the other ten sites.
             It named: #{inspect(kinds_named(hint))}
             Hint was: #{hint}
             Fix it in api/lib/barkpark/content/errors.ex (@hints "unauthorized"), or
             give the route its own hint via ErrorResponse.emit_custom/6.
             """
    end

    test "the hint is still PRESENT — agnostic must not mean absent" do
      hint =
        ErrorResponse.emit_custom(conn(), 401, "unauthorized", "nope")
        |> body()
        |> Map.fetch!("hint")

      assert String.length(hint) > 40,
             "the credential-agnostic default must still tell the caller what to do; got: #{inspect(hint)}"
    end

    test "CONTROL: the detector flags the credential-specific text this replaced" do
      assert :bearer_api_token in kinds_named(@credential_specific_default),
             """
             The detector must be able to SEE a credential-specific hint, or the
             assertions above pass on anything. It failed to flag the exact string
             this change removed from @hints.
             """
    end

    test "CONTROL: an emitter that passes no hint still reaches the table default" do
      env = Errors.stamp(%{code: "unauthorized", message: "m", status: 401}, nil)

      assert is_binary(Map.get(env, :hint)),
             "Errors.stamp/2 must still put the code-keyed default on an envelope that carries none"
    end
  end

  describe "each 401 emitter names only credentials its own route accepts" do
    test "no 401 hint names a credential kind outside its route's accepted set" do
      for {label, accepted, run} <- emitters() do
        err = run.() |> body()

        assert err["code"] == "unauthorized",
               "#{label}: expected an unauthorized envelope, got #{inspect(err)}"

        hint = err["hint"] || ""
        stray = kinds_named(hint) -- accepted

        assert stray == [],
               """
               #{label}
               named a credential kind this route does not accept: #{inspect(stray)}
               accepted: #{inspect(accepted)}
               hint: #{hint}

               A refusal that names the wrong credential costs MORE than silence: the
               caller goes and fetches a credential this route will refuse again, and
               concludes their working credential is broken.
               """
      end
    end

    test "POSITIVE CONTROL: a route-derived hint actually names its own credential" do
      for {label, accepted, run} <- emitters() do
        hint = run.() |> body() |> Map.get("hint", "")
        named = kinds_named(hint)

        assert named != [],
               """
               #{label}
               emitted a 401 whose hint names NO credential kind: #{inspect(hint)}
               An empty or fully agnostic hint would pass the check above vacuously —
               that is how this class survived. A plug that knows its own credential
               must pass it through ErrorResponse.emit_custom/6.
               """

        assert named -- accepted == [],
               "#{label}: named #{inspect(named)}, accepted #{inspect(accepted)}"
      end
    end

    test "CONTROL: forcing the OLD default onto these routes would be caught" do
      # The detector run against the pre-change world, per route. Three of the
      # five routes refuse a dataset-scoped api token outright, so the old
      # code-keyed default was WRONG on them — and this shows the check above
      # would have said so.
      wrong =
        for {label, accepted, _run} <- emitters(),
            stray = kinds_named(@credential_specific_default) -- accepted,
            stray != [],
            do: label

      assert length(wrong) >= 3,
             """
             The old code-keyed default named a credential kind at least three of these
             five routes do not accept; the check above must be able to see that.
             It saw #{length(wrong)}: #{inspect(wrong)}
             """
    end
  end
end
