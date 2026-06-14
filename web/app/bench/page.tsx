import type { Metadata } from "next";
import { Bench } from "@/components/bench";

export const metadata: Metadata = {
  title: "Engine benchmark · Barkpark",
  description:
    "Latency benchmark across Postgres and Indx search engines, with Next.js Data Cache off/on.",
};

export default function BenchPage() {
  return <Bench />;
}
