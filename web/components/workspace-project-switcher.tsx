"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

/** A workspace and its selectable projects, for populating the switcher. */
export interface WorkspaceOption {
  /** Workspace slug, used in the `/w/<workspace>/...` path. */
  slug: string;
  /** Project slugs that live under this workspace. */
  projects: string[];
}

interface WorkspaceProjectSwitcherProps {
  /** Active workspace slug from the route params. */
  workspace: string;
  /** Active project slug from the route params. */
  project: string;
  /**
   * Switchable scopes to offer, fetched by the scoped layout from
   * `@barkpark/core`'s tenancy list endpoints (`listWorkspaces` /
   * `listProjects`). When omitted or empty — e.g. the list fetch failed — the
   * switcher renders an honest "only current scope" state instead of crashing.
   * The navigation below targets the canonical scoped route.
   */
  options?: WorkspaceOption[];
}

/**
 * Header control that shows the active `w/<workspace> · p/<project>` scope and,
 * when given `options`, lets the user switch to another workspace/project.
 *
 * Changing the *project* navigates straight to `/w/<workspace>/p/<project>/`.
 * Changing the *workspace* navigates to `/w/<workspace>` (the workspace landing
 * route), which resolves that workspace's default project server-side and
 * redirects — the switcher can't know another workspace's projects, since the
 * scoped layout only fetches the current one's. With no `options` (the current
 * reality: no list endpoint), it degrades to a static scope label rather than
 * fabricating a list.
 */
export function WorkspaceProjectSwitcher({
  workspace,
  project,
  options,
}: WorkspaceProjectSwitcherProps) {
  const router = useRouter();
  const [ws, setWs] = useState(workspace);

  const hasOptions = Array.isArray(options) && options.length > 0;

  if (!hasOptions) {
    // No list source available — show the current scope honestly.
    return (
      <span
        className="inline-flex items-center gap-1 rounded-md border border-zinc-200 bg-zinc-50 px-2.5 py-1 font-mono text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"
        title="Only the current scope is available — no workspaces/projects list endpoint yet."
      >
        w/{workspace} · p/{project}
      </span>
    );
  }

  const projectsForWs =
    options.find((o) => o.slug === ws)?.projects ?? [];

  function goTo(nextWs: string, nextProject: string) {
    if (!nextWs || !nextProject) return;
    router.push(`/w/${nextWs}/p/${nextProject}/`);
  }

  function onWorkspaceChange(nextWs: string) {
    setWs(nextWs);
    if (!nextWs || nextWs === workspace) return;
    // We can't pick a project for *another* workspace here: the scoped layout
    // only fetches the current workspace's projects, so every other entry in
    // `options` has `projects: []`. Navigate to the workspace landing route
    // (`/w/<ws>`), which resolves that workspace's default project
    // server-side and redirects to `/w/<ws>/p/<project>`.
    router.push(`/w/${nextWs}`);
  }

  const selectClass =
    "rounded-md border border-zinc-200 bg-white px-2 py-1 font-mono text-xs text-zinc-700 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300";

  return (
    <span className="inline-flex items-center gap-1.5 text-xs">
      <span className="text-zinc-400">w/</span>
      <select
        aria-label="Workspace"
        className={selectClass}
        value={ws}
        onChange={(e) => onWorkspaceChange(e.target.value)}
      >
        {options!.map((o) => (
          <option key={o.slug} value={o.slug}>
            {o.slug}
          </option>
        ))}
      </select>
      <span className="text-zinc-400">p/</span>
      <select
        aria-label="Project"
        className={selectClass}
        value={projectsForWs.includes(project) ? project : (projectsForWs[0] ?? "")}
        onChange={(e) => goTo(ws, e.target.value)}
      >
        {projectsForWs.map((p) => (
          <option key={p} value={p}>
            {p}
          </option>
        ))}
      </select>
    </span>
  );
}
