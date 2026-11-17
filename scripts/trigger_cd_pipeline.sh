#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

log_step "CD pipeline trigger placeholder"
write_placeholder_report "cd-trigger.txt" "cd_pipeline_placeholder"

cat <<'EOF'
Placeholder stage for triggering the CD pipeline.

For GitHub Actions without the API, use the native workflow_run trigger in .github/workflows/cd.yml.
That means CD starts after CT completes, but only once cd.yml exists on the repository default branch.
EOF
