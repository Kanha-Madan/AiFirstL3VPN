# AiFirstL3VPN — AI-first L3VPN PE Attachment service for Cisco NSO

An AI-first (spec-driven) build of an L3VPN customer-attachment service for an
IOS-XR PE router. A Low-Level Design document (`docs/LLD_L3VPN_PE_Attachment.md`)
was turned into a spec, and the spec into the NSO service package **`l3vpn-ai`**
by the Cursor `AIFirst-NSO-Development` agent. The package was then built,
loaded and validated against a netsim IOS-XR router (`pe0`).

One service instance configures, on one PE:

| Part | What it configures |
|---|---|
| VRF | `vrf <name>`, IPv4/IPv6 unicast, import/export route-targets, `maximum prefix` |
| QoS | Ingress `policy-map` (police rate + burst/peak-burst, set MPLS EXP) and egress `policy-map` (shape) |
| Interface | QinQ sub-interface: description, bandwidth, `dot1q`/`second-dot1q`, service-policies, VRF, IPv4/IPv6, uRPF, unreachables |
| Routing | `router bgp 9730` → `vrf <name>` with RD, label mode per-vrf, dampening, redistribute connected/static |

---

## 1. Repository layout

```
AiFirstL3VPN/
├── README.md                         ← this file
├── docs/LLD_L3VPN_PE_Attachment.md   ← source LLD (input to the AI build)
├── aifirstspec/                      ← spec + package memory
│   ├── config.yaml                   ← packages_root: packages
│   ├── inputs/l3vpn-ai.yaml          ← spec generated from the LLD
│   ├── specs/l3vpn-ai-pe-attachment/ ← living spec of the built package
│   ├── changes/archive/              ← archived change record (validated)
│   └── packages-registry.md          ← package registry
├── packages/l3vpn-ai/                ← ★ THE NSO SERVICE PACKAGE
│   ├── package-meta-data.xml         ← requires cisco-iosxr-cli-7.74
│   ├── src/yang/l3vpn-ai.yang        ← service model (/l3vpn-ai{name})
│   ├── src/Makefile
│   ├── python/l3vpn_ai/main.py       ← computes police/shape rate, burst, peak-burst
│   └── templates/l3vpn-ai-template.xml
├── scripts/                          ← CI/CT/CD helper scripts
├── .github/workflows/nso-ci-ct-cd.yml← GitHub Actions pipeline
├── Jenkinsfile                       ← Jenkins pipeline
├── .gitleaks.toml                    ← secret-scanning rules
└── .cursor/                          ← AI agents, skills and rules used for the build
```

`packages/*/load-dir/` (compiled `.fxs`) is git-ignored — run `make` after cloning.

---

## 2. Prerequisites

| Item | Version used | Notes |
|---|---|---|
| macOS | Apple Silicon (arm64) | |
| Cisco NSO | **6.6.1** (local install) | `nso-6.6.1.darwin.arm64.installer.bin` |
| NED | **cisco-iosxr-cli-7.74.11** | `ncs-6.6.1-cisco-iosxr-7.74.11.signed.bin` |
| Java | 17 | `brew install openjdk@17` |
| Python | 3.11 | NSO Python VM |
| Cursor | with the `.cursor/` agents in this repo | for the AI-first build |
| `aifirst` CLI | `~/.aifirst/bin/aifirst` | spec / package-memory commands — install in 3.0 |
| GitHub CLI | `gh` | only for publishing |

This demo reuses the NSO lab from the sibling project **NSO_Demo**
(`~/Projects/NSO_Demo`), which contains the NSO install, the NED, the netsim
devices `pe0`/`pe1` and the runtime directory `nso/ncs-run`.

```
~/Projects/
├── NSO_Demo/            ← NSO 6.6.1 + NED + netsim + ncs-run (the lab)
│   └── nso/ncs-run/packages/l3vpn-ai -> ~/Projects/AiFirstL3VPN/packages/l3vpn-ai
└── AiFirstL3VPN/        ← this repo (package source)
```

---

## 3. First-time setup

Each block states the directory it is run from (📁).

### 3.0 Install the `aifirst` CLI (once)

