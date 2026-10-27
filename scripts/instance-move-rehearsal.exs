# Seeds and checks the data that scripts/instance-move-rehearsal.sh moves.
# Run from api/ with MIX_ENV=prod: mix run --no-start <this file> seed|check
# `seed` migrates and seeds an empty database, then writes one document with an
# encrypted field and one user with TOTP. `check` boots the tree without a
# listener and reads both back. MOVE_TOTP_SECRET is the TOTP secret in hex.
alias Barkpark.{Accounts, Content, Repo}
alias Barkpark.Accounts.User
alias Barkpark.Content.{CallerContext, Document, SchemaDefinition}
import Ecto.Query

dataset = "production"
type = "move_vault"
email = "move-rehearsal@example.com"
secret = Base.decode16!(System.fetch_env!("MOVE_TOTP_SECRET"), case: :lower)

case System.argv() do
  ["seed"] ->
    Barkpark.Release.migrate()
    Barkpark.Release.seed()

    {:ok, _} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => type,
        "title" => type,
        "dataset" => dataset,
        "fields" => [%{"name" => "secret", "type" => "string", "encrypted" => true}]
      })
      |> Repo.insert()

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => "move-1", "title" => "move", "content" => %{"secret" => "hunter2"}},
        dataset
      )

    {:ok, user} = Accounts.register_user(%{"email" => email, "password" => "move-rehearsal-pw-1"})
    {:ok, _, _} = Accounts.enable_totp(user, secret, NimbleTOTP.verification_code(secret))
    IO.puts("seeded: encrypted field and TOTP user")

  ["check"] ->
    Barkpark.Release.seed_boot!()
    schema = Repo.get_by!(SchemaDefinition, name: type, dataset: dataset)
    doc = Repo.one!(from d in Document, where: d.type == ^type and d.dataset == ^dataset)
    admin = %CallerContext{principal_type: :api_token, is_admin: true}

    {:ok, %{content: %{"secret" => "hunter2"}}} =
      Content.reveal_fields(doc, schema, dataset, admin)

    IO.puts("check: encrypted field reads back")

    %User{totp_enabled: true, totp_secret: ^secret} = user = Repo.get_by!(User, email: email)
    true = Accounts.valid_totp?(user, NimbleTOTP.verification_code(secret))
    IO.puts("check: TOTP secret decrypts and a current code is valid")
end
