// Regenerates supabase/setup/01_ALL_IN_ONE.sql from supabase/migrations/*.sql  (npm run build:setup)
import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export function buildAllInOne() {
  const dir = path.join(root, "supabase/migrations");
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  let out = `-- =====================================================================
-- MAKKAH DELIVERY - ALL-IN-ONE database setup (generated: do not edit; run "npm run build:setup")
-- Contains: ${files.join(", ")}
-- Runs as ONE transaction: if anything fails, nothing is applied.
-- Run on an EMPTY public schema (new project, or after 00_RESET_public_schema.sql).
-- =====================================================================
begin;
`;
  for (const f of files) out += `\n-- ############ ${f} ############\n${fs.readFileSync(path.join(dir, f), "utf8").trim()}\n`;
  return out + "\ncommit;\n";
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.writeFileSync(path.join(root, "supabase/setup/01_ALL_IN_ONE.sql"), buildAllInOne());
  console.log("wrote supabase/setup/01_ALL_IN_ONE.sql");
}
