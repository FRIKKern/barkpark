import { PostsListSkeleton } from "@/components/posts-list";

/**
 * Route-level fallback for `/w/[workspace]/p/[project]` — the scoped post
 * listing. The RSC awaits the scoped posts fetch; this paints the listing
 * skeleton instantly on navigation (the same shell the page's own <Suspense>
 * renders) so switching workspace/project never freezes the previous pane.
 */
export default function ScopedHomeLoading() {
  return <PostsListSkeleton />;
}
