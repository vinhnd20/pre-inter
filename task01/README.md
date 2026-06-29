# Task 01 — Kubernetes Node Provisioning

Ansible automation that turns a fresh **Ubuntu 24.04 LTS** host into a
**production-ready Kubernetes worker node**, ready to run `kubeadm join`.

> It does **not** create a cluster and does **not** run `kubeadm join` — the
> bootstrap token, CA hash, and API endpoint belong to the target cluster and
> are out of scope.

---

## Quick start

### Option A — run on the node itself (fresh Ubuntu, via console)

```bash
# As root, from a clone on the target host:
./bootstrap.sh          # installs ansible+git, collections, writes local inventory
# then:
ansible-playbook -i inventory/local.ini site.yml
./validate.sh

# ...or do it all in one shot:
./bootstrap.sh --run
```

### Option B — run from a controller against remote node(s)

```bash
# 1. Install collection dependencies
ansible-galaxy collection install -r requirements.yml

# 2. Edit inventory + vars
$EDITOR inventory/hosts.ini      # add your node(s)
$EDITOR group_vars/all.yml       # set users, SSH keys, versions, DNS

# 3. Provision
ansible-playbook site.yml

# 4. Validate (runtime state, on the node)
sudo ./validate.sh
```

Generated sysadmin passwords are written to `.secrets/credentials.yml` on the
**machine that runs Ansible** (mode `0600`, git-ignored) — for Option A that is
the node itself. Users are forced to change them on first login.

---

## Design principles

| Principle | How it's applied |
|-----------|------------------|
| **No hardcoding** | Everything tunable lives in `group_vars/all.yml`; roles read variables only. |
| **Idempotent** | Safe to re-run. Passwords generated once via the `password` lookup and `update_password: on_create`; containerd config patched not clobbered; sysctl/modules declarative. |
| **Fail-fast** | `preflight` asserts OS/version/arch and aborts before any change; `any_errors_fatal` in `ansible.cfg`. |
| **DRY (in moderation)** | One variable file, role-per-concern, loops over data. Not over-abstracted — readability first. |
| **KISS** | Standard modules over shell wherever possible; `shell`/`command` only where a module can't do the job (documented inline). |
| **Secure by default** | Secrets never logged (`no_log`), SSH key-first, least-privilege sudoers, packages pinned + held. |

---

## Structure

```
task01/
├── ansible.cfg              # inventory, become, fact cache, fail-fast
├── site.yml                 # role pipeline
├── requirements.yml         # community.general, ansible.posix
├── inventory/hosts.ini
├── group_vars/all.yml       # ← single source of configuration
├── validate.sh              # standalone runtime validator
└── roles/
    ├── preflight/           # assert Ubuntu 24.04 + arch
    ├── baseline/            # hostname, /etc/hosts, DNS, timezone, NTP, CLI tools
    ├── users/               # sysadmin accounts, random passwords, sudo
    ├── k8s_prereqs/         # swap off, kernel modules, sysctl
    ├── containerd/          # runtime, SystemdCgroup, pause image
    ├── kubernetes/          # kubelet, kubeadm, kubectl, crictl
    ├── hardening/           # SSH + selected CIS L1 controls
    └── auditd/              # capture every user command to a dedicated log
```

---

## How the requirements are met

### Sysadmin accounts (idempotent random passwords)
`roles/users` generates each password **once** with the `password` lookup
(persisted to `.secrets/<user>.pass` on the controller). Re-runs reuse the
stored value, so the account password never churns. `update_password:
on_create` guarantees existing users are never re-hashed. Plaintext is guarded
by `no_log: true` on every task that touches it and never printed to stdout.
Sudo is granted per-user under `/etc/sudoers.d/` with `visudo` validation;
`chage -d 0` forces rotation on first login.

### Swap & kernel parameters
`roles/k8s_prereqs` disables swap immediately (`swapoff`) and permanently
(removes/comments fstab entries), loads `overlay` + `br_netfilter` (persisted
via `/etc/modules-load.d`), and sets the required sysctls
(`ip_forward`, `bridge-nf-call-iptables`, `bridge-nf-call-ip6tables`) in
`/etc/sysctl.d/99-kubernetes.conf` with immediate reload.

