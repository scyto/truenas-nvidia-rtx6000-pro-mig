#!/bin/bash
# setup-runner-vm.sh — Create a self-hosted GitHub Actions runner VM on TrueNAS
#
# Usage: sudo bash setup-runner-vm.sh
#
# Prerequisites:
#   - Run on TrueNAS shell as root (sudo -i)
#   - cloud-image-utils package (script will install if missing)
#
# After the VM boots (~2-3 min), SSH in and run the installer:
#   ssh runner@<VM-IP>
#   ./install-runner.sh
#
# It will prompt for your runner token from:
#   https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/settings/actions/runners/new

set -euo pipefail

# ── Fixed configuration ─────────────────────────────────────────────────────
POOL="rust"                    # ZFS pool for VM storage
VM_NAME="githubrunner"         # VM name (TrueNAS requires alphanumeric only)
VM_CPUS=8                      # vCPUs
VM_RAM=32768                   # Memory in MB (32 GB)
DISK_SIZE="200G"               # VM disk size
RUNNER_USER="runner"           # Username inside the VM
# ────────────────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Run this script as root (sudo -i first)"
  exit 1
fi

echo "=============================================="
echo "  GitHub Actions Runner VM Setup"
echo "=============================================="
echo ""

# ── Prompt for SSH public key ──
echo "Paste your SSH public key (from ~/.ssh/id_ed25519.pub or similar):"
read -p "> " SSH_PUBKEY
if [ -z "$SSH_PUBKEY" ] || ! echo "$SSH_PUBKEY" | grep -qE '^ssh-(rsa|ed25519|ecdsa)'; then
  echo "ERROR: That doesn't look like a valid SSH public key"
  exit 1
fi
echo ""

# ── Prompt for password ──
while true; do
  read -s -p "Set a password for the '${RUNNER_USER}' user: " RUNNER_PASS
  echo ""
  read -s -p "Confirm password: " RUNNER_PASS_CONFIRM
  echo ""
  if [ "$RUNNER_PASS" = "$RUNNER_PASS_CONFIRM" ]; then
    break
  fi
  echo "Passwords don't match, try again."
  echo ""
done
if [ -z "$RUNNER_PASS" ]; then
  echo "ERROR: Password cannot be empty"
  exit 1
fi
echo ""

# ── Prompt for network interface ──
echo "Available network interfaces:"
echo ""
# Get interfaces and display them numbered
INTERFACES=$(midclt call interface.query | jq -r '.[].name')
i=1
declare -a IF_ARRAY
while IFS= read -r iface; do
  IF_ARRAY[$i]="$iface"
  # Show extra info if available
  STATE=$(midclt call interface.query | jq -r ".[] | select(.name==\"$iface\") | .state.link_state // \"unknown\"")
  echo "  $i) $iface ($STATE)"
  i=$((i + 1))
done <<< "$INTERFACES"
echo ""
read -p "Select interface number [1]: " NIC_CHOICE
NIC_CHOICE=${NIC_CHOICE:-1}
NIC_BRIDGE="${IF_ARRAY[$NIC_CHOICE]}"
if [ -z "$NIC_BRIDGE" ]; then
  echo "ERROR: Invalid selection"
  exit 1
fi
echo "Using: $NIC_BRIDGE"
echo ""

echo "=== Configuration ==="
echo "  VM:        ${VM_NAME} (${VM_CPUS} vCPU, $((VM_RAM / 1024))GB RAM, ${DISK_SIZE} disk)"
echo "  Pool:      ${POOL}"
echo "  User:      ${RUNNER_USER}"
echo "  NIC:       ${NIC_BRIDGE}"
echo "  SSH key:   ${SSH_PUBKEY:0:30}..."
echo ""
read -p "Continue? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

echo "=== Step 1: Download Ubuntu 22.04 cloud image ==="
mkdir -p /mnt/${POOL}/isos
cd /mnt/${POOL}/isos
if [ ! -f ubuntu-22.04-server-cloudimg-amd64.img ]; then
  wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img
else
  echo "Cloud image already downloaded, skipping."
fi

echo "=== Step 2: Verify required tools ==="
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required but not found."
  exit 1
fi

