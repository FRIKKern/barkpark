defmodule BarkparkCloud.Repo.Migrations.AddPushRelaySecretToBarkparks do
  use Ecto.Migration

  # Push-relay spike (mobile charter D15) — the per-barkpark shared secret the
  # INSTANCE signs its chat_blocked webhook deliveries with (the box's
  # Barkpark.Webhooks.Dispatcher `t=<unix>,v1=<hex>` scheme) and Cloud's
  # /v1/relay/chat-blocked/:barkpark_id receiver verifies against.
  #
  # Custody is EXACTLY the admin-token pattern (add_admin_token_to_barkparks):
  # the column holds the Base64 of Registry.Vault's AES-256-GCM output — never
  # the plaintext. Minted Cloud-side (Registry.mint_push_relay_secret/1); the
  # plaintext travels ONCE, server-to-instance, when wave 2 registers the
  # chat_blocked webhook row on the box (the same admin-relay path create_site
  # uses for content-publish secrets).
  #
  # Nullable = SEVERABLE: a row with no secret means no relay is configured for
  # that instance, and the receiver answers the same silent 404 as a nonexistent
  # barkpark (probe-proof, mirroring reveal_site_content_secret's contract).
  #
  # Expand/contract: purely ADDITIVE (new nullable column). Safe under
  # blue/green overlap.
  def change do
    alter table(:barkparks) do
      add :push_relay_secret_encrypted, :text
    end
  end
end
