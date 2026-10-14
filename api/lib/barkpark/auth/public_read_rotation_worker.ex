defmodule Barkpark.Auth.PublicReadRotationWorker do
  @moduledoc """
  The weekly `public-read` token rotation as a core job (task-eaaf13ab768f34f6
  criterion 6). It replaces the `barkpark-rotate-public-token` systemd timer,
  which was staged in deploy/systemd and never installed, so the rotation never
  ran and nothing said so.

  Scheduled Mondays 03:00 UTC in the static Oban crontab, the timer's slot.
  The work is `Barkpark.Auth.PublicRead.rotate/1`.

  SHIPS DISABLED. While `config :barkpark, :public_read_rotation,
  enabled: false` (the default; runtime switch
  `BARKPARK_PUBLIC_READ_ROTATION=on`) a tick writes nothing and returns
  `{:ok, %{skipped: :disabled}}`, logging that once at :info. Turning it on is the owner's call: from then
  on the token rotates weekly and the previous one is purged after 8 days.

  A failed rotation returns `{:error, _}`: Oban retries it and logs each
  failure, instead of a timer failing silently on a host nobody watches.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 6 * 24 * 60 * 60]

  require Logger

  alias Barkpark.Auth.PublicRead

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if PublicRead.rotation_enabled?() do
      case PublicRead.rotate() do
        {:ok, %{label: label, purged: purged} = result} ->
          Logger.info("public-read rotation: minted #{label}, purged #{purged} aged token(s)")
          {:ok, result}

        {:error, reason} = error ->
          Logger.error("public-read rotation failed: #{inspect(reason)}")
          error
      end
    else
      Logger.info(
        "public-read rotation: disabled (BARKPARK_PUBLIC_READ_ROTATION is not on); no token minted"
      )

      {:ok, %{skipped: :disabled}}
    end
  end
end
