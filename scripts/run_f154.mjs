import { spawnSync } from 'node:child_process'
const r = spawnSync('bash', ['scripts/phase10_duplicate_bin_db.sh'], { stdio: 'inherit', env: process.env })
if (r.error) throw r.error
process.exitCode = r.status ?? 1
