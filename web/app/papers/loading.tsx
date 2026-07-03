import { PostsListSkeleton } from "@/components/posts-list";

/**
 * Route-level fallback for `/papers`. The listing is an async RSC (force-dynamic
 * fetch of the papers corpus); on a cold navigation the router would otherwise
 * hold the previous pane until the RSC payload's first chunk arrives. This gives
 * Next an instant skeleton that mirrors the listing's header + rows — the same
 * shell PostsListSkeleton renders inside the page's own <Suspense>, so there's
 * no layout jump when the real content streams in.
 */
export default function PapersLoading() {
  return <PostsListSkeleton />;
}