echo "=== Step 3: Create VM disk (zvol) ==="
if zfs list ${POOL}/${VM_NAME}-disk &>/dev/null; then
  echo "ERROR: zvol ${POOL}/${VM_NAME}-disk already exists."
  echo "To start over: zfs destroy ${POOL}/${VM_NAME}-disk"
  exit 1
fi
zfs create -V ${DISK_SIZE} -o volblocksize=64k ${POOL}/${VM_NAME}-disk

echo "Writing cloud image to zvol..."
qemu-img dd -f qcow2 -O raw \
  bs=4M if=/mnt/${POOL}/isos/ubuntu-22.04-server-cloudimg-amd64.img \
  of=/dev/zvol/${POOL}/${VM_NAME}-disk

echo "=== Step 4: Create cloud-init seed ==="
SEED_DIR=$(mktemp -d)

cat > ${SEED_DIR}/user-data <<USERDATA
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${RUNNER_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

chpasswd:
  list: |
    ${RUNNER_USER}:${RUNNER_PASS}
  expire: false

package_update: true
package_upgrade: true
packages:
  - build-essential
  - debootstrap
  - git
  - squashfs-tools
  - unzip
  - libjson-perl
  - rsync
  - libarchive-tools
  - zstd
  - ccache
  - curl
  - jq
  - software-properties-common

write_files:
  - path: /home/${RUNNER_USER}/install-runner.sh
    permissions: '0755'
    owner: ${RUNNER_USER}:${RUNNER_USER}
    content: |
      #!/bin/bash
      set -euo pipefail

      REPO="https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig"
      RUNNER_DIR="\$HOME/actions-runner"

      if [ -d "\$RUNNER_DIR/.credentials" ] || [ -f "\$RUNNER_DIR/.runner" ]; then
        echo "Runner is already configured in \$RUNNER_DIR"
        echo "To reconfigure, run: cd \$RUNNER_DIR && ./config.sh remove && rm -rf \$RUNNER_DIR"
        exit 0
      fi

      echo "============================================"
      echo "  GitHub Actions Runner Installer"
      echo "============================================"
      echo ""
      echo "Get your token from:"
      echo "  \$REPO/settings/actions/runners/new"
      echo ""
      echo "(The token is in the ./config.sh line, starts with A)"
      echo ""
      read -p "Paste your runner registration token: " TOKEN

      if [ -z "\$TOKEN" ]; then
        echo "ERROR: No token provided"
        exit 1
      fi

      echo ""
      echo "=== Downloading runner agent ==="
      mkdir -p "\$RUNNER_DIR"
      cd "\$RUNNER_DIR"

      # Fetch latest runner version
      LATEST=\$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
      echo "Latest runner version: \$LATEST"
      curl -sL -o actions-runner.tar.gz \\
        "https://github.com/actions/runner/releases/download/v\${LATEST}/actions-runner-linux-x64-\${LATEST}.tar.gz"
      tar xzf actions-runner.tar.gz
      rm actions-runner.tar.gz

      echo ""
      echo "=== Configuring runner ==="
      ./config.sh --url "\$REPO" \\
        --token "\$TOKEN" \\
        --name truenas-runner \\
        --labels self-hosted,linux,x64,truenas \\
        --work _work \\
        --unattended

      echo ""
      echo "=== Installing as system service ==="
      sudo ./svc.sh install
      sudo ./svc.sh start

      echo ""
      echo "============================================"
      echo "  Runner installed and running!"
      echo "============================================"
      echo ""
      echo "Verify at: \$REPO/settings/actions/runners"
      echo ""
      echo "Update your workflow to use:"
      echo "  runs-on: [self-hosted, linux, x64, truenas]"
      echo "============================================"

runcmd:
  # Install Python 3.11 (needed by scale-build)
  - add-apt-repository -y ppa:deadsnakes/ppa
  - apt-get install -y python3.11 python3.11-venv python3.11-dev
  - update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
  # Expand the root partition to fill the entire disk
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || true
  # Signal that cloud-init is done
  - echo "cloud-init complete" > /var/log/cloud-init-done
USERDATA

cat > ${SEED_DIR}/meta-data <<METADATA
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA

SEED_IMG="/mnt/${POOL}/isos/${VM_NAME}-seed.img"
# Create a minimal ISO9660 "cidata" image with user-data and meta-data.
# This replaces cloud-localds/genisoimage which aren't available on TrueNAS.
python3 - "${SEED_IMG}" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" <<'PYEOF'
import struct, sys, os, time

def pad(data, block=2048):
    r = len(data) % block
    return data + b'\x00' * (block - r) if r else data

def dir_record(name, lba, size, is_dir=False, raw_name=None):
    n = raw_name if raw_name else name.encode()
    rec_len = 33 + len(n)
    if rec_len % 2: rec_len += 1
    flags = 0x02 if is_dir else 0x00
    now = time.gmtime()
    date = struct.pack('7B', now.tm_year - 1900, now.tm_mon, now.tm_mday,
                       now.tm_hour, now.tm_min, now.tm_sec, 0)
    rec = struct.pack('<B', rec_len)
    rec += b'\x00'  # ext attr length
    rec += struct.pack('<I', lba) + struct.pack('>I', lba)
    rec += struct.pack('<I', size) + struct.pack('>I', size)
    rec += date
    rec += struct.pack('B', flags)
    rec += b'\x00\x00'  # file unit size, interleave
    rec += struct.pack('<H', 1) + struct.pack('>H', 1)  # volume seq
    rec += struct.pack('B', len(n))
    rec += n
    if len(rec) % 2: rec += b'\x00'
    return rec

def volume_descriptor(vol_id, root_lba, root_size, path_table_lba, total_blocks):
    vd = struct.pack('B', 1) + b'CD001' + b'\x01' + b'\x00'  # type, id, version, unused
    vd += b' ' * 32  # system id
    vd += vol_id.encode().ljust(32)  # volume id
    vd += b'\x00' * 8  # unused
    vd += struct.pack('<I', total_blocks) + struct.pack('>I', total_blocks)
    vd += b'\x00' * 32  # unused
    vd += struct.pack('<H', 1) + struct.pack('>H', 1)  # volume set size
    vd += struct.pack('<H', 1) + struct.pack('>H', 1)  # volume seq number
    vd += struct.pack('<H', 2048) + struct.pack('>H', 2048)  # block size
    pt_size = 10 + 1  # one entry for root
    vd += struct.pack('<I', pt_size) + struct.pack('>I', pt_size)
    vd += struct.pack('<I', path_table_lba)  # L path table
    vd += struct.pack('<I', 0)  # optional L path table
    vd += struct.pack('>I', path_table_lba + 1)  # M path table
    vd += struct.pack('>I', 0)  # optional M path table
    root_rec = dir_record('.', root_lba, root_size, is_dir=True, raw_name=b'\x00')
    vd += root_rec.ljust(34, b'\x00')
    vd += b' ' * 128  # volume set id
    vd += b' ' * 128  # publisher
    vd += b' ' * 128  # data preparer
    vd += b' ' * 128  # application
    vd += b' ' * 37 * 3  # copyright, abstract, biblio
    vd += b'0000000000000000\x00' * 2  # creation, modification dates
    vd += b'0000000000000000\x00' * 2  # expiration, effective dates
    vd += b'\x01' + b'\x00'  # file structure version, reserved
    return vd.ljust(2048, b'\x00')

out_path, ud_path, md_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(ud_path, 'rb') as f: ud = f.read()
with open(md_path, 'rb') as f: md = f.read()

# Layout: 16 system blocks, PVD, terminator, path tables (L+M), root dir, files
pt_lba = 18
root_lba = 20
file1_lba = 21
file1_blocks = (len(ud) + 2047) // 2048
file2_lba = file1_lba + file1_blocks
file2_blocks = (len(md) + 2047) // 2048
total = file2_lba + file2_blocks

# Root directory entries
root_data = dir_record('.', root_lba, 2048, is_dir=True, raw_name=b'\x00')
root_data += dir_record('..', root_lba, 2048, is_dir=True, raw_name=b'\x01')
root_data += dir_record('USER-DATA', file1_lba, len(ud), raw_name=b'USER_DATA.;1')
root_data += dir_record('META-DATA', file2_lba, len(md), raw_name=b'META_DATA.;1')
root_data = root_data.ljust(2048, b'\x00')

# Path table (little-endian)
pt_l = struct.pack('<BBI', 1, 0, root_lba) + struct.pack('>H', 1) + b'\x00'
pt_l = pt_l.ljust(2048, b'\x00')
# Path table (big-endian)
pt_m = struct.pack('<BB', 1, 0) + struct.pack('>I', root_lba) + struct.pack('>H', 1) + b'\x00'
pt_m = pt_m.ljust(2048, b'\x00')

iso = b'\x00' * 2048 * 16  # system area
iso += volume_descriptor('cidata', root_lba, 2048, pt_lba, total)
# Terminator
iso += struct.pack('B', 255) + b'CD001' + b'\x01'
iso = iso.ljust(2048 * 18, b'\x00')
iso += pt_l + pt_m
iso += root_data
iso += pad(ud)
iso += pad(md)

with open(out_path, 'wb') as f: f.write(iso)
print(f"Created seed ISO: {out_path} ({len(iso)} bytes)")
PYEOF

rm -rf ${SEED_DIR}
echo "Seed image created: /mnt/${POOL}/isos/${VM_NAME}-seed.img"

echo "=== Step 5: Create VM via TrueNAS API ==="
RESULT=$(midclt call vm.create "{
  \"name\": \"${VM_NAME}\",
  \"cpu_mode\": \"HOST-PASSTHROUGH\",
  \"vcpus\": ${VM_CPUS},
  \"memory\": ${VM_RAM},
  \"bootloader\": \"UEFI\",
  \"autostart\": true,
  \"description\": \"GitHub Actions self-hosted runner (8 vCPU, 32GB RAM, 200GB disk)\"
}")
VM_ID=$(echo ${RESULT} | jq '.id')
echo "Created VM ID: ${VM_ID}"

# Disk
echo "  Adding disk..."
midclt call vm.device.create "{
  \"vm\": ${VM_ID},
  \"dtype\": \"DISK\",
  \"order\": 1001,
  \"attributes\": {
    \"path\": \"/dev/zvol/${POOL}/${VM_NAME}-disk\",
    \"type\": \"VIRTIO\"
  }
}"

