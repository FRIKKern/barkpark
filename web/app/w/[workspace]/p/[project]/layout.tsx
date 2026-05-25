import type { ReactNode } from "react";

/**
 * Scoped layout for `/w/[workspace]/p/[project]/...`.
 *
 * The workspace + project slugs come from the URL params; the actual scoped
 * `@barkpark/core` client is built per-request in each page via
 * `createClient({ workspace, project })` (see `@/lib/barkpark-client`). This
 * layout surfaces the active scope as a breadcrumb so every nested page renders
 * inside a clear workspace/project frame.
 */
export default async function ScopedLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ workspace: string; project: string }>;
}) {
  const { workspace, project } = await params;

  return (
    <div className="flex min-h-screen flex-col">
      <nav className="border-b border-zinc-200 px-6 py-3 text-sm text-zinc-500 dark:border-zinc-800">
        <a href={`/w/${workspace}/p/${project}`} className="hover:underline">
          w/{workspace} · p/{project}
        </a>
      </nav>
      {children}
    </div>
  );
}
