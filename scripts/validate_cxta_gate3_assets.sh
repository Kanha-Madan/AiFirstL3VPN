#!/usr/bin/env bash
# Gate 3 asset check. Prints a few PASS/FAIL lines and no file bodies,
# so the QA Builder can sign off without reading the suite back in.
set -euo pipefail

spec_id="${1:-}"
if [[ -z "${spec_id}" || "${spec_id}" == *"/"* || "${spec_id}" == *.* ]]; then
  echo "ERROR: usage: bash scripts/validate_cxta_gate3_assets.sh <spec-id>" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${CXTA_GATE3_ROOT:-}" ]]; then
  root="${CXTA_GATE3_ROOT}"
fi

python3 - "${root}" "${spec_id}" <<'PY'
import csv, re, sys
from pathlib import Path

root = Path(sys.argv[1])
spec = sys.argv[2]
fails = []

def fail(msg):
    if len(fails) < 20:
        fails.append(msg)
    elif len(fails) == 20:
        fails.append("... further failures omitted")

def col(fieldnames, *names):
    norm = {}
    for h in fieldnames or []:
        norm[re.sub(r"[^a-z0-9]", "", (h or "").lower())] = h
    for name in names:
        key = re.sub(r"[^a-z0-9]", "", name.lower())
        if key in norm:
            return norm[key]
    return None

csv_path = root / "qa" / "02_testcases" / f"{spec}_TestCases_LLD.csv"
if not csv_path.is_file():
    print(f"assets: FAIL missing {csv_path.relative_to(root)}")
    sys.exit(1)

with csv_path.open(newline="") as fh:
    reader = csv.DictReader(fh)
    id_col = col(reader.fieldnames, "TC ID", "TC_ID")
    auto_col = col(reader.fieldnames, "Automation")
    if not id_col or not auto_col:
        print("assets: FAIL CSV needs TC ID and Automation columns")
        sys.exit(1)
    rows = list(reader)

automated = []
manual = 0
seen = set()
for row in rows:
    tc = (row.get(id_col) or "").strip()
    auto = (row.get(auto_col) or "").strip().lower()
    if not tc:
        continue
    if auto in {"manual-only", "manual", "no"}:
        manual += 1
        continue
    if auto not in {"yes", "y", "true", "automated"}:
        fail(f"assets: FAIL {tc} has Automation={auto or 'blank'}")
        continue
    if tc in seen:
        fail(f"assets: FAIL duplicate {tc}")
        continue
    seen.add(tc)
    parts = tc.split(".")
    if len(parts) < 5 or parts[0] != "TC":
        fail(f"assets: FAIL {tc} is not TC.<SERVICE>.<PLATFORM>.<FUNCTION>.<FLAVOR>...")
        continue
    service, platform, function, flavor = parts[1:5]
    base = root / "qa" / "03_cxta_automation" / "tests" / service / platform
    flavor_dir = base / function / flavor
    needed = [
        flavor_dir / "scripts" / f"{tc}.robot",
        flavor_dir / "expected" / f"{tc}.expected.j2",
        flavor_dir / "preconfig" / f"{tc}.pre.cfg",
        base / "testdata" / f"{tc}.yaml",
    ]
    if function.upper() == "APPLY":
        needed.append(flavor_dir / "config" / f"{flavor}.config.json")
    missing = [str(p.relative_to(root)) for p in needed if not p.is_file()]
    if missing:
        fail("assets: FAIL " + tc + " missing " + ", ".join(missing))
    automated.append((tc, flavor_dir / "scripts" / f"{tc}.robot", base / "testdata" / f"{tc}.yaml"))

atp_ids = set()
atp_path = root / "qa" / "02_testcases" / f"{spec}_ATP_TestCases.csv"
if atp_path.is_file():
    with atp_path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        atp_col = col(reader.fieldnames, "TC ID", "TC_ID")
        if atp_col:
            atp_ids = {(r.get(atp_col) or "").strip() for r in reader}
            atp_ids.discard("")

stub_re = re.compile(
    r"Pass Execution|Should Be True\s+True|#\s*TODO|#\s*FIXME|placeholder|implement later|Log\s+Test Context",
    re.I,
)
assert_re = re.compile(r"\b(Should|Verify|Assert)\b")
var_re = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)")
builtin_vars = {
    "tc_id", "TC_ID", "nso", "device", "true", "false", "none",
    "loop", "item", "accepted_leaves",
}

