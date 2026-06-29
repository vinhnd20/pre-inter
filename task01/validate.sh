#!/usr/bin/env bash
# ============================================================================
# validate.sh — verify a provisioned Kubernetes node against RUNTIME state.
#
# Checks live kernel/runtime state (not config files): /proc/sys, lsmod,
# systemctl, crictl. Prints PASS/FAIL per check. Exits 0 only if all pass.
#
# Usage:  sudo ./validate.sh
#         KUBERNETES_VERSION=1.30 PAUSE_IMAGE=registry.k8s.io/pause:3.9 ./validate.sh
# ============================================================================
set -uo pipefail

# --- Expected values (override via env to match group_vars) ----------------
EXPECTED_UBUNTU="${EXPECTED_UBUNTU:-24.04}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
SYSADMIN_USER="${SYSADMIN_USER:-sysadmin}"
AUDIT_LOG="${AUDIT_LOG:-/var/log/audit/audit.log}"

PASS=0
FAIL=0
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; RST=""; }

check() {
  # check "<description>" "<command>" "<expected substring (optional)>"
  local desc="$1" cmd="$2" want="${3:-}"
  local out rc
  out="$(eval "$cmd" 2>/dev/null)"; rc=$?
  if [[ $rc -eq 0 ]] && { [[ -z "$want" ]] || grep -qF -- "$want" <<<"$out"; }; then
    printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$desc"
    ((PASS++))
  else
    printf '%s[FAIL]%s %s%s\n' "$RED" "$RST" "$desc" \
      "${out:+ ${YEL}(got: $(tr '\n' ' ' <<<"$out" | cut -c1-80))${RST}}"
    ((FAIL++))
  fi
}

section() { printf '\n=== %s ===\n' "$1"; }

# --- Operating system ------------------------------------------------------
section "Operating System"
check "Ubuntu ${EXPECTED_UBUNTU}" \
  "grep -oP 'VERSION_ID=\"\\K[^\"]+' /etc/os-release" "$EXPECTED_UBUNTU"

# --- User management -------------------------------------------------------
section "User Management"
check "Sysadmin account '${SYSADMIN_USER}' exists" "id ${SYSADMIN_USER}"
check "Sysadmin in sudo group" "id -nG ${SYSADMIN_USER}" "sudo"
check "Sudoers syntax valid" "visudo -c"

# --- Kernel prerequisites (the core requirement) ---------------------------
section "Kernel Prerequisites"
check "Swap disabled (none active)" "[ -z \"\$(swapon --noheadings)\" ] && echo ok" "ok"
check "Module overlay loaded/built-in" \
  "{ lsmod | grep -qw overlay || test -d /sys/module/overlay; } && echo ok" "ok"
check "Module br_netfilter loaded/built-in" \
  "{ lsmod | grep -qw br_netfilter || test -d /sys/module/br_netfilter || test -e /proc/sys/net/bridge/bridge-nf-call-iptables; } && echo ok" "ok"
check "sysctl net.ipv4.ip_forward = 1" \
  "cat /proc/sys/net/ipv4/ip_forward" "1"
check "sysctl bridge-nf-call-iptables = 1" \
  "cat /proc/sys/net/bridge/bridge-nf-call-iptables" "1"
check "sysctl bridge-nf-call-ip6tables = 1" \
  "cat /proc/sys/net/bridge/bridge-nf-call-ip6tables" "1"

# --- Container runtime -----------------------------------------------------
section "Container Runtime"
check "containerd service active" "systemctl is-active containerd" "active"
check "containerd SystemdCgroup = true" \
  "containerd config dump | grep -i SystemdCgroup" "true"
check "Pause image = ${PAUSE_IMAGE}" \
  "containerd config dump | grep -iE 'sandbox_image|sandbox ='" "$PAUSE_IMAGE"

# --- Kubernetes components -------------------------------------------------
section "Kubernetes Components"
check "kubelet installed" "command -v kubelet"
check "kubeadm installed" "command -v kubeadm"
check "kubelet enabled" "systemctl is-enabled kubelet" "enabled"
check "crictl endpoint configured" \
  "grep runtime-endpoint /etc/crictl.yaml" "containerd.sock"

# --- Security --------------------------------------------------------------
section "Security"
check "SSH PermitRootLogin no" "sshd -T 2>/dev/null | grep permitrootlogin" "no"
check "SSH PasswordAuthentication" "sshd -T 2>/dev/null | grep -E '^passwordauthentication'"
check "auditd service active" "systemctl is-active auditd" "active"
check "Audit rule for user commands loaded" "auditctl -l" "user_commands"
check "Audit log file present" "test -f ${AUDIT_LOG} && echo ok" "ok"

# --- Result ----------------------------------------------------------------
printf '\n========================================\n'
printf 'Result: %s%d passed%s, %s%d failed%s\n' \
  "$GRN" "$PASS" "$RST" "$( ((FAIL>0)) && echo "$RED" || echo "$GRN")" "$FAIL" "$RST"
printf '========================================\n'
exit $(( FAIL > 0 ? 1 : 0 ))
