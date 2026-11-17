#!/usr/bin/env bash
# CT: aggregate stage logs into a single CT summary.
set -euo pipefail
mkdir -p reports

cat > reports/ct-summary.html <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>CT Summary</title>
<style>body{font-family:sans-serif;margin:2em} pre{background:#f4f4f4;padding:.5em;overflow:auto}</style>
</head><body><h1>CT Summary</h1>
HTML

for f in reports/netsim-list.log reports/netsim-load.log reports/netsim-keys.log reports/netsim-sync.log \
         reports/dryrun-*.log reports/commit-*.log \
         reports/idempotency-*.log reports/packages-status.log reports/ncserr.log; do
  [[ -f "$f" ]] || continue
  echo "<h2>$(basename "$f")</h2><pre>$(sed 's/&/\&amp;/g;s/</\&lt;/g' "$f")</pre>" >> reports/ct-summary.html
done

echo "</body></html>" >> reports/ct-summary.html
echo "==> report: wrote reports/ct-summary.html"
