#!/usr/bin/env bash
# Database tests run on an in-process PostgreSQL (PGlite): no Docker, no sudo, no local Postgres needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
npm run test:db
