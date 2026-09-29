import fs from 'node:fs'
import { execFileSync } from 'node:child_process'

const failures = []
const ok = (name, condition, detail = '') => {
  if (condition) console.log(`PASS ${name}${detail ? ` - ${detail}` : ''}`)
  else { console.error(`FAIL ${name}${detail ? ` - ${detail}` : ''}`); failures.push(name) }
}

const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'))
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'))
const root = lock.packages?.[''] ?? {}
for (const group of ['dependencies', 'devDependencies']) {
  const a = pkg[group] ?? {}
  const b = root[group] ?? {}
  const sameKeys = Object.keys(a).sort().join('\n') === Object.keys(b).sort().join('\n')
  const sameValues = Object.entries(a).every(([k, v]) => b[k] === v)
  ok(`npm lock matches ${group}`, sameKeys && sameValues)
}
ok('canonical package manager is npm', pkg.packageManager?.startsWith('npm@'), pkg.packageManager ?? 'unset')
ok('stale pnpm lock removed', !fs.existsSync('pnpm-lock.yaml'))
ok('Figma site configuration exists', fs.existsSync('.figma/make/site.json'))

const matrix = fs.readFileSync('docs/remediation/REMEDIATION_MATRIX.csv', 'utf8').trim().split(/\r?\n/)
ok('remediation matrix has 186 findings', matrix.length === 187, `${matrix.length - 1} findings`)

let tagCommit = ''
try {
  tagCommit = execFileSync('git', ['rev-list', '-n', '1', 'pre-inventory-remediation'], { encoding: 'utf8' }).trim()
} catch {}
ok('immutable baseline tag exists', /^[0-9a-f]{40}$/.test(tagCommit), tagCommit || 'missing')

if (failures.length) {
  console.error(`\n${failures.length} Phase 0 verification check(s) failed.`)
  process.exit(1)
}
console.log('\nPhase 0 control checks passed.')
