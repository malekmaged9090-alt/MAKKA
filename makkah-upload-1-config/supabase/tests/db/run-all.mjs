// npm run test:db  — runs every database test file in its own fresh PostgreSQL instance.
import { spawnSync } from "node:child_process"; import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
const dir = path.dirname(fileURLToPath(import.meta.url));
let failed = 0;
for (const f of fs.readdirSync(dir).filter((x) => /^\d+_.*\.test\.mjs$/.test(x)).sort()) {
  const r = spawnSync(process.execPath, [path.join(dir, f)], { stdio: "inherit" });
  if (r.status !== 0) failed++;
}
console.log(failed ? `\n✗ ${failed} test file(s) FAILED` : "\n✓ all database tests passed");
process.exit(failed ? 1 : 0);
