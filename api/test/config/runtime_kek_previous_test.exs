defmodule Barkpark.Config.RuntimeKekPreviousTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads at
  # eval time (same pattern as RuntimeTaskLeaseTtlTest / RuntimeUrlPortTest).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # BARKPARK_KEK_PREVIOUS carries PRIOR BARKPARK_KEK values through a rotation
  # window so `DataKeys.rewrap_all/0` can unwrap blobs sealed under them.
  # `LocalKek.keys/0` filters previous keys with
  # `Enum.filter(&match?(<<_::binary-size(32)>>, &1))`, which DISCARDS a
  # malformed entry with no log line at all — the blobs sealed under that KEK
  # then become permanently undecryptable, an unbounded time after a clean
  # boot.
  #
  # runtime.exs therefore AUDITS every set entry (base64 of exactly 32 raw
  # bytes, the primary BARKPARK_KEK's own contract) and REFUSES THE BOOT on a
  # malformed one, naming the 1-based positions and never the entry
  # (task-ef0c59e4fd3fc985). A clean verdict is recorded under
  # `Barkpark.Crypto.LocalKek`'s `:kek_previous_audit`, which `Barkpark.Status`
  # republishes on /status.json.
  #
  # No-primary boundary, DECIDED: with no BARKPARK_KEK set nothing consumes the
  # previous keys, so a malformed BARKPARK_KEK_PREVIOUS is deliberately IGNORED
  # (checked: false) and does not refuse. Pinned below.

  @good Base.encode64(String.duplicate("k", 32))
  @older Base.encode64(String.duplicate("j", 32))

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ ~w(BARKPARK_KEK_PREVIOUS)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("BARKPARK_KEK_PREVIOUS")
    :ok
  end

  defp read_previous_keys(nil) do
    System.delete_env("BARKPARK_KEK_PREVIOUS")
    do_read()
  end

  defp read_previous_keys(value) do
    System.put_env("BARKPARK_KEK_PREVIOUS", value)
    do_read()
  end

  defp do_read do
    read_kek_config() |> Keyword.get(:previous_keys)
  end

  defp read_kek_config(env \\ :prod) do
    Config.Reader.read!(@runtime_exs, env: env)
    |> get_in([:barkpark, Barkpark.Crypto.LocalKek])
  end

  # Evaluate runtime.exs with BARKPARK_KEK_PREVIOUS set to `value` and return
  # `{audit, log}` — the machine-readable verdict and everything it logged.
  defp audit_and_log(value, env \\ :prod) do
    case value do
      nil -> System.delete_env("BARKPARK_KEK_PREVIOUS")
      v -> System.put_env("BARKPARK_KEK_PREVIOUS", v)
    end

    log =
      capture_log(fn ->
        Process.put(
          :kek_previous_audit,
          Keyword.get(read_kek_config(env) || [], :kek_previous_audit)
        )
      end)

    {Process.delete(:kek_previous_audit), log}
  end

  # --- CONTROL: the shapes that must keep booting -------------------------

  test "unset BARKPARK_KEK_PREVIOUS boots with no previous keys" do
    assert read_previous_keys(nil) == []
  end

  test "empty BARKPARK_KEK_PREVIOUS boots with no previous keys" do
    assert read_previous_keys("") == []
  end

  test "well-formed entries boot and are passed through in order" do
    assert read_previous_keys("#{@good},#{@older}") == [@good, @older]
  end

  test "stray and trailing commas still boot (blank entries are not an error)" do
    assert read_previous_keys(",#{@good},,#{@older},") == [@good, @older]
    assert read_previous_keys(" , ") == []
  end

  test "surrounding whitespace on a good entry still boots" do
    assert read_previous_keys("  #{@good}  ") == [@good]
  end

  # --- The defect: a malformed entry must REFUSE the boot ------------------

  defp refusal(value, env \\ :prod) do
    System.put_env("BARKPARK_KEK_PREVIOUS", value)

    error = assert_raise(RuntimeError, fn -> read_kek_config(env) end)
    error.message
  end

  test "a non-base64 entry refuses the boot and names its position" do
    msg = refusal("not-base64!!")

    assert msg =~ "BARKPARK_KEK_PREVIOUS"
    assert msg =~ "position 1"
    assert msg =~ "32 raw bytes"
  end

  test "the refusal holds in every env, not just prod" do
    for env <- [:dev, :test] do
      assert refusal("typo", env) =~ "position 1"
    end
  end

  test "a base64 entry of the wrong length refuses the boot" do
    short = Base.encode64(String.duplicate("k", 31))
    long = Base.encode64(String.duplicate("k", 33))

    assert refusal(short) =~ "position 1"
    assert refusal(long) =~ "position 1"
  end

  test "the positions name the offending entries, not the first one" do
    msg = refusal("#{@good},#{@older},typo")

    assert msg =~ "position 3"
    refute msg =~ "position 1"
  end

  test "several malformed entries are all counted and all named" do
    msg = refusal("typo,#{@good},also-typo")

    assert msg =~ "2 entries"
    assert msg =~ "positions 1, 3"
  end

  test "the refusal does not leak the key material" do
    secret = Base.encode64(String.duplicate("k", 31))
    refute refusal(secret) =~ secret
  end

  # --- CONTROLS on the audit itself: clean must be DISTINCT from unchecked ---

  test "a clean list records checked: true with nothing discarded, and logs nothing" do
    {audit, log} = audit_and_log("#{@good},#{@older}")

    assert audit == %{checked: true, discarded: 0, positions: []}
    refute log =~ "BARKPARK_KEK_PREVIOUS"
  end

  test "unset BARKPARK_KEK_PREVIOUS still records a checked, clean audit" do
    assert {%{checked: true, discarded: 0, positions: []}, _} = audit_and_log(nil)
  end

  test "with NO primary BARKPARK_KEK the audit says checked: false, not clean" do
    System.delete_env("BARKPARK_KEK")
    # env: :dev — the prod arm REQUIRES a primary BARKPARK_KEK and refuses
    # without one, so that env can never reach the no-primary state.
    {audit, log} = audit_and_log("typo,also-typo", :dev)

    # SCOPE DECISION, pinned: with no primary KEK, runtime.exs configures no
    # previous_keys at all, so nothing is consumed and nothing is discarded —
    # the malformed entries are deliberately IGNORED and the boot is NOT refused
    # (reaching the assertions below proves no raise).
    # That is recorded as checked: false — distinguishable from "checked and
    # clean", so a reader can never confuse the two.
    assert audit == %{checked: false, discarded: 0, positions: []}
    assert Keyword.get(read_kek_config(:dev) || [], :previous_keys) == nil
    refute log =~ "BARKPARK_KEK_PREVIOUS:"
  end

  # A malformed entry that gets PAST runtime.exs is exactly what LocalKek
  # discards in silence, and this is what that costs. It pins the failure the
  # boot gate now prevents, so the gate's value is not asserted on faith.
  test "a mistyped previous key makes old ciphertext undecryptable, silently" do
    prev = Application.get_env(:barkpark, Barkpark.Crypto.LocalKek, [])
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Crypto.LocalKek, prev) end)

    put = fn opts ->
      Application.put_env(
        :barkpark,
        Barkpark.Crypto.LocalKek,
        Keyword.merge(prev, opts)
      )
    end

    # Seal a blob under the OLD KEK, before the rotation.
    put.(key: @older, previous_keys: [])
    plaintext = :crypto.strong_rand_bytes(32)
    sealed = Barkpark.Crypto.LocalKek.wrap(plaintext)

    # CONTROL: rotate with the old KEK spelled CORRECTLY — the blob still
    # unwraps, which is the whole point of BARKPARK_KEK_PREVIOUS.
    put.(key: @good, previous_keys: [@older])
    assert {:ok, ^plaintext} = Barkpark.Crypto.LocalKek.unwrap(sealed)

    # THE DEFECT: one character wrong in the rotation entry. No raise, no log,
    # no :error at boot — the blob is simply gone.
    put.(key: @good, previous_keys: ["typo" <> @older])
    assert Barkpark.Crypto.LocalKek.unwrap(sealed) == :error

    # And a Base64 string of the wrong LENGTH fails the same silent way.
    put.(key: @good, previous_keys: [Base.encode64(String.duplicate("j", 31))])
    assert Barkpark.Crypto.LocalKek.unwrap(sealed) == :error
  end
end