```bash
# 📁 anywhere
curl -fsSL https://wwwin-github.cisco.com/raw/cxsao/aifirst-cli/refs/heads/master/install.sh | bash
```

The installer is on Cisco's internal GitHub, so you need to be on the Cisco
network/VPN. It installs to `~/.aifirst/bin/aifirst`; open a new terminal (or
add `~/.aifirst/bin` to `PATH`) and check with `which aifirst`.

### 3.1 Install NSO and the IOS-XR NED (once)

Skip if `NSO_Demo` is already set up.

```bash
# 📁 ~/Projects/NSO_Demo/nso/installers
cd ~/Projects/NSO_Demo/nso/installers
sh nso-6.6.1.darwin.arm64.installer.bin --local-install ../nso661
cd .. && ln -sfn nso661 current
cd installers
sh ncs-6.6.1-cisco-iosxr-7.74.11.signed.bin
tar -xzf ncs-6.6.1-cisco-iosxr-7.74.11.tar.gz -C ../neds
```

Create the runtime and netsim devices (once):

```bash
# 📁 ~/Projects/NSO_Demo
source scripts/env.sh
ncs-netsim create-network "$NED_DIR" 2 pe --dir "$NETSIM_DIR"
ncs-setup --netsim-dir "$NETSIM_DIR" --dest "$NCS_RUN"     # also links the NED into ncs-run/packages
```

> Never install NSO in a path containing spaces, and never move a local install
> after installing (`ncsrc` holds absolute paths).

### 3.2 Clone this repo

```bash
# 📁 ~/Projects
git clone https://github.com/Kanha-Madan/AiFirstL3VPN.git
cd AiFirstL3VPN
```

### 3.3 Start the lab (every session)

```bash
# 📁 ~/Projects/NSO_Demo
cd ~/Projects/NSO_Demo
source scripts/env.sh          # loads ncsrc, JAVA_HOME, NCS_RUN, NETSIM_DIR, NED_DIR
./scripts/start-lab.sh         # netsim start + ncs + fetch-ssh-host-keys + sync-from
```

`start-lab.sh` runs:

```bash
ncs-netsim --dir "$NETSIM_DIR" start
(cd "$NCS_RUN" && ncs)
ncs_cli -C -u admin <<'EOF'
devices fetch-ssh-host-keys
devices sync-from
show devices list
EOF
```

### 3.4 Preflight (environment readiness)

```bash
# 📁 ~/Projects/AiFirstL3VPN
source ~/Projects/NSO_Demo/nso/nso661/ncsrc
bash .cursor/skills/af-nso-preflight/scripts/preflight_check.sh
curl -s -o /dev/null -w "restconf=%{http_code}\n" http://localhost:8080/restconf
printf 'show packages package oper-status | tab\nshow devices list\ndevices check-sync\n' | ncs_cli -Cu admin
```

Expected: NSO 6.6.1 running, RESTCONF answering, `cisco-iosxr-cli-7.74` `up`,
`pe0`/`pe1` `in-sync`.

> Inside a Cursor sandbox the preflight script can wrongly report "NSO not
> running" (process check blocked) — the RESTCONF / `ncs_cli` checks are the
> source of truth.

---

## 4. AI-first build: LLD → spec → package

This is how the package was produced. You do **not** need to repeat it to use
the package — the result is already in `packages/l3vpn-ai/`.

### 4.1 Ask the agent in Cursor

In Cursor chat:

```
/"AIFirst-NSO-Development" Build a new NSO service package from the LLD @docs/LLD_L3VPN_PE_Attachment.md
```

The agent:

1. Read the LLD and checked package memory → **NEW** package.
2. Wrote the spec `aifirstspec/inputs/l3vpn-ai.yaml` (raw config from LLD §11,
   23 `<VARIABLE>` tokens → instance variables, 4 of them computed in Python).
3. Ran preflight.
4. **Stopped for human approval** of the spec, naming and location. Answers given:
   - package / YANG / service path name: `l3vpn-ai` (registry entry: `l3vpn-ai-pe-attachment`)
   - location: `packages/l3vpn-ai/` in this repo, symlinked into `NSO_Demo/nso/ncs-run/packages/`
   - spec: approved
