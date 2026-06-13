import { Suspense } from "react";
import { client } from "@/lib/barkpark-client";
import { fetchPosts, type PostDocument } from "@/lib/posts";
import { PostsList, PostsListSkeleton } from "@/components/posts-list";

// Live surface: render fresh each request so <BarkparkLive/>'s router.refresh()
// reflects content changes immediately (ISR caching would lag up to revalidate).
export const dynamic = "force-dynamic";

/** Async data boundary — streams the list in behind the skeleton fallback. */
async function FlatPosts() {
  let posts: PostDocument[] = [];
  let error: string | null = null;

  try {
    posts = await fetchPosts(client);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  return <PostsList posts={posts} error={error} basePath="/posts" />;
}

export default function Home() {
  return (
    <Suspense fallback={<PostsListSkeleton />}>
      <FlatPosts />
    </Suspense>
  );
}
