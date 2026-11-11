#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Fail early if this host cannot run rootless Podman (uidmap, subuid, TUN, userns).
# Called from install.sh before image pull. Does not switch the stack to rootful.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
#
# Changes in v1.1.0:
# - Error text for unprepared operators: what is missing, why evi needs it,
#   which VM types usually lack it, where to enable it.
#
# Changes in v1.0.0:
# - Check newuidmap/newgidmap, /etc/subuid+subgid, /dev/net/tun, podman unshare.
# - On LXC: if subuid start is outside 0-65535, remap to 10000:55536 and retry.
# - Print Proxmox CT hints (nesting, keyctl, TUN). Never claim the host is fine on EPERM.
#
set -euo pipefail

RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
err() { printf "${RED}error:${NC} %s\n" "$*" >&2; }
log() { printf "${CYAN}[app]${NC} %s\n" "$*"; }

virt_container() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v=$(systemd-detect-virt -c 2>/dev/null || true)
    [[ -n "${v}" && "${v}" != "none" ]] && { printf '%s\n' "${v}"; return 0; }
  fi
  if [[ -r /proc/1/environ ]] && tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -q '^container=lxc'; then
    printf 'lxc\n'
    return 0
  fi
  return 1
}

u=$(id -un)
virt=$(virt_container || true)

if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
  err "the uidmap tools (newuidmap, newgidmap) are not installed. the application needs them to run as a rootless application."
  err "install them with: sudo apt-get install -y uidmap"
  err "then run this installer again."
  exit 1
fi

if ! grep -q "^${u}:" /etc/subuid 2>/dev/null || ! grep -q "^${u}:" /etc/subgid 2>/dev/null; then
  err "user ${u} has no mapping in /etc/subuid or /etc/subgid. the application needs that mapping to run as a rootless application."
  err "this is usual when uidmap was never set up. install uidmap, add a mapping for this user (for example ${u}:10000:55536), then run this installer again."
  exit 1
fi

if [[ ! -c /dev/net/tun ]]; then
  err "your virtual machine does not provide TUN (/dev/net/tun). the application needs TUN to run as a rootless application."
  if [[ "${virt}" == "lxc" ]]; then
    err "this is usual on Proxmox LXC, LXD, and OpenVZ containers. enable nesting, keyctl, and TUN in the hypervisor or hosting panel (on Proxmox: CT Features), reboot the machine, then run this installer again."
  else
    err "on KVM/QEMU this device is normally present. enable TUN in the hypervisor or hosting panel, reboot the machine, then run this installer again."
  fi
  exit 1
fi

try_unshare() {
  command -v podman >/dev/null 2>&1 || return 0
  podman unshare true >/tmp/app-userns.err 2>&1
}

if ! try_unshare; then
  start=$(awk -F: -v u="${u}" '$1==u {print $2; exit}' /etc/subuid)
  if [[ "${virt}" == "lxc" && "${start}" =~ ^[0-9]+$ && "${start}" -ge 65536 ]]; then
    log "LXC subuid ${u}:${start}:... is outside the CT map 0-65535; remapping to ${u}:10000:55536"
    remap_user_subid() {
      local file="$1"
      local tmp
      tmp=$(mktemp)
      awk -F: -v u="${u}" 'BEGIN{OFS=":"} $1==u {print u,"10000","55536"; next} {print}' "${file}" > "${tmp}"
      if ! grep -q "^${u}:" "${tmp}"; then
        printf '%s:10000:55536\n' "${u}" >> "${tmp}"
      fi
      sudo cp "${tmp}" "${file}"
      rm -f "${tmp}"
    }
    remap_user_subid /etc/subuid
    remap_user_subid /etc/subgid
    if try_unshare; then
      log "user namespace ok after subuid remap."
      rm -f /tmp/app-userns.err
      exit 0
    fi
  fi
  err "your virtual machine does not allow user namespaces (newuidmap). the application needs user namespaces to run as a rootless application."
  if [[ -s /tmp/app-userns.err ]]; then
    sed 's/^/  /' /tmp/app-userns.err >&2 || true
  fi
  rm -f /tmp/app-userns.err
  if [[ "${virt}" == "lxc" ]]; then
    err "this is usual on unprivileged Proxmox LXC / LXD containers. enable nesting and keyctl in the hypervisor or hosting panel (on Proxmox: CT Features), keep this user's /etc/subuid inside 0-65535 (for example ${u}:10000:55536), reboot the machine, then run this installer again."
  else
    err "check in the hypervisor or hosting panel that user namespaces are enabled, that /proc/sys/user/max_user_namespaces is greater than 0, then run this installer again."
  fi
  exit 1
fi
rm -f /tmp/app-userns.err
exit 0
