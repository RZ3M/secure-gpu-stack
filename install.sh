#!/usr/bin/env bash
# Secure GPU Stack installer: a security-first alternative to Lambda Stack.
#
#   sudo ./install.sh [options]
#
# Options:
#   --user NAME         account that gets the Jupyter service (default: the user
#                       who ran sudo, or "ubuntu")
#   --no-driver         don't install the NVIDIA driver
#   --no-cuda-toolkit   don't install the system CUDA toolkit, cuDNN and NCCL
#   --no-docker         don't install Docker and the NVIDIA Container Toolkit
#   --no-hardening      don't change SSH, the firewall, automatic updates, kernel
#                       settings, kernel lockdown or audit rules
#   --no-lockdown       don't turn on kernel lockdown (needed for hibernation,
#                       writing CPU registers or PCI config space, or unsigned
#                       kernel modules); takes it back out if an earlier run
#                       turned it on
#
# Run it from an unpacked release or a checkout: it reads python/, bin/ and
# files/ next to this script. See docs/lambda-stack-findings.md for why each
# step is done the way it is.
set -euo pipefail
# apt translates the output this script parses ("Candidate:", ...).
export LC_ALL=C.UTF-8

SGS_VERSION="0.1.1"
SGS_PREFIX="/opt/sgs"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NVIDIA R580 is the long-term support branch, supported until June 2028.
# Lambda Stack pins R570, which is end of life.
DRIVER_BRANCH="580"
# CUDA 13.0 is the toolkit release matched to R580.
CUDA_TOOLKIT_PKG="cuda-toolkit-13-0"
CUDA_TAG="cuda13.0"

# Signing keys, pinned by full fingerprint. A downloaded key that doesn't match
# is refused, so a tampered download can't become a trusted key.
NVIDIA_CUDA_KEY_FPR="EB693B3035CD5710E231E123A4B469963BF863CC"
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

WITH_DRIVER=1
WITH_CUDA_TOOLKIT=1
WITH_DOCKER=1
WITH_HARDENING=1
WITH_LOCKDOWN=1
TARGET_USER=""
NEED_REBOOT=0

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Ubuntu's daily apt jobs and unattended-upgrades often run right after boot,
# when cloud-init runs this installer, and apt gives up at once if one holds
# its lock (exit 100; it happened on krabs). Wait for them, up to 20 minutes;
# DPkg::Lock::Timeout covers one that starts in between.
wait_for_apt() {
  command -v fuser >/dev/null || return 0
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
              /var/cache/apt/archives/lock >/dev/null 2>&1; do
    [ "$n" -gt 0 ] || info "Waiting for another apt run (Ubuntu's automatic updates) to finish..."
    n=$((n + 1))
    # fuser also lists a process that merely has a lock file open; after 20
    # minutes, let apt's own lock timeout decide.
    if [ "$n" -ge 240 ]; then info "Still busy after 20 minutes; trying anyway"; return 0; fi
    sleep 5
  done
}
apt_get() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@"
}
apt_install() {
  apt_get install -y -q --no-install-recommends "$@"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) TARGET_USER="${2:?--user needs a name}"; shift ;;
      --no-driver) WITH_DRIVER=0 ;;
      --no-cuda-toolkit) WITH_CUDA_TOOLKIT=0 ;;
      --no-docker) WITH_DOCKER=0 ;;
      --no-hardening) WITH_HARDENING=0 ;;
      --no-lockdown) WITH_LOCKDOWN=0 ;;
      -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