def yaml_keys(path):
    keys = set()
    if not path.is_file():
        return keys
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", line)
        if m:
            keys.add(m.group(1))
    return keys

testbed = root / "qa" / "03_cxta_automation" / "environments" / f"testbed_{spec}.yaml"
testbed_keys = yaml_keys(testbed)

for tc, robot, testdata in automated:
    if not robot.is_file():
        continue
    text = robot.read_text(errors="replace")
    if stub_re.search(text):
        fail(f"stubs: FAIL {tc}")
    elif not assert_re.search(text):
        fail(f"stubs: FAIL {tc} has no assertion keyword")
    tags = " ".join(
        line for line in text.splitlines() if line.strip().lower().startswith("[tags]")
    )
    tagged = "ATP" in tags.split()
    if tc in atp_ids and not tagged:
        fail(f"tags: FAIL {tc} missing ATP tag")
    if tc not in atp_ids and tagged:
        fail(f"tags: FAIL {tc} carries ATP but is not in the ATP csv")
    keys = yaml_keys(testdata) | testbed_keys | builtin_vars
    expected = robot.parent.parent / "expected" / f"{tc}.expected.j2"
    if expected.is_file():
        unknown = sorted(set(var_re.findall(expected.read_text(errors="replace"))) - keys)
        if unknown:
            fail(f"templates: FAIL {tc} undefined {', '.join(unknown[:8])}")

if not automated and not fails:
    fail("assets: FAIL CSV has no automated test cases")

literal = re.compile(r"^\s*(username|password):\s*[^$\s#]")
env_user = re.compile(r"^\s*username_env:\s*NSO_RESTCONF_USER\s*$")
env_pass = re.compile(r"^\s*password_env:\s*NSO_RESTCONF_PASSWORD\s*$")
if not testbed.is_file():
    fail(f"testbed: FAIL missing {testbed.relative_to(root)}")
else:
    body = testbed.read_text(errors="replace").splitlines()
    if any(literal.search(line) for line in body):
        fail("testbed: FAIL literal username or password; use *_env")
    if not any(env_user.search(line) for line in body):
        fail("testbed: FAIL username_env is not NSO_RESTCONF_USER")
    if not any(env_pass.search(line) for line in body):
        fail("testbed: FAIL password_env is not NSO_RESTCONF_PASSWORD")

contract = root / "qa" / "03_cxta_automation" / "environments" / f"{spec}.runtime-contract.yaml"
if not contract.is_file():
    fail(f"runtime-contract: FAIL missing {contract.relative_to(root)}")
else:
    lines = contract.read_text(errors="replace").splitlines()
    if any(re.match(r"^\s*[^#:]+:\s*unresolved\s*$", line, re.I) for line in lines):
        fail("runtime-contract: FAIL contains unresolved")
    text = "\n".join(lines)
    if "ned_id" not in text or "NSO_RESTCONF_USER" not in text:
        fail("runtime-contract: FAIL needs ned_id and NSO_RESTCONF_USER")

deps = root / "nso-dependencies.yaml"
version = image = ""
if deps.is_file():
    for line in deps.read_text(errors="replace").splitlines():
        if re.match(r"^\s+cxta-version:", line) and not version:
            version = line.split(":", 1)[1].strip()
        elif re.match(r"^\s+cxta-image:", line) and not image:
            image = line.split(":", 1)[1].strip()
if not version or not image or version.lower() == "latest" or image.lower() == "latest" or image.lower().endswith(":latest"):
    fail(f"cxta-image: FAIL unpinned version={version or 'missing'} image={image or 'missing'}")

if fails:
    print("\n".join(fails))
    sys.exit(1)

print(f"assets: PASS ({len(automated)} automated, {manual} manual-only)")
print("stubs: PASS")
print("templates: PASS")
print("testbed: PASS")
print("runtime-contract: PASS")
print(f"cxta-image: PASS {version} {image}")
PY

set +e
plan="$(cd "${root}" && bash scripts/validate_cxta_pipeline_contract.sh 2>&1)"
plan_rc=$?
set -e
if [[ "${plan_rc}" -ne 0 ]]; then
  echo "pipeline-contract: FAIL"
  printf '%s\n' "${plan}" | tail -n 30
  exit 1
fi
echo "pipeline-contract: PASS"
