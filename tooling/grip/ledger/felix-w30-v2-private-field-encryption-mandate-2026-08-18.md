# felix-w30 V2 — is FieldCipher encryption mandatory for private/owner_only fields?

VERDICT: NO. Encryption is NOT forced for private/owner_only/visibility fields.
Private-without-encryption is a fully valid schema shape → persists PLAINTEXT-AT-REST.
V2's backstop DOES NOT hold; the scar-class is NOT closed by construction.
Census cleanliness falls back entirely to V1's schema-resolution invariant.

## Re-derive (api/, origin/main 2026-08-18)

1. The write chokepoint keys ONLY on `encrypted: true`, never on private/visibility:
   grep -n 'maybe_encrypt_marked_fields\|Encryption.encrypt_marked' lib/barkpark/content/writer.ex
   # writer.ex:1103-1140 — maybe_encrypt_marked_fields → Encryption.encrypt_marked
   sed -n '30,80p' lib/barkpark/content/encryption.ex
   # encrypt_marked drives off `%SchemaDefinition{fields}` with `encrypted: true` ONLY
   #   sensitive_field?(%Field{encrypted: true}) -> true  (encryption.ex:185)

2. The four visibility markers are orthogonal, data-only, NO cross-validation:
   sed -n '202,222p' lib/barkpark/content/schema_definition.ex
   #   :encrypted (default false), private: false, visibility: nil, readable_by: []
   sed -n '460,466p' lib/barkpark/content/schema_definition.ex
   #   parsed independently: encrypted / private / visibility / readable_by
   # visibility comment line 214: "owner_only (no validation)"

3. NO validation forces private ⇒ encrypted:
   grep -n 'validate' lib/barkpark/content/schema_definition.ex
   # only field validators: validate_field_name (450,481-498)
   # line 95 validate_inclusion(:visibility, public|private) is the SCHEMA-LEVEL
   #   (listing) changeset — top-level SchemaDefinition, NOT a field. Unrelated.

4. No test asserts the private→encrypt link (because it does not exist):
   grep -n 'private\|visibility\|owner_only\|mandat\|force' test/barkpark/content/encryption_test.exs
   # (empty) — encryption tests never touch field-visibility.

## Consequence for the wave

envelope.ex nil-schema guard drops ONLY encrypted ciphertext (V1's finding).
A declared `private: true` / `visibility: "owner_only"` field WITHOUT `encrypted: true`
is legal and stored plaintext, so the nil-schema guard does NOT cover it.
The scar-class remains gated SOLELY by V1: can a non-admin reach a
schema-missing-yet-doc-readable state? V2 provides NO independent backstop.
