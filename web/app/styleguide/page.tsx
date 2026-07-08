import type { Metadata } from "next";
import { Styleguide } from "@/components/styleguide";

export const metadata: Metadata = {
  title: "Style guide · Barkpark",
  description:
    "The living design-token spec for the web demo — palette, status roles and type ladder rendered from the emitted CSS vars (design/tokens.json).",
};

export default function StyleguidePage() {
  return <Styleguide />;
}
