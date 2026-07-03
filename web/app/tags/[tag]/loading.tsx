import { PostsListSkeleton } from "@/components/posts-list";

/**
 * Route-level fallback for `/tags/[tag]`. The tag listing awaits the papers
 * corpus, then filters. Mirrors the listing's header + rows so a cold
 * navigation paints an instant skeleton instead of freezing the prior pane —
 * the same shell the page's own <Suspense> uses (no layout jump on load).
 */
export default function TagLoading() {
  return <PostsListSkeleton />;
}
