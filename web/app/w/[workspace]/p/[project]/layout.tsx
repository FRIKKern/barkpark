import type { ReactNode } from "react";
import Link from "next/link";
import {
  WorkspaceProjectSwitcher,
  type WorkspaceOption,
} from "@/components/workspace-project-switcher";
import { createClient } from "@/lib/barkpark-client";

/**
 * Build the switcher `options[]` from the tenancy list endpoints.
 *
 * Fetches every reachable workspace (`listWorkspaces`) plus the project list
 * for the *current* workspace (`listProjects(currentWorkspace)`). Other
 * workspaces start with an empty project list — they're populated on navigation
 * since this layout re-renders per scoped route. The current project is folded
 * in so its `<option>` always exists even before the list round-trips.
 *
 * Tenancy endpoints are top-level (not dataset/scope-prefixed), so the flat
 * client is used. On any failure we return `null` and the switcher degrades to
 * a static current-scope label rather than crashing the layout.
 */
async function loadSwitcherOptions(
  currentWorkspace: string,
  currentProject: string,
): Promise<WorkspaceOption[] | null> {
  try {
    const bp = createClient();
    const [workspaces, currentProjects] = await Promise.all([
      bp.listWorkspaces(),
      bp.listProjects(currentWorkspace),
    ]);

    const currentProjectSlugs = currentProjects.map((p) => p.slug);
    if (!currentProjectSlugs.includes(currentProject)) {
      currentProjectSlugs.unshift(currentProject);
    }

    const options: WorkspaceOption[] = workspaces.map((w) => ({
      slug: w.slug,
      projects: w.slug === currentWorkspace ? currentProjectSlugs : [],
    }));

    // Ensure the active workspace is always present, even if the list omitted it.
    if (!options.some((o) => o.slug === currentWorkspace)) {
      options.unshift({ slug: currentWorkspace, projects: currentProjectSlugs });
    }

    return options.length > 0 ? options : null;
  } catch {
    // No list source / fetch failed — fall back to current-scope-only.
    return null;
  }
}

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
 * The switcher receives `options` fetched from `@barkpark/core`'s tenancy list
 * endpoints (`listWorkspaces` / `listProjects`). When that fetch fails it
 * degrades gracefully to a static current-scope label (`options` omitted).
 */
export default async function ScopedLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ workspace: string; project: string }>;
}) {
  const { workspace, project } = await params;
  const options = await loadSwitcherOptions(workspace, project);

  return (
    <div className="flex min-h-screen flex-col">
      <header className="sticky top-0 z-10 flex items-center justify-between gap-4 border-b border-zinc-200 bg-background/80 px-6 py-3 text-sm backdrop-blur dark:border-zinc-800">
        <nav className="text-zinc-500" aria-label="Breadcrumb">
          <Link
            href={`/w/${workspace}/p/${project}`}
            className="font-mono hover:underline"
          >
            w/{workspace} · p/{project}
          </Link>
        </nav>
        <WorkspaceProjectSwitcher
          workspace={workspace}
          project={project}
          {...(options ? { options } : {})}
        />
      </header>
      {children}
    </div>
  );
}
