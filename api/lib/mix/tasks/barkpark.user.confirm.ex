defmodule Mix.Tasks.Barkpark.User.Confirm do
  @moduledoc """
  Confirm a user's email on the operator's word:
  `MIX_ENV=prod mix barkpark.user.confirm editor@example.com`.

  Password login refuses an unconfirmed account (`403 email_unconfirmed`) and
  re-sends the confirmation link. When that link cannot arrive (a seeded
  editor at an address with no mailbox, or a box with no SMTP), an operator
  with shell access confirms the account here. The password is kept, so only
  confirm an account you created or whose owner you know.
  See `Barkpark.Accounts.confirm_user_by_operator/1`.
  """
  @shortdoc "Confirm a user's email without the emailed link"

  use Mix.Task

  @impl Mix.Task
  def run([email]) do
    # The narrowed tree: no listener, no Oban, so it runs beside the live
    # server without taking its port.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    case Barkpark.Accounts.confirm_user_by_operator(email) do
      {:ok, user} ->
        Mix.shell().info("confirmed #{user.email}")

      {:ok, user, :already_confirmed} ->
        Mix.shell().info("#{user.email} was already confirmed")

      {:error, :not_found} ->
        Mix.raise("no account has the email #{email}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix barkpark.user.confirm <email>")
end
