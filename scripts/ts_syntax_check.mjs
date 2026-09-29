import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

function tryRequire(specifier) {
  try {
    return require(specifier)
  } catch {
    return null
  }
}

function loadTypeScript() {
  const local = tryRequire('typescript')
  if (local) return local

  // npm lifecycle scripts may inject npm_config_prefix. Remove it so `npm root -g`
  // resolves the actual global installation instead of the project prefix.
  try {
    const env = { ...process.env }
    delete env.npm_config_prefix
    delete env.NPM_CONFIG_PREFIX
    const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8', env }).trim()
    const globalTs = tryRequire(path.join(globalRoot, 'typescript'))
    if (globalTs) return globalTs
  } catch {
    // Fall through to the tsc executable resolution below.
  }

  try {
    const tscPath = execFileSync('sh', ['-lc', 'command -v tsc'], { encoding: 'utf8' }).trim()
    if (tscPath) {
      const realTsc = fs.realpathSync(tscPath)
      const packageRoot = path.dirname(path.dirname(realTsc))
      const executableTs = tryRequire(packageRoot)
      if (executableTs) return executableTs
    }
  } catch {
    // Fall through to a clear failure message.
  }

  throw new Error('TypeScript compiler API is unavailable. Install project dependencies or provide a global `tsc` installation.')
}

const ts = loadTypeScript()

function walk(directory) {
  const result = []
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) result.push(...walk(full))
    else if (/\.(ts|tsx)$/.test(entry.name) && !entry.name.endsWith('.d.ts')) result.push(full)
  }
  return result
}

const files = [...walk('src'), 'vite.config.ts']
let failed = false
for (const file of files) {
  const source = fs.readFileSync(file, 'utf8')
  const result = ts.transpileModule(source, {
    fileName: file,
    reportDiagnostics: true,
    compilerOptions: {
      target: ts.ScriptTarget.ES2020,
      module: ts.ModuleKind.ESNext,
      jsx: ts.JsxEmit.ReactJSX,
      isolatedModules: true,
    },
  })
  const diagnostics = (result.diagnostics ?? []).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error)
  if (diagnostics.length) {
    failed = true
    for (const diagnostic of diagnostics) {
      const message = ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')
      console.error(`FAIL ${file} TS${diagnostic.code}: ${message}`)
    }
  }
}

if (failed) process.exit(1)
console.log(`PASS TypeScript/TSX syntax transpile - ${files.length} files`)
