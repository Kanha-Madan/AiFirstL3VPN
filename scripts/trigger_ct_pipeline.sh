#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

log_step "CT pipeline trigger placeholder"
write_placeholder_report "ct-trigger.txt" "ct_pipeline_placeholder"

cat <<'EOF'
Placeholder stage for triggering the CT pipeline.

For GitHub Actions without the API, use the native workflow_run trigger in .github/workflows/ct.yml.
That means CT starts after CI completes, but only once ct.yml exists on the repository default branch.
EOF