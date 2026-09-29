import { spawnSync } from 'node:child_process'
const r = spawnSync('bash', ['scripts/phase10_concurrent_dispatch.sh'], { stdio: 'inherit', env: process.env })
if (r.error) throw r.error
process.exitCode = r.status ?? 1
