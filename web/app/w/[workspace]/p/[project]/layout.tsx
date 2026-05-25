import type { ReactNode } from "react";
import { WorkspaceProjectSwitcher } from "@/components/workspace-project-switcher";

/**
 * Scoped layout for `/w/[workspace]/p/[project]/...`.
 *
 * The workspace + project slugs come from the URL params; the actual scoped
 * `@barkpark/core` client is built per-request in each page via
 * `createClient({ workspace, project })` (see `@/lib/barkpark-client`). This
 * layout surfaces the active scope as a breadcrumb and mounts the
 * workspace/project switcher so every nested page renders inside a clear,
 * switchable workspace/project frame.
 *
 * The switcher is rendered without an `options` list: `@barkpark/core` exposes
 * no workspaces/projects list endpoint yet, so it degrades to showing the
 * current scope. Pass `options` once such a source exists.
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
      <header className="flex items-center justify-between gap-4 border-b border-zinc-200 px-6 py-3 text-sm dark:border-zinc-800">
        <nav className="text-zinc-500" aria-label="Breadcrumb">
          <a
            href={`/w/${workspace}/p/${project}`}
            className="font-mono hover:underline"
          >
            w/{workspace} · p/{project}
          </a>
        </nav>
        <WorkspaceProjectSwitcher workspace={workspace} project={project} />
      </header>
      {children}
    </div>
  );
}
