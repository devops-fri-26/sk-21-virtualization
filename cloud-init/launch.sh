#!/usr/bin/env bash
# =====================================================================
#  Zagon BookStack VM v VirtualBoxu s cloud-init (NoCloud datasource)
#
#  Uporaba:
#    ./launch.sh up        # prenese Ubuntu cloud image, zgradi seed ISO, zažene VM
#    ./launch.sh status    # stanje VM in cloud-init
#    ./launch.sh logs      # sledi namestitvenemu logu
#    ./launch.sh ssh       # SSH v VM (uporabnik ubuntu)
#    ./launch.sh destroy   # ugasne in pobriše VM
#
#  Nastavitve lahko povoziš z okoljskimi spremenljivkami, npr.:
#    CPUS=4 MEMORY=8192 ./launch.sh up
#
#  Javni način z Let's Encrypt (najprej testni certifikat, nato pravi):
#    PUBLIC_DOMAIN=devops-sk-21.lrk.si LE_EMAIL=ti@student.uni-lj.si ./launch.sh up
#    PUBLIC_DOMAIN=... LE_EMAIL=... LE_STAGING=0 ./launch.sh up
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VM_NAME="${VM_NAME:-bookstack-ci}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-4096}"          # MB
DISK_MB="${DISK_MB:-15360}"       # 15 GB
SSH_PORT="${SSH_PORT:-2422}"      # porti na hostu (samo 127.0.0.1)
HTTP_PORT="${HTTP_PORT:-9080}"
HTTPS_PORT="${HTTPS_PORT:-9443}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Javni način: PUBLIC_DOMAIN nastavljen -> Let's Encrypt + HTTP/HTTPS porti na vseh IP-jih
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
LE_STAGING="${LE_STAGING:-1}"     # 1 = testni LE certifikat (brez rate limitov), 0 = pravi
if [ -n "$PUBLIC_DOMAIN" ]; then BIND_IP=""; else BIND_IP="127.0.0.1"; fi

IMG_RELEASE="noble"               # Ubuntu 24.04 LTS
IMG_FILE="${IMG_RELEASE}-server-cloudimg-amd64.vmdk"
IMG_URL="https://cloud-images.ubuntu.com/${IMG_RELEASE}/current"
CACHE_DIR="$HOME/.cache/sk21-cloudinit"
VM_BASE="$HOME/vms"
DATA_DIR="$VM_BASE/${VM_NAME}-data"

SSH_OPTS=(-p "$SSH_PORT" -i "$SSH_KEY"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5)

log() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mNAPAKA:\e[0m %s\n' "$*" >&2; exit 1; }

vm_exists() { VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; }
vm_ssh()    { ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 "$@"; }

check_deps() {
  for cmd in VBoxManage cloud-localds curl sha256sum ssh ssh-keygen; do
    command -v "$cmd" >/dev/null \
      || die "Manjka ukaz '$cmd' (za cloud-localds: sudo apt install cloud-image-utils)"
  done
  if [ ! -f "$SSH_KEY.pub" ]; then
    log "Ustvarjam SSH ključ $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
  fi
}

fetch_image() {
  mkdir -p "$CACHE_DIR"
  log "Preverjam Ubuntu cloud image ($IMG_FILE)"
  curl -fsSL -o "$CACHE_DIR/SHA256SUMS" "$IMG_URL/SHA256SUMS"
  check() { (cd "$CACHE_DIR" && grep -E "[ *]${IMG_FILE}\$" SHA256SUMS | sha256sum -c --status); }
  if [ -f "$CACHE_DIR/$IMG_FILE" ] && check; then
    log "Image je že v cache-u in veljaven"
  else
    log "Prenašam image (samo prvič oz. ob novi verziji)"
    curl -fL --progress-bar -o "$CACHE_DIR/$IMG_FILE" "$IMG_URL/$IMG_FILE"
    check || die "SHA256 se ne ujema – image je poškodovan"
  fi
}

build_seed() {
  log "Gradim NoCloud seed ISO"
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR"
  # user-data = naš user-data.yaml + SSH ključ privzetega uporabnika (samo za ta zagon)
  {
    cat "$SCRIPT_DIR/user-data.yaml"
    printf '\n# --- dodano z launch.sh ---\nssh_authorized_keys:\n  - %s\n' "$(cat "$SSH_KEY.pub")"
  } > "$DATA_DIR/user-data"

  # Javni način: v bloku deploy.env zamenjaj domeno, URL in način certifikata
  if [ -n "$PUBLIC_DOMAIN" ]; then
    [ -n "$LE_EMAIL" ] || die "Za PUBLIC_DOMAIN nastavi še LE_EMAIL"
    sed -i "/path: \/etc\/bookstack\/deploy.env/,/^  - path:/{
s|^      DOMAIN=.*|      DOMAIN=${PUBLIC_DOMAIN}|
s|^      APP_URL=.*|      APP_URL=https://${PUBLIC_DOMAIN}|
s|^      CERT_MODE=.*|      CERT_MODE=letsencrypt|
s|^      LE_EMAIL=.*|      LE_EMAIL=${LE_EMAIL}\n      LE_STAGING=${LE_STAGING}|
}" "$DATA_DIR/user-data"
    grep -q "^      CERT_MODE=letsencrypt" "$DATA_DIR/user-data" \
      || die "Zamenjava v deploy.env ni uspela – preveri blok deploy.env v user-data.yaml"
    log "Javni način: https://${PUBLIC_DOMAIN} (LE_STAGING=${LE_STAGING})"
  fi
  # nov instance-id ob vsakem zagonu -> cloud-init se vedno izvede na novo
  printf 'instance-id: %s-%s\nlocal-hostname: bookstack\n' "$VM_NAME" "$(date +%s)" \
    > "$DATA_DIR/meta-data"
  cloud-localds "$DATA_DIR/seed.iso" "$DATA_DIR/user-data" "$DATA_DIR/meta-data"
}

