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

export async function runPrompts(inputs: PromptInputs): Promise<PromptAnswers> {
  p.intro('Barkpark')

  const defaults: PromptAnswers = {
    projectName: inputs.targetArg ?? 'my-barkpark-site',
    template: inputs.templateArg ?? DEFAULT_TEMPLATE,
    hostedDemo: inputs.hostedDemoFlag,
    install: !inputs.skipInstall,
    git: !inputs.skipGit,
  }

  if (inputs.yesFlag) {
    return defaults
  }

  const projectName = inputs.targetArg
    ? inputs.targetArg
    : await p.text({
        message: 'Project name?',
        placeholder: 'my-barkpark-site',
        defaultValue: 'my-barkpark-site',
        validate(value) {
          const trimmed = value.trim()
          if (!trimmed) return 'Project name is required.'
          if (trimmed.startsWith('.')) return 'Project name may not start with "."'
          return undefined
        },
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
          hint: name === 'website-starter' ? 'marketing site — page/post/author' : 'pure blog — post/author/tag',
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
    projectName: path.basename(String(projectName).trim()),
    template,
    hostedDemo: inputs.hostedDemoFlag,
    install: Boolean(install),
    git: Boolean(git),
  }
}
