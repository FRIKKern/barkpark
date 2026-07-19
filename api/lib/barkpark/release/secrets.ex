defmodule Barkpark.Release.Secrets do
  @moduledoc """
  First-run secret generation for personal/local installs.

  `config/runtime.exs` raises in `:prod` when any of these env vars are
  missing: `BARKPARK_CLOAK_KEY`, `BARKPARK_KEK`, `DATABASE_URL`,
  `SECRET_KEY_BASE`, `PHX_HOST`, `PREVIEW_JWT_SECRET`, and
  `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET`. This module generates the five
  cryptographic secrets and writes a `~/.barkpark/.env` template
  idempotently so a personal-local install can boot without hand-rolling
  `openssl rand` invocations.

  This is intentionally **separate** from `Barkpark.Release` (the
  migrate/seed release-task module) — it never touches the database and
  has no compile-time coupling to the repo.

  ## Why these byte-lengths

    * `SECRET_KEY_BASE` — 64 raw bytes. Phoenix signs/encrypts cookies and
      other secrets with it; `mix phx.gen.secret` defaults to 64 bytes.
    * `PREVIEW_JWT_SECRET` — 64 raw bytes. Signs the preview JWTs; matching
      `SECRET_KEY_BASE`'s strength is the floor, hence `>= 64`.
    * `BARKPARK_CLOAK_KEY` — 32 raw bytes. `runtime.exs` feeds this value
      through `:crypto.hash(:sha256, key)` to derive Cloak's AES-256-GCM
      key, so 32 bytes of entropy is the right size and it is generated
      **independently** of `SECRET_KEY_BASE` (key rotation in either
      system must not invalidate the other — see runtime.exs).
    * `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` — 32 raw bytes. Authenticates
      server-owned reader evidence independently of cookie, preview, and field
      encryption keys, so rotating any one authority does not forge another.
    * `BARKPARK_KEK` — 32 raw bytes. The master key-encryption-key for envelope
      encryption (wraps the per-scope DEKs in `data_keys` — see
      `Barkpark.Crypto.LocalKek`). `runtime.exs` REQUIRES it in `:prod` and
      raises without it, so a fresh `bin/barkpark up` (which boots `:prod`) can
      only start once this is generated. Base64 of 32 raw bytes, generated
      **independently** of `BARKPARK_CLOAK_KEY` and `SECRET_KEY_BASE` so the
      three rotate on their own.
  """

  @secret_key_base_bytes 64
  @preview_jwt_secret_bytes 64
  @cloak_key_bytes 32
  @release_capture_hmac_bytes 32
  @kek_bytes 32

  @doc """
  Generate the five crypto secrets as a map of `var => base64 value`.

  Each value is independently sourced from `:crypto.strong_rand_bytes/1`
  and Base64-encoded.

      iex> secrets = Barkpark.Release.Secrets.generate()
      iex> Map.keys(secrets) |> Enum.sort()
      ["BARKPARK_CLOAK_KEY", "BARKPARK_KEK", "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET", "PREVIEW_JWT_SECRET", "SECRET_KEY_BASE"]
      iex> byte_size(Base.decode64!(secrets["SECRET_KEY_BASE"]))
      64
      iex> byte_size(Base.decode64!(secrets["BARKPARK_CLOAK_KEY"]))
      32
      iex> byte_size(Base.decode64!(secrets["BARKPARK_KEK"]))
      32

  """
  @spec generate() :: %{String.t() => String.t()}
  def generate do
    %{
      "SECRET_KEY_BASE" => random_base64(@secret_key_base_bytes),
      "PREVIEW_JWT_SECRET" => random_base64(@preview_jwt_secret_bytes),
      "BARKPARK_CLOAK_KEY" => random_base64(@cloak_key_bytes),
      "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => random_base64(@release_capture_hmac_bytes),
      "BARKPARK_KEK" => random_base64(@kek_bytes)
    }
  end

  @doc """
  Write (or top up) the personal-local `.env` template at `path`.

  Defaults to `~/.barkpark/.env`. Behaviour:

    * creates the parent directory if missing,
    * generates the five crypto secrets via `generate/0`,
    * adds placeholders for the two non-secret env vars `runtime.exs`
      requires — `DATABASE_URL` and `PHX_HOST`,
    * `chmod 0600` so the secrets are not world/group readable.

  **Idempotent.** Existing keys are never overwritten: the current file
  (if any) is parsed first and only *missing* keys are appended. A second
  call after the user hand-edits `DATABASE_URL` leaves their value intact.

  Returns `{:ok, path}` on success.
  """
  # `path` is a trusted release/operator argument, never request input. The API
  # intentionally supports an explicit path so installers and tests can target
  # an isolated Barkpark home without mutating the user's real one.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_env(Path.t()) :: {:ok, Path.t()}
  def write_env(path \\ default_path()) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    existing = read_existing(path)

    additions =
      template_entries()
      |> Enum.reject(fn {key, _value} -> Map.has_key?(existing, key) end)

    if additions != [] do
      lines = Enum.map(additions, fn {key, value} -> "#{key}=#{value}\n" end)
      append_block = IO.iodata_to_binary(lines)

      content =
        case File.read(path) do
          {:ok, current} -> ensure_trailing_newline(current) <> append_block
          {:error, :enoent} -> append_block
        end

      File.write!(path, content)
    end

    File.chmod!(path, 0o600)

    {:ok, path}
  end

  @doc """
  Default `.env` location for a personal-local install.

  Honors `BARKPARK_HOME` (the same root `bin/barkpark` and `bin/barkpark-pg`
  use) so the shell launcher and this module never disagree on where the env
  file lives. Falls back to `~/.barkpark/.env` when `BARKPARK_HOME` is unset.
  """
  @spec default_path() :: String.t()
  def default_path do
    home =
      case System.get_env("BARKPARK_HOME") do
        nil -> "~/.barkpark"
        "" -> "~/.barkpark"
        value -> value
      end

    home |> Path.join(".env") |> Path.expand()
  end

  # The full set of var=value entries the template should contain. Crypto
  # secrets are freshly generated; the two non-secret vars are placeholders
  # the user must fill in. Var names match config/runtime.exs exactly.
  defp template_entries do
    placeholders = [
      {"DATABASE_URL", "ecto://postgres:postgres@localhost/barkpark"},
      {"PHX_HOST", "localhost"}
    ]

    Map.to_list(generate()) ++ placeholders
  end

  defp random_base64(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  # Parse the existing .env into a set of present keys. Tolerant of blank
  # lines and `#` comments; only the key (left of the first `=`) matters
  # for the idempotency check.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_existing(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          trimmed = String.trim(line)

          cond do
            trimmed == "" -> acc
            String.starts_with?(trimmed, "#") -> acc
            true -> parse_key(trimmed, acc)
          end
        end)

      {:error, :enoent} ->
        %{}
    end
  end

  defp parse_key(line, acc) do
    case String.split(line, "=", parts: 2) do
      [key, _value] -> Map.put(acc, String.trim(key), true)
      _ -> acc
    end
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(contents) do
    if String.ends_with?(contents, "\n"), do: contents, else: contents <> "\n"
  end
end