# Cloud-init seed (CDROM)
echo "  Adding cloud-init seed..."
midclt call vm.device.create "{
  \"vm\": ${VM_ID},
  \"dtype\": \"CDROM\",
  \"order\": 1004,
  \"attributes\": {
    \"path\": \"/mnt/${POOL}/isos/${VM_NAME}-seed.img\"
  }
}"

# NIC
echo "  Adding NIC..."
MAC=$(midclt call vm.random_mac)
midclt call vm.device.create "{
  \"vm\": ${VM_ID},
  \"dtype\": \"NIC\",
  \"order\": 1003,
  \"attributes\": {
    \"type\": \"VIRTIO\",
    \"nic_attach\": \"${NIC_BRIDGE}\",
    \"mac\": ${MAC}
  }
}"

# VNC display (for debugging)
echo "  Adding VNC display..."
midclt call vm.device.create "{
  \"vm\": ${VM_ID},
  \"dtype\": \"DISPLAY\",
  \"order\": 1005,
  \"attributes\": {
    \"web\": true,
    \"type\": \"VNC\",
    \"bind\": \"0.0.0.0\",
    \"wait\": false
  }
}"

echo "=== Step 6: Starting VM ==="
midclt call vm.start ${VM_ID}

echo ""
echo "=============================================="
echo "  VM '${VM_NAME}' created and starting!"
echo "=============================================="
echo ""
echo "Cloud-init is installing packages (~2-3 min)."
echo ""
echo "Find the VM's IP:"
echo "  - Check your router/DHCP server, or"
echo "  - Use the VNC console in TrueNAS UI > Virtualization"
echo ""
echo "Then SSH in and run the installer:"
echo ""
echo "  ssh ${RUNNER_USER}@<VM-IP>"
echo "  ./install-runner.sh"
echo ""
echo "It will ask for your runner token (get it from"
echo "GitHub > Settings > Actions > Runners > New)"
echo "and handle everything else automatically."
echo "=============================================="
