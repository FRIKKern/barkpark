defmodule BarkparkCloud.NotificationsPlatformAdminEnvTest do
  @moduledoc """
  GR60 step 1 — the FULL platform-operator chain, end to end:

      PLATFORM_ADMIN_EMAILS (OS env)
        -> the real config/runtime.exs prod block, evaluated through
           `Config.Reader` exactly as a release boot does
        -> Application env `:platform_admin_emails`
        -> `Notifications.platform_admin_emails/0` (resolves each address to a
           REGISTERED user, drops the rest)
        -> `Auth.require_platform_operator/2` (the gate on all six
           /v1/operator/* routes and the source of `/v1/me`'s
           `platform_operator` boolean)

  Every link existed; nothing tested them together. `runtime_config_test.exs`
  stops at the env->config parse, and `router_operator_test.exs` starts by
  `Application.put_env`-ing the list directly — so the resolver and the env leg
  of the chain had NO coverage, and the crown shipped dark without a red test.

  Note what this test does NOT prove: that the variable reaches the CONTAINER.
  That is `cloud/docker-compose.yml`'s bare passthrough line (compose passes
  nothing it does not bare-list), which no Elixir test can observe.

  `async: false` — it mutates real OS environment variables AND the
  process-global `:platform_admin_emails` Application key.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Notifications}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Every env var this test touches: the prod hard-raise requirements, the two
  # that silence the partial-billing IO.warn, and the var under test.
  @touched ~w(
    DATABASE_URL REGISTRY_ENCRYPTION_KEY STRIPE_SECRET_KEY OAUTH_STATE_SECRET
    STRIPE_WEBHOOK_SECRET STRIPE_PRICE_SUPPORTER PLATFORM_ADMIN_EMAILS
  )

  setup do
    prior_env = Map.new(@touched, &{&1, System.get_env(&1)})
    prior_config = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])

    on_exit(fn ->
      for {name, value} <- prior_env do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end

      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior_config)
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://user:pass@localhost/platform_admin_env_test",
      "REGISTRY_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "STRIPE_SECRET_KEY" => "sk_test_platform_admin_env_test",
      "OAUTH_STATE_SECRET" => "platform-admin-env-test-state-secret",
      "STRIPE_WEBHOOK_SECRET" => "whsec_platform_admin_env_test",
      "STRIPE_PRICE_SUPPORTER" => "price_platform_admin_env_test"
    })

    :ok
  end

  ## Chain drivers

  # Set (or clear) the env var, then walk the release-boot path: evaluate the
  # REAL runtime.exs prod block and install ONLY the resulting
  # `:platform_admin_emails` value into Application env — the other keys stay
  # untouched so the sandboxed test Repo keeps its own config.
  defp boot_with_env(nil) do
    System.delete_env("PLATFORM_ADMIN_EMAILS")
    install_runtime_config()
  end

  defp boot_with_env(value) when is_binary(value) do
    System.put_env("PLATFORM_ADMIN_EMAILS", value)
    install_runtime_config()
  end

  defp install_runtime_config do
    parsed =
      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod, target: :host)
      |> get_in([:barkpark_cloud, :platform_admin_emails])

    Application.put_env(:barkpark_cloud, :platform_admin_emails, parsed)
    parsed
  end

  ## Fixtures

  defp user_fixture(email \\ nil) do
    {:ok, user} =
      Accounts.register_user(%{
        email: email || "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # The cheapest operator-gated route; the gate itself is shared by all six.
  defp operator_call(user) do
    conn(:get, "/v1/operator/fleet")
    |> put_req_header("authorization", "Bearer #{session_token(user)}")
    |> Router.call(@opts)
  end

  ## 1. Unset — the honest, fail-closed default

  test "unset PLATFORM_ADMIN_EMAILS resolves to [] even with registered users" do
    _registered = user_fixture()

    assert boot_with_env(nil) == []
    assert Notifications.platform_admin_emails() == []
  end

  ## 2. Registered — the canonical stored email comes back

  test "a registered address resolves to the canonical stored email" do
    user = user_fixture("ops-#{System.unique_integer([:positive])}@example.com")

    # Mixed case + padding on the way in: the resolver downcases and the DB
    # lookup returns the stored email, so the OUTPUT is canonical, not the
    # operator's typing.
    assert boot_with_env("  #{String.upcase(user.email)} ") == [String.upcase(user.email)]
    assert Notifications.platform_admin_emails() == [user.email]
  end

  ## 3. Unregistered entries are silently dropped, siblings survive

  test "an unregistered entry is dropped while a registered sibling survives" do
    user = user_fixture()
    ghost = "ghost-#{System.unique_integer([:positive])}@example.com"

    assert boot_with_env("#{ghost},#{user.email}") == [ghost, user.email]
    assert Notifications.platform_admin_emails() == [user.email]
  end

  ## 4. All-unregistered collapses back to []

  test "an all-unregistered allowlist resolves to []" do
    a = "nobody-a-#{System.unique_integer([:positive])}@example.com"
    b = "nobody-b-#{System.unique_integer([:positive])}@example.com"

    # The config parse is happy — the RESOLVER is what fails closed.
    assert boot_with_env("#{a}, #{b}") == [a, b]
    assert Notifications.platform_admin_emails() == []
  end

  ## 5. The gate fails closed on both empty shapes

  test "require_platform_operator 403s on unset and on listed-but-unregistered, 200s on listed+registered" do
    user = user_fixture()

    boot_with_env(nil)
    assert operator_call(user).status == 403, "unset env must fail closed for an authed user"

    boot_with_env("someone-else-#{System.unique_integer([:positive])}@example.com")

    assert operator_call(user).status == 403,
           "a listed-but-unregistered allowlist is still nobody"

    boot_with_env(user.email)
    assert operator_call(user).status == 200
  end

  ## 6. The far end of the same chain: what the DIGEST does with the empty set
  ##
  ##    §1-§5 prove the chain fails CLOSED — an unset variable is nobody, and the
  ##    operator gate 403s. dr-w18-s3 adds the other consequence of that same
  ##    empty set, which had no test at all: the daily fleet digest resolves the
  ##    same population, finds nobody, and used to return a success nothing
  ##    counted. Driven here from the REAL runtime.exs boot path rather than an
  ##    `Application.put_env`, so the assertion is about the deployed
  ##    configuration and not about a value a test typed in.

  test "an unset variable makes the daily fleet digest a COUNTED loss, not a quiet success" do
    _registered = user_fixture()
    assert boot_with_env(nil) == []

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :no_admins} = Notifications.deliver_fleet_digest([])
      end)

    # The loss is greppable and it is a WARNING — the same env state that dark-
    # ens the operator console also silences the one push channel for fleet
    # health, and now says so.
    assert log =~ "fleet_digest phase=settled"
    assert log =~ "recipients=0 sent=0"
    assert log =~ "reason=no_platform_admins"
    assert log =~ "[warning]"
  end

  # The one link no Elixir test can OBSERVE is also the one that was broken, and
  # it shipped with nothing watching it. This is the narrowest honest tripwire:
  # a text assertion that the bare passthrough line is still in the
  # x-control-plane environment block. It cannot prove compose forwards the
  # value — but it reds the moment someone reorders or refactors that block and
  # drops the line, which is exactly how the console went dark the first time.
  #
  # Deliberately NOT a general "every runtime.exs env name must be bare-listed"
  # lint: 22 other names are absent today, and deciding which of those are real
  # omissions is its own piece of work (filed, not smuggled in here).
  test "docker-compose.yml still bare-lists PLATFORM_ADMIN_EMAILS for the control plane" do
    compose = File.read!(Path.join(__DIR__, "../../docker-compose.yml"))

    [_, control_plane_block | _] = String.split(compose, "x-control-plane:", parts: 2)
    # The anchor block ends where the next top-level key begins.
    block = control_plane_block |> String.split(~r/\n(?=\S)/, parts: 2) |> hd()

    assert block =~ ~r/^\s*- PLATFORM_ADMIN_EMAILS\s*$/m,
           """
           cloud/docker-compose.yml's x-control-plane environment: list must carry a
           BARE `- PLATFORM_ADMIN_EMAILS` entry. Compose passes nothing it does not
           bare-list, so without it an operator can set the variable in
           /opt/barkpark/cloud/.env, see it set on the host, and still get a dark
           Operator console — the exact false green GR60 exists to prevent.
           """
  end
end
