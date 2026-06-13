import Link from "next/link";

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col items-start justify-center gap-4 px-6 py-16">
      <p className="font-mono text-sm text-zinc-400">404</p>
      <h1 className="text-3xl font-semibold tracking-tight">Post not found</h1>
      <p className="text-zinc-600 dark:text-zinc-400">
        The post you’re looking for doesn’t exist or isn’t published.
      </p>
      <Link
        href="/"
        className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
      >
        ← back to all posts
      </Link>
    </main>
  );
}
