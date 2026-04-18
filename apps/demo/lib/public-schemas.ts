// Fallback list of public schema types. Used when /v1/schemas/production is
// admin-only or otherwise unreachable. Keep small — add a type here only after
// confirming it is safe to expose on the public demo.
export const PUBLIC_SCHEMAS = ["post"] as const;

export type PublicSchema = (typeof PUBLIC_SCHEMAS)[number];
