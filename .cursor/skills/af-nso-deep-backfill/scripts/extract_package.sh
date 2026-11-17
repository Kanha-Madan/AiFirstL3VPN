#!/usr/bin/env bash
# extract_package.sh — deterministic structural dump of one NSO package, as raw
# material for the af-nso-deep-backfill skill's LLM understanding step.
#
# This is EXTRACTION ONLY — it interprets nothing. The skill reads this output
# (and the source files it points at) to reconstruct the as-built understanding,
# then commits it with `aifirst spec backfill --deep`.
#
# Usage:
#   extract_package.sh --list                 # list candidate packages
#   extract_package.sh <package-dir|name|id>  # human-readable dump
#   extract_package.sh <package-dir> --json   # machine-readable dump
#
# Options:
#   --list              List packages under packages_root (or ./packages)
#   --json              Emit JSON instead of human-readable text
#   --packages-root DIR Override the packages root (else aifirstspec/config.yaml)
#   --install-dir DIR   Override auto-detected ~/nso-[0-9]* (for pyang tree)
#   -h, --help          Show this help

set -euo pipefail

# ─── Args ────────────────────────────────────────────────────────────────────
PKG_ARG=""
LIST_MODE=false
JSON=false
PACKAGES_ROOT=""
INSTALL_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)           LIST_MODE=true; shift ;;
    --json)           JSON=true; shift ;;
    --packages-root)  PACKAGES_ROOT="${2:-}"; shift 2 ;;
    --install-dir)    INSTALL_DIR="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               echo "Unknown option: $1" >&2; exit 2 ;;
    *)                PKG_ARG="$1"; shift ;;
  esac
done

# ─── Resolve packages root ───────────────────────────────────────────────────
# Priority: --packages-root, then aifirstspec/config.yaml, then ./packages.
if [[ -z "$PACKAGES_ROOT" ]]; then
  cfg="aifirstspec/config.yaml"
  if [[ -f "$cfg" ]]; then
    PACKAGES_ROOT="$(grep -E '^[[:space:]]*packages_root:' "$cfg" 2>/dev/null \
      | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//')"
  fi
fi
[[ -z "$PACKAGES_ROOT" && -d packages ]] && PACKAGES_ROOT="packages"

# ─── is_pkg: directory holds package-meta-data.xml ───────────────────────────
is_pkg() { [[ -f "$1/package-meta-data.xml" ]]; }

# ─── LIST MODE ───────────────────────────────────────────────────────────────
if [[ "$LIST_MODE" == true ]]; then
  root="${PACKAGES_ROOT:-.}"
  echo "Scanning for packages under: $root"
  echo ""
  count=0
  while IFS= read -r meta; do
    dir="$(dirname "$meta")"
    name="$(grep -oE '<name>[^<]+' "$meta" 2>/dev/null | head -1 | sed 's/<name>//')"
    ver="$(grep -oE '<package-version>[^<]+' "$meta" 2>/dev/null | head -1 | sed 's/<package-version>//')"
    count=$((count + 1))
    printf "  %d. %s (%s)  →  %s\n" "$count" "${name:-$(basename "$dir")}" "${ver:-?}" "$dir"
  done < <(find "$root" -type f -name package-meta-data.xml \
             -not -path '*/nso-run-*/*' 2>/dev/null | sort)
  [[ $count -eq 0 ]] && echo "  (no packages found)"
  exit 0
fi

# ─── Resolve the package directory ───────────────────────────────────────────
if [[ -z "$PKG_ARG" ]]; then
  echo "Usage: $0 <package-dir|name|id> [--json]   (or --list)" >&2
  exit 2
fi

PKG_DIR=""
for cand in "$PKG_ARG" "${PACKAGES_ROOT:+$PACKAGES_ROOT/$PKG_ARG}" "packages/$PKG_ARG"; do
  [[ -n "$cand" ]] || continue
  if is_pkg "$cand"; then PKG_DIR="$cand"; break; fi
done
if [[ -z "$PKG_DIR" ]]; then
  echo "ERROR: no package-meta-data.xml found for '$PKG_ARG'" >&2
  exit 1
fi

META="$PKG_DIR/package-meta-data.xml"
PKG_NAME="$(grep -oE '<name>[^<]+' "$META" 2>/dev/null | head -1 | sed 's/<name>//')"
[[ -z "$PKG_NAME" ]] && PKG_NAME="$(basename "$PKG_DIR")"
PKG_VER="$(grep -oE '<package-version>[^<]+' "$META" 2>/dev/null | head -1 | sed 's/<package-version>//')"
NCS_MIN="$(grep -oE '<ncs-min-version>[^<]+' "$META" 2>/dev/null | head -1 | sed 's/<ncs-min-version>//')"

