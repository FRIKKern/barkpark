import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/barkpark-client";

/**
 * Workspace landing route — `/w/[workspace]`.
 *
 * No project segment yet, so resolve the workspace's default project
 * server-side (the first project from `@barkpark/core`'s `listProjects`) and
 * redirect to `/w/<workspace>/p/<project>`. This is the target of the
 * workspace switcher: selecting a *different* workspace can't know that
 * workspace's projects from the current scoped layout (they're empty by
 * design), so it navigates here and lets this route resolve the default.
 *
 * Empty workspace (no projects) → `notFound()`. A failed list fetch propagates
 * as a server error rather than silently redirecting to a non-existent scope.
 */
export default async function WorkspaceLanding({
  params,
}: {
  params: Promise<{ workspace: string }>;
}) {
  const { workspace } = await params;

  const bp = createClient();
  const projects = await bp.listProjects(workspace);
  const defaultProject = projects[0]?.slug;

  if (!defaultProject) {
    notFound();
  }

  redirect(`/w/${workspace}/p/${defaultProject}`);
}
