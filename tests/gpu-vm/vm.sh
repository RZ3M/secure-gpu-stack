#!/usr/bin/env bash
# Ubuntu 24.04 test VMs for the M2 test bench (docs/m2-test-bench.md), with the
# host's NVIDIA GPU passed through once gpu-handoff.sh has put it on vfio-pci.
#
#   sudo vm.sh create NAME ADDR USER_DATA   disk on the cloud image, cloud-init seed
#   sudo vm.sh start NAME [--gpu]           boot it as systemd unit sgs-vm-NAME
#   sudo vm.sh stop NAME                    shut it down (forced after 3 minutes)
#   sudo vm.sh delete NAME
#        vm.sh ssh NAME [COMMAND...]        log in as ubuntu
#
# ADDR is a loopback address of the VM's own (127.0.0.2, ...). Its SSH is on
# ADDR:2222, and the ports the attack demo probes (8888, 8080-8082) on the same
# numbers, all through QEMU's user-mode network: nothing is reachable from
# outside this host. USER_DATA is a #cloud-config file; vm-key.pub is added to
# it as the ubuntu user's SSH key. Files live next to this script: the base
# image, vm-key (the VMs' SSH key) and NAME.* for each VM.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$DIR/noble-server-cloudimg-amd64.img"
OVMF=/usr/share/edk2/x64
PORTS="8888 8080 8081 8082"
die() { echo "$*" >&2; exit 1; }

create() {
  local name=$1 addr=$2 ud=$3 seed
  [ -e "$DIR/$name.qcow2" ] && die "$name exists; vm.sh delete $name first"
  head -1 "$ud" | grep -qx '#cloud-config' || die "$ud isn't a #cloud-config file"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DIR/$name.qcow2" "${SGS_VM_DISK:-200G}"
  cp "$OVMF/OVMF_VARS.4m.fd" "$DIR/$name-vars.fd"
  echo "$addr" > "$DIR/$name.addr"
  # cloud-init's NoCloud seed: a small FAT disk labelled CIDATA.
  seed=$(mktemp -d)
  printf 'instance-id: %s-%s\nlocal-hostname: sgs-%s\n' "$name" "$(date +%s)" "$name" > "$seed/meta-data"
  { cat "$ud"; printf '\nssh_authorized_keys:\n  - %s\n' "$(cat "$DIR/vm-key.pub")"; } > "$seed/user-data"
  rm -f "$DIR/$name-seed.img"
  mkfs.vfat -n CIDATA -C "$DIR/$name-seed.img" 2048 > /dev/null
  mcopy -i "$DIR/$name-seed.img" "$seed/meta-data" "$seed/user-data" ::
  rm -rf "$seed"
  echo "Created $name ($addr)"
}

start() {
  local name=$1 gpu=${2:-} addr fwd p g f mf i=0 devs=()
  [ -e "$DIR/$name.qcow2" ] || die "No VM called $name"
  systemctl is-active -q "sgs-vm-$name" && die "$name is already running"
  addr=$(cat "$DIR/$name.addr")
  fwd="hostfwd=tcp:$addr:2222-:22"
  for p in $PORTS; do fwd+=",hostfwd=tcp:$addr:$p-:$p"; done
  if [ "$gpu" = --gpu ]; then
    g=$(lspci -D -d 10de: | awk '/VGA compatible|3D controller/ { print $1; exit }')
    # Behind a PCIe root port, as on a real machine; the GPU and its audio
    # stay one multi-function device.
    devs=(-device pcie-root-port,id=gpu-port,bus=pcie.0,chassis=1,slot=1)
    for f in $(cd /sys/bus/pci/devices && ls -d "${g%.*}".*); do
      [ "$(basename "$(readlink "/sys/bus/pci/devices/$f/driver")")" = vfio-pci ] \
        || die "$f isn't on vfio-pci: run gpu-handoff.sh to-vm first"
      if [ "$i" = 0 ]; then mf=,multifunction=on; else mf=; fi
      devs+=(-device "vfio-pci,host=$f,bus=gpu-port,addr=00.$i$mf")
      i=$((i + 1))
    done
  fi
  # X-PciMmio64Mb: room above 4 GB for a resizable BAR (the RTX 3080's is 16 GB).
  systemd-run --quiet --unit="sgs-vm-$name" --collect -p LimitMEMLOCK=infinity \
    qemu-system-x86_64 -name "$name" -machine q35,accel=kvm -cpu host,host-phys-bits=on \
      -smp "${SGS_VM_CPUS:-12}" -m "${SGS_VM_MEM:-16G}" \
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF/OVMF_CODE.4m.fd" \
      -drive "if=pflash,format=raw,file=$DIR/$name-vars.fd" \
      -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 \
      -drive "file=$DIR/$name.qcow2,if=virtio,format=qcow2,discard=unmap" \
      -drive "file=$DIR/$name-seed.img,if=virtio,format=raw,readonly=on" \
      -netdev "user,id=net0,$fwd" -device virtio-net-pci,netdev=net0 \
      -display none -vga none \
      -chardev "file,id=console,path=$DIR/$name-console.log,append=on" -serial chardev:console \
      -monitor "unix:$DIR/$name-monitor.sock,server=on,wait=off" \
      "${devs[@]}"
  echo "Started $name$([ "$gpu" = --gpu ] && echo ' with the GPU'); console: $DIR/$name-console.log"
}

stop() {
  local name=$1 i
  systemctl is-active -q "sgs-vm-$name" || { echo "$name isn't running"; return; }
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"system_powerdown\n")' \
    "$DIR/$name-monitor.sock"
  for i in $(seq 180); do
    systemctl is-active -q "sgs-vm-$name" || { echo "$name shut down"; return; }
    sleep 1
  done
  echo "$name didn't shut down in 3 minutes; stopping it"
  systemctl stop "sgs-vm-$name"
}

delete() {
  local name=$1
  stop "$name"
  rm -f "$DIR/$name".{qcow2,addr,known_hosts} "$DIR/$name"-{vars.fd,seed.img,console.log,monitor.sock}
  echo "Deleted $name"
}

ssh_vm() {
  local name=$1; shift
  exec ssh -i "$DIR/vm-key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -o UserKnownHostsFile="$DIR/$name.known_hosts" -o StrictHostKeyChecking=accept-new \
    -p 2222 "ubuntu@$(cat "$DIR/$name.addr")" "$@"
}

cmd=${1:-}; shift || true
case "$cmd" in
  create) [ $# = 3 ] || die "usage: vm.sh create NAME ADDR USER_DATA"; create "$@" ;;
  start) [ $# -ge 1 ] || die "usage: vm.sh start NAME [--gpu]"; start "$@" ;;
  stop) [ $# = 1 ] || die "usage: vm.sh stop NAME"; stop "$1" ;;
  delete) [ $# = 1 ] || die "usage: vm.sh delete NAME"; delete "$1" ;;
  ssh) [ $# -ge 1 ] || die "usage: vm.sh ssh NAME [COMMAND...]"; ssh_vm "$@" ;;
  *) die "usage: vm.sh create|start|stop|delete|ssh NAME ..." ;;
esac