# required-package entries → the authoritative NED type@version signal. Only
# <name> elements *inside* a <required-package> block count; a plain <name>
# under <component> (Java/Python action) is NOT a dependency (that was a prior
# bug that surfaced action class names as fake NEDs).
REQ_PKGS=()
while IFS= read -r rp; do
  [[ -n "$rp" ]] && REQ_PKGS+=("$rp")
done < <(awk '
  /<required-package>/  { inrp=1 }
  inrp && match($0,/<name>[^<]*/) { s=substr($0,RSTART+6,RLENGTH-6); gsub(/^[ \t]+|[ \t]+$/,"",s); if(s!="") print s }
  /<\/required-package>/ { inrp=0 }
' "$META" 2>/dev/null || true)

# Components (callback/application classes) declared in package-meta-data.xml.
# Captures "<name> -> <java-class-name|python-class-name>" per <component>. This
# is where Java packages (no python/ dir) expose their action/service logic.
COMPONENTS=()
while IFS= read -r comp; do
  [[ -n "$comp" ]] && COMPONENTS+=("$comp")
done < <(awk '
  /<component>/  { inc=1; nm=""; cls="" }
  inc {
    if (nm=="" && match($0,/<name>[^<]*/))               { nm=substr($0,RSTART+6,RLENGTH-6);  gsub(/^[ \t]+|[ \t]+$/,"",nm) }
    if (match($0,/<java-class-name>[^<]*/))              { cls=substr($0,RSTART+17,RLENGTH-17); gsub(/^[ \t]+|[ \t]+$/,"",cls) }
    if (match($0,/<python-class-name>[^<]*/))            { cls=substr($0,RSTART+19,RLENGTH-19); gsub(/^[ \t]+|[ \t]+$/,"",cls) }
  }
  /<\/component>/ { if(inc && nm!="") { if(cls!="") print nm" -> "cls; else print nm } inc=0 }
' "$META" 2>/dev/null || true)

# YANG facts. Leaves are classified by their enclosing block so that a package's
# real per-instance inputs are separated from action/RPC parameters and from
# library/reference-data leaves:
#   - service       : leaf in a module that declares a servicepoint, not inside input/output
#   - action-input  : leaf inside an action/rpc `input { }` block
#   - other         : everything else (groupings, reference-data, library models)
LEAF_AWK='
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
{
  line=$0
  sub(/\/\/.*/,"",line)                              # strip // comments
  if (match(line,/^[ \t]*(leaf-list|leaf)[ \t]+[A-Za-z0-9_.:-]+/)) {
    nm=substr(line,RSTART,RLENGTH); sub(/^[ \t]*(leaf-list|leaf)[ \t]+/,"",nm); nm=trim(nm)
    ininput=0
    for (i=1;i<=depth;i++) if (stack[i]=="input") { ininput=1; break }
    if (ininput)            print "action-input\t" nm
    else if (fhsp=="1")     print "service\t" nm
    else                    print "other\t" nm
  }
  o=line; nopen=gsub(/\{/,"",o)
  c=line; nclose=gsub(/\}/,"",c)
  if (nopen>0) {
    kw=""
    if (match(line,/[A-Za-z][A-Za-z0-9_.:-]*/)) kw=substr(line,RSTART,RLENGTH)
    sub(/^[^:]*:/,"",kw)                             # drop prefix (ncs:/tailf:)
    for (k=0;k<nopen;k++){ depth++; stack[depth]=(k==0?kw:"?") }
  }
  if (nclose>0) for (k=0;k<nclose;k++){ if(depth>0){ delete stack[depth]; depth-- } }
}
'
YANG_FILES=(); SERVICE_POINTS=(); AUGMENTS=()
SVC_LEAVES=(); ACTION_INPUTS=(); OTHER_LEAVES=()
if compgen -G "$PKG_DIR/src/yang/*.yang" >/dev/null 2>&1; then
  for y in "$PKG_DIR"/src/yang/*.yang; do
    YANG_FILES+=("$y")
    while IFS= read -r sp; do SERVICE_POINTS+=("$sp"); done \
      < <(grep -oE "servicepoint[[:space:]]+\"?[^\";[:space:]]+" "$y" 2>/dev/null \
          | sed -E 's/servicepoint[[:space:]]+"?//' || true)
    while IFS= read -r au; do AUGMENTS+=("$au"); done \
      < <(grep -oE 'augment[[:space:]]+"?[^"{[:space:]]+' "$y" 2>/dev/null \
          | sed -E 's/augment[[:space:]]+"?//' || true)
    fhsp=0; grep -q 'servicepoint' "$y" 2>/dev/null && fhsp=1
    while IFS="$(printf '\t')" read -r bucket nm; do
      [[ -n "$nm" ]] || continue
      case "$bucket" in
        service)      SVC_LEAVES+=("$nm") ;;
        action-input) ACTION_INPUTS+=("$nm") ;;
        *)            OTHER_LEAVES+=("$nm") ;;
      esac
    done < <(awk -v fhsp="$fhsp" "$LEAF_AWK" "$y" 2>/dev/null || true)
  done
fi

# Templates → target-NED signal (from device-config xmlns ".../ned/<NED>") and
# the `{$VAR}` template variables (a direct instance-variable signal).
TEMPLATES=(); TMPL_NEDS=(); TMPL_VARS=()
if compgen -G "$PKG_DIR/templates/*.xml" >/dev/null 2>&1; then
  for t in "$PKG_DIR"/templates/*.xml; do
    TEMPLATES+=("$t")
    while IFS= read -r ned; do TMPL_NEDS+=("$ned"); done \
      < <(grep -oE 'xmlns(:[A-Za-z0-9_-]+)?="[^"]*/ned/[^"]*"' "$t" 2>/dev/null \
          | sed -E 's#.*/ned/##; s/".*//' || true)
    while IFS= read -r v; do TMPL_VARS+=("$v"); done \
      < <(grep -oE '\{\$[A-Za-z0-9_]+\}' "$t" 2>/dev/null | sed -E 's/[{}$]//g' || true)
  done
fi

# Python callbacks (Java packages expose logic via <component> above instead).
PY_FILES=(); PY_CLASSES=(); PY_HOOKS=()
if compgen -G "$PKG_DIR/python/*/*.py" >/dev/null 2>&1; then
  for p in "$PKG_DIR"/python/*/*.py; do
    [[ "$(basename "$p")" == "__init__.py" ]] && continue
    PY_FILES+=("$p")
    while IFS= read -r c; do PY_CLASSES+=("$c"); done \
      < <(grep -oE '^class[[:space:]]+[A-Za-z0-9_]+' "$p" 2>/dev/null | sed -E 's/^class[[:space:]]+//' || true)
    for hook in cb_create cb_pre_modification cb_post_modification; do
      grep -q "$hook" "$p" 2>/dev/null && PY_HOOKS+=("$hook")
    done
  done
fi

# Dedupe helper.
uniq_lines() { printf '%s\n' "$@" | awk 'NF' | sort -u; }
count_uniq() { printf '%s\n' "$@" | awk 'NF' | sort -u | wc -l | tr -d ' '; }

# ─── JSON OUTPUT ─────────────────────────────────────────────────────────────
if [[ "$JSON" == true ]]; then
  json_arr() { # print a JSON array from stdin lines
    local first=true; printf '['
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      $first || printf ','; first=false
      printf '"%s"' "$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    done
    printf ']'
  }
  printf '{'
  printf '"id":"%s",' "$(printf '%s' "$PKG_NAME" | tr '[:upper:] _' '[:lower:]--' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  printf '"name":"%s",' "$PKG_NAME"
  printf '"dir":"%s",' "$PKG_DIR"
  printf '"package_version":"%s",' "${PKG_VER:-}"
  printf '"ncs_min_version":"%s",' "${NCS_MIN:-}"
  printf '"required_packages":';   uniq_lines "${REQ_PKGS[@]:-}" | json_arr; printf ','
  printf '"components":';          uniq_lines "${COMPONENTS[@]:-}" | json_arr; printf ','
  printf '"service_points":';      uniq_lines "${SERVICE_POINTS[@]:-}" | json_arr; printf ','
  printf '"augmentations":';       uniq_lines "${AUGMENTS[@]:-}" | json_arr; printf ','
  printf '"service_leaves":';      uniq_lines "${SVC_LEAVES[@]:-}" | json_arr; printf ','
  printf '"action_input_leaves":'; uniq_lines "${ACTION_INPUTS[@]:-}" | json_arr; printf ','
  printf '"other_leaves":';        uniq_lines "${OTHER_LEAVES[@]:-}" | json_arr; printf ','
  printf '"template_neds":';       uniq_lines "${TMPL_NEDS[@]:-}" | json_arr; printf ','
  printf '"template_vars":';       uniq_lines "${TMPL_VARS[@]:-}" | json_arr; printf ','
  printf '"python_classes":';      uniq_lines "${PY_CLASSES[@]:-}" | json_arr; printf ','
  printf '"python_hooks":';        uniq_lines "${PY_HOOKS[@]:-}" | json_arr
  printf '}\n'
  exit 0
fi

# ─── HUMAN OUTPUT ────────────────────────────────────────────────────────────
echo "# Package: $PKG_NAME"
echo "- dir: $PKG_DIR"
echo "- package_version: ${PKG_VER:-?}"
echo "- ncs_min_version: ${NCS_MIN:-?}"
echo ""
echo "## required-package (NED type@version signal)"
if [[ ${#REQ_PKGS[@]} -gt 0 ]]; then uniq_lines "${REQ_PKGS[@]}" | sed 's/^/- /'; else echo "- (none declared — cross-check target NEDs from templates below)"; fi
echo ""
echo "## components (meta callback/application classes)"
if [[ ${#COMPONENTS[@]} -gt 0 ]]; then uniq_lines "${COMPONENTS[@]}" | sed 's/^/- /'; else echo "- (none)"; fi
echo ""
echo "## YANG"
echo "### modules"
if [[ ${#YANG_FILES[@]} -gt 0 ]]; then for y in "${YANG_FILES[@]}"; do echo "- $y"; done; else echo "- (none)"; fi
echo "### service points"
if [[ ${#SERVICE_POINTS[@]} -gt 0 ]]; then uniq_lines "${SERVICE_POINTS[@]}" | sed 's/^/- /'; else echo "- (none — not a service package; likely a library/action package)"; fi
echo "### augmentations"
if [[ ${#AUGMENTS[@]} -gt 0 ]]; then uniq_lines "${AUGMENTS[@]}" | sed 's/^/- /'; else echo "- (none)"; fi
echo "### service input leaves (candidate instance-variable keys)"
if [[ ${#SVC_LEAVES[@]} -gt 0 ]]; then uniq_lines "${SVC_LEAVES[@]}" | sed 's/^/- /'; else echo "- (none — no servicepoint; use template variables / action inputs below)"; fi
echo "### action/rpc input leaves"
if [[ ${#ACTION_INPUTS[@]} -gt 0 ]]; then uniq_lines "${ACTION_INPUTS[@]}" | sed 's/^/- /'; else echo "- (none)"; fi
echo "### other model/grouping leaves"
echo "- $(count_uniq "${OTHER_LEAVES[@]:-}") leaf name(s) in groupings/reference-data (not instance inputs; read YANG if relevant)"

# YANG tree (best-effort; needs pyang + an NSO install for ncsrc YANG path).
[[ -z "$INSTALL_DIR" ]] && INSTALL_DIR="$(ls -d ~/nso-[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
echo "### tree"
if command -v pyang >/dev/null 2>&1 && [[ ${#YANG_FILES[@]} -gt 0 ]]; then
  if [[ -n "$INSTALL_DIR" && -f "$INSTALL_DIR/ncsrc" ]]; then
    set +u; # shellcheck source=/dev/null
    source "$INSTALL_DIR/ncsrc"; set -u
  fi
  echo '```'
  pyang -f tree --tree-depth=4 "${YANG_FILES[0]}" 2>/dev/null || echo "(pyang tree failed; read the YANG directly)"
  echo '```'
else
  echo "(pyang unavailable — read the YANG module directly)"
fi
echo ""
echo "## Templates"
if [[ ${#TEMPLATES[@]} -gt 0 ]]; then
  for t in "${TEMPLATES[@]}"; do echo "- $t"; done
  echo "### target NEDs (from device-config xmlns .../ned/<NED>)"
  if [[ ${#TMPL_NEDS[@]} -gt 0 ]]; then uniq_lines "${TMPL_NEDS[@]}" | sed 's/^/- /'; else echo "- (none detected)"; fi
  echo "### template variables ({\$VAR}) — instance-variable signal"
  if [[ ${#TMPL_VARS[@]} -gt 0 ]]; then uniq_lines "${TMPL_VARS[@]}" | sed 's/^/- /'; else echo "- (none)"; fi
else
  echo "- (none)"
fi
echo ""
echo "## Python callbacks"
if [[ ${#PY_FILES[@]} -gt 0 ]]; then
  for p in "${PY_FILES[@]}"; do echo "- $p"; done
  echo "### classes"; uniq_lines "${PY_CLASSES[@]:-}" | sed 's/^/- /'
  echo "### hooks";   uniq_lines "${PY_HOOKS[@]:-}" | sed 's/^/- /'
else
  echo "- (none — Java package? see components above)"
fi
echo ""
echo "Next: read the files above, map onto store fields (references/field-mapping.md),"
echo "then commit with: aifirst spec backfill --deep ..."