5. Scaffolded, built, loaded and tested the package (sections 5–6 below).

### 4.2 Spec / package-memory commands used

```bash
# 📁 ~/Projects/AiFirstL3VPN
aifirst spec init
aifirst spec discover
aifirst spec view
aifirst spec plan --spec aifirstspec/inputs/l3vpn-ai.yaml          # → NEW
aifirst spec change new --spec aifirstspec/inputs/l3vpn-ai.yaml     # open change record
# ... build + validate ...
aifirst spec change archive 2026-11-17-l3vpn-ai --status validated  # record result
aifirst spec view
```

### 4.3 Scaffold the package

```bash
# 📁 ~/Projects/AiFirstL3VPN
bash .cursor/skills/af-nso-manage-package/scripts/manage_package.sh l3vpn-ai \
  --type python-and-template \
  --install-dir ~/Projects/NSO_Demo/nso/nso661 \
  --runtime-dir ~/Projects/NSO_Demo/nso/ncs-run -y
```

This creates `packages/l3vpn-ai/` (via `ncs-make-package`) and the symlink in
the runtime. The YANG, template and Python were then written from the spec and
from the NED data captured from the device (`NSO_Demo/output/pe1-captured.xml`).

---

## 5. Build and load the package

After a fresh clone, link the package into the runtime (once):

```bash
ln -s ~/Projects/AiFirstL3VPN/packages/l3vpn-ai ~/Projects/NSO_Demo/nso/ncs-run/packages/l3vpn-ai
```

Build and reload:

```bash
# 📁 ~/Projects/AiFirstL3VPN
source ~/Projects/NSO_Demo/nso/nso661/ncsrc
make -C packages/l3vpn-ai/src clean all
printf 'packages reload\n' | ncs_cli -Cu admin
printf 'show packages package l3vpn-ai oper-status\n' | ncs_cli -Cu admin    # → up
```

---

## 6. Deploy and test the service

### 6.1 Create an instance and dry-run (T1)

```bash
ncs_cli -Cu admin <<'EOF'
config
l3vpn-ai AI-TEST-1 device-name pe0 bandwidth 1676
l3vpn-ai AI-TEST-1 vrf vrf-name AI-TEST-VRF rd-value 71728999
l3vpn-ai AI-TEST-1 vrf route-target 71728999
l3vpn-ai AI-TEST-1 qos in-policy-name in_AI_TEST_1676_By_NSO out-policy-name out_AI_TEST_1676_By_NSO
l3vpn-ai AI-TEST-1 interface interface-type GigabitEthernet interface-id 0/0/1 subintf-id 5102 description AI-TEST-1-1676k svlan 3715 cvlan 1261 ip-address 52.45.121.133 subnet-mask 255.255.255.252 ipv6-address 5936:3533::1/126
commit dry-run outformat native
EOF
```

Expected highlights (bandwidth 1676 kbps):

```
police rate 1676000 bps burst 314250 bytes peak-burst 628500 bytes
shape average 1676000 bps
interface GigabitEthernet 0/0/1.5102
 encapsulation dot1q 3715 second-dot1q 1261
router bgp 9730
 vrf AI-TEST-VRF
  rd 9730:71728999
```

Derived in Python: `rate = bandwidth × 1000`, `burst = rate × 1.5 / 8`,
`peak-burst = 2 × burst` (both overridable via `qos burst` / `qos peak-burst`).

> The exact LLD sample (`MSHA-ML3-1-810095`, §14) was only dry-run, not
> committed: in this lab `pe0` already carries that config, owned by the
> `l3vpn-service` instance from NSO_Demo. Use a separate instance such as
> `AI-TEST-1`, or a clean netsim device, to commit.

### 6.2 Commit and check sync (T2)

Run the same commands as 6.1 with `commit` instead of `commit dry-run outformat native`, then:

```bash
ncs_cli -Cu admin <<'EOF'
l3vpn-ai AI-TEST-1 check-sync
devices device pe0 check-sync
EOF
```

### 6.3 Other LLD test cases

