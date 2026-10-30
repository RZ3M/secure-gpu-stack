#!/usr/bin/env bash
# Move this host's NVIDIA GPU between its NVIDIA driver and vfio-pci, so a test
# VM (vm.sh start NAME --gpu) gets the whole card, as a Lambda Cloud instance
# does. Written for the M2 test bench (docs/m2-test-bench.md): a desktop whose
# only GPU also drives its screen.
#
#   sudo gpu-handoff.sh status    which driver each of the GPU's functions is on
#   sudo gpu-handoff.sh to-vm     end the desktop session, unload the NVIDIA
#                                 driver, give the GPU to vfio-pci
#   sudo gpu-handoff.sh to-host   give it back and start the login screen
#
# to-vm ends graphical logins and then stops the apps that still hold the GPU,
# by their systemd unit, never by killing processes; unsaved work in them is
# lost. Other services keep running. If something still holds the GPU after
# that, it says what and puts the desktop back. Nothing here changes boot
# settings, so a reboot also undoes it.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root" >&2; exit 1; }
# Ending the desktop session can kill the terminal this was started from, and a
# dropped SSH connection would stop it halfway, leaving the host without its
# display. A transient systemd unit outlives both.
if [ -z "${INVOCATION_ID:-}" ] && { [ "${1:-}" = to-vm ] || [ "${1:-}" = to-host ]; }; then
  exec systemd-run --quiet --collect --wait --pipe --unit="sgs-gpu-handoff-$1" \
    ${SGS_GPU:+--setenv=SGS_GPU="$SGS_GPU"} "$(readlink -f "$0")" "$@"
fi

GPU="${SGS_GPU:-$(lspci -D -d 10de: | awk '/VGA compatible|3D controller/ { print $1; exit }')}"
[ -n "$GPU" ] || { echo "No NVIDIA GPU found" >&2; exit 1; }
# The GPU and the functions sharing its slot (its HDMI audio): a VM takes all.
FUNCS=$(cd /sys/bus/pci/devices && ls -d "${GPU%.*}".*)
STATE=/run/sgs-gpu-handoff

driver_of() { local d; if d=$(readlink "/sys/bus/pci/devices/$1/driver"); then basename "$d"; else echo none; fi; }
holders() { { fuser /dev/nvidia* /dev/dri/* 2>/dev/null || true; } | tr -s ' ' '\n' | grep -o '[0-9]\+' | sort -un; }
cgroup_of() { sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null; }

status() {
  for f in $FUNCS; do echo "$f  $(lspci -s "$f" | cut -d' ' -f2-)  ->  $(driver_of "$f")"; done
  echo "login screen (display-manager): $(systemctl is-active display-manager || true)"
}

# User apps still holding the GPU: stop their units (app scopes, Plasma's own
# services). systemd and logind hold it only for the session and let go once
# it ends; any other system service is left alone, and to-vm then gives up.
stop_holder_units() {
  local pid cg uid
  for pid in $(holders); do
    cg=$(cgroup_of "$pid") || continue
    case "$cg" in
      */user@*.service/*)
        uid=${cg#*user@}; uid=${uid%%.service*}
        echo "  stopping ${cg##*/} ($(ps -o comm= -p "$pid"))"
        systemctl --user -M "$(id -nu "$uid")@" stop "${cg##*/}" || true ;;
    esac
  done
}

to_vm() {
  if [ "$(driver_of "$GPU")" = vfio-pci ]; then echo "The GPU is already on vfio-pci"; return; fi
  : > "$STATE"
  if systemctl is-active -q nvidia-persistenced; then echo persistenced >> "$STATE"; fi
  trap 'echo "Handoff failed or interrupted; giving the GPU back to the host" >&2; to_host; exit 1' ERR HUP INT TERM

  echo "Stopping the login screen and ending graphical sessions"
  systemctl stop display-manager || true
  systemctl stop nvidia-persistenced 2>/dev/null || true
  local s
  for s in $(loginctl list-sessions --no-legend | awk '{ print $1 }'); do
    case "$(loginctl show-session "$s" -p Type --value)" in
      wayland|x11|mir) loginctl terminate-session "$s" ;;
    esac
  done
  local i
  for i in $(seq 30); do
    if [ -z "$(holders)" ]; then break; fi
    if [ "$i" = 5 ]; then stop_holder_units; fi
    sleep 1
  done
  if [ -n "$(holders)" ]; then
    echo "Still using the GPU:" >&2
    for i in $(holders); do echo "  pid $i  $(ps -o user=,comm= -p "$i")  $(cgroup_of "$i")" >&2; done
    false
  fi

  echo "Unloading the NVIDIA driver"
  modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia
  modprobe vfio-pci
  local f
  for f in $FUNCS; do
    echo vfio-pci > "/sys/bus/pci/devices/$f/driver_override"
    if [ -e "/sys/bus/pci/devices/$f/driver" ]; then echo "$f" > "/sys/bus/pci/devices/$f/driver/unbind"; fi
    echo "$f" > /sys/bus/pci/drivers_probe
    if [ "$(driver_of "$f")" != vfio-pci ]; then echo "$f didn't bind to vfio-pci" >&2; false; fi
  done
  trap - ERR HUP INT TERM
  status
}

to_host() {
  trap - ERR HUP INT TERM
  # Only the GPU's own IOMMU group: another VM may hold an unrelated device.
  local group
  group=$(basename "$(readlink "/sys/bus/pci/devices/$GPU/iommu_group")")
  if fuser -s "/dev/vfio/$group" 2>/dev/null; then
    echo "A VM still has the GPU; stop it first (vm.sh stop NAME)" >&2
    return 1
  fi
  set +e
  local f
  for f in $FUNCS; do
    echo > "/sys/bus/pci/devices/$f/driver_override"
    if [ "$(driver_of "$f")" = vfio-pci ]; then echo "$f" > /sys/bus/pci/drivers/vfio-pci/unbind; fi
    echo "$f" > /sys/bus/pci/drivers_probe
  done
  # nvidia_drm pulls in nvidia and nvidia_modeset; loading nvidia binds the GPU.
  modprobe nvidia_drm
  modprobe nvidia_uvm
  if grep -qx persistenced "$STATE" 2>/dev/null; then systemctl start nvidia-persistenced; fi
  if systemctl is-enabled -q display-manager 2>/dev/null; then systemctl start display-manager; fi
  rm -f "$STATE"
  set -e
  status
}

case "${1:-}" in
  status) status ;;
  to-vm) to_vm ;;
  to-host) to_host ;;
  *) echo "usage: gpu-handoff.sh status|to-vm|to-host" >&2; exit 2 ;;
esac