### containerd
Installed from the Docker apt repo (pinnable via `containerd_version`).
The version-appropriate default config is generated once, then two keys are
patched idempotently: `SystemdCgroup = true` (must match kubelet's cgroup
driver) and `sandbox_image` set to a **version-matched pause image**
(`containerd_pause_image`). Restart is handler-driven.

### Validation script
`validate.sh` checks **runtime state, not config files**: `/proc/sys/...`
values, `lsmod`, `swapon`, `systemctl is-active`, `containerd config dump`,
`auditctl -l`, `sshd -T`. It prints `PASS`/`FAIL` per check and **exits
non-zero if any check fails**, naming what failed. Expected values are
overridable via env vars to match `group_vars`.

### Audit logging — every user command
`roles/auditd` installs auditd and loads execve rules keyed `user_commands`
(for `auid>=1000`) and `root_commands`, writing to a dedicated log
(`/var/log/audit/audit.log`) with rotation configured.

> **Documented limitation:** auditd records the `execve` syscall, which covers
> every binary a user runs. Pure shell **builtins** (`cd`, `export`, `alias`)
> do not call `execve` and are therefore not captured by syscall auditing —
> this is inherent to the approach, not a bug. If full keystroke/builtin
> capture is required, layer `pam_tty_audit` or shell-level session logging on
> top; that was judged out of scope for a node baseline.

---

## CIS Ubuntu 24.04 Level 1 — applied controls

A **deliberate subset** (not the full benchmark), chosen for relevance to a
Kubernetes node. Each is implemented in `roles/hardening` or `roles/auditd`:

| # | CIS area | Control | Where |
|---|----------|---------|-------|
| 1 | 1.1 Filesystems | Disable uncommon FS modules (cramfs, freevxfs, jffs2, hfs, hfsplus, udf, squashfs) | `hardening` |
| 2 | 5.1 SSH | Root login off, password auth off (key-first), `MaxAuthTries`, idle timeout, no X11, banner | `hardening` |
| 3 | 5.3 PAM | `pwquality` (minlen 14, complexity, maxrepeat) | `hardening` |
| 4 | 5.4 Accounts | Password ageing (`PASS_MAX/MIN/WARN`), default `UMASK 027` | `hardening` |
| 5 | 6.1 Permissions | Lock down `/etc/passwd,group,shadow,gshadow,sshd_config` | `hardening` |
| 6 | 1.7 Banners | Warning banner in `/etc/issue[.net]` | `hardening` |
| 7 | 4.1 Auditing | auditd enabled, execve command auditing, log rotation | `auditd` |

---

## Configuration reference

Key variables in `group_vars/all.yml`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `kubernetes_version` | `1.30` | minor track → drives apt repo + held package |
| `containerd_version` | `""` (latest) | pin containerd; `""` = repo latest |
| `containerd_pause_image` | `registry.k8s.io/pause:3.9` | must match kubeadm; verify with `kubeadm config images list` |
| `sysadmin_users` | `[{name: sysadmin}]` | accounts; add `ssh_authorized_keys` |
| `dns_nameservers` | `1.1.1.1`, `8.8.8.8` | systemd-resolved upstreams |
| `ssh_password_authentication` | `no` | set `yes` only if no keys provisioned yet |

> **⚠ Lockout safety:** SSH password auth is disabled by default. Provide
> `ssh_authorized_keys` for your sysadmin user(s) **before** running, or set
> `ssh_password_authentication: "yes"` for the first run.

---

## Post-provision: joining the cluster

On the node, with values from your control plane:

```bash
sudo kubeadm join <api-endpoint>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

kubelet is **enabled** but stays inactive (crash-loops) until `join` writes its
config — this is expected and is why `validate.sh` checks *enabled*, not
*active*, for kubelet.

---

## Requirements

- Ansible core ≥ 2.16, collections in `requirements.yml`
- Target: Ubuntu 24.04 LTS, `amd64` or `arm64`
- Controller→node SSH with sudo

Verified with `ansible-playbook --syntax-check` and `ansible-lint`
(`production` profile, 0 findings).
