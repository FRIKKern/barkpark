import "server-only";
import { createClient, type BarkparkClient } from "@barkpark/core";

const projectUrl = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000";

export const client: BarkparkClient = createClient({
  projectUrl,
  dataset: "production",
  apiVersion: "2026-04-01",
  perspective: "published",
});
