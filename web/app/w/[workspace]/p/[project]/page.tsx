import { Suspense } from "react";
import { getScopedPosts, type PostDocument } from "@/lib/posts";
import { PostsList, PostsListSkeleton } from "@/components/posts-list";

// 60s ISR is now a SAFETY NET, not the freshness mechanism: getScopedPosts
// wraps the fetch in unstable_cache tagged bpAll()+bpType("post"), so a publish
// webhook busts this listing instantly (see lib/posts.ts).
export const revalidate = 60;

/**
 * Scoped post listing. The route params → `createClient({ workspace, project })`
 * (inside getScopedPosts) → a core client whose requests carry
 * `/w/<ws>/p/<project>` (via scopePrefix). The fetch streams in behind the
 * skeleton fallback.
 */
async function ScopedPosts({
  workspace,
  project,
}: {
  workspace: string;
  project: string;
}) {
  let posts: PostDocument[] = [];
  let error: string | null = null;

  try {
    posts = await getScopedPosts(workspace, project);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  return (
    <PostsList
      posts={posts}
      error={error}
      basePath={`/w/${workspace}/p/${project}/posts`}
      scopeLabel={`w/${workspace} · p/${project}`}
    />
  );
}

export default async function ScopedHome({
  params,
}: {
  params: Promise<{ workspace: string; project: string }>;
}) {
  const { workspace, project } = await params;
  return (
    <Suspense fallback={<PostsListSkeleton />}>
      <ScopedPosts workspace={workspace} project={project} />
    </Suspense>
  );
}
