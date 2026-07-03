import type { MetadataRoute } from "next";
import { absoluteUrl } from "@/lib/site-url";

/**
 * Robots policy for the public demo. Everything is crawlable; the sitemap is
 * advertised at the SAME origin metadataBase/sitemap/feed all derive from
 * (`@/lib/site-url`), so crawlers get an absolute, resolvable pointer.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: "*", allow: "/" },
    sitemap: absoluteUrl("/sitemap.xml"),
  };
}