preflight() {
  log "Checking this machine"
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"

  . /etc/os-release
  [ "$ID" = ubuntu ] && [ "$VERSION_ID" = "24.04" ] \
    || die "Secure GPU Stack supports Ubuntu 24.04 only (found ${PRETTY_NAME})."

  case "$(dpkg --print-architecture)" in
    amd64) ARCH=amd64; PY_ARCH=x86_64;  CUDA_REPO_ARCH=x86_64 ;;
    arm64) ARCH=arm64; PY_ARCH=aarch64; CUDA_REPO_ARCH=sbsa ;;
    *) die "Unsupported CPU architecture: $(dpkg --print-architecture)" ;;
  esac

  # Lambda's pin (priority 1001) overrides every other package source, so the
  # two stacks can't be mixed safely. Detected by its package and by its
  # repository, whatever the files are called.
  if dpkg-query -W -f='${Status}' lambda-repository 2>/dev/null | grep -q 'ok installed' \
     || grep -rqsF 'lambdalabs.com' /etc/apt/sources.list /etc/apt/sources.list.d/ /etc/apt/preferences /etc/apt/preferences.d/; then
    die "Lambda Stack's package repository is set up on this machine. Its apt pin overrides other sources, so the two stacks can't be mixed. Start from Lambda's plain 'Ubuntu Server 24.04' image instead."
  fi

  if [ -z "$TARGET_USER" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then TARGET_USER="$SUDO_USER"
    elif id ubuntu >/dev/null 2>&1; then TARGET_USER=ubuntu
    fi
  fi
  [ -z "$TARGET_USER" ] || id "$TARGET_USER" >/dev/null 2>&1 || die "No such user: $TARGET_USER"
  # Jupyter for root would hand notebook code every key and credential on the box.
  [ -z "$TARGET_USER" ] || [ "$(id -u "$TARGET_USER")" != 0 ] || die "--user can't be root: Jupyter would run as root"

  for f in "python/lock-${PY_ARCH}.txt" "python/tools-lock-${PY_ARCH}.txt" "python/tf-cuda12-lock-${PY_ARCH}.txt" \
           bin/sgs-check bin/sgs-venv bin/sgs-jupyter bin/sgs-sbom bin/sgs-egress files/apt-pin-nvidia-cuda files/apt-pin-nccl \
           files/egress-allow files/sgs-egress-dns.service files/sgs-egress.service files/sgs-guard.nft files/sgs-guard.service \
           files/grub-60-sgs-lockdown.cfg \
           files/sgs_cuda_preload.py files/sgs-cuda-preload.pth files/sysctl-60-sgs.conf \
           files/modprobe-sgs-nvidia.conf files/docker-daemon.json files/sshd-10-sgs.conf files/profile-sgs.sh \
           files/motd-60-sgs files/sgs-check.service files/sgs-check.timer files/sgs-jupyter@.service files/sgs-gpu-devices files/72-sgs-nvidia-devices.rules files/nvidia-cdi-refresh-sgs.conf \
           files/sgs-gpu-devices.service files/nvidia-persistenced-sgs.conf files/ub-device-create; do
    [ -f "$SRC_DIR/$f" ] || die "Missing $f next to install.sh. Run it from an unpacked release."
  done

  # Entries for these repositories with other keys (Docker's guide, NVIDIA's
  # cuda-keyring) can already clash with each other, or with ours on a re-run,
  # and apt then refuses to run at all. setup_sources adds ours with a
  # fingerprint-checked key.
  disable_duplicate_sources "developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/" \
    /etc/apt/sources.list.d/sgs-nvidia-cuda.sources
  if [ "$WITH_DOCKER" = 1 ]; then
    disable_duplicate_sources "download.docker.com/linux/ubuntu" /etc/apt/sources.list.d/sgs-docker.sources
  fi
  apt_get update -q
  apt_install ca-certificates curl gnupg pciutils

  # NVIDIA GPUs are PCI class 03xx. NVSwitch bridges (multi-GPU servers) need
  # Fabric Manager. GPUs before Turing (device ID below 0x1e00) need the
  # closed-source kernel modules; Turing and newer use the open ones.
  local gpu_ids
  gpu_ids=$(lspci -mn -d 10de: | awk '$2 ~ /^"03/ { gsub(/"/, "", $4); print $4 }')
  GPU_COUNT=$(printf '%s' "$gpu_ids" | grep -c . || true)
  HAS_NVSWITCH=0
  lspci -mn -d 10de: | awk '{ gsub(/"/, "", $4); print $4 }' | grep -qiE '^(1ac2|1af1|22a3)$' && HAS_NVSWITCH=1
  DRIVER_VARIANT="server-open"
  for id in $gpu_ids; do
    if [ $((16#$id)) -lt $((16#1e00)) ]; then DRIVER_VARIANT="server"; fi
  done

  # Prebuilt driver modules come per kernel line: GA ("generic") or HWE
  # ("generic-hwe-24.04", the default on recent desktop installs). Using the GA
  # package on an HWE machine pulls in an older kernel and leaves the newest
  # one, which boots by default, without a driver. The flavour is everything
  # after "X.Y.Z-N-": "generic", but also "generic-64k" or "nvidia-64k" (arm64).
  KERNEL_FLAVOUR="$(uname -r | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-//')"
  if dpkg-query -W -f='${Status}' "linux-image-${KERNEL_FLAVOUR}-hwe-${VERSION_ID}" 2>/dev/null | grep -q 'ok installed'; then
    KERNEL_FLAVOUR="${KERNEL_FLAVOUR}-hwe-${VERSION_ID}"
  fi

  info "Ubuntu ${VERSION_ID} on ${ARCH}, kernel $(uname -r) (${KERNEL_FLAVOUR} line)"
  info "NVIDIA GPUs found: ${GPU_COUNT}$([ "$HAS_NVSWITCH" = 1 ] && echo ', with NVSwitch')"
  info "Jupyter user: ${TARGET_USER:-none}"

  # R580 still drives pre-Turing GPUs (Maxwell, Pascal, Volta), but CUDA 13
  # dropped them, so the CUDA 13 builds of PyTorch and JAX have no code for
  # them. TensorFlow's CUDA 12 build still covers Pascal and Volta, except for
  # convolutions: cuDNN 9.27 has no kernels for them (tested on krabs, a GTX
  # 1070). Lambda serves its V100s with a separate "Legacy" image for this reason.
  if [ "$DRIVER_VARIANT" = server ]; then
    info "Note: this GPU predates Turing (2018). The driver, nvidia-smi and GPU"
    info "containers work. PyTorch and JAX (CUDA 13) can't use it and run on the"
    info "CPU; TensorFlow (CUDA 12) can, except for convolutions."
  fi
}

# Download a signing key, check it is exactly one key with the expected
# fingerprint, and store it where only its own repository uses it (signed-by),
# instead of apt's global trust directory.
install_key() {
  local name="$1" url="$2" want="$3" tmp got count
  tmp="$(mktemp -d)"
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp/key"
  count=$(gpg --show-keys --with-colons "$tmp/key" 2>/dev/null | grep -c '^pub' || true)
  got=$(gpg --show-keys --with-colons "$tmp/key" 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }')
  [ "$count" = 1 ] && [ "$got" = "$want" ] \
    || die "Signing key for $name doesn't match (got ${count} key(s), fingerprint ${got:-none}; expected $want). Refusing to trust it."
  install -d -m 0755 /etc/apt/keyrings
  gpg --dearmor < "$tmp/key" > "/etc/apt/keyrings/sgs-${name}.gpg"
  chmod 0644 "/etc/apt/keyrings/sgs-${name}.gpg"
  rm -rf "$tmp"
  info "$name key verified: $want"
}

# A second entry for the same repository with a different key makes apt refuse
# to run ("Conflicting values set for option Signed-By"). Docker's install guide
# and NVIDIA's cuda-keyring package both create one, so move such files aside.
# Ours points at the same repository, with a fingerprint-checked key.
disable_duplicate_sources() {
  local repo="$1" ours="$2" f
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$f" ] && [ "$f" != "$ours" ] || continue
    grep -qF "$repo" "$f" || continue
    mv "$f" "$f.disabled"
    info "Moved aside $f (same repository as $ours)"
  done
}

setup_sources() {
  log "Adding package sources (HTTPS, each with its own verified key)"
  disable_duplicate_sources "developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/" \
    /etc/apt/sources.list.d/sgs-nvidia-cuda.sources
  install_key nvidia-cuda \
    "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${CUDA_REPO_ARCH}/3bf863cc.pub" \
    "$NVIDIA_CUDA_KEY_FPR"
  cat > /etc/apt/sources.list.d/sgs-nvidia-cuda.sources <<EOF
# Secure GPU Stack: NVIDIA CUDA toolkit, cuDNN, NCCL and Container Toolkit.
Types: deb
URIs: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${CUDA_REPO_ARCH}/
Suites: /
Signed-By: /etc/apt/keyrings/sgs-nvidia-cuda.gpg
EOF
  install -m 0644 "$SRC_DIR/files/apt-pin-nvidia-cuda" /etc/apt/preferences.d/sgs-nvidia-cuda
  install -m 0644 "$SRC_DIR/files/apt-pin-nccl" /etc/apt/preferences.d/sgs-nccl

  if [ "$WITH_DOCKER" = 1 ]; then
    disable_duplicate_sources "download.docker.com/linux/ubuntu" /etc/apt/sources.list.d/sgs-docker.sources
    install_key docker "https://download.docker.com/linux/ubuntu/gpg" "$DOCKER_KEY_FPR"
    cat > /etc/apt/sources.list.d/sgs-docker.sources <<EOF
# Secure GPU Stack: Docker Engine from Docker's official repository.
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/sgs-docker.gpg
EOF
  fi
  apt_get update -q
}

harden() {
  [ "$WITH_HARDENING" = 1 ] || { log "Skipping hardening (--no-hardening)"; return; }
  log "Hardening SSH, the firewall and automatic updates"
  local had_sshd=""
  dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'ok installed' && had_sshd=1
  apt_install openssh-server ufw unattended-upgrades auditd

  # Turn off password logins only if someone can still get in with a key, so
  # this can't lock the owner out. If the SSH server is new here, nobody can be
  # relying on its password logins, so it starts keys-only either way.
  local keys="" home
  if [ -n "$TARGET_USER" ]; then
    home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [ -s "$home/.ssh/authorized_keys" ] && keys=1
  fi
  if [ -n "$keys" ] || [ -z "$had_sshd" ]; then
    install -m 0644 "$SRC_DIR/files/sshd-10-sgs.conf" /etc/ssh/sshd_config.d/10-sgs.conf
    if sshd -t 2>/dev/null || { mkdir -p /run/sshd && sshd -t; }; then
      systemctl try-reload-or-restart ssh
      info "SSH: keys only, no root login"
      [ -n "$keys" ] || info "SSH: ${TARGET_USER:-the target user} has no authorized keys yet; add one to log in with SSH"
    else
      rm -f /etc/ssh/sshd_config.d/10-sgs.conf
      info "SSH: config check failed, left SSH unchanged"
    fi
  else
    info "SSH: left unchanged, because ${TARGET_USER:-the target user} has no authorized SSH keys"
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  # sshd may listen on another port as well; opening only 22 would lock the
  # owner out the moment the firewall turns on.
  local port
  mkdir -p /run/sshd
  for port in $(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'); do
    [ "$port" = 22 ] || ufw allow "${port}/tcp" >/dev/null
  done
  # Tailscale peers are devices the owner has already authenticated, and the
  # tailnet's access policy filters them. Blocking them would break Tailscale
  # SSH and every service the owner reaches over it, without adding protection.
  local allowed="SSH"
  if ip link show tailscale0 >/dev/null 2>&1; then
    ufw allow in on tailscale0 >/dev/null
    allowed="SSH and Tailscale"
  fi
  ufw --force enable >/dev/null
  info "Firewall: incoming blocked except ${allowed}"

  # Daily security updates, including the NVIDIA driver from noble-security.
  # A driver update applies fully after a reboot; sgs-check reports when one is due.
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  # Unattended upgrades only take Ubuntu's own packages by default, so fixes for
  # Docker and NVIDIA's packages (the Container Toolkit has had container-escape
  # CVEs) would never install themselves. NVIDIA's driver packages stay blocked
  # by the apt pin; the driver comes from Ubuntu.
  cat > /etc/apt/apt.conf.d/52sgs-unattended-upgrades <<'EOF'
// Secure GPU Stack: also update Docker and NVIDIA's CUDA, cuDNN, NCCL and
// Container Toolkit packages automatically. The labels are matched exactly:
// a first version said "Docker" and "NVIDIA" and matched nothing.
Unattended-Upgrade::Origins-Pattern {
        "origin=Docker,label=Docker CE";
        "origin=NVIDIA,label=NVIDIA CUDA";
};
EOF
  # apt's daily jobs are oneshot units, which systemd never times out. On the
  # krabs test bench one hung download held apt's lock for 99 days, and no
  # security update ran in that time while the settings above still said "on".
  # The upgrade job gets longer: it may have to build a driver module.
  local unit limit
  for unit in apt-daily:1h apt-daily-upgrade:4h; do
    limit="${unit#*:}"; unit="${unit%%:*}"
    install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
    printf '[Service]\nTimeoutStartSec=%s\n' "$limit" > "/etc/systemd/system/${unit}.service.d/sgs-timeout.conf"
  done
  systemctl daemon-reload
  systemctl enable --now auditd >/dev/null 2>&1 || true
  info "Automatic security updates (with time limits) and audit logging on"

  # Pin kernel settings, but never loosen a stricter value already in place (a
  # hardening role may have set ptrace_scope=2) and never stop the install over
  # one: the kernel refuses unprivileged_bpf_disabled=2 once it's 1, which is
  # the stricter, one-way setting.
  local line key want have opt
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) echo "$line"; continue ;;
    esac
    key="$(echo "${line%%=*}" | tr -d ' ')"; want="$(echo "${line#*=}" | tr -d ' ')"
    # A leading "-" tells systemd-sysctl to skip a key this kernel doesn't have.
    opt=""; case "$key" in -*) opt=-; key="${key#-}" ;; esac
    have="$(sysctl -n "$key" 2>/dev/null || echo "$want")"
    # Higher is stricter, except where the wanted value is 0 (ldisc autoload,
    # ICMP redirects): those are set as written.
    if [ "$key" = kernel.unprivileged_bpf_disabled ] && [ "$have" = 1 ]; then want=1
    elif [ "$want" != 0 ] && [ "$have" -gt "$want" ] 2>/dev/null; then want="$have"; fi
    echo "$opt$key = $want"
    # The loop's output is the config file: messages go to stderr.
    [ "$have" = "$want" ] || sysctl -q -w "$key=$want" >/dev/null 2>&1 || info "Couldn't set $key to $want" >&2
  done < "$SRC_DIR/files/sysctl-60-sgs.conf" > /etc/sysctl.d/60-sgs.conf
  chmod 0644 /etc/sysctl.d/60-sgs.conf
  # The glob keys (every network interface) apply through systemd-sysctl.
  /usr/lib/systemd/systemd-sysctl /etc/sysctl.d/60-sgs.conf >/dev/null 2>&1 \
    || info "Couldn't apply every setting in /etc/sysctl.d/60-sgs.conf now; they apply at the next boot"
  # apport, Ubuntu's crash reporter, writes fs.suid_dumpable=2 when it starts at
  # boot, after systemd-sysctl: the pin lasted until the first reboot (M2 test
  # bench, a fresh cloud image). Put 0 back once it has started; apport still
  # collects ordinary crashes.
  install -d -m 0755 /etc/systemd/system/apport.service.d
  printf '[Service]\nExecStartPost=/usr/sbin/sysctl -q -w fs.suid_dumpable=0\n' \
    > /etc/systemd/system/apport.service.d/sgs-suid-dumpable.conf
  systemctl daemon-reload
  info "Kernel hardening settings pinned (/etc/sysctl.d/60-sgs.conf)"

  # Apply the security updates already waiting, instead of leaving them for
  # tomorrow's automatic run.
  wait_for_apt
  if unattended-upgrade >/dev/null 2>&1; then
    info "Pending security updates applied"
  else
    info "Couldn't apply pending security updates now; the daily run will retry"
  fi
  # An if, not `[ ] && ...`: as a function's last command, a false test would be
  # its exit status, and set -e would stop the install (it did, once).
  if [ -f /var/run/reboot-required ]; then NEED_REBOOT=1; fi
}

install_driver() {
  [ "$WITH_DRIVER" = 1 ] || { log "Skipping the NVIDIA driver (--no-driver)"; return; }
  log "NVIDIA driver R${DRIVER_BRANCH} from Ubuntu's archive"

  # Prefer Ubuntu's prebuilt, signed kernel modules. Fall back to building
  # them with DKMS if this kernel flavour has none.
  local modules="linux-modules-nvidia-${DRIVER_BRANCH}-${DRIVER_VARIANT}-${KERNEL_FLAVOUR}"
  local headers pkgs=()
  if apt-cache show "$modules" >/dev/null 2>&1; then
    # The prebuilt modules are linked against their kernel during install,
    # with tools from its headers package (objtool, module.lds), but don't
    # depend on it. The headers meta package for this kernel line tracks the
    # same kernel version as the modules meta package.
    headers="linux-headers-${KERNEL_FLAVOUR}"
    pkgs=("$modules" "nvidia-headless-no-dkms-${DRIVER_BRANCH}-${DRIVER_VARIANT}" "nvidia-utils-${DRIVER_BRANCH}-server")
  else
    headers="linux-headers-$(uname -r)"
    pkgs=("nvidia-headless-${DRIVER_BRANCH}-${DRIVER_VARIANT}" "nvidia-utils-${DRIVER_BRANCH}-server")
    # DKMS builds the module here, unsigned: Secure Boot won't load it until
    # the DKMS key is enrolled with the firmware (MOK), which needs someone at
    # the console. Say so now, not after the reboot.
    if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
      info "Warning: no prebuilt driver for the ${KERNEL_FLAVOUR} kernel, so DKMS builds an unsigned one, and"
      info "Secure Boot is on: the driver won't load until its key is enrolled (mokutil --import)."
    fi
  fi
  [ "$HAS_NVSWITCH" = 1 ] && pkgs+=("nvidia-fabricmanager-${DRIVER_BRANCH}")

  if [ "$GPU_COUNT" -eq 0 ]; then
    info "No NVIDIA GPU here, so the driver isn't installed. Checking it would resolve:"
    apt-get install -s -y --no-install-recommends "$headers" "${pkgs[@]}" >/dev/null \
      || die "The driver packages don't resolve: $headers ${pkgs[*]}"
    info "OK: $headers ${pkgs[*]}"
    return
  fi

  # Before the packages, so the initramfs they build includes it.
  local vgid
  vgid="$(getent group video | cut -d: -f3)"
  [ -n "$vgid" ] || die "There's no video group to give the GPU device files to"
  install -m 0644 "$SRC_DIR/files/modprobe-sgs-nvidia.conf" /etc/modprobe.d/sgs-nvidia.conf
  if [ "$vgid" != 44 ]; then
    sed -i "s/NVreg_DeviceFileGID=44 /NVreg_DeviceFileGID=$vgid /" /etc/modprobe.d/sgs-nvidia.conf
    grep -q "NVreg_DeviceFileGID=$vgid " /etc/modprobe.d/sgs-nvidia.conf || die "Couldn't set the video gid in /etc/modprobe.d/sgs-nvidia.conf"
  fi
  # Headers first, in their own step, so they're in place when the module
  # packages' setup scripts run.
  apt_install "$headers"
  apt_install "${pkgs[@]}"
  if [ "$HAS_NVSWITCH" = 1 ]; then
    systemctl enable "nvidia-fabricmanager" >/dev/null 2>&1 \
      || info "WARNING: couldn't enable nvidia-fabricmanager; multi-GPU CUDA fails without it"
  fi
  # A reboot is only needed if the loaded driver isn't the one just installed.
  local loaded installed
  loaded="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
  installed="$(dpkg-query -W -f='${Version}' "nvidia-utils-${DRIVER_BRANCH}-server" 2>/dev/null | cut -d- -f1)"
  [ -n "$loaded" ] && [ "$loaded" = "$installed" ] || NEED_REBOOT=1
  # The device-file settings only apply when the module loads.
  grep -qx "DeviceFileMode: 432" /proc/driver/nvidia/params 2>/dev/null \
    && grep -qx "DeviceFileGID: $vgid" /proc/driver/nvidia/params || NEED_REBOOT=1
  info "Installed: $headers ${pkgs[*]}"

  # GPU device files for the video group only: Ubuntu creates them 0666, open
  # to every local user and service account. Four things recreate them, so
  # sgs-gpu-devices sets them root:video 0660 and locks them with a read-only
  # bind mount (files/sgs-gpu-devices has why). udev starts it when the driver
  # loads, the drop-in after every nvidia-cdi-refresh run, and it runs now.
  # The Jupyter user and the persistence daemon get video; GPU containers keep
  # working.
  install -m 0755 "$SRC_DIR/files/sgs-gpu-devices" /usr/local/sbin/sgs-gpu-devices
  install -m 0644 "$SRC_DIR/files/sgs-gpu-devices.service" /etc/systemd/system/sgs-gpu-devices.service
  # Ubuntu's ub-device-create creates them 0666 when the driver loads; a
  # process waiting for them got one open 10 times out of 10. dpkg-divert
  # keeps the original (and its updates) aside, under .distrib.
  if [ -e /sbin/ub-device-create ]; then
    if [ "$(dpkg-divert --truename /sbin/ub-device-create)" = /sbin/ub-device-create ]; then
      dpkg-divert --quiet --local --rename --divert /sbin/ub-device-create.distrib --add /sbin/ub-device-create
    fi
    install -m 0755 "$SRC_DIR/files/ub-device-create" /sbin/ub-device-create
  fi
  install -d -m 0755 /etc/systemd/system/nvidia-cdi-refresh.service.d /etc/systemd/system/nvidia-persistenced.service.d
  install -m 0644 "$SRC_DIR/files/nvidia-cdi-refresh-sgs.conf" /etc/systemd/system/nvidia-cdi-refresh.service.d/sgs-gpu-devices.conf
  install -m 0644 "$SRC_DIR/files/nvidia-persistenced-sgs.conf" /etc/systemd/system/nvidia-persistenced.service.d/sgs-gpu-devices.conf
  systemctl daemon-reload
  install -m 0644 "$SRC_DIR/files/72-sgs-nvidia-devices.rules" /etc/udev/rules.d/72-sgs-nvidia-devices.rules
  udevadm control --reload-rules >/dev/null 2>&1 || true
  /usr/local/sbin/sgs-gpu-devices || die "Couldn't limit the GPU device files to the video group"
  [ -z "$TARGET_USER" ] || usermod -aG video "$TARGET_USER"
  # Restart the persistence daemon with the video group (its drop-in).
  if systemctl is-active --quiet nvidia-persistenced.service \
     || systemctl is-failed --quiet nvidia-persistenced.service; then
    systemctl restart nvidia-persistenced.service >/dev/null 2>&1 \
      || info "WARNING: nvidia-persistenced didn't restart (journalctl -u nvidia-persistenced)"
  fi
  info "GPU device files: video group only${TARGET_USER:+ (${TARGET_USER} added to video)}"

  # Packages left from another driver branch (krabs had R535 libraries) are
  # held back for good: their updates need the rest of that branch. They'd
  # never get their security fixes, so they go.
  local old
  old=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-*' 'libnvidia-*' \
          'linux-modules-nvidia-*' 'linux-objects-nvidia-*' 'xserver-xorg-video-nvidia-*' 2>/dev/null \
        | awk '$1 ~ /^(ii|rc)/ { print $2 }' | grep -E -- '-[0-9]{3}(-|$)' \
        | grep -vE -- "-${DRIVER_BRANCH}(-|$)" || true)
  if [ -n "$old" ]; then
    # Only if nothing else goes with them: apt would also remove whatever
    # depends on these, such as a desktop's display driver or a cuda meta-package.
    local extra
    # shellcheck disable=SC2086
    extra=$(apt-get purge -s $old 2>/dev/null | awk '/^(Purg|Remv) / { print $2 }' \
              | grep -vxF -f <(echo "$old") || true)
    if [ -n "$extra" ]; then
      info "Left $(echo "$old" | wc -l) packages from another driver branch in place:"
      info "removing them would also remove $(echo $extra)"
    else
      # shellcheck disable=SC2086
      apt_get purge -y -q $old >/dev/null
      info "Removed $(echo "$old" | wc -l) packages left from another driver branch"
    fi
  fi
}

# Kernel lockdown (integrity): Secure Boot turns it on; without it, the kernel
# command line does (files/grub-60-sgs-lockdown.cfg has why). After the driver,
# which can fall back to a DKMS build: DKMS modules are unsigned, lockdown
# refuses them, and the GPU would be gone after the reboot.
setup_lockdown() {
  [ "$WITH_HARDENING" = 1 ] || return 0
  local cfg=/etc/default/grub.d/60-sgs-lockdown.cfg lockdown on=0 dkms_mods="" why=""
  lockdown=$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null || true)
  case "$lockdown" in integrity|confidentiality) on=1 ;; esac
  if command -v dkms >/dev/null; then dkms_mods=$(dkms status 2>/dev/null | cut -d, -f1 | cut -d/ -f1 | sort -u | paste -sd' ' -); fi
  [ "$WITH_LOCKDOWN" = 1 ] || why="--no-lockdown"
  [ -z "$dkms_mods" ] || why="DKMS modules ($dkms_mods) are unsigned, and lockdown would refuse them"
  # On from Secure Boot, with no file of ours: nothing to add or take out.
  if [ ! -f "$cfg" ] && [ "$on" = 1 ] && ! grep -q 'lockdown=' /proc/cmdline; then
    info "Kernel lockdown is on ($lockdown, from Secure Boot)"
    [ -z "$dkms_mods" ] || info "DKMS modules ($dkms_mods) load only once their key is enrolled: sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"
    [ "$WITH_LOCKDOWN" = 1 ] || info "--no-lockdown can't turn it off: Secure Boot does that"
    return 0
  fi
  if [ -n "$why" ]; then
    # Take ours back out, also when a DKMS module arrived after an earlier run.
    if [ -f "$cfg" ]; then
      rm -f "$cfg"
      update-grub >/dev/null 2>&1 || info "WARNING: couldn't update GRUB after removing $cfg"
    fi
    if grep -qs 'lockdown=' /etc/default/grub /etc/default/grub.d/*.cfg; then
      info "Kernel lockdown is set in this machine's own GRUB settings (/etc/default/grub), so it stays"
    elif grep -q 'lockdown=' /proc/cmdline; then
      NEED_REBOOT=1
      info "Kernel lockdown turns off at the next boot: $why"
    elif [ "$on" = 0 ]; then
      info "Kernel lockdown left off: $why"
    fi
    return 0
  fi
  if [ ! -d /etc/default/grub.d ] || ! command -v update-grub >/dev/null; then
    info "Kernel lockdown left off: no GRUB here to set it on the kernel command line"
    return 0
  fi
  cmp -s "$SRC_DIR/files/grub-60-sgs-lockdown.cfg" "$cfg" || install -m 0644 "$SRC_DIR/files/grub-60-sgs-lockdown.cfg" "$cfg"
  # Only a boot menu that has it counts. Otherwise take the file back out, so
  # a later kernel update can't turn it on unexpectedly.
  if ! grep -qs 'lockdown=integrity' /boot/grub/grub.cfg; then
    if ! update-grub >/dev/null 2>&1 || ! grep -qs 'lockdown=integrity' /boot/grub/grub.cfg; then
      rm -f "$cfg"
      update-grub >/dev/null 2>&1 || true
      info "WARNING: couldn't add kernel lockdown to GRUB's boot menu; left off"
      return 0
    fi
  fi
  if [ "$on" = 1 ]; then
    info "Kernel lockdown is on ($lockdown)"
  else
    NEED_REBOOT=1
    info "Kernel lockdown (integrity) turns on at the next boot"
  fi
}

install_cuda_toolkit() {
  [ "$WITH_CUDA_TOOLKIT" = 1 ] || { log "Skipping the CUDA toolkit (--no-cuda-toolkit)"; return; }
  log "CUDA toolkit, cuDNN and NCCL from NVIDIA's repository"
  # files/apt-pin-nccl steers NCCL to its CUDA 13.0 builds; make sure one exists.
  local nccl_ver
  nccl_ver="$(apt-cache policy libnccl2 | awk '/Candidate:/ { print $2 }')"
  case "$nccl_ver" in
    *"+${CUDA_TAG}") ;;
    *) die "No NCCL build for ${CUDA_TAG} in NVIDIA's repository (candidate: ${nccl_ver:-none})" ;;
  esac
  apt_install "$CUDA_TOOLKIT_PKG" libcudnn9-cuda-13 libcudnn9-dev-cuda-13 libnccl2 libnccl-dev
  info "Installed ${CUDA_TOOLKIT_PKG}, cuDNN 9, NCCL ${nccl_ver}"
}

install_docker() {
  [ "$WITH_DOCKER" = 1 ] || { log "Skipping Docker (--no-docker)"; return; }
  log "Docker Engine and the NVIDIA Container Toolkit"
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    nvidia-container-toolkit

  # Published container ports bind to localhost unless asked otherwise, on the
  # default network and on networks created later (docker compose makes its
  # own). Docker writes its own firewall rules, so without this a published
  # port would be open to the internet even with ufw blocking incoming traffic.
  # The stack's settings are merged into an existing daemon.json, so a re-run
  # keeps the owner's own settings, such as a data-root on another disk.
  install -d -m 0755 /etc/docker
  python3 -I - "$SRC_DIR/files/docker-daemon.json" /etc/docker/daemon.json <<'EOF' \
    || die "/etc/docker/daemon.json isn't valid JSON; fix or remove it and re-run"
import json, os, sys
ours, path = json.load(open(sys.argv[1])), sys.argv[2]
current = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
current.update(ours)
# "nvidia" as the default runtime gives every container the GPU and the
# toolkit's host-side hooks without asking (the NVIDIAScape path), so it goes.
if current.get("default-runtime") == "nvidia":
    del current["default-runtime"]
    print("    Removed \"default-runtime\": \"nvidia\" from daemon.json; use --gpus or --device")
with open(path + ".sgs-new", "w") as f:
    json.dump(current, f, indent=2)
    f.write("\n")
os.chmod(path + ".sgs-new", 0o644)
os.replace(path + ".sgs-new", path)
EOF
  nvidia-ctk runtime configure --runtime=docker >/dev/null
  systemctl restart docker
  # The GPU device spec (CDI) lists the host files mounted into GPU containers
  # and is generated at boot. After driver packages change it can name files
  # that are gone, and then every GPU container fails to start (seen on krabs).
  if [ "$GPU_COUNT" -gt 0 ]; then
    systemctl restart nvidia-cdi-refresh.service >/dev/null 2>&1 \
      || nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml >/dev/null 2>&1 || true
  fi
  # The docker group is root-equivalent, so nobody is added to it. Use sudo docker.
  # Existing members are reported, not removed: they may depend on it.
  local members
  members="$(getent group docker | cut -d: -f4)"
  info "Docker $(docker --version | awk '{print $3}' | tr -d ,), Container Toolkit $(nvidia-ctk --version | awk 'NR==1 {print $NF}')"
  info "Container ports publish to 127.0.0.1 by default"
  if [ -n "$members" ]; then
    info "Already in the docker group (root-equivalent): ${members}. Remove with: sudo gpasswd -d USER docker"
  else
    info "Nobody is in the docker group; use sudo docker"
  fi
}

# Create a root-owned environment from a hash-locked file. Only wheels are
# accepted, so no package build script runs during the install. A changed
# lockfile gets a fresh environment, because pip never removes packages a
# lockfile dropped; the old one is put back if the new one fails to build.
# With "target" as the third argument it's a plain library folder (pip
# --target) instead of a virtual environment.
make_venv() {
  local dir="$1" lock="$2" kind="${3:-venv}" sum ok=1
  local opts=(-q --no-cache-dir --disable-pip-version-check --require-hashes --only-binary :all: --no-deps -r "$lock")
  sum="$(sha256sum "$lock" | cut -d' ' -f1)"
  # A run interrupted mid-build left the previous environment in $dir.old and an
  # unfinished one (no marker yet) in $dir. Put the previous one back first.
  if [ -e "$dir.old" ] && [ ! -e "$dir/.sgs-lock-sha256" ]; then
    rm -rf "$dir"; mv "$dir.old" "$dir"
  fi
  rm -rf "$dir.old"
  [ "$(cat "$dir/.sgs-lock-sha256" 2>/dev/null)" = "$sum" ] && return 0
  if [ -e "$dir" ]; then mv "$dir" "$dir.old"; fi
  if [ "$kind" = target ]; then
    "$SGS_PREFIX/venv/bin/python" -m pip install --target "$dir" "${opts[@]}" || ok=0
  else
    { python3 -m venv "$dir" && "$dir/bin/python" -m pip install "${opts[@]}"; } || ok=0
  fi
  if [ "$ok" = 0 ]; then
    rm -rf "$dir"
    if [ -e "$dir.old" ]; then mv "$dir.old" "$dir"; fi
    die "Installing $lock failed; the previous $dir is unchanged"
  fi
  echo "$sum" > "$dir/.sgs-lock-sha256"
  rm -rf "$dir.old"
  chown -R root:root "$dir"
  chmod -R go-w "$dir"
}

install_python() {
  log "Python ML stack in ${SGS_PREFIX}/venv (hash-verified wheels only)"
  apt_install python3-venv python3-dev build-essential git
  install -d -m 0755 "$SGS_PREFIX"
  make_venv "$SGS_PREFIX/venv" "$SRC_DIR/python/lock-${PY_ARCH}.txt"
  info "$("$SGS_PREFIX/venv/bin/python" -m pip list --format=freeze 2>/dev/null \
    | grep -iE '^(torch|tensorflow|keras|jax|jupyterlab)==' | tr '\n' ' ')"

  # TensorFlow is built for CUDA 12, PyTorch and JAX for CUDA 13. Their cuDNN
  # and NCCL wheels write the same files, so TensorFlow's CUDA 12 libraries get
  # their own folder, and a hook loads them when tensorflow is imported.
  log "TensorFlow's CUDA 12 libraries in ${SGS_PREFIX}/tf-cuda12"
  make_venv "$SGS_PREFIX/tf-cuda12" "$SRC_DIR/python/tf-cuda12-lock-${PY_ARCH}.txt" target
  # TensorFlow's cuDNN opens sub-libraries by their full version
  # (libcudnn_graph.so.9.27.0), but the wheel names them only .so.9. Its own
  # folder is searched first, so give the files those names too: otherwise the
  # system-wide CUDA 13 cuDNN of the same version answers, the two builds mix,
  # and every TensorFlow convolution fails ("cudnn status 1008", M2 test bench).
  local cudnn_dir="$SGS_PREFIX/tf-cuda12/nvidia/cudnn/lib" cudnn_ver lib
  cudnn_ver="$(sed -n 's/^Version: \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$SGS_PREFIX"/tf-cuda12/nvidia_cudnn_cu12-*.dist-info/METADATA)"
  [ -n "$cudnn_ver" ] || die "Couldn't read the version of TensorFlow's cuDNN in $SGS_PREFIX/tf-cuda12"
  for lib in "$cudnn_dir"/libcudnn*.so."${cudnn_ver%%.*}"; do
    ln -sfn "${lib##*/}" "$lib.${cudnn_ver#*.}"
  done
  local site
  site="$("$SGS_PREFIX/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  install -m 0644 "$SRC_DIR/files/sgs_cuda_preload.py" "$SRC_DIR/files/sgs-cuda-preload.pth" "$site/"
  info "Loaded for TensorFlow only (files/sgs_cuda_preload.py)"

  log "Security tools in ${SGS_PREFIX}/tools (pip-audit, modelscan)"
  make_venv "$SGS_PREFIX/tools" "$SRC_DIR/python/tools-lock-${PY_ARCH}.txt"
  ln -sf "$SGS_PREFIX/tools/bin/modelscan" /usr/local/bin/modelscan

  install -m 0644 "$SRC_DIR/files/profile-sgs.sh" /etc/profile.d/sgs.sh
}

install_commands() {
  log "Commands and the Jupyter service"
  install -m 0755 "$SRC_DIR/bin/sgs-check" "$SRC_DIR/bin/sgs-venv" "$SRC_DIR/bin/sgs-jupyter" "$SRC_DIR/bin/sgs-sbom" /usr/local/bin/
  install -m 0755 "$SRC_DIR/files/motd-60-sgs" /etc/update-motd.d/60-sgs
  install -m 0644 "$SRC_DIR/files/sgs-jupyter@.service" /etc/systemd/system/sgs-jupyter@.service
  # The daily posture check; the login message shows its latest result.
  install -m 0644 "$SRC_DIR/files/sgs-check.service" "$SRC_DIR/files/sgs-check.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now sgs-check.timer >/dev/null 2>&1 || info "Couldn't enable the daily check (sgs-check.timer)"
  # The optional strict mode for outbound traffic (sgs-egress strict), off until
  # someone turns it on. A re-run keeps it as it was.
  apt_install dnsmasq-base nftables
  id sgs-egress >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sgs-egress
  install -d -m 0755 /etc/sgs
  [ -e /etc/sgs/egress-allow ] || install -m 0644 "$SRC_DIR/files/egress-allow" /etc/sgs/egress-allow
  install -m 0755 "$SRC_DIR/bin/sgs-egress" /usr/local/sbin/sgs-egress
  install -m 0644 "$SRC_DIR/files/sgs-egress-dns.service" "$SRC_DIR/files/sgs-egress.service" /etc/systemd/system/
  systemctl daemon-reload
  # Cloud metadata for root only, always on.
  install -m 0644 "$SRC_DIR/files/sgs-guard.nft" /etc/sgs/guard.nft
  install -m 0644 "$SRC_DIR/files/sgs-guard.service" /etc/systemd/system/sgs-guard.service
  systemctl daemon-reload
  systemctl enable sgs-guard.service >/dev/null 2>&1
  systemctl restart sgs-guard.service || info "WARNING: couldn't load /etc/sgs/guard.nft"
  if [ "$(cat /etc/sgs/egress-mode 2>/dev/null)" = strict ]; then
    /usr/local/sbin/sgs-egress strict >/dev/null || info "WARNING: couldn't restore strict outbound mode (sudo sgs-egress strict)"
  fi
  if [ -n "$TARGET_USER" ]; then
    systemctl enable "sgs-jupyter@${TARGET_USER}" >/dev/null 2>&1 || info "Couldn't enable sgs-jupyter@${TARGET_USER}"
    # Restart, not just start: a re-run may have rebuilt the environment. A
    # Jupyter that won't start mustn't stop the install before the audit rules
    # and the file manifest are written.
    if systemctl restart "sgs-jupyter@${TARGET_USER}"; then
      info "JupyterLab running for ${TARGET_USER} on a private socket (sgs-jupyter shows how to connect)"
    else
      info "JupyterLab didn't start; see: journalctl -u sgs-jupyter@${TARGET_USER}"
    fi
  fi
}

# Record changes to what decides what this machine trusts and runs: package
# sources, sudo, SSH, Docker and the GPU container hooks, kernel settings, the
# stack itself, and kernel module loading. /dev/nvidia* and /var/lib/docker are
# left out: every CUDA program and image pull would flood the log. Only paths
# that exist are watched, because a missing one stops auditd loading the rest.
install_audit_rules() {
  if [ "$WITH_HARDENING" != 1 ]; then log "Skipping audit rules (--no-hardening)"; return 0; fi
  command -v augenrules >/dev/null || return 0
  log "Audit rules for the machine's trust roots"
  local rules=/etc/audit/rules.d/60-sgs.rules entry path
  # The stack's own files that decide what runs: the startup hook in every
  # Python process, the audit command, the Jupyter service. Its ~60,000
  # package files are left to sgs-check's integrity check; watching all of
  # /opt/sgs would flush the audit log on every upgrade.
  local site="$SGS_PREFIX/venv/lib/python3.12/site-packages"
  {
    echo "# Secure GPU Stack (install.sh). Read the log with: sudo ausearch -k sgs-"
    for entry in /etc/apt/:sgs-packages /etc/sudoers:sgs-privilege /etc/sudoers.d/:sgs-privilege \
                 /etc/ssh/sshd_config:sgs-ssh /etc/ssh/sshd_config.d/:sgs-ssh \
                 /etc/docker/:sgs-docker /usr/bin/dockerd:sgs-docker \
                 /etc/nvidia-container-runtime/:sgs-gpu /etc/cdi/:sgs-gpu /var/run/cdi/:sgs-gpu \
                 /etc/udev/rules.d/:sgs-gpu /usr/local/sbin/sgs-gpu-devices:sgs-gpu \
                 /etc/systemd/system/nvidia-cdi-refresh.service.d/:sgs-gpu \
                 /etc/systemd/system/sgs-gpu-devices.service:sgs-gpu /usr/sbin/ub-device-create:sgs-gpu \
                 /etc/systemd/system/nvidia-persistenced.service.d/:sgs-gpu \
                 /etc/modprobe.d/:sgs-kernel \
                 /etc/sysctl.d/:sgs-kernel /etc/profile.d/:sgs-profile \
                 "$site/sgs-cuda-preload.pth":sgs-stack "$site/sgs_cuda_preload.py":sgs-stack \
                 /usr/local/bin/sgs-check:sgs-stack /etc/systemd/system/sgs-jupyter@.service:sgs-stack; do
      path="${entry%:*}"
      if [ -e "$path" ]; then echo "-w $path -p wa -k ${entry##*:}"; fi
    done
    echo "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k sgs-kernel"
  } > "$rules"
  chmod 0640 "$rules"
  augenrules --load >/dev/null 2>&1 || info "Couldn't load the audit rules now; they apply at the next boot"
  info "$(grep -c '^-' "$rules") rules in $rules (read with: sudo ausearch -k sgs-)"
}

write_manifest() {
  {
    echo "version=${SGS_VERSION}"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$WITH_DRIVER" = 1 ]; then echo "driver_branch=${DRIVER_BRANCH}"; else echo "driver=skipped"; fi
    echo "cuda_toolkit=${CUDA_TOOLKIT_PKG}"
    echo "lockfile_sha256=$(sha256sum "$SRC_DIR/python/lock-${PY_ARCH}.txt" | cut -d' ' -f1)"
    echo "tf_cuda12_lockfile_sha256=$(sha256sum "$SRC_DIR/python/tf-cuda12-lock-${PY_ARCH}.txt" | cut -d' ' -f1)"
    echo "[python]"
    "$SGS_PREFIX/venv/bin/python" -m pip list --format=freeze 2>/dev/null
  } > "$SGS_PREFIX/manifest.txt"
  install -m 0644 "$SRC_DIR/python/lock-${PY_ARCH}.txt" "$SGS_PREFIX/lock.txt"
  # The stack's files outside pip, for sgs-check's integrity check.
  local site="$SGS_PREFIX/venv/lib/python3.12/site-packages" f
  for f in "$site/sgs_cuda_preload.py" "$site/sgs-cuda-preload.pth" /usr/local/bin/sgs-check \
           /usr/local/bin/sgs-venv /usr/local/bin/sgs-jupyter /usr/local/bin/sgs-sbom /etc/systemd/system/sgs-jupyter@.service \
           /etc/profile.d/sgs.sh /etc/modprobe.d/sgs-nvidia.conf /etc/ssh/sshd_config.d/10-sgs.conf \
           /usr/local/sbin/sgs-gpu-devices /etc/udev/rules.d/72-sgs-nvidia-devices.rules \
           /etc/systemd/system/nvidia-cdi-refresh.service.d/sgs-gpu-devices.conf \
           /etc/systemd/system/sgs-gpu-devices.service /sbin/ub-device-create \
           /etc/systemd/system/nvidia-persistenced.service.d/sgs-gpu-devices.conf \
           /etc/sysctl.d/60-sgs.conf /etc/systemd/system/apport.service.d/sgs-suid-dumpable.conf \
           /etc/audit/rules.d/60-sgs.rules /etc/update-motd.d/60-sgs \
           /etc/systemd/system/sgs-check.service /etc/systemd/system/sgs-check.timer \
           /usr/local/sbin/sgs-egress /etc/systemd/system/sgs-egress-dns.service /etc/systemd/system/sgs-egress.service \
           /etc/sgs/guard.nft /etc/systemd/system/sgs-guard.service /etc/default/grub.d/60-sgs-lockdown.cfg; do
    if [ -f "$f" ]; then sha256sum "$f"; fi
  done > "$SGS_PREFIX/files.sha256"
  # What's actually installed, apt and Python, as CycloneDX (sgs-sbom regenerates it).
  /usr/bin/python3 -I /usr/local/bin/sgs-sbom --output "$SGS_PREFIX/sbom.cdx.json" 2>/dev/null \
    && info "Software bill of materials: $SGS_PREFIX/sbom.cdx.json" || info "Couldn't write the software bill of materials"
}

main() {
  parse_args "$@"
  # The startup files sgs-check watches, before this run changes any (even
  # preflight installs packages). The end of main accepts what changed since.
  local startup_before=""
  if [ "$(id -u)" -eq 0 ] && [ -f "$SRC_DIR/bin/sgs-check" ] && grep -qs '^place ' /var/lib/sgs/startup-files; then
    startup_before=$(mktemp)
    bash "$SRC_DIR/bin/sgs-check" --list-startup-files > "$startup_before" 2>/dev/null || { rm -f "$startup_before"; startup_before=""; }
  fi
  preflight
  setup_sources
  harden
  install_driver
  setup_lockdown
  install_cuda_toolkit
  install_docker
  install_python
  install_commands
  install_audit_rules
  write_manifest
  # The startup files sgs-check watches (cron, services, shell startup, SSH
  # keys): all of them at the first install; on a re-run, only what this run
  # changed, plus places this version watches for the first time. A change
  # made before the run, waiting for review, stays reported.
  if [ -n "$startup_before" ]; then
    /usr/local/bin/sgs-check --accept-changes-since "$startup_before" >/dev/null 2>&1 \
      || info "WARNING: couldn't update the record of startup files sgs-check watches"
    rm -f "$startup_before"
  elif grep -qs '^place ' /var/lib/sgs/startup-files; then
    info "WARNING: couldn't list the startup files before this run, so their record is unchanged (sudo sgs-check shows what changed)"
  else
    /usr/local/bin/sgs-check --accept-changes >/dev/null 2>&1 \
      || info "WARNING: couldn't record the startup files sgs-check watches"
  fi
  # The first daily check now, in the background, so the login message has a
  # result: after the manifest, which it checks against.
  systemctl start --no-block sgs-check.service >/dev/null 2>&1 || true

  log "Secure GPU Stack ${SGS_VERSION} is installed"
  info "Check it:   sgs-check"
  [ "$NEED_REBOOT" = 1 ] && info "Reboot to finish (the NVIDIA driver, kernel lockdown and their settings load at boot):   sudo reboot"
  return 0
}

main "$@"
