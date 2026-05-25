import { client } from "@/lib/barkpark-client";
import { fetchPosts, type PostDocument } from "@/lib/posts";
import { PostsList } from "@/components/posts-list";

export const revalidate = 60;

export default async function Home() {
  let posts: PostDocument[] = [];
  let error: string | null = null;

  try {
    posts = await fetchPosts(client);
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  }

  return <PostsList posts={posts} error={error} basePath="/posts" />;
}
