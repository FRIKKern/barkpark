import { PostsListSkeleton } from "@/components/posts-list";

/**
 * Route-level fallback for `/w/[workspace]`. This route resolves the
 * workspace's default project server-side (an async `listProjects` await) and
 * redirects to `/w/<ws>/p/<project>`. During that await the pane would freeze
 * with no feedback; the listing skeleton — which also matches the redirect
 * target's chrome — bridges the gap so the switch feels instant.
 */
export default function WorkspaceLandingLoading() {
  return <PostsListSkeleton />;
}