create_vm() {
  log "Ustvarjam VM $VM_NAME ($CPUS CPU, ${MEMORY} MB RAM, ${DISK_MB} MB disk)"
  VBoxManage createvm --name "$VM_NAME" --ostype Ubuntu_64 \
    --basefolder "$VM_BASE" --register >/dev/null
  VBoxManage modifyvm "$VM_NAME" --cpus "$CPUS" --memory "$MEMORY" --ioapic on \
    --boot1 disk --nic1 nat \
    --uart1 0x3F8 4 --uartmode1 file "$DATA_DIR/console.log"
  VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,127.0.0.1,$SSH_PORT,,22"
  VBoxManage modifyvm "$VM_NAME" --natpf1 "http,tcp,$BIND_IP,$HTTP_PORT,,80"
  VBoxManage modifyvm "$VM_NAME" --natpf1 "https,tcp,$BIND_IP,$HTTPS_PORT,,443"

  # cloud image -> VDI (VirtualBox) in povečanje diska; growpart ga v VM razširi sam
  VBoxManage clonemedium disk "$CACHE_DIR/$IMG_FILE" "$DATA_DIR/disk.vdi" --format VDI >/dev/null
  VBoxManage closemedium disk "$CACHE_DIR/$IMG_FILE" >/dev/null 2>&1 || true
  VBoxManage modifymedium disk "$DATA_DIR/disk.vdi" --resize "$DISK_MB"

  VBoxManage storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 2
  VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
    --type hdd --medium "$DATA_DIR/disk.vdi"
  VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 \
    --type dvddrive --medium "$DATA_DIR/seed.iso"
}

wait_ready() {
  log "Čakam na SSH (port $SSH_PORT)"
  for _ in $(seq 1 120); do
    vm_ssh true 2>/dev/null && break
    sleep 5
  done
  vm_ssh true 2>/dev/null || die "SSH ni dosegljiv – poglej $DATA_DIR/console.log"

  log "Čakam, da cloud-init konča (to traja nekaj minut)"
  vm_ssh 'cloud-init status --wait --long' || true
  echo
  vm_ssh 'sudo tail -n 5 /var/log/bookstack-setup.log' || true
}

cmd_up() {
  SECONDS=0
  check_deps
  vm_exists && die "VM '$VM_NAME' že obstaja – najprej ./launch.sh destroy"
  fetch_image
  build_seed
  create_vm
  log "Zaganjam VM"
  VBoxManage startvm "$VM_NAME" --type headless >/dev/null
  wait_ready
  log "Deploy končan v ${SECONDS} s"
  echo "  SSH:    ./launch.sh ssh"
  if [ -n "$PUBLIC_DOMAIN" ]; then
    echo "  HTTPS:  https://$PUBLIC_DOMAIN"
  else
    echo "  HTTPS:  https://localhost:$HTTPS_PORT (na laptopu prek port forwarda)"
  fi
  echo "  Geslo:  ./launch.sh ssh sudo cat /root/bookstack-secrets.env"
}

cmd_destroy() {
  if vm_exists; then
    log "Ugašam in brišem VM $VM_NAME"
    VBoxManage controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
    sleep 3
    VBoxManage unregistervm "$VM_NAME" --delete >/dev/null
  fi
  VBoxManage closemedium dvd "$DATA_DIR/seed.iso" >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
  log "Pobrisano"
}

cmd_status() {
  vm_exists || die "VM '$VM_NAME' ne obstaja"
  VBoxManage showvminfo "$VM_NAME" --machinereadable | grep -E '^VMState='
  vm_ssh 'cloud-init status --long' || true
}

case "${1:-}" in
  up)      cmd_up ;;
  destroy) cmd_destroy ;;
  status)  cmd_status ;;
  logs)    vm_ssh 'sudo tail -f /var/log/bookstack-setup.log' ;;
  ssh)     shift; vm_ssh "$@" ;;
  *)       echo "Uporaba: $0 {up|status|logs|ssh|destroy}"; exit 1 ;;
esac