```bash
# T3 – bandwidth change: only police/shape/bandwidth lines differ
ncs_cli -Cu admin <<'EOF'
config
l3vpn-ai AI-TEST-1 bandwidth 2000
commit dry-run outformat native
abort
EOF

# Burst / peak-burst override
printf 'config\nl3vpn-ai AI-TEST-1 qos burst 400000\ncommit dry-run outformat native\nabort\n' | ncs_cli -Cu admin

# T8 – VLAN range validation (rejected)
printf 'config\nl3vpn-ai X interface svlan 4095\nabort\n' | ncs_cli -Cu admin

# T9 – out-of-band change on the device, then repair
source ~/Projects/NSO_Demo/scripts/env.sh
printf 'config\ninterface GigabitEthernet 0/0/1.5102 description MANUAL-CHANGE\ncommit\nend\nexit\n' | ncs-netsim --dir "$NETSIM_DIR" cli-c pe0
printf 'devices device pe0 sync-from\nl3vpn-ai AI-TEST-1 check-sync\nl3vpn-ai AI-TEST-1 re-deploy\nl3vpn-ai AI-TEST-1 check-sync\n' | ncs_cli -Cu admin

# T10 – delete dry-run (router bgp 9730 stays)
printf 'config\nno l3vpn-ai AI-TEST-1\ncommit dry-run outformat native\nabort\n' | ncs_cli -Cu admin
```

T4–T7 (`ipv6-enable false`, IPv6 on without address, no route-target,
route-target `direction import|export|both`) are run the same way: set the
leaves, `commit dry-run outformat native`, `abort`.

| Test | Result |
|---|---|
| T1 dry-run native | PASS |
| T2 commit + check-sync | PASS |
| T3 bandwidth 2000 | PASS |
| T4 ipv6-enable false | PASS |
| T5 IPv6 on, no address | PASS (must error) |
| T6 no route-target | PASS (min-elements 1) |
| T7 RT direction | PASS |
| T8 VLAN range | PASS |
| T9 out-of-band + re-deploy | PASS |
| T10 delete dry-run | PASS |

### 6.4 Clean up

```bash
printf 'config\nno l3vpn-ai AI-TEST-1\ncommit\nend\ndevices check-sync\n' | ncs_cli -Cu admin
```

---

## 7. Publish to GitHub (what was done for this repo)

```bash
# 📁 ~/Projects/AiFirstL3VPN
brew install gh
gh auth login --hostname github.com --git-protocol https --web
gh auth refresh -h github.com -s workflow     # needed to push .github/workflows/
gh auth setup-git

git add -A
git commit -m "Initial commit: AI-first L3VPN NSO project with l3vpn-ai PE attachment service package"
gh repo create AiFirstL3VPN --public --source=. --remote=origin --push
git push -u origin main
```

Without the `workflow` scope GitHub rejects the push with
`refusing to allow an OAuth App to create or update workflow ...`.

---

## 8. CI/CD

`.github/workflows/nso-ci-ct-cd.yml` (and the `Jenkinsfile`) run on a
self-hosted runner labelled `cx-sao-ocp` and need these repository secrets:
`TAILF_USERNAME`, `TAILF_PASSWORD`, `SONAR_TOKEN`, `WEBEX_TOKEN`. Until a runner
with that label is registered, runs stay **queued**.

---

## 9. Stop the lab

```bash
# 📁 ~/Projects/NSO_Demo
./scripts/stop-lab.sh          # ncs --stop + ncs-netsim stop
```

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `packages reload` → `Duplicate callbacks (create) registered for servicepoint` | Template and Python both registered the servicepoint. Remove `servicepoint` from the template's `config-template` element; Python is the only callback. |
| `5936:3532::1/126` rejected | `inet:ipv6-prefix` rejects host bits. Use `tailf:ipv6-address-and-prefix-length`. |
| `command not found: ncs-netsim` / `ncs` | Run `source ~/Projects/NSO_Demo/scripts/env.sh` in every new terminal. |
| `l3vpn-ai` missing after clone | `load-dir` is git-ignored — run `make -C packages/l3vpn-ai/src all` and `packages reload`. |
| Devices `out-of-sync` after lab restart | `printf 'devices sync-from\n' \| ncs_cli -Cu admin` |
