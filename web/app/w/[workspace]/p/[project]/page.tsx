import { createClient } from "@/lib/barkpark-client";
import { fetchPosts, type PostDocument } from "@/lib/posts";
import { PostsList } from "@/components/posts-list";

export const revalidate = 60;

/**
 * Scoped post listing. The route params → `createClient({ workspace, project })`
 * → a core client whose requests carry `/w/<ws>/p/<project>` (via scopePrefix).
 */
export default async function ScopedHome({
  params,
}: {
  params: Promise<{ workspace: string; project: string }>;
}) {
  const { workspace, project } = await params;
  const client = createClient({ workspace, project });

  let posts: PostDocument[] = [];
  let error: string | null = null;

  try {
    posts = await fetchPosts(client);
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
