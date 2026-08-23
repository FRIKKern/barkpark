import * as p from '@clack/prompts'
import path from 'node:path'
import { AVAILABLE_TEMPLATES, DEFAULT_TEMPLATE, type TemplateName } from './constants.js'

export interface PromptAnswers {
  projectName: string
  template: TemplateName
  hostedDemo: boolean
  install: boolean
  git: boolean
}

export interface PromptInputs {
  targetArg: string | undefined
  templateArg: TemplateName | undefined
  hostedDemoFlag: boolean
  yesFlag: boolean
  skipInstall: boolean
  skipGit: boolean
}

export function normalizeProjectName(raw: string): string {
  return path.basename(String(raw).trim())
}

// Validate a non-interactively-supplied project name (a positional dir arg or
// --yes), returning an error message or undefined. The interactive `p.text`
// validator rejects an empty or dot-leading name; the non-interactive path
// skipped that check, so `create-barkpark-app .` / `/` / an empty or
// whitespace name normalized to the cwd and produced a confusing
// "directory not empty" error later instead of a clear "invalid name".
export function projectNameError(targetArg: string): string | undefined {
  const name = normalizeProjectName(targetArg)
  if (!name) {
    return `Invalid project name ${JSON.stringify(targetArg)} — provide a non-empty directory name.`
  }
  if (name.startsWith('.')) {
    return `Invalid project name ${JSON.stringify(targetArg)} — the directory name may not start with ".".`
  }
  return undefined
}

/**
 * The interactive `p.text` validator — validates the NORMALISED name, i.e.
 * what the run will actually use (runPrompts applies normalizeProjectName at
 * return). The old validator checked the RAW entry, so `foo/..` passed and
 * then normalised to `..`, pointing targetDir at the PARENT of cwd — not a
 * clobber (ensureTargetEmpty aborts on the almost-always-non-empty parent),
 * but a confusing "not empty" error naming a directory the user never typed.
 * Delegating to projectNameError keeps ONE owner for the name rule, so the
 * interactive and non-interactive paths cannot disagree again.
 */
export function interactiveNameError(value: string): string | undefined {
  return projectNameError(value)
}

export async function runPrompts(inputs: PromptInputs): Promise<PromptAnswers> {
  p.intro('Barkpark')

  // A non-interactively-supplied name (positional arg or --yes) bypasses the
  // interactive validator below — validate it here so a bad name fails fast with
  // a clear message rather than a downstream "directory not empty".
  if (inputs.targetArg !== undefined) {
    const err = projectNameError(inputs.targetArg)
    if (err) throw new Error(err)
  }

  const defaults: PromptAnswers = {
    projectName: normalizeProjectName(inputs.targetArg ?? 'my-barkpark-site'),
    template: inputs.templateArg ?? DEFAULT_TEMPLATE,
    hostedDemo: inputs.hostedDemoFlag,
    install: !inputs.skipInstall,
    git: !inputs.skipGit,
  }

  if (inputs.yesFlag) {
    return defaults
  }

  const projectName = inputs.targetArg
    ? normalizeProjectName(inputs.targetArg)
    : await p.text({
        message: 'Project name?',
        placeholder: 'my-barkpark-site',
        defaultValue: 'my-barkpark-site',
        validate: interactiveNameError,
      })

  if (p.isCancel(projectName)) {
    p.cancel('Scaffold aborted.')
    process.exit(0)
  }

  const template = inputs.templateArg
    ? inputs.templateArg
    : ((await p.select({
        message: 'Which template?',
        options: AVAILABLE_TEMPLATES.map((name) => ({
          value: name,
          label: name,
          hint:
            name === 'website-starter'
              ? 'marketing site — page/post/author'
              : 'pure blog — post/author/tag',
        })),
        initialValue: DEFAULT_TEMPLATE,
      })) as TemplateName)

  if (p.isCancel(template)) {
    p.cancel('Scaffold aborted.')
    process.exit(0)
  }

  const install = inputs.skipInstall
    ? false
    : await p.confirm({
        message: 'Install dependencies now?',
        initialValue: true,
      })
  if (p.isCancel(install)) {
    p.cancel('Scaffold aborted.')
    process.exit(0)
  }

  const git = inputs.skipGit
    ? false
    : await p.confirm({
        message: 'Initialize a git repository?',
        initialValue: true,
      })
  if (p.isCancel(git)) {
    p.cancel('Scaffold aborted.')
    process.exit(0)
  }

  return {
    projectName: normalizeProjectName(projectName),
    template,
    hostedDemo: inputs.hostedDemoFlag,
    install: Boolean(install),
    git: Boolean(git),
  }
}
