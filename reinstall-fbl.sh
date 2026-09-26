#!/usr/bin/env bash
# reinstall-freebsd-linux.sh
# Reinstall system on Linux / FreeBSD using DD + cloud-init (NoCloud) with:
#   - freebsd
#   - rocky
#   - almalinux
#   - fedora
#   - debian
#   - redhat
#
# All target systems use cloud-init to inject:
#   - root password (--password)
#   - SSH public key(s) (--ssh-key, multiple)
#   - SSH port (--ssh-port)
#   - optional FRPC config (--frpc-toml) embedded into NoCloud user-data
#
# Requirements:
#   - Run with bash:  bash reinstall-freebsd-linux.sh ...
#   - Needs dd, xz, qemu-img, mount, and curl or wget or fetch
#   - Designed to be executed from a dracut initramfs (via rd.reinstall=1 wrapper).
#
# Added:
#   - On Linux+GRUB+EFI host, automatically prepare Alpine RAM installer,
#     add a one-time GRUB entry, reboot into Alpine RAM, and auto-continue.
#   - On FreeBSD+UEFI host, automatically prepare Alpine RAM installer,
#     build a GRUB EFI binary, add a one-time BootNext entry, reboot into Alpine RAM,
#     and auto-continue.
#
# Alpine RAM download mode:
#   - Host phase stores only the reinstall plan, script, optional local inputs,
#     and Alpine boot assets on bootstrap storage.
#   - Alpine RAM obtains networking with DHCP and installs runtime packages
#     directly from the official Alpine repositories.
#   - Alpine RAM enables zram swap for runtime memory pressure.
#   - After relocating modloop to RAM, Alpine always recreates the target disk with a
#     dedicated 3 GiB temporary staging partition at the physical end of the disk.
#   - Target qcow/qcow.xz is downloaded/decompressed as qcow2 onto that staging partition.
#   - qcow2 is written only to the safe prefix before the staging partition, then the
#     staging partition is released, GPT is repaired, the last data partition is expanded,
#     and a dedicated CIDATA partition is created.
#
# Important compatibility note:
#   - This script creates a dedicated VFAT partition labeled CIDATA for standard NoCloud discovery.
#   - Target images must include cloud-init with NoCloud support.
#   - Installer staging is fixed at 3 GiB on the tail of the target disk.
#   - Minimum target disk capacity is documented as 9.5 GiB; use a nominal 10G VPS disk or larger.
#   - The script intentionally does not enforce that minimum with an additional disk-capacity probe.
#   - Validate your target image before relying on unattended deployment.

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_NAME="${0##*/}"

error() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

info() {
    echo "==> $*" >&2
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME freebsd   14|15 [--disk /dev/sdX] [options...]  # major version only
  $SCRIPT_NAME rocky     10   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME almalinux 10   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME fedora    44   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME debian    13   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME redhat         [--disk /dev/sdX] --img URL [options...]

If --disk is not specified, the script will try to auto-detect the main disk:
  - Prefer the disk that backs the current /, /boot, and EFI mountpoints.
  - If those agree, that disk is recommended first.
  - If they cannot be resolved confidently, the script refuses to guess; use --disk explicitly.
  - On host phase, a candidate list is shown and explicit confirmation is required.

Options:
  --disk DISK          Target disk, e.g. /dev/sda, /dev/vda, /dev/nvme0n1, /dev/ada0
                       If you omit /dev/, the script will automatically prefix /dev/.

  --img URL            Override default image URL (redhat requires this).
                       Supports http:// and https://

  --password PASSWORD  Set root password.
                       When using --ssh-key only, password can be empty (SSH key login only).

  --ssh-key KEY        Set SSH public key, can be specified multiple times. Supported forms:
                         --ssh-key "ssh-rsa AAAA... comment"
                         --ssh-key "ssh-ed25519 AAAA... comment"
                         --ssh-key "ecdsa-sha2-nistp256/384/521 AAAA... comment"
                         --ssh-key http://path/to/public_key
                         --ssh-key https://path/to/public_key
                         --ssh-key github:your_username
                         --ssh-key gitlab:your_username
                         --ssh-key /path/to/public_key
                         --ssh-key C:\\path\\to\\public_key   (not supported directly, copy to local file first)

  --ssh-port PORT      Change SSH port in the new system. cloud-init will try to modify
                       sshd_config and restart sshd. Default is 22 if not specified.

  --web-port PORT      Reserved for web log port. This script only writes it into cloud-init,
                       you can consume it later from within the system.

  --frpc-toml PATH/URL Add FRPC configuration for tunneling:
                         - Local path: cache the small file during host phase
                         - HTTP(S): download from Alpine RAM during installer phase
                       cloud-init writes it to /etc/frp/frpc.toml and tries to start frpc if available.

  --post-install-hook PATH
                       Optional explicit post-install hook script to run after image write/injection.
                       This replaces the old implicit current-directory hook behavior.

  --hold 1             Only validate and print planned actions, do not download or write disk.
  --hold 2             Perform target-disk write + NoCloud injection but do NOT reboot.

Password / SSH key behaviour:
  - If you specify one or more --ssh-key, you may omit --password (root login via key only).
  - If you specify --password, you may omit --ssh-key.
  - If you specify neither password nor ssh-key:
      * The script will prompt for a root password.
      * If you leave it empty, a random 20-character password (A–Z, a–z, 0–9) will be generated.
      * The generated password will be printed before reboot.
  - Username is always: root
EOF
    exit 1
}

to_lower() {
    printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z'
}

is_port_valid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

http_download() {
    local url="$1" dst="$2" tmp
    tmp="${dst}.part.$$"
    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -L --fail -o "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    elif command -v fetch >/dev/null 2>&1; then
        if ! fetch -o "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    else
        error "No curl/wget/fetch found, cannot download: $url"
    fi

    mv -f "$tmp" "$dst"
}

http_content_length() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsIL "$url" | awk '
            /^[Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); n=$2 }
            END { if (n != "") print n }
        '
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget --server-response --spider "$url" 2>&1 | awk '
            /^  [Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); n=$2 }
            END { if (n != "") print n }
        '
        return 0
    fi

    return 1
}

get_available_bytes() {
    local path="$1"
    df -Pk "$path" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'
}

get_file_size_bytes() {
    local path="$1"

    if [[ ! -e "$path" ]]; then
        return 1
    fi

    if stat -c '%s' "$path" >/dev/null 2>&1; then
        stat -c '%s' "$path"
        return 0
    fi

    if stat -f '%z' "$path" >/dev/null 2>&1; then
        stat -f '%z' "$path"
        return 0
    fi

    return 1
}

precheck_tmp_space_for_image() {
    local url="$1"
    local avail size need

    avail=$(get_available_bytes /tmp)
    [[ -n "$avail" ]] || {
        warn "Could not determine available space under /tmp, skipping space precheck."
        return 0
    }

    size=$(http_content_length "$url" || true)
    [[ -n "$size" ]] || {
        warn "Could not determine remote image size, skipping /tmp space precheck."
        return 0
    }

    if [[ "$url" == *.xz ]]; then
        need=$(( size * 7 ))
    else
        need=$(( size * 3 ))
    fi

    if [[ "$avail" -lt "$need" ]]; then
        error "Insufficient space under /tmp for installation workflow.
Available: ${avail} bytes
Estimated required: ${need} bytes
Remote image size: ${size} bytes"
    fi
}

precheck_tmp_space_for_local_image() {
    local path="$1"
    local avail size need

    avail=$(get_available_bytes /tmp)
    [[ -n "$avail" ]] || {
        warn "Could not determine available space under /tmp, skipping local image /tmp space precheck."
        return 0
    }

    size=$(get_file_size_bytes "$path" || true)
    [[ -n "$size" ]] || {
        warn "Could not determine local image size for $path, skipping /tmp space precheck."
        return 0
    }

    if [[ "$path" == *.xz ]]; then
        need=$(( size * 7 ))
    else
        need=$(( size * 3 ))
    fi

    if [[ "$avail" -lt "$need" ]]; then
        error "Insufficient space under /tmp for offline installation workflow.
Available: ${avail} bytes
Estimated required: ${need} bytes
Local image size: ${size} bytes
Local image path: ${path}"
    fi
}

precheck_bootstrap_space_for_download() {
    local mount_path="$1" url="$2" multiplier="${3:-2}"
    local avail size need

    avail=$(get_available_bytes "$mount_path")
    [[ -n "$avail" ]] || {
        warn "Could not determine available space under $mount_path, skipping bootstrap space precheck."
        return 0
    }

    size=$(http_content_length "$url" || true)
    [[ -n "$size" ]] || {
        warn "Could not determine remote size for $url, skipping bootstrap space precheck."
        return 0
    }

    need=$(( size * multiplier ))

    if [[ "$avail" -lt "$need" ]]; then
        error "Insufficient space on bootstrap storage.
Bootstrap path: ${mount_path}
Available: ${avail} bytes
Estimated required: ${need} bytes
Remote file size: ${size} bytes
URL: ${url}"
    fi
}

lsblk_get_kv() {
    local line="$1" key="$2"
    awk -v want="$key" '
        {
            len = length($0)
            i = 1
            while (i <= len) {
                while (i <= len && substr($0, i, 1) == " ") i++
                if (i > len) break

                eq = index(substr($0, i), "=")
                if (eq == 0) break
                eq = i + eq - 1

                k = substr($0, i, eq - i)
                i = eq + 1

                if (substr($0, i, 1) != "\"") break
                i++

                v = ""
                while (i <= len) {
                    c = substr($0, i, 1)
                    if (c == "\\") {
                        i++
                        if (i <= len) v = v substr($0, i, 1)
                    } else if (c == "\"") {
                        i++
                        break
                    } else {
                        v = v c
                    }
                    i++
                }

                if (k == want) {
                    print v
                    exit
                }
            }
        }
    ' <<<"$line"
}

hash_password() {
    local plain="$1"

    if command -v openssl >/dev/null 2>&1; then
        openssl passwd -6 "$plain"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        if python3 - <<'PY' >/dev/null 2>&1
from passlib.hash import sha512_crypt
print("ok")
PY
        then
            python3 - "$plain" <<'PY'
from passlib.hash import sha512_crypt
import sys
pw = sys.argv[1]
print(sha512_crypt.hash(pw))
PY
            return 0
        fi
    fi

    if command -v perl >/dev/null 2>&1; then
        perl -e '
            use strict;
            use warnings;
            my $pw = shift @ARGV;
            my @chars = ("a".."z","A".."Z",0..9,".","/");
            my $salt = join("", map { $chars[rand @chars] } 1..16);
            my $rounds = 5000;
            my $out = crypt($pw, "\$6\$rounds=$rounds\$$salt\$");
            print "$out\n";
        ' "$plain"
        return 0
    fi

    error "No password hashing tool found. Install openssl, or python3 with passlib, or perl, or use --ssh-key only."
}

detect_os_arch() {
    OS=$(uname -s)
    ARCH=$(uname -m)

    case "$OS" in
        Linux|FreeBSD) ;;
        *) error "Unsupported OS: $OS (only Linux and FreeBSD are supported)" ;;
    esac

    case "$ARCH" in
        x86_64|amd64) MACHINE_ARCH="x86_64" ;;
        aarch64|arm64) MACHINE_ARCH="aarch64" ;;
        *)
            warn "Unknown arch: $ARCH, image URL selection may fail"
            MACHINE_ARCH="$ARCH"
            ;;
    esac
}

# -------- dependencies (auto-install on Red Hat / FreeBSD only) --------

LINUX_FAMILY=""

detect_linux_family() {
    local id_val="" id_like_val="" ids=""
    LINUX_FAMILY=""

    [[ "$OS" == "Linux" ]] || return 0

    if [[ -r /etc/os-release ]]; then
        id_val="$(
            (
                # shellcheck disable=SC1091
                . /etc/os-release 2>/dev/null
                printf '%s' "${ID:-}"
            ) || true
        )"
        id_like_val="$(
            (
                # shellcheck disable=SC1091
                . /etc/os-release 2>/dev/null
                printf '%s' "${ID_LIKE:-}"
            ) || true
        )"

        ids=" ${id_val} ${id_like_val} "

        case "$ids" in
            *" rhel "*|*" rocky "*|*" almalinux "*|*" centos "*|*" fedora "*)
                LINUX_FAMILY="redhat"
                ;;
            *)
                LINUX_FAMILY=""
                ;;
        esac
    fi
}

have_any_downloader() {
    command -v curl >/dev/null 2>&1 || \
    command -v wget >/dev/null 2>&1 || \
    command -v fetch >/dev/null 2>&1
}

missing_deps_linux_common() {
    local missing=()

    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v xz >/dev/null 2>&1 || missing+=("xz")
    command -v file >/dev/null 2>&1 || missing+=("file")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    have_any_downloader || missing+=("downloader")

    ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
}

missing_deps_freebsd_host() {
    local missing=()

    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v xz >/dev/null 2>&1 || missing+=("xz")
    command -v file >/dev/null 2>&1 || missing+=("file")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    have_any_downloader || missing+=("downloader")
    command -v efibootmgr >/dev/null 2>&1 || missing+=("efibootmgr")

    ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
}

missing_deps_freebsd_installer() {
    local missing=()

    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v xz >/dev/null 2>&1 || missing+=("xz")
    command -v file >/dev/null 2>&1 || missing+=("file")
    have_any_downloader || missing+=("downloader")

    ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
}

install_deps_redhat() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)   pkgs+=("qemu-img") ;;
            xz)         pkgs+=("xz") ;;
            file)       pkgs+=("file") ;;
            tar)        pkgs+=("tar") ;;
            downloader) pkgs+=("curl") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v dnf >/dev/null 2>&1 || error "Auto-install requires dnf on Red Hat family system"

    info "Installing missing dependencies with dnf: ${pkgs[*]}"
    dnf install -y "${pkgs[@]}"
}

install_deps_freebsd_host() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)          pkgs+=("qemu-tools") ;;
            xz)                pkgs+=("xz") ;;
            file)              pkgs+=("file") ;;
            tar)               : ;;
            downloader)        pkgs+=("curl") ;;
            efibootmgr)        pkgs+=("efibootmgr") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v pkg >/dev/null 2>&1 || error "Auto-install requires pkg on FreeBSD"

    info "Installing missing dependencies with pkg: ${pkgs[*]}"
    ASSUME_ALWAYS_YES=yes pkg install "${pkgs[@]}"
}

install_deps_freebsd_installer() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)   pkgs+=("qemu-tools") ;;
            xz)         pkgs+=("xz") ;;
            file)       pkgs+=("file") ;;
            downloader) pkgs+=("curl") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v pkg >/dev/null 2>&1 || error "Auto-install requires pkg on FreeBSD"

    info "Installing missing dependencies with pkg: ${pkgs[*]}"
    ASSUME_ALWAYS_YES=yes pkg install "${pkgs[@]}"
}

ensure_dependencies() {
    local missing=()

    if [[ "$OS" == "Linux" ]]; then
        if [[ "$ENV_MODE" == "alpine-ram" ]] || [[ -f /etc/alpine-release ]]; then
            return 0
        fi

        detect_linux_family
        mapfile -t missing < <(missing_deps_linux_common)

        [[ "${#missing[@]}" -gt 0 ]] || return 0

        case "${LINUX_FAMILY:-}" in
            redhat)
                install_deps_redhat "${missing[@]}"
                ;;
            *)
                error "Unsupported Linux family for auto-install. Only Red Hat family Linux is supported.
Missing dependencies: ${missing[*]}"
                ;;
        esac

        mapfile -t missing < <(missing_deps_linux_common)
        [[ "${#missing[@]}" -eq 0 ]] || error "Failed to install required Linux dependencies: ${missing[*]}"
        return 0
    fi

    if [[ "$OS" == "FreeBSD" ]]; then
        if [[ "$ENV_MODE" == "host" ]]; then
            mapfile -t missing < <(missing_deps_freebsd_host)
            [[ "${#missing[@]}" -gt 0 ]] && install_deps_freebsd_host "${missing[@]}"
            mapfile -t missing < <(missing_deps_freebsd_host)
            [[ "${#missing[@]}" -eq 0 ]] || error "Failed to install required FreeBSD host dependencies: ${missing[*]}"
        else
            mapfile -t missing < <(missing_deps_freebsd_installer)
            [[ "${#missing[@]}" -gt 0 ]] && install_deps_freebsd_installer "${missing[@]}"
            mapfile -t missing < <(missing_deps_freebsd_installer)
            [[ "${#missing[@]}" -eq 0 ]] || error "Failed to install required FreeBSD installer dependencies: ${missing[*]}"
        fi
        return 0
    fi
}

# -------- disk detection / confirmation --------

AUTO_DETECTED_DISK=""
AUTO_DETECT_REASON=""
DISK_CANDIDATE_LINES=""
DISK_AUTO_SELECTED=0
DISK_ID_WWN=""
DISK_ID_SERIAL=""
DISK_ID_SIZE=""
DISK_ID_MODEL=""

validate_target_disk() {
    local disk="$1" typ d

    [[ -n "$disk" ]] || error "Target disk is empty"

    if [[ "$OS" == "Linux" ]]; then
        [[ -b "$disk" ]] || error "Target disk $disk is not a block device"
        command -v lsblk >/dev/null 2>&1 || error "lsblk is required to validate the target disk on Linux"
        typ=$(lsblk -ndo TYPE "$disk" 2>/dev/null | head -n1 || true)
        [[ "$typ" == "disk" ]] || error "Target $disk is not a whole disk (lsblk TYPE=${typ:-unknown})"
        return 0
    fi

    [[ -c "$disk" || -b "$disk" ]] || error "Target disk $disk does not exist"
    d="${disk#/dev/}"
    command -v sysctl >/dev/null 2>&1 || error "sysctl is required to validate the target disk on FreeBSD"
    case " $(sysctl -n kern.disks 2>/dev/null || true) " in
        *" $d "*) ;;
        *) error "Target $disk is not a whole disk listed by kern.disks" ;;
    esac
}

normalize_disk_wwn() {
    local v="${1:-}"
    v=$(printf '%s' "$v" | tr 'A-Z' 'a-z' | tr -d '[:space:]:-')
    v="${v#0x}"
    v="${v#naa.}"
    printf '%s\n' "$v"
}

capture_target_disk_identity() {
    local disk="$1" line d

    DISK_ID_WWN=""
    DISK_ID_SERIAL=""
    DISK_ID_SIZE=""
    DISK_ID_MODEL=""

    if [[ "$OS" == "Linux" ]]; then
        line=$(lsblk -b -dn -P -o WWN,SERIAL,SIZE,MODEL "$disk" 2>/dev/null | head -n1 || true)
        [[ -n "$line" ]] || error "Failed to read target disk identity: $disk"
        DISK_ID_WWN=$(normalize_disk_wwn "$(lsblk_get_kv "$line" "WWN")")
        DISK_ID_SERIAL=$(lsblk_get_kv "$line" "SERIAL")
        DISK_ID_SIZE=$(lsblk_get_kv "$line" "SIZE")
        DISK_ID_MODEL=$(lsblk_get_kv "$line" "MODEL")
    else
        d="${disk#/dev/}"
        if command -v diskinfo >/dev/null 2>&1; then
            DISK_ID_SERIAL=$(diskinfo -s "$disk" 2>/dev/null | head -n1 || true)
            DISK_ID_SIZE=$(diskinfo "$disk" 2>/dev/null | awk 'NR==1 {print $3; exit}' || true)
        fi
        if command -v geom >/dev/null 2>&1; then
            DISK_ID_WWN=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*lunid:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
            DISK_ID_WWN=$(normalize_disk_wwn "$DISK_ID_WWN")
            DISK_ID_MODEL=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*descr:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
        fi
    fi

    [[ -n "$DISK_ID_SERIAL" || -n "$DISK_ID_WWN" || -n "$DISK_ID_SIZE" ]] || \
        error "Could not obtain a stable identity for target disk $disk"

    info "Target disk identity: serial=${DISK_ID_SERIAL:-unknown} wwn=${DISK_ID_WWN:-unknown} size=${DISK_ID_SIZE:-unknown}"
}

resolve_target_disk_from_identity() {
    local matches=() line path typ wwn serial size model d
    local bootstrap_part="" bootstrap_disk="" bootstrap_size=""
    local strong_match=0

    # The bootstrap filesystem UUID is a better cross-environment identity than
    # virtio device names/serials.  QEMU/UTM may expose SERIAL/WWN differently
    # between the host kernel and Alpine, while the existing filesystem UUID is
    # stored on disk and remains stable until the destructive write begins.
    if [[ "$OS" == "Linux" && -n "${PLAN_EFI_UUID:-}" ]] && command -v blkid >/dev/null 2>&1; then
        bootstrap_part=$(blkid -U "$PLAN_EFI_UUID" 2>/dev/null || true)
        if [[ -n "$bootstrap_part" && -b "$bootstrap_part" ]]; then
            bootstrap_disk=$(linux_source_to_disk "$bootstrap_part" || true)
            if [[ -n "$bootstrap_disk" && -b "$bootstrap_disk" ]]; then
                bootstrap_size=$(lsblk -b -dn -o SIZE "$bootstrap_disk" 2>/dev/null | head -n1 || true)
                if [[ -z "${DISK_ID_SIZE:-}" || -z "$bootstrap_size" || "$bootstrap_size" == "$DISK_ID_SIZE" ]]; then
                    if [[ -n "${DISK:-}" && "$DISK" != "$bootstrap_disk" ]]; then
                        info "Target disk device name changed: $DISK -> $bootstrap_disk"
                    fi
                    info "Resolved target disk from bootstrap filesystem UUID ${PLAN_EFI_UUID}: ${bootstrap_part} -> ${bootstrap_disk}"
                    DISK="$bootstrap_disk"
                    return 0
                fi
                warn "Bootstrap UUID ${PLAN_EFI_UUID} resolved to ${bootstrap_disk}, but disk size changed (${bootstrap_size} != ${DISK_ID_SIZE}); not trusting it."
            fi
        fi
    fi

    if [[ -z "${DISK_ID_SERIAL:-}" && -z "${DISK_ID_WWN:-}" && -z "${DISK_ID_SIZE:-}" ]]; then
        warn "No saved target disk identity is present; using saved device path: ${DISK:-unset}"
        return 0
    fi

    if [[ "$OS" == "Linux" ]]; then
        while IFS= read -r line; do
            path=$(lsblk_get_kv "$line" "PATH")
            typ=$(lsblk_get_kv "$line" "TYPE")
            wwn=$(normalize_disk_wwn "$(lsblk_get_kv "$line" "WWN")")
            serial=$(lsblk_get_kv "$line" "SERIAL")
            size=$(lsblk_get_kv "$line" "SIZE")
            model=$(lsblk_get_kv "$line" "MODEL")
            [[ "$typ" == "disk" && -n "$path" ]] || continue

            # Saved disk size is always used as an additional guard when known.
            [[ -z "${DISK_ID_SIZE:-}" || "$size" == "$DISK_ID_SIZE" ]] || continue

            strong_match=0
            if [[ -n "${DISK_ID_WWN:-}" && -n "$wwn" && "$wwn" == "$DISK_ID_WWN" ]]; then
                strong_match=1
            elif [[ -n "${DISK_ID_SERIAL:-}" && -n "$serial" && "$serial" == "$DISK_ID_SERIAL" ]]; then
                strong_match=1
            fi

            if [[ "$strong_match" -eq 1 ]]; then
                matches+=("$path")
                continue
            fi

            # Only fall back to size/model when no stable hardware identifier is
            # available on either side.  Never silently ignore a conflicting ID.
            if [[ -z "${DISK_ID_WWN:-}" && -z "${DISK_ID_SERIAL:-}" ]]; then
                [[ -n "${DISK_ID_SIZE:-}" && "$size" == "$DISK_ID_SIZE" ]] || continue
                if [[ -n "${DISK_ID_MODEL:-}" ]]; then
                    [[ "$model" == "$DISK_ID_MODEL" ]] || continue
                fi
                matches+=("$path")
            fi
        done < <(lsblk -b -dn -P -o PATH,TYPE,WWN,SERIAL,SIZE,MODEL 2>/dev/null || true)
    else
        for d in $(sysctl -n kern.disks 2>/dev/null || true); do
            path="/dev/$d"
            serial=$(diskinfo -s "$path" 2>/dev/null | head -n1 || true)
            size=$(diskinfo "$path" 2>/dev/null | awk 'NR==1 {print $3; exit}' || true)
            wwn=""
            model=""
            if command -v geom >/dev/null 2>&1; then
                wwn=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*lunid:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
                wwn=$(normalize_disk_wwn "$wwn")
                model=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*descr:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
            fi

            [[ -z "${DISK_ID_SIZE:-}" || "$size" == "$DISK_ID_SIZE" ]] || continue

            strong_match=0
            if [[ -n "${DISK_ID_WWN:-}" && -n "$wwn" && "$wwn" == "$DISK_ID_WWN" ]]; then
                strong_match=1
            elif [[ -n "${DISK_ID_SERIAL:-}" && -n "$serial" && "$serial" == "$DISK_ID_SERIAL" ]]; then
                strong_match=1
            fi

            if [[ "$strong_match" -eq 1 ]]; then
                matches+=("$path")
                continue
            fi

            if [[ -z "${DISK_ID_WWN:-}" && -z "${DISK_ID_SERIAL:-}" ]]; then
                [[ -n "${DISK_ID_SIZE:-}" && "$size" == "$DISK_ID_SIZE" ]] || continue
                if [[ -n "${DISK_ID_MODEL:-}" ]]; then
                    [[ "$model" == "$DISK_ID_MODEL" ]] || continue
                fi
                matches+=("$path")
            fi
        done
    fi

    if [[ "${#matches[@]}" -ne 1 ]]; then
        warn "Saved target identity: path=${DISK:-unset} wwn=${DISK_ID_WWN:-none} serial=${DISK_ID_SERIAL:-none} size=${DISK_ID_SIZE:-none} model=${DISK_ID_MODEL:-none} bootstrap_uuid=${PLAN_EFI_UUID:-none}"
        if [[ "$OS" == "Linux" ]]; then
            warn "Disks visible in installer environment:"
            lsblk -b -dn -o PATH,TYPE,WWN,SERIAL,SIZE,MODEL 2>/dev/null >&2 || true
        fi
        error "Saved target disk identity matched ${#matches[@]} disks; refusing destructive write. Matches: ${matches[*]:-(none)}"
    fi

    if [[ -n "${DISK:-}" && "$DISK" != "${matches[0]}" ]]; then
        info "Target disk device name changed: $DISK -> ${matches[0]}"
    fi
    DISK="${matches[0]}"
}

get_disk_size_bytes() {
    local disk="$1"
    if [[ "$OS" == "Linux" ]]; then
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --getsize64 "$disk" 2>/dev/null && return 0
        fi
        lsblk -b -dn -o SIZE "$disk" 2>/dev/null | head -n1
        return 0
    fi
    diskinfo "$disk" 2>/dev/null | awk 'NR==1 {print $3; exit}'
}

unmount_target_disk_filesystems() {
    local disk="$1" dev mnt d sysname holder_found holder

    cd /

    if [[ "$OS" == "Linux" ]]; then
        command -v lsblk >/dev/null 2>&1 || error "lsblk is required before destructive write"

        if command -v swapon >/dev/null 2>&1 && command -v swapoff >/dev/null 2>&1; then
            while IFS= read -r dev; do
                [[ -n "$dev" ]] || continue
                if lsblk -nrpo NAME "$disk" 2>/dev/null | grep -Fxq "$dev"; then
                    info "Disabling swap on target disk: $dev"
                    swapoff "$dev" || error "Failed to disable target-disk swap: $dev"
                fi
            done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
        fi

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            while IFS= read -r mnt; do
                [[ -n "$mnt" ]] || continue
                info "Unmounting target-disk filesystem: $dev from $mnt"
                if ! umount "$mnt"; then
                    warn "Failed to unmount $mnt; dumping mount/loop diagnostics before aborting."
                    findmnt -R "$mnt" 2>/dev/null || true
                    losetup -a 2>/dev/null || true
                    if command -v fuser >/dev/null 2>&1; then
                        fuser -vm "$mnt" 2>/dev/null || true
                    fi
                    error "Failed to unmount target-disk filesystem: $mnt"
                fi
            done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null | tac)

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            if findmnt -rn -S "$dev" >/dev/null 2>&1; then
                error "A target-disk filesystem is still mounted on $dev; refusing dd"
            fi
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null)

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            sysname="${dev#/dev/}"
            sysname="${sysname//\//!}"
            holder_found=0
            if [[ -d "/sys/class/block/$sysname/holders" ]]; then
                for holder in "/sys/class/block/$sysname/holders/"*; do
                    [[ -e "$holder" ]] || continue
                    holder_found=1
                    break
                done
            fi
            [[ "$holder_found" -eq 0 ]] || error "Target-disk device $dev still has active block holders; refusing dd"
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null)
        return 0
    fi

    d="${disk#/dev/}"
    while read -r dev _ mnt _; do
        case "$dev" in
            /dev/${d}p*|/dev/${d}s*|/dev/${d})
                info "Unmounting target-disk filesystem: $dev from $mnt"
                umount "$mnt" || error "Failed to unmount target-disk filesystem: $mnt"
                ;;
        esac
    done < <(mount -p 2>/dev/null || true)
}

linux_source_to_disk() {
    local src="$1" name pkname typ
    [[ -n "$src" ]] || return 1
    [[ -b "$src" ]] || return 1

    if command -v lsblk >/dev/null 2>&1; then
        pkname=$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1 || true)
        if [[ -n "$pkname" ]]; then
            echo "/dev/$pkname"
            return 0
        fi

        typ=$(lsblk -ndo TYPE "$src" 2>/dev/null | head -n1 || true)
        name=$(lsblk -ndo NAME "$src" 2>/dev/null | head -n1 || true)
        if [[ "$typ" == "disk" && -n "$name" ]]; then
            echo "/dev/$name"
            return 0
        fi
    fi

    case "$src" in
        /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*)
            echo "${src%p*}"
            return 0
            ;;
        /dev/sd[a-z][0-9]*|/dev/vd[a-z][0-9]*|/dev/xvd[a-z][0-9]*)
            echo "${src%%[0-9]*}"
            return 0
            ;;
    esac

    return 1
}

linux_find_mount_source() {
    local mnt="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o SOURCE --target "$mnt" 2>/dev/null | head -n1 || true
    fi
}

linux_current_root_disk() {
    local src
    src=$(linux_find_mount_source "/")
    [[ -n "$src" ]] || return 1
    linux_source_to_disk "$src"
}

linux_current_boot_disk() {
    local src
    src=$(linux_find_mount_source "/boot")
    [[ -n "$src" ]] || return 1
    linux_source_to_disk "$src"
}

linux_current_efi_disk() {
    local src
    src=$(linux_find_mount_source "/boot/efi")
    [[ -n "$src" ]] || return 1
    linux_source_to_disk "$src"
}

linux_is_partition_of_disk() {
    local part="$1" disk="$2" pk
    [[ -n "$part" && -n "$disk" ]] || return 1
    [[ -b "$part" && -b "$disk" ]] || return 1

    pk=$(linux_source_to_disk "$part" || true)
    [[ -n "$pk" && "$pk" == "$disk" ]]
}

is_mountpoint() {
    local path="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path" 2>/dev/null
        return $?
    fi

    # FreeBSD base system has no util-linux mountpoint(1). mount -p prints
    # fstab-style records: device, mountpoint, fstype, options, dump, pass.
    mount -p 2>/dev/null | awk -v mp="$path" '
        $2 == mp {
            found=1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

freebsd_mount_source_for() {
    local mountpoint="$1"

    mount -p 2>/dev/null | awk -v mp="$mountpoint" '
        $2 == mp {
            print $1
            exit
        }
    '
}

freebsd_provider_to_disk() {
    local source="$1"
    local provider disks d resolved=""

    [[ -n "$source" ]] || return 1
    provider="${source#/dev/}"
    disks=$(sysctl -n kern.disks 2>/dev/null || true)
    [[ -n "$disks" ]] || return 1

    # Fast path for normal FreeBSD partition names such as:
    #   nda0p4, ada0p3, da0p2, vtbd0p4
    # and MBR/BSD forms such as da0s1a.
    for d in $disks; do
        case "$provider" in
            "$d"|"$d"p[0-9]*|"$d"s[0-9]*)
                printf '/dev/%s\n' "$d"
                return 0
                ;;
        esac
    done

    # Labels such as /dev/gpt/rootfs, /dev/ufs/rootfs and similar providers
    # appear below their backing PART/DISK provider in GEOM's hierarchy.
    if command -v geom >/dev/null 2>&1; then
        resolved=$(
            geom -t 2>/dev/null | awk -v target="$provider" '
                /^[^[:space:]]/ && $2 == "DISK" {
                    disk=$1
                }
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i == target && disk != "") {
                            print "/dev/" disk
                            exit
                        }
                    }
                }
            '
        )
        if [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    fi

    return 1
}

print_disk_candidates() {
    [[ -n "$DISK_CANDIDATE_LINES" ]] || return 0
    echo
    echo "Detected target disk candidates:"
    printf '%s\n' "$DISK_CANDIDATE_LINES"
    echo
    echo "Recommended disk: $AUTO_DETECTED_DISK"
    echo "Reason: $AUTO_DETECT_REASON"
    echo
}

confirm_auto_detected_disk_host() {
    [[ "$DISK_AUTO_SELECTED" -eq 1 ]] || return 0
    print_disk_candidates
    while :; do
        read -r -p "Use recommended disk '$AUTO_DETECTED_DISK'? [yes/no]: " ans
        case "$ans" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                error "Auto-detected disk was not accepted. Please rerun with --disk /dev/XXX"
                ;;
            *)
                echo "Please type yes or no."
                ;;
        esac
    done
}

auto_detect_disk() {
    info "Auto-detecting target disk..."

    DISK_CANDIDATE_LINES=""
    AUTO_DETECTED_DISK=""
    AUTO_DETECT_REASON=""
    DISK_AUTO_SELECTED=0

    if [[ "$OS" == "Linux" ]]; then
        if command -v lsblk >/dev/null 2>&1; then
            local best_name="" best_size=0
            local root_disk="" boot_disk="" efi_disk=""
            local preferred=""
            local idx=0
            local line name type rm size disk_path marker reason

            root_disk=$(linux_current_root_disk || true)
            boot_disk=$(linux_current_boot_disk || true)
            efi_disk=$(linux_current_efi_disk || true)

            if [[ -n "$root_disk" ]]; then
                info "Current / appears to be on: $root_disk"
            fi
            if [[ -n "$boot_disk" ]]; then
                info "Current /boot appears to be on: $boot_disk"
            fi
            if [[ -n "$efi_disk" ]]; then
                info "Current EFI appears to be on: $efi_disk"
            fi

            if [[ -n "$root_disk" && -n "$boot_disk" && -n "$efi_disk" &&
                  "$root_disk" == "$boot_disk" && "$boot_disk" == "$efi_disk" ]]; then
                preferred="$root_disk"
                AUTO_DETECT_REASON="current /, /boot, and EFI all resolve to the same disk"
            elif [[ -n "$root_disk" ]]; then
                preferred="$root_disk"
                AUTO_DETECT_REASON="current / resolves to this disk"
            elif [[ -n "$boot_disk" ]]; then
                preferred="$boot_disk"
                AUTO_DETECT_REASON="current /boot resolves to this disk"
            elif [[ -n "$efi_disk" ]]; then
                preferred="$efi_disk"
                AUTO_DETECT_REASON="current EFI resolves to this disk"
            fi

            while read -r name type rm size; do
                [[ "$type" == "disk" ]] || continue
                [[ "$rm" == "0" ]] || continue

                disk_path="/dev/$name"
                marker=""
                reason=""

                if [[ -n "$root_disk" && "$disk_path" == "$root_disk" ]]; then
                    marker+=" root"
                fi
                if [[ -n "$boot_disk" && "$disk_path" == "$boot_disk" ]]; then
                    marker+=" boot"
                fi
                if [[ -n "$efi_disk" && "$disk_path" == "$efi_disk" ]]; then
                    marker+=" efi"
                fi
                if [[ -n "$preferred" && "$disk_path" == "$preferred" ]]; then
                    marker+=" recommended"
                    reason="$AUTO_DETECT_REASON"
                fi

                idx=$(( idx + 1 ))
                if [[ -n "$DISK_CANDIDATE_LINES" ]]; then
                    DISK_CANDIDATE_LINES+=$'\n'
                fi
                if [[ -n "$marker" ]]; then
                    DISK_CANDIDATE_LINES+=$(printf '  [%d] %-16s size=%s bytes markers:%s%s' "$idx" "$disk_path" "$size" "$marker" "${reason:+ ($reason)}")
                else
                    DISK_CANDIDATE_LINES+=$(printf '  [%d] %-16s size=%s bytes' "$idx" "$disk_path" "$size")
                fi

                if [[ "$size" -gt "$best_size" ]]; then
                    best_size="$size"
                    best_name="$name"
                fi
            done < <(lsblk -b -ndo NAME,TYPE,RM,SIZE 2>/dev/null || true)

            if [[ -n "$preferred" ]]; then
                AUTO_DETECTED_DISK="$preferred"
                DISK="$preferred"
                DISK_AUTO_SELECTED=1
                info "Auto-detected disk: $DISK ($AUTO_DETECT_REASON)"
                return 0
            fi

            if [[ -n "$best_name" ]]; then
                warn "Could not resolve the current system disk confidently. Refusing to choose the largest disk automatically."
            fi
        fi
        error "Unable to auto-detect target disk on Linux. Please specify --disk explicitly."
    else
        if command -v sysctl >/dev/null 2>&1; then
            local disks size d idx=0 candidate_count=0
            local only_disk="" root_source="" root_disk=""
            local marker="" reason=""

            disks=$(sysctl -n kern.disks 2>/dev/null || true)

            root_source=$(freebsd_mount_source_for "/" || true)
            if [[ -n "$root_source" ]]; then
                info "Current / is mounted from: $root_source"
                root_disk=$(freebsd_provider_to_disk "$root_source" || true)
                if [[ -n "$root_disk" ]]; then
                    info "Current / resolves through GEOM to: $root_disk"
                fi
            fi

            for d in $disks; do
                case "$d" in
                    cd*|md*|lo*|ram*) continue ;;
                esac

                if command -v diskinfo >/dev/null 2>&1; then
                    size=$(diskinfo "/dev/$d" 2>/dev/null | awk 'NR==1 {print $3; exit}')
                else
                    size=0
                fi
                [[ -z "$size" ]] && size=0

                candidate_count=$(( candidate_count + 1 ))
                only_disk="/dev/$d"
                marker=""
                reason=""

                if [[ -n "$root_disk" && "/dev/$d" == "$root_disk" ]]; then
                    marker=" root recommended"
                    reason="current / resolves through FreeBSD GEOM to this disk"
                fi

                idx=$(( idx + 1 ))
                if [[ -n "$DISK_CANDIDATE_LINES" ]]; then
                    DISK_CANDIDATE_LINES+=$'\n'
                fi

                if [[ -n "$marker" ]]; then
                    DISK_CANDIDATE_LINES+=$(printf '  [%d] %-16s size=%s bytes markers:%s (%s)' \
                        "$idx" "/dev/$d" "$size" "$marker" "$reason")
                else
                    DISK_CANDIDATE_LINES+=$(printf '  [%d] %-16s size=%s bytes' \
                        "$idx" "/dev/$d" "$size")
                fi
            done

            if [[ -n "$root_disk" ]]; then
                for d in $disks; do
                    case "$d" in
                        cd*|md*|lo*|ram*) continue ;;
                    esac
                    if [[ "/dev/$d" == "$root_disk" ]]; then
                        AUTO_DETECTED_DISK="$root_disk"
                        DISK="$root_disk"
                        AUTO_DETECT_REASON="current / resolves through FreeBSD GEOM to this disk"
                        DISK_AUTO_SELECTED=1
                        info "Auto-detected disk: $DISK ($AUTO_DETECT_REASON)"
                        return 0
                    fi
                done
                warn "Current root resolved to $root_disk, but it is not present in the usable kern.disks candidate list."
            fi

            if [[ "$candidate_count" -eq 1 && -n "$only_disk" ]]; then
                AUTO_DETECTED_DISK="$only_disk"
                DISK="$only_disk"
                AUTO_DETECT_REASON="only one usable physical disk is present"
                DISK_AUTO_SELECTED=1
                info "Auto-detected disk: $DISK ($AUTO_DETECT_REASON)"
                return 0
            fi

            if [[ "$candidate_count" -gt 1 ]]; then
                warn "Multiple FreeBSD disks are present and the current root disk could not be resolved confidently."
            fi
        fi
        error "Unable to auto-detect target disk on FreeBSD. Please specify --disk explicitly."
    fi
}

show_partition_info() {
    echo
    echo "---------------- Disk partition layout ----------------"
    if [[ "$OS" == "Linux" ]]; then
        if command -v lsblk >/dev/null 2>&1; then
            lsblk "$DISK" || true
        elif command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" || true
        else
            echo "Could not show partition info (no lsblk/fdisk)."
        fi
    else
        if command -v gpart >/dev/null 2>&1; then
            local d="${DISK#/dev/}"
            gpart show "$d" 2>/dev/null || gpart show "$DISK" 2>/dev/null || echo "Could not show partition info with gpart."
        else
            echo "Could not show partition info (no gpart)."
        fi
    fi
    echo "-------------------------------------------------------"
}

# Explicit post-install hook only.
run_rhel_freebsd_hook() {
    if [[ -z "${POST_INSTALL_HOOK:-}" ]]; then
        return 0
    fi

    if [[ ! -f "$POST_INSTALL_HOOK" ]]; then
        warn "Post-install hook not found: $POST_INSTALL_HOOK"
        return 0
    fi

    info "Running explicit post-install hook: $POST_INSTALL_HOOK"
    if ! bash "$POST_INSTALL_HOOK"; then
        warn "Post-install hook failed: $POST_INSTALL_HOOK"
    fi
}

parse_ssh_key() {
    local val="$1"
    local val_lower key_url tmpfile ssh_key

    ssh_key_error_and_exit() {
        error "$1
Available options:
  --ssh-key \"ssh-rsa ...\"
  --ssh-key \"ssh-ed25519 ...\"
  --ssh-key \"ecdsa-sha2-nistp(256|384|521) ...\"
  --ssh-key github:your_username
  --ssh-key gitlab:your_username
  --ssh-key http://path/to/public_key
  --ssh-key https://path/to/public_key
  --ssh-key /path/to/public_key
  --ssh-key C:\\path\\to\\public_key (not supported directly, copy to a local path first)"
    }

    is_valid_ssh_key() {
        grep -qE '^(ecdsa-sha2-nistp(256|384|521)|ssh-(ed25519|rsa)) ' <<<"$1"
    }

    val_lower=$(to_lower "$val")

    case "$val_lower" in
        github:*|gitlab:*|http://*|https://*)
            if [[ "$val_lower" == http* ]]; then
                key_url="$val"
            else
                local site user extra
                IFS=: read -r site user extra <<<"$val"
                [[ -n "$user" ]] || ssh_key_error_and_exit "Need a username for $site"
                site=$(to_lower "$site")
                key_url="https://$site.com/$user.keys"
            fi
            info "Downloading SSH key from: $key_url"
            tmpfile=$(mktemp /tmp/reinstall-sshkey.XXXXXX)
            if ! http_download "$key_url" "$tmpfile"; then
                rm -f "$tmpfile"
                ssh_key_error_and_exit "Failed to download SSH key from $key_url"
            fi
            ssh_key=$(grep -m1 -E '^(ecdsa-sha2-nistp(256|384|521)|ssh-(ed25519|rsa)) ' "$tmpfile" || true)
            rm -f "$tmpfile"
            [[ -n "$ssh_key" ]] || ssh_key_error_and_exit "No valid SSH key found in $key_url"
            ;;
        *)
            if [[ "$val" =~ ^[A-Za-z]:\\ ]]; then
                ssh_key_error_and_exit "Windows path is not supported, please copy the key file to local filesystem and use /path/to/public_key"
            fi
            if is_valid_ssh_key "$val"; then
                ssh_key="$val"
            else
                if [[ ! -f "$val" ]]; then
                    ssh_key_error_and_exit "SSH key/file/url \"$val\" is invalid (file not found)"
                fi
                ssh_key=$(grep -m1 -E '^(ecdsa-sha2-nistp(256|384|521)|ssh-(ed25519|rsa)) ' "$val" || true)
                [[ -n "$ssh_key" ]] || ssh_key_error_and_exit "No valid SSH key found in file: $val"
            fi
            ;;
    esac

    echo "$ssh_key"
}

get_default_image_url() {
    local os="$1" ver="$2"

    case "$os" in
        freebsd)
            case "$ver" in
                14)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/amd64/Latest/FreeBSD-14.5-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        aarch64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/aarch64/Latest/FreeBSD-14.5-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic FreeBSD image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                15)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        aarch64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/aarch64/Latest/FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic FreeBSD image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported FreeBSD major version: $ver (supported: 14 -> latest 14.x, 15 -> latest 15.x)"
                    ;;
            esac
            ;;
        rocky)
            case "$ver" in
                10)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-EC2-LVM.latest.x86_64.qcow2"
                            ;;
                        aarch64)
                            echo "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-EC2-LVM.latest.aarch64.qcow2"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic Rocky image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported Rocky version: $ver (future: add rocky 9, etc.)"
                    ;;
            esac
            ;;
        almalinux)
            case "$ver" in
                10)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2"
                            ;;
                        aarch64)
                            echo "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic AlmaLinux image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported AlmaLinux version: $ver"
                    ;;
            esac
            ;;
        fedora)
            case "$ver" in
                44)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
                            ;;
                        aarch64)
                            echo "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic Fedora image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported Fedora version: $ver"
                    ;;
            esac
            ;;
        debian)
            case "$ver" in
                13)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
                            ;;
                        aarch64)
                            echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic Debian image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported Debian version: $ver (supported: 13)"
                    ;;
            esac
            ;;
        redhat)
            echo ""
            ;;
        *)
            error "Unknown target OS: $os"
            ;;
    esac
}

find_efi_partition() {
    local disk="$1"

    if [[ "$OS" == "Linux" ]]; then
        if command -v findmnt >/dev/null 2>&1; then
            local mounted_efi_src mounted_efi_disk
            mounted_efi_src=$(findmnt -n -o SOURCE --target /boot/efi 2>/dev/null | head -n1 || true)
            if [[ -n "$mounted_efi_src" ]]; then
                mounted_efi_disk=$(linux_source_to_disk "$mounted_efi_src" || true)
                if [[ -n "$mounted_efi_disk" && "$mounted_efi_disk" == "$disk" ]]; then
                    echo "$mounted_efi_src"
                    return 0
                fi
            fi
        fi

        if command -v lsblk >/dev/null 2>&1; then
            local line part path pkname parttype fstype partlabel partflags
            while read -r line; do
                path=$(lsblk_get_kv "$line" "PATH")
                pkname=$(lsblk_get_kv "$line" "PKNAME")
                parttype=$(lsblk_get_kv "$line" "PARTTYPE")
                fstype=$(lsblk_get_kv "$line" "FSTYPE")
                partlabel=$(lsblk_get_kv "$line" "PARTLABEL")
                partflags=$(lsblk_get_kv "$line" "PARTFLAGS")

                [[ -n "$path" && -n "$pkname" ]] || continue
                [[ "/dev/$pkname" == "$disk" ]] || continue

                if [[ "$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                    echo "$path"
                    return 0
                fi
                if echo "${partlabel:-}" | grep -qiE 'efi|esp'; then
                    echo "$path"
                    return 0
                fi
                if [[ "$fstype" == "vfat" ]] && echo "${partflags:-}" | grep -qi 'boot,esp'; then
                    echo "$path"
                    return 0
                fi
            done < <(lsblk -P -o PATH,PKNAME,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS "$disk" 2>/dev/null || true)
        fi

        warn "Could not confidently identify EFI partition on $disk from lsblk metadata."
        return 1
    else
        if command -v gpart >/dev/null 2>&1; then
            local d p
            d="${disk#/dev/}"
            p=$(gpart show -p "$d" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
            if [[ -n "$p" ]]; then
                echo "/dev/$p"
                return 0
            fi
        fi
        warn "Could not confidently identify EFI partition on $disk from gpart metadata."
        return 1
    fi
}

write_nocloud_seed() {
    local os="$1" meta_path="$2" user_path="$3"
    local frpc_b64=""

    mkdir -p "$(dirname "$meta_path")"

    cat >"$meta_path" <<EOF
instance-id: iid-$(date +%s)
local-hostname: $os
EOF

    if [[ -n "${FRPC_PRESENT:-}" && -n "${FRPC_TOML:-}" && -f "$FRPC_TOML" ]]; then
        frpc_b64=$(base64 <"$FRPC_TOML" | tr -d '\n')
    fi

    {
        echo "#cloud-config"

        if [[ "$os" == "freebsd" ]]; then
            # FreeBSD BASIC-CLOUDINIT images use nuageinit rather than Python
            # cloud-init. Existing root password changes belong under chpasswd;
            # SSH authorized keys for root are supplied with the top-level
            # ssh_authorized_keys key.
            echo "disable_root: false"

            if [[ -n "$PASSWORD_HASH" ]]; then
                echo "ssh_pwauth: true"
            else
                echo "ssh_pwauth: false"
            fi

            if [[ -n "$SSH_KEYS_ALL" ]]; then
                echo "ssh_authorized_keys:"
                while IFS= read -r line; do
                    [[ -n "$line" ]] || continue
                    printf '  - %s\n' "$line"
                done <<<"$SSH_KEYS_ALL"
            fi

            if [[ -n "$PASSWORD_HASH" ]]; then
                echo
                echo "chpasswd:"
                echo "  expire: false"
                echo "  users:"
                echo "    - name: root"
                echo "      password: \"${PASSWORD_HASH}\""
            fi
        else
            # Linux cloud images use Python cloud-init. root already exists in
            # those images, so hashed_passwd is used rather than creation-only
            # passwd.
            if [[ -n "$PASSWORD_HASH" || -n "$SSH_KEYS_ALL" ]]; then
                if [[ -n "$PASSWORD_HASH" ]]; then
                    echo "ssh_pwauth: true"
                else
                    echo "ssh_pwauth: false"
                fi
                echo "disable_root: false"
                echo "users:"
                echo "  - name: root"

                if [[ -n "$PASSWORD_HASH" ]]; then
                    echo "    lock_passwd: false"
                    echo "    hashed_passwd: \"${PASSWORD_HASH}\""
                else
                    echo "    lock_passwd: true"
                fi

                if [[ -n "$SSH_KEYS_ALL" ]]; then
                    echo "    ssh_authorized_keys:"
                    while IFS= read -r line; do
                        [[ -n "$line" ]] || continue
                        printf '      - %s\n' "$line"
                    done <<<"$SSH_KEYS_ALL"
                fi
            fi
        fi

        if [[ -n "$WEB_PORT" || -n "$frpc_b64" ]]; then
            echo
            echo "write_files:"
        fi

        if [[ -n "$WEB_PORT" ]]; then
            cat <<EOF
  - path: /etc/reinstall-web-port
    permissions: '0644'
    owner: root:root
    content: |
      $WEB_PORT
EOF
        fi

        if [[ -n "$frpc_b64" ]]; then
            cat <<EOF
  - path: /etc/frp/frpc.toml
    permissions: '0600'
    owner: root:root
    encoding: b64
    content: $frpc_b64
EOF
        fi

        # FreeBSD nuageinit and Linux cloud-init both support runcmd. Keep the
        # existing service-adjustment behavior, but make root SSH policy explicit
        # on FreeBSD so key-only and password-enabled setups behave predictably.
        if [[ -n "$SSH_PORT" || -n "$frpc_b64" || "$os" == "freebsd" ]]; then
            echo
            echo "runcmd:"
        fi

        if [[ "$os" == "freebsd" ]]; then
            cat <<EOF
  - |
      if [ -f /etc/ssh/sshd_config ]; then
        awk '
          /^[[:space:]]*PermitRootLogin[[:space:]]+/ { next }
          /^[[:space:]]*PasswordAuthentication[[:space:]]+/ { next }
          { print }
          END {
            if ("${PASSWORD_HASH}" != "") {
              print "PermitRootLogin yes"
              print "PasswordAuthentication yes"
            } else {
              print "PermitRootLogin prohibit-password"
              print "PasswordAuthentication no"
            }
          }
        ' /etc/ssh/sshd_config > /tmp/sshd_config.reinstall && \
        cat /tmp/sshd_config.reinstall > /etc/ssh/sshd_config && \
        rm -f /tmp/sshd_config.reinstall
      fi
      service sshd restart 2>/dev/null || true
EOF
        fi

        if [[ -n "$SSH_PORT" ]]; then
            cat <<EOF
  - |
      if [ -f /etc/ssh/sshd_config ]; then
        awk '
          /^[[:space:]]*Port[[:space:]]+/ { next }
          { print }
          END { print "Port ${SSH_PORT}" }
        ' /etc/ssh/sshd_config > /tmp/sshd_config.reinstall && \
        cat /tmp/sshd_config.reinstall > /etc/ssh/sshd_config && \
        rm -f /tmp/sshd_config.reinstall
      fi
      if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp ${SSH_PORT} 2>/dev/null || true
      fi
      if command -v sshd >/dev/null 2>&1; then
        sshd -t || exit 1
      fi
      systemctl restart sshd 2>/dev/null || \
      systemctl restart ssh 2>/dev/null || \
      service sshd restart 2>/dev/null || \
      service ssh restart 2>/dev/null || exit 1
EOF
        fi

        if [[ -n "$frpc_b64" ]]; then
            cat <<'EOF'
  - |
      if [ -f /etc/frp/frpc.toml ]; then
        (frpc -c /etc/frp/frpc.toml || /usr/local/bin/frpc -c /etc/frp/frpc.toml || true) &
      fi
EOF
        fi
    } >"$user_path"
}


# ----------------- environment + plan handling -----------------

ENV_MODE="host"
EFI_MOUNT_POINT="/boot/efi"
PLAN_DIR_REL="REINSTALL"
PLAN_FILE_NAME="plan.env"
PLAN_EFI_PART=""
PLAN_EFI_UUID=""
PLAN_EFI_FS_TYPE=""
PLAN_EFI_MOUNTED_BY_SCRIPT=0
PLAN_STORAGE_MODE="efi"
PLAN_PATH_PREFIX_REL=""
PLAN_EFI_PART_DISK=""
PLAN_EFI_PART_NUM=""
POST_INSTALL_HOOK=""

# Alpine RAM preparation
ALPINE_ENTRY_TITLE="Reinstall Alpine RAM"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.22"
ALPINE_NETBOOT_SUBDIR="netboot-3.22.6"
ALPINE_BOOT_SUBDIR="alpine"
ALPINE_BOOT_DIR_REL=""
ALPINE_BOOT_DIR_ABS=""
ALPINE_VMLINUZ_REL=""
ALPINE_INITRAMFS_REL=""
ALPINE_MODLOOP_REL=""
ALPINE_MODLOOP_URL=""
ALPINE_APKOVL_REL=""
ALPINE_VMLINUZ_ABS=""
ALPINE_INITRAMFS_ABS=""
ALPINE_MODLOOP_ABS=""
ALPINE_APKOVL_ABS=""
ALPINE_SCRIPT_COPY_ABS=""
ALPINE_FREEBSD_GRUB_EFI_REL=""
ALPINE_FREEBSD_GRUB_EFI_ABS=""
ALPINE_FREEBSD_GRUB_CFG_REL=""
ALPINE_FREEBSD_GRUB_CFG_ABS=""
ALPINE_NETBOOT_ARCH=""
ALPINE_KERNEL_FLAVOR=""
GRUB_SCRIPT_PATH=""
GRUB_CFG_PATH=""
GRUB_MKCONFIG_CMD=""
GRUB_REBOOT_CMD=""
GRUB_DEFAULT_CMD=""
GRUB_EFI_TARGET=""
CURRENT_CONSOLE_ARGS=""
AUTO_YES=0
PASSWORD_TO_DISPLAY=""

# Offline bundle paths
BOOTSTRAP_CACHE_DIR_REL=""
BOOTSTRAP_CACHE_DIR_ABS=""
BOOTSTRAP_APKREPO_DIR_REL=""
BOOTSTRAP_APKREPO_DIR_ABS=""
BOOTSTRAP_APKREPO_MAIN_REL=""
BOOTSTRAP_APKREPO_MAIN_ABS=""
BOOTSTRAP_APKREPO_COMMUNITY_REL=""
BOOTSTRAP_APKREPO_COMMUNITY_ABS=""
BOOTSTRAP_IMG_REL=""
BOOTSTRAP_IMG_ABS=""
BOOTSTRAP_IMG_NAME=""
BOOTSTRAP_INPUT_DIR_REL=""
BOOTSTRAP_INPUT_DIR_ABS=""
FRPC_BOOTSTRAP_REL=""
POST_INSTALL_HOOK_BOOTSTRAP_REL=""

ALPINE_RUNTIME_PKGS=(
    bash curl wget ca-certificates xz qemu-img util-linux coreutils grep sed gawk findutils file tar
    e2fsprogs dosfstools sgdisk kmod
)

detect_env_mode() {
    local os
    os=$(uname -s)
    case "$os" in
        FreeBSD)
            if [[ -f /etc/mfsbsd.conf ]] || grep -qi 'mfsbsd' /etc/motd 2>/dev/null; then
                ENV_MODE="mfsbsd"
            else
                ENV_MODE="host"
            fi
            ;;
        Linux)
            if grep -qw 'reinstall_alpine=1' /proc/cmdline 2>/dev/null; then
                ENV_MODE="alpine-ram"
            elif grep -qw 'rd.reinstall=1' /proc/cmdline 2>/dev/null || { [[ -d /run/initramfs ]] && [[ ! -f /etc/os-release ]]; }; then
                ENV_MODE="initramfs"
            else
                ENV_MODE="host"
            fi
            ;;
        *)
            ENV_MODE="host"
            ;;
    esac
}

find_efi_for_plan() {
    local os
    os=$(uname -s)
    if [[ "$os" == "Linux" ]]; then
        if command -v findmnt >/dev/null 2>&1; then
            local mounted_src
            mounted_src=$(findmnt -n -o SOURCE --target /boot/efi 2>/dev/null | head -n1 || true)
            if [[ -n "$mounted_src" && -b "$mounted_src" ]]; then
                echo "$mounted_src"
                return 0
            fi
        fi

        if command -v lsblk >/dev/null 2>&1; then
            local line name type parttype partlabel partflags fstype path
            while read -r line; do
                path=$(lsblk_get_kv "$line" "PATH")
                name=$(lsblk_get_kv "$line" "NAME")
                type=$(lsblk_get_kv "$line" "TYPE")
                parttype=$(lsblk_get_kv "$line" "PARTTYPE")
                fstype=$(lsblk_get_kv "$line" "FSTYPE")
                partlabel=$(lsblk_get_kv "$line" "PARTLABEL")
                partflags=$(lsblk_get_kv "$line" "PARTFLAGS")

                [[ "$type" == "part" ]] || continue
                if [[ "$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] ||
                   echo "${partlabel:-}" | grep -qiE 'efi|esp' ||
                   { [[ "$fstype" == "vfat" ]] && echo "${partflags:-}" | grep -qi 'boot,esp'; }; then
                    if [[ -n "$path" ]]; then
                        echo "$path"
                    else
                        echo "/dev/$name"
                    fi
                    return 0
                fi
            done < <(lsblk -P -o PATH,NAME,TYPE,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS 2>/dev/null || true)
        fi
    elif [[ "$os" == "FreeBSD" ]]; then
        if command -v sysctl >/dev/null 2>&1 && command -v gpart >/dev/null 2>&1; then
            local d p preferred=""

            # Bootstrap must be written to the ESP on the same physical disk that
            # will be reinstalled. Prefer the already selected target disk.
            if [[ -n "${DISK:-}" ]]; then
                preferred="${DISK#/dev/}"
                p=$(gpart show -p "$preferred" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [[ -n "$p" ]]; then
                    echo "/dev/$p"
                    return 0
                fi
            fi

            # Fallback only when no target-disk ESP was found.
            for d in $(sysctl -n kern.disks 2>/dev/null || true); do
                [[ -n "$preferred" && "$d" == "$preferred" ]] && continue
                p=$(gpart show -p "$d" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [[ -n "$p" ]]; then
                    echo "/dev/$p"
                    return 0
                fi
            done
        fi
    fi
    return 1
}

get_fs_uuid_linux() {
    local dev="$1"
    if command -v blkid >/dev/null 2>&1; then
        blkid -s UUID -o value "$dev" 2>/dev/null || true
    fi
}

get_fs_type_linux() {
    local dev="$1"
    if command -v blkid >/dev/null 2>&1; then
        blkid -s TYPE -o value "$dev" 2>/dev/null || true
    fi
}

get_fs_uuid_freebsd() {
    local dev="$1"
    local desc="" serial=""

    # FreeBSD fstyp(8) has no filesystem-UUID output mode.  For FAT/MS-DOS
    # filesystems, file(1) reports the 32-bit volume serial number, which is
    # the same identifier Linux blkid/GRUB expose as XXXX-XXXX.
    command -v file >/dev/null 2>&1 || return 0
    desc=$(file -s "$dev" 2>/dev/null || true)

    if [[ "$desc" =~ serial[[:space:]]number[[:space:]]0x([0-9A-Fa-f]{1,8}) ]]; then
        serial="${BASH_REMATCH[1]}"
    else
        return 0
    fi

    while ((${#serial} < 8)); do
        serial="0${serial}"
    done
    serial="${serial^^}"

    printf '%s-%s\n' "${serial:0:4}" "${serial:4:4}"
}

get_fs_type_freebsd() {
    local dev="$1"
    if command -v fstyp >/dev/null 2>&1; then
        fstyp "$dev" 2>/dev/null || true
    fi
}

split_freebsd_part_device() {
    local part="$1"
    local dev="${part#/dev/}"

    case "$dev" in
        *p[0-9]*)
            PLAN_EFI_PART_DISK="/dev/${dev%%p[0-9]*}"
            PLAN_EFI_PART_NUM="${dev##*p}"
            ;;
        *)
            error "Unable to parse FreeBSD EFI partition device: $part"
            ;;
    esac

    [[ -n "$PLAN_EFI_PART_DISK" && -n "$PLAN_EFI_PART_NUM" ]] || \
        error "Failed to derive FreeBSD EFI disk/partition from: $part"
}

mount_efi_for_plan() {
    if [[ "$OS" == "Linux" ]]; then
        # Prefer real EFI/ESP if available.
        if [[ -d "/boot/efi" ]] && is_mountpoint "/boot/efi"; then
            EFI_MOUNT_POINT="/boot/efi"
            PLAN_STORAGE_MODE="efi"
            PLAN_PATH_PREFIX_REL=""
            PLAN_EFI_MOUNTED_BY_SCRIPT=0
            if [[ -z "$PLAN_EFI_PART" ]]; then
                PLAN_EFI_PART=$(findmnt -n -o SOURCE --target "$EFI_MOUNT_POINT" 2>/dev/null || true)
            fi
            if [[ -n "$PLAN_EFI_PART" ]]; then
                PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
                PLAN_EFI_FS_TYPE=$(get_fs_type_linux "$PLAN_EFI_PART")
            fi
            return 0
        fi

        local efi_part=""
        efi_part=$(find_efi_for_plan 2>/dev/null || true)
        if [[ -n "$efi_part" ]]; then
            EFI_MOUNT_POINT="/boot/efi"
            mkdir -p "$EFI_MOUNT_POINT"
            if ! mount "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null; then
                if ! mount -t vfat "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null && \
                   ! mount -t msdos "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null && \
                   ! mount -t msdosfs "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null; then
                    error "Failed to mount EFI partition $efi_part on $EFI_MOUNT_POINT"
                fi
            fi
            PLAN_STORAGE_MODE="efi"
            PLAN_PATH_PREFIX_REL=""
            PLAN_EFI_PART="$efi_part"
            PLAN_EFI_MOUNTED_BY_SCRIPT=1
            PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
            PLAN_EFI_FS_TYPE=$(get_fs_type_linux "$PLAN_EFI_PART")
            return 0
        fi

        # Linux fallback: no EFI found, use /boot instead.
        if [[ -d "/boot" ]]; then
            EFI_MOUNT_POINT="/boot"
            PLAN_STORAGE_MODE="boot"
            PLAN_PATH_PREFIX_REL=""
            PLAN_EFI_MOUNTED_BY_SCRIPT=0

            if [[ -z "$PLAN_EFI_PART" ]]; then
                if is_mountpoint "/boot"; then
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --target "/boot" 2>/dev/null || true)
                else
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --target "/" 2>/dev/null || true)
                fi
            fi

            if [[ -n "$PLAN_EFI_PART" ]]; then
                PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
                PLAN_EFI_FS_TYPE=$(get_fs_type_linux "$PLAN_EFI_PART")
            fi
            return 0
        fi

        error "Could not find EFI partition for plan storage, and /boot fallback is unavailable"
    fi

    if [[ -d "$EFI_MOUNT_POINT" ]] && is_mountpoint "$EFI_MOUNT_POINT"; then
        local mounted_efi_src="" physical_efi_part=""

        PLAN_STORAGE_MODE="efi"
        PLAN_PATH_PREFIX_REL=""
        PLAN_EFI_MOUNTED_BY_SCRIPT=0

        mounted_efi_src=$(freebsd_mount_source_for "$EFI_MOUNT_POINT" || true)
        physical_efi_part=$(find_efi_for_plan 2>/dev/null || true)

        if [[ -n "$physical_efi_part" ]]; then
            PLAN_EFI_PART="$physical_efi_part"
        elif [[ -n "$mounted_efi_src" ]]; then
            PLAN_EFI_PART="$mounted_efi_src"
        fi

        [[ -n "$PLAN_EFI_PART" ]] || \
            error "EFI is mounted at $EFI_MOUNT_POINT but its backing partition could not be identified"

        PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
        PLAN_EFI_FS_TYPE=$(get_fs_type_freebsd "$PLAN_EFI_PART")

        case "${PLAN_EFI_PART#/dev/}" in
            *p[0-9]*)
                split_freebsd_part_device "$PLAN_EFI_PART"
                ;;
            *)
                error "EFI is mounted from ${mounted_efi_src:-unknown}, but the physical EFI partition could not be resolved"
                ;;
        esac

        info "Using already-mounted FreeBSD EFI partition: ${mounted_efi_src:-$PLAN_EFI_PART} on $EFI_MOUNT_POINT"
        info "Physical EFI partition for BootNext: $PLAN_EFI_PART"
        return 0
    fi

    mkdir -p "$EFI_MOUNT_POINT"
    local efi_part
    efi_part=$(find_efi_for_plan 2>/dev/null || true)
    [[ -n "$efi_part" ]] || error "Could not find EFI partition for plan storage"

    if command -v mount_msdosfs >/dev/null 2>&1; then
        if ! mount_msdosfs "$efi_part" "$EFI_MOUNT_POINT"; then
            error "Failed to mount FreeBSD EFI partition $efi_part on $EFI_MOUNT_POINT with mount_msdosfs"
        fi
    elif ! mount -t msdosfs "$efi_part" "$EFI_MOUNT_POINT"; then
        error "Failed to mount FreeBSD EFI partition $efi_part on $EFI_MOUNT_POINT"
    fi

    PLAN_STORAGE_MODE="efi"
    PLAN_PATH_PREFIX_REL=""
    PLAN_EFI_PART="$efi_part"
    PLAN_EFI_MOUNTED_BY_SCRIPT=1
    PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
    PLAN_EFI_FS_TYPE=$(get_fs_type_freebsd "$PLAN_EFI_PART")
    split_freebsd_part_device "$PLAN_EFI_PART"
}

save_plan_to_efi() {
    mount_efi_for_plan
    local plan_dir="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL/$PLAN_DIR_REL"
    local plan_file="$plan_dir/$PLAN_FILE_NAME"
    mkdir -p "$plan_dir"

    {
        printf 'TARGET_OS=%q\n' "$TARGET_OS"
        printf 'TARGET_VER=%q\n' "$TARGET_VER"
        printf 'DISK=%q\n' "$DISK"
        printf 'DISK_ID_WWN=%q\n' "${DISK_ID_WWN:-}"
        printf 'DISK_ID_SERIAL=%q\n' "${DISK_ID_SERIAL:-}"
        printf 'DISK_ID_SIZE=%q\n' "${DISK_ID_SIZE:-}"
        printf 'DISK_ID_MODEL=%q\n' "${DISK_ID_MODEL:-}"
        printf 'IMG_URL=%q\n' "$IMG_URL"
        printf 'PASSWORD_HASH=%q\n' "$PASSWORD_HASH"
        printf 'SSH_KEYS_ALL=%q\n' "$SSH_KEYS_ALL"
        printf 'SSH_PORT=%q\n' "$SSH_PORT"
        printf 'WEB_PORT=%q\n' "$WEB_PORT"
        printf 'FRPC_TOML=%q\n' "$FRPC_TOML"
        printf 'POST_INSTALL_HOOK=%q\n' "$POST_INSTALL_HOOK"
        printf 'FRPC_BOOTSTRAP_REL=%q\n' "${FRPC_BOOTSTRAP_REL:-}"
        printf 'POST_INSTALL_HOOK_BOOTSTRAP_REL=%q\n' "${POST_INSTALL_HOOK_BOOTSTRAP_REL:-}"
        printf 'AUTO_PASSWORD=%q\n' "$AUTO_PASSWORD"
        printf 'HOLD=%q\n' "$HOLD"
        printf 'PLAN_EFI_PART=%q\n' "$PLAN_EFI_PART"
        printf 'PLAN_EFI_UUID=%q\n' "$PLAN_EFI_UUID"
        printf 'PLAN_EFI_FS_TYPE=%q\n' "$PLAN_EFI_FS_TYPE"
        printf 'PLAN_STORAGE_MODE=%q\n' "$PLAN_STORAGE_MODE"
        printf 'PLAN_PATH_PREFIX_REL=%q\n' "$PLAN_PATH_PREFIX_REL"
        printf 'PLAN_EFI_PART_DISK=%q\n' "${PLAN_EFI_PART_DISK:-}"
        printf 'PLAN_EFI_PART_NUM=%q\n' "${PLAN_EFI_PART_NUM:-}"
        printf 'PLAN_DIR_REL=%q\n' "$PLAN_DIR_REL"
        printf 'PLAN_FILE_NAME=%q\n' "$PLAN_FILE_NAME"
        printf 'SCRIPT_NAME=%q\n' "$SCRIPT_NAME"
    } >"$plan_file"

    chmod 0600 "$plan_file" 2>/dev/null || true
    sync
    info "Saved reinstall plan to $plan_file"
}

linux_bootstrap_scan_devices() {
    local dev
    for dev in \
        /dev/sd[a-z][0-9]* \
        /dev/vd[a-z][0-9]* \
        /dev/xvd[a-z][0-9]* \
        /dev/nvme*n*p[0-9]* \
        /dev/mmcblk*p[0-9]*; do
        [[ -e "$dev" ]] || continue
        printf '%s\n' "$dev"
    done
}

try_mount_linux_bootstrap_candidate() {
    local candidate="$1" mountpoint_path="$2" mode="${3:-auto}"

    info "Trying bootstrap candidate: $candidate"

    if [[ "$mode" == "efi" ]]; then
        mount "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t vfat "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t msdos "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t msdosfs "$candidate" "$mountpoint_path" 2>/dev/null || true
    elif [[ "$mode" == "boot" ]]; then
        mount "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t ext4 "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t xfs "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t btrfs "$candidate" "$mountpoint_path" 2>/dev/null || true
    else
        mount "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t ext4 "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t xfs "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t btrfs "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t vfat "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t msdos "$candidate" "$mountpoint_path" 2>/dev/null || \
        mount -t msdosfs "$candidate" "$mountpoint_path" 2>/dev/null || true
    fi

    if ! is_mountpoint "$mountpoint_path"; then
        warn "Mount failed for candidate: $candidate"
        return 1
    fi

    return 0
}

load_plan_from_efi() {
    local boot_mnt="/media/bootstrap"
    local plan_file=""
    local candidate=""
    local vars_loaded=0
    local current_efi_src="" current_boot_src=""

    # Alpine RAM receives a self-contained copy of the install plan via apkovl.
    # Prefer it so the installer does not depend on remounting the boot ESP.
    if [[ "$OS" == "Linux" && -f /etc/reinstall/plan.env ]]; then
        # shellcheck disable=SC1091
        . /etc/reinstall/plan.env
        PASSWORD="${PASSWORD:-}"
        PASSWORD_HASH="${PASSWORD_HASH:-}"

        if [[ -f /etc/reinstall/frpc.toml ]]; then
            FRPC_TOML="/etc/reinstall/frpc.toml"
            FRPC_BOOTSTRAP_REL=""
        fi
        if [[ -f /etc/reinstall/post-install-hook.sh ]]; then
            POST_INSTALL_HOOK="/etc/reinstall/post-install-hook.sh"
            POST_INSTALL_HOOK_BOOTSTRAP_REL=""
        fi

        info "Loaded reinstall plan from embedded Alpine apkovl: /etc/reinstall/plan.env"
        return 0
    fi

    if [[ -f /etc/reinstall/vars ]]; then
        # shellcheck disable=SC1091
        . /etc/reinstall/vars
        vars_loaded=1
    fi

    if [[ "$OS" == "Linux" ]]; then
        mkdir -p "$boot_mnt"

        # 1) 优先按 /etc/reinstall/vars 提供的信息尝试挂载
        if [[ "$vars_loaded" -eq 1 ]] && ! is_mountpoint "$boot_mnt"; then
            if [[ -n "${PLAN_EFI_PART:-}" && -e "${PLAN_EFI_PART}" ]]; then
                info "Trying bootstrap mount from PLAN_EFI_PART: ${PLAN_EFI_PART}"
                if [[ "${PLAN_STORAGE_MODE:-efi}" == "efi" ]]; then
                    try_mount_linux_bootstrap_candidate "${PLAN_EFI_PART}" "$boot_mnt" "efi" || true
                else
                    try_mount_linux_bootstrap_candidate "${PLAN_EFI_PART}" "$boot_mnt" "boot" || true
                fi
            fi
            if ! is_mountpoint "$boot_mnt" && [[ -n "${PLAN_EFI_UUID:-}" ]]; then
                candidate="$(blkid -U "$PLAN_EFI_UUID" 2>/dev/null || true)"
                if [[ -n "$candidate" && -e "$candidate" ]]; then
                    info "Trying bootstrap mount from PLAN_EFI_UUID: ${PLAN_EFI_UUID} -> ${candidate}"
                    if [[ "${PLAN_STORAGE_MODE:-efi}" == "efi" ]]; then
                        try_mount_linux_bootstrap_candidate "$candidate" "$boot_mnt" "efi" || true
                    else
                        try_mount_linux_bootstrap_candidate "$candidate" "$boot_mnt" "boot" || true
                    fi
                fi
            fi
        fi

        # 2) 当前系统已挂载的 EFI/boot 优先
        if ! is_mountpoint "$boot_mnt"; then
            current_efi_src=$(findmnt -n -o SOURCE --target /boot/efi 2>/dev/null | head -n1 || true)
            if [[ -n "$current_efi_src" && -e "$current_efi_src" ]]; then
                info "Trying currently mounted EFI source: $current_efi_src"
                try_mount_linux_bootstrap_candidate "$current_efi_src" "$boot_mnt" "efi" || true
            fi
        fi

        if ! is_mountpoint "$boot_mnt"; then
            current_boot_src=$(findmnt -n -o SOURCE --target /boot 2>/dev/null | head -n1 || true)
            if [[ -n "$current_boot_src" && -e "$current_boot_src" ]]; then
                info "Trying currently mounted /boot source: $current_boot_src"
                try_mount_linux_bootstrap_candidate "$current_boot_src" "$boot_mnt" "boot" || true
            fi
        fi

        if ! is_mountpoint "$boot_mnt"; then
            current_boot_src=$(findmnt -n -o SOURCE --target / 2>/dev/null | head -n1 || true)
            if [[ -n "$current_boot_src" && -e "$current_boot_src" ]]; then
                info "Trying current root source as /boot fallback: $current_boot_src"
                try_mount_linux_bootstrap_candidate "$current_boot_src" "$boot_mnt" "boot" || true
            fi
        fi

        # 3) 如果已挂载，先找 plan
        if [[ -d "$boot_mnt" ]] && is_mountpoint "$boot_mnt"; then
            if [[ -f "$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                PLAN_STORAGE_MODE="boot"
                PLAN_PATH_PREFIX_REL=""
                plan_file="$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                EFI_MOUNT_POINT="$boot_mnt"
            elif [[ -f "$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                PLAN_STORAGE_MODE="boot"
                PLAN_PATH_PREFIX_REL="/boot"
                plan_file="$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                EFI_MOUNT_POINT="$boot_mnt"
            elif [[ -f "$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                plan_file="$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME"
            fi
        fi

        # 4) 最后才做白名单块设备扫描
        if [[ -z "$plan_file" ]] && ! is_mountpoint "$boot_mnt"; then
            info "Bootstrap plan not found via explicit hints or current mounts; falling back to conservative device scan."
            while read -r candidate; do
                try_mount_linux_bootstrap_candidate "$candidate" "$boot_mnt" "auto" || continue

                if [[ -f "$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                    PLAN_STORAGE_MODE="boot"
                    PLAN_PATH_PREFIX_REL=""
                    plan_file="$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                    EFI_MOUNT_POINT="$boot_mnt"
                    PLAN_EFI_PART="$candidate"
                    break
                elif [[ -f "$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                    PLAN_STORAGE_MODE="boot"
                    PLAN_PATH_PREFIX_REL="/boot"
                    plan_file="$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                    EFI_MOUNT_POINT="$boot_mnt"
                    PLAN_EFI_PART="$candidate"
                    break
                fi
                umount "$boot_mnt" 2>/dev/null || true
            done < <(linux_bootstrap_scan_devices)
        fi

        if [[ -z "$plan_file" && -d "$boot_mnt" ]] && is_mountpoint "$boot_mnt"; then
            if [[ -f "$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                PLAN_STORAGE_MODE="boot"
                PLAN_PATH_PREFIX_REL=""
                plan_file="$boot_mnt/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                EFI_MOUNT_POINT="$boot_mnt"
            elif [[ -f "$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME" ]]; then
                PLAN_STORAGE_MODE="boot"
                PLAN_PATH_PREFIX_REL="/boot"
                plan_file="$boot_mnt/boot/$PLAN_DIR_REL/$PLAN_FILE_NAME"
                EFI_MOUNT_POINT="$boot_mnt"
            fi
        fi

        [[ -n "$plan_file" && -f "$plan_file" ]] || error "Plan file not found on Linux bootstrap storage"

        # shellcheck disable=SC1090
        . "$plan_file"
        PASSWORD="${PASSWORD:-}"
        PASSWORD_HASH="${PASSWORD_HASH:-}"
        info "Loaded reinstall plan from $plan_file"
        return 0
    fi

    mount_efi_for_plan
    plan_file="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL/$PLAN_DIR_REL/$PLAN_FILE_NAME"
    [[ -f "$plan_file" ]] || error "Plan file not found on bootstrap storage: $plan_file"
    # shellcheck disable=SC1090
    . "$plan_file"
    PASSWORD="${PASSWORD:-}"
    PASSWORD_HASH="${PASSWORD_HASH:-}"
    info "Loaded reinstall plan from $plan_file"
}

# ----------------- Alpine RAM / boot bootstrap -----------------

normalize_dep_token() {
    local tok="$1"

    tok="${tok%%[*}"
    tok="${tok%%~*}"
    tok="${tok%%<*}"
    tok="${tok%%>*}"
    tok="${tok%%=*}"

    if [[ "$tok" == \!* ]]; then
        echo ""
        return 0
    fi

    printf '%s\n' "$tok"
}

setup_bootstrap_bundle_paths() {
    local root_abs="$1"

    BOOTSTRAP_CACHE_DIR_REL="/$PLAN_DIR_REL/cache"
    BOOTSTRAP_APKREPO_DIR_REL="/$PLAN_DIR_REL/apkrepo"
    BOOTSTRAP_APKREPO_MAIN_REL="$BOOTSTRAP_APKREPO_DIR_REL/main"
    BOOTSTRAP_APKREPO_COMMUNITY_REL="$BOOTSTRAP_APKREPO_DIR_REL/community"
    BOOTSTRAP_INPUT_DIR_REL="/$PLAN_DIR_REL/input"

    if [[ "${IMG_URL:-}" == *.xz ]]; then
        BOOTSTRAP_IMG_NAME="image.qcow2.xz"
    else
        BOOTSTRAP_IMG_NAME="image.qcow2"
    fi
    BOOTSTRAP_IMG_REL="$BOOTSTRAP_CACHE_DIR_REL/$BOOTSTRAP_IMG_NAME"

    BOOTSTRAP_CACHE_DIR_ABS="$root_abs$BOOTSTRAP_CACHE_DIR_REL"
    BOOTSTRAP_APKREPO_DIR_ABS="$root_abs$BOOTSTRAP_APKREPO_DIR_REL"
    BOOTSTRAP_APKREPO_MAIN_ABS="$root_abs$BOOTSTRAP_APKREPO_MAIN_REL"
    BOOTSTRAP_APKREPO_COMMUNITY_ABS="$root_abs$BOOTSTRAP_APKREPO_COMMUNITY_REL"
    BOOTSTRAP_IMG_ABS="$root_abs$BOOTSTRAP_IMG_REL"
    BOOTSTRAP_INPUT_DIR_ABS="$root_abs$BOOTSTRAP_INPUT_DIR_REL"
}

detect_current_console_args() {
    CURRENT_CONSOLE_ARGS=""
    if [[ -r /proc/cmdline ]]; then
        local tok
        for tok in $(cat /proc/cmdline); do
            case "$tok" in
                console=*)
                    CURRENT_CONSOLE_ARGS+=" $tok"
                    ;;
            esac
        done
    fi

    if [[ -z "$CURRENT_CONSOLE_ARGS" ]]; then
        CURRENT_CONSOLE_ARGS=" console=ttyS0 console=tty0"
    fi
}

ensure_grub_tools() {
    [[ "$OS" == "Linux" ]] || error "Automatic Alpine RAM bootstrap only supports Linux host in this function"

    if command -v grub2-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub2-mkconfig"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub-mkconfig"
    else
        error "Could not find grub2-mkconfig or grub-mkconfig"
    fi

    if command -v grub2-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub2-reboot"
    elif command -v grub-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub-reboot"
    else
        error "Could not find grub2-reboot or grub-reboot"
    fi

    if command -v grub2-set-default >/dev/null 2>&1; then
        GRUB_DEFAULT_CMD="grub2-set-default"
    elif command -v grub-set-default >/dev/null 2>&1; then
        GRUB_DEFAULT_CMD="grub-set-default"
    else
        GRUB_DEFAULT_CMD=""
    fi

    if [[ -d /etc/grub.d ]]; then
        GRUB_SCRIPT_PATH="/etc/grub.d/09_reinstall_alpine"
    else
        error "/etc/grub.d not found; unsupported GRUB layout"
    fi

    if [[ -f /boot/grub2/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub2/grub.cfg"
    elif [[ -f /boot/grub/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub/grub.cfg"
    else
        error "Could not find GRUB config file under /boot/grub2/grub.cfg or /boot/grub/grub.cfg"
    fi
}

ensure_freebsd_boot_tools() {
    [[ "$OS" == "FreeBSD" ]] || error "Automatic FreeBSD BootNext bootstrap only supports FreeBSD host"
    command -v efibootmgr >/dev/null 2>&1 || error "efibootmgr is required on FreeBSD host"
    command -v tar >/dev/null 2>&1 || error "tar is required on FreeBSD host"
    command -v file >/dev/null 2>&1 || error "file is required on FreeBSD host"
    command -v dd >/dev/null 2>&1 || error "dd is required on FreeBSD host"
    command -v cmp >/dev/null 2>&1 || error "cmp is required on FreeBSD host"
    command -v grep >/dev/null 2>&1 || error "grep is required on FreeBSD host"

    if ! efibootmgr -v >/dev/null 2>&1; then
        error "efibootmgr is present but EFI NVRAM is not accessible; FreeBSD automatic boot requires UEFI boot mode"
    fi
}

prepare_alpine_paths() {
    mount_efi_for_plan

    case "$MACHINE_ARCH" in
        x86_64)
            GRUB_EFI_TARGET="x86_64-efi"
            ALPINE_NETBOOT_ARCH="x86_64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubx64.efi"
            ;;
        aarch64)
            GRUB_EFI_TARGET="arm64-efi"
            ALPINE_NETBOOT_ARCH="aarch64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubaa64.efi"
            ;;
        *)
            error "Automatic Alpine RAM bootstrap currently supports host arch x86_64 and aarch64 only"
            ;;
    esac

    if [[ "$PLAN_STORAGE_MODE" == "efi" ]]; then
        [[ -n "$PLAN_EFI_UUID" ]] || error "Could not determine EFI filesystem UUID"
    else
        [[ -n "$PLAN_EFI_PART" || -n "$PLAN_EFI_UUID" ]] || error "Could not determine Linux /boot fallback source"
    fi

    ALPINE_BOOT_DIR_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR"
    ALPINE_BOOT_DIR_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_BOOT_DIR_REL"
    ALPINE_FREEBSD_GRUB_CFG_REL="$ALPINE_BOOT_DIR_REL/grub/grub.cfg"
    ALPINE_FREEBSD_GRUB_CFG_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_FREEBSD_GRUB_CFG_REL"

    # Use generic destination names on bootstrap storage so different source flavors/arches can be normalized.
    ALPINE_KERNEL_FLAVOR="virt"
    ALPINE_VMLINUZ_REL="$ALPINE_BOOT_DIR_REL/vmlinuz"
    ALPINE_INITRAMFS_REL="$ALPINE_BOOT_DIR_REL/initramfs"
    # Keep the legacy local path only so stale files from older script versions
    # can be removed. The current bootstrap always fetches modloop over HTTPS.
    ALPINE_MODLOOP_REL="$ALPINE_BOOT_DIR_REL/modloop"
    ALPINE_MODLOOP_URL="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}/modloop-${ALPINE_KERNEL_FLAVOR}"
    # Keep apkovl at bootstrap filesystem root so Alpine nlplug-findfs can auto-discover it.
    ALPINE_APKOVL_REL="/reinstall.apkovl.tar.gz"

    ALPINE_VMLINUZ_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_VMLINUZ_REL"
    ALPINE_INITRAMFS_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_INITRAMFS_REL"
    ALPINE_MODLOOP_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_MODLOOP_REL"
    ALPINE_APKOVL_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_APKOVL_REL"

    ALPINE_SCRIPT_COPY_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL/$PLAN_DIR_REL/$SCRIPT_NAME"
    ALPINE_FREEBSD_GRUB_EFI_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_FREEBSD_GRUB_EFI_REL"

    setup_bootstrap_bundle_paths "$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL"
}

copy_script_to_efi() {
    local self
    self="$0"

    if command -v readlink >/dev/null 2>&1; then
        self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    elif command -v realpath >/dev/null 2>&1; then
        self=$(realpath "$0" 2>/dev/null || echo "$0")
    fi

    [[ -f "$self" ]] || error "Cannot locate current script file: $self"

    cp "$self" "$ALPINE_SCRIPT_COPY_ABS"
    chmod 0755 "$ALPINE_SCRIPT_COPY_ABS"
    sync
    info "Copied script to bootstrap storage: $ALPINE_SCRIPT_COPY_ABS"
}

download_alpine_ram_files() {
    mkdir -p "$ALPINE_BOOT_DIR_ABS"

    local base tmpdir
    tmpdir=$(mktemp -d /tmp/reinstall-alpine-netboot.XXXXXX)

    base="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}"

    # Older releases of this script copied modloop to the ESP. FreeBSD cloud
    # images commonly have only a ~32 MiB ESP, so that does not fit alongside
    # vmlinuz + initramfs + GRUB. Remove any stale/partial local modloop first.
    rm -f "$ALPINE_MODLOOP_ABS"
    sync

    local free_kb
    free_kb=$(df -k "$ALPINE_BOOT_DIR_ABS" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 22528 )); then
        rm -rf "$tmpdir"
        error "Bootstrap filesystem has only ${free_kb} KiB free after removing stale modloop; at least 22 MiB is required for Alpine kernel/initramfs and bootstrap files"
    fi

    info "Using fixed Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}, source=${base}"
    info "Alpine modloop will be fetched by initramfs over HTTPS at boot:"
    info "  ${ALPINE_MODLOOP_URL}"

    if ! http_download "$base/vmlinuz-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/vmlinuz"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine kernel"
    fi
    if ! http_download "$base/initramfs-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/initramfs"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine initramfs"
    fi

    mv "$tmpdir/vmlinuz" "$ALPINE_VMLINUZ_ABS"
    mv "$tmpdir/initramfs" "$ALPINE_INITRAMFS_ABS"

    chmod 0644 "$ALPINE_VMLINUZ_ABS" "$ALPINE_INITRAMFS_ABS"
    rm -rf "$tmpdir"
    sync

    info "Selected Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}"
}

build_local_apk_repo() {
    local root_main_url root_community_url tmpdir
    local main_index community_index selected_list
    declare -A PKG_VER PKG_REPO PKG_DEPS PROVIDE_TO_PKG RESOLVED SEEN

    mkdir -p "$BOOTSTRAP_APKREPO_MAIN_ABS" "$BOOTSTRAP_APKREPO_COMMUNITY_ABS"

    root_main_url="${ALPINE_REPO_BASE}/main/${ALPINE_NETBOOT_ARCH}"
    root_community_url="${ALPINE_REPO_BASE}/community/${ALPINE_NETBOOT_ARCH}"

    tmpdir=$(mktemp -d /tmp/reinstall-apkrepo.XXXXXX)
    trap 'rm -rf "$tmpdir"' RETURN

    main_index="$tmpdir/main.APKINDEX.tar.gz"
    community_index="$tmpdir/community.APKINDEX.tar.gz"

    info "Downloading Alpine APKINDEX (main)..."
    http_download "$root_main_url/APKINDEX.tar.gz" "$main_index"
    info "Downloading Alpine APKINDEX (community)..."
    http_download "$root_community_url/APKINDEX.tar.gz" "$community_index"

    cp "$main_index" "$BOOTSTRAP_APKREPO_MAIN_ABS/APKINDEX.tar.gz"
    cp "$community_index" "$BOOTSTRAP_APKREPO_COMMUNITY_ABS/APKINDEX.tar.gz"

    tar -xOzf "$main_index" APKINDEX >"$tmpdir/main.APKINDEX"
    tar -xOzf "$community_index" APKINDEX >"$tmpdir/community.APKINDEX"

    parse_apkindex_file() {
        local file="$1" repo="$2"
        local rec name ver deps provides tok norm

        while IFS= read -r -d '' rec; do
            name=$(awk '/^P:/{sub(/^P:/, ""); print; exit}' <<<"$rec")
            ver=$(awk '/^V:/{sub(/^V:/, ""); print; exit}' <<<"$rec")
            deps=$(awk '/^D:/{sub(/^D:/, ""); print; exit}' <<<"$rec")
            provides=$(awk '/^p:/{sub(/^p:/, ""); print; exit}' <<<"$rec")

            [[ -n "$name" && -n "$ver" ]] || continue

            if [[ -z "${PKG_VER[$name]:-}" ]]; then
                PKG_VER["$name"]="$ver"
                PKG_REPO["$name"]="$repo"
                PKG_DEPS["$name"]="$deps"
            fi

            for tok in $provides; do
                norm=$(normalize_dep_token "$tok")
                [[ -n "$norm" ]] || continue
                if [[ -z "${PROVIDE_TO_PKG[$norm]:-}" ]]; then
                    PROVIDE_TO_PKG["$norm"]="$name"
                fi
            done
        done < <(
            awk 'BEGIN { RS=""; ORS="" } { if (length($0) > 0) printf "%s\0", $0 }' "$file"
        )
    }

    parse_apkindex_file "$tmpdir/main.APKINDEX" "main"
    parse_apkindex_file "$tmpdir/community.APKINDEX" "community"

    selected_list="$tmpdir/selected.list"

    resolve_pkg() {
        local want="$1"
        local tok norm deps dep real

        [[ -n "$want" ]] || return 0
        [[ -z "${RESOLVED[$want]:-}" ]] || return 0
        [[ -z "${SEEN[$want]:-}" ]] || return 0
        SEEN["$want"]=1

        real="$want"
        if [[ -z "${PKG_VER[$real]:-}" ]]; then
            real="${PROVIDE_TO_PKG[$want]:-}"
        fi

        [[ -n "$real" ]] || return 0
        [[ -n "${PKG_VER[$real]:-}" ]] || return 0
        [[ -z "${RESOLVED[$real]:-}" ]] || return 0

        RESOLVED["$real"]=1
        printf '%s\n' "$real" >>"$selected_list"

        deps="${PKG_DEPS[$real]:-}"
        for tok in $deps; do
            norm=$(normalize_dep_token "$tok")
            [[ -n "$norm" ]] || continue
            case "$norm" in
                so:*|cmd:*|/bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*)
                    dep="${PROVIDE_TO_PKG[$norm]:-}"
                    ;;
                *)
                    dep="$norm"
                    if [[ -z "${PKG_VER[$dep]:-}" ]]; then
                        dep="${PROVIDE_TO_PKG[$dep]:-}"
                    fi
                    ;;
            esac
            [[ -n "$dep" ]] || continue
            resolve_pkg "$dep"
        done
    }

    : >"$selected_list"
    for pkg in "${ALPINE_RUNTIME_PKGS[@]}"; do
        resolve_pkg "$pkg"
    done

    sort -u "$selected_list" -o "$selected_list"

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        local ver repo url dst_dir
        ver="${PKG_VER[$pkg]}"
        repo="${PKG_REPO[$pkg]}"
        if [[ "$repo" == "main" ]]; then
            url="$root_main_url/${pkg}-${ver}.apk"
            dst_dir="$BOOTSTRAP_APKREPO_MAIN_ABS"
        else
            url="$root_community_url/${pkg}-${ver}.apk"
            dst_dir="$BOOTSTRAP_APKREPO_COMMUNITY_ABS"
        fi
        if [[ -f "$dst_dir/${pkg}-${ver}.apk" ]]; then
            info "APK already cached: ${pkg}-${ver}.apk"
            continue
        fi
        info "Downloading APK: ${pkg}-${ver}.apk ($repo)"
        http_download "$url" "$dst_dir/${pkg}-${ver}.apk"
    done <"$selected_list"

    sync
    rm -rf "$tmpdir"
    trap - RETURN

    info "Built local Alpine APK repos under: $BOOTSTRAP_APKREPO_DIR_ABS"
}

download_target_image_to_bootstrap() {
    mkdir -p "$BOOTSTRAP_CACHE_DIR_ABS"

    precheck_bootstrap_space_for_download "$EFI_MOUNT_POINT" "$IMG_URL" 2

    if [[ -f "$BOOTSTRAP_IMG_ABS" ]]; then
        if [[ "$BOOTSTRAP_IMG_ABS" == *.xz ]]; then
            if xz -t "$BOOTSTRAP_IMG_ABS" >/dev/null 2>&1; then
                info "Target image already cached on bootstrap storage: $BOOTSTRAP_IMG_ABS"
                return 0
            fi
        elif qemu-img info "$BOOTSTRAP_IMG_ABS" >/dev/null 2>&1; then
            info "Target image already cached on bootstrap storage: $BOOTSTRAP_IMG_ABS"
            return 0
        fi
        warn "Cached target image failed validation; redownloading: $BOOTSTRAP_IMG_ABS"
        rm -f "$BOOTSTRAP_IMG_ABS"
    fi

    info "Downloading target image to bootstrap storage..."
    http_download "$IMG_URL" "$BOOTSTRAP_IMG_ABS"
    if [[ "$BOOTSTRAP_IMG_ABS" == *.xz ]]; then
        xz -t "$BOOTSTRAP_IMG_ABS" || error "Downloaded xz image failed integrity validation"
    else
        qemu-img info "$BOOTSTRAP_IMG_ABS" >/dev/null || error "Downloaded image is not a readable qcow2 image"
    fi
    sync
    info "Cached target image: $BOOTSTRAP_IMG_ABS"
}

cache_optional_inputs_to_bootstrap() {
    mkdir -p "$BOOTSTRAP_INPUT_DIR_ABS"

    FRPC_BOOTSTRAP_REL=""
    POST_INSTALL_HOOK_BOOTSTRAP_REL=""

    if [[ -n "${FRPC_TOML:-}" ]]; then
        if [[ "$FRPC_TOML" =~ ^https?:// ]]; then
            info "FRPC URL will be downloaded later from Alpine RAM: $FRPC_TOML"
        elif [[ -f "$FRPC_TOML" ]]; then
            FRPC_BOOTSTRAP_REL="$BOOTSTRAP_INPUT_DIR_REL/frpc.toml"
            info "Caching local FRPC config on bootstrap storage: $FRPC_TOML"
            cp "$FRPC_TOML" "$BOOTSTRAP_INPUT_DIR_ABS/frpc.toml"
            chmod 0600 "$BOOTSTRAP_INPUT_DIR_ABS/frpc.toml" 2>/dev/null || true
        else
            error "Invalid FRPC config path: $FRPC_TOML"
        fi
    fi

    if [[ -n "${POST_INSTALL_HOOK:-}" ]]; then
        [[ -f "$POST_INSTALL_HOOK" ]] || error "Post-install hook not found: $POST_INSTALL_HOOK"
        POST_INSTALL_HOOK_BOOTSTRAP_REL="$BOOTSTRAP_INPUT_DIR_REL/post-install-hook.sh"
        info "Caching local post-install hook on bootstrap storage: $POST_INSTALL_HOOK"
        cp "$POST_INSTALL_HOOK" "$BOOTSTRAP_INPUT_DIR_ABS/post-install-hook.sh"
        chmod 0700 "$BOOTSTRAP_INPUT_DIR_ABS/post-install-hook.sh"
    fi

    sync
}

build_alpine_apkovl() {
    local tmp ovl_dir startfile svcfile runlevel_link repofile markerfile
    tmp=$(mktemp -d /tmp/reinstall-alpine-apkovl.XXXXXX)

    ovl_dir="$tmp/ovl"

    mkdir -p \
        "$ovl_dir/etc/apk" \
        "$ovl_dir/etc/init.d" \
        "$ovl_dir/etc/runlevels/default" \
        "$ovl_dir/usr/local/sbin" \
        "$ovl_dir/etc/reinstall"

    # Tell Alpine initramfs to add the normal default OpenRC boot services even with an apkovl.
    : >"$ovl_dir/etc/.default_boot_services"

    repofile="$ovl_dir/etc/apk/repositories"
    cat >"$repofile" <<EOF
${ALPINE_REPO_BASE}/main/${ALPINE_NETBOOT_ARCH}
${ALPINE_REPO_BASE}/community/${ALPINE_NETBOOT_ARCH}
EOF

    markerfile="$ovl_dir/etc/reinstall/vars"
    cat >"$markerfile" <<EOF
PLAN_EFI_PART='${PLAN_EFI_PART}'
PLAN_EFI_UUID='${PLAN_EFI_UUID}'
PLAN_EFI_FS_TYPE='${PLAN_EFI_FS_TYPE}'
PLAN_STORAGE_MODE='${PLAN_STORAGE_MODE}'
PLAN_PATH_PREFIX_REL='${PLAN_PATH_PREFIX_REL}'
PLAN_DIR_REL='${PLAN_DIR_REL}'
PLAN_FILE_NAME='${PLAN_FILE_NAME}'
SCRIPT_NAME='${SCRIPT_NAME}'
HOLD='${HOLD}'
EOF

    # Make the Alpine RAM environment self-contained after apkovl is loaded.
    # The boot ESP is only needed to load kernel/initramfs/modloop/apkovl; the
    # destructive installer must not depend on mounting it again.
    local embedded_plan embedded_installer
    embedded_plan="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL/$PLAN_DIR_REL/$PLAN_FILE_NAME"
    embedded_installer="$ALPINE_SCRIPT_COPY_ABS"

    [[ -f "$embedded_plan" ]] || error "Plan file missing while building apkovl: $embedded_plan"
    [[ -f "$embedded_installer" ]] || error "Installer script missing while building apkovl: $embedded_installer"

    cp "$embedded_plan" "$ovl_dir/etc/reinstall/plan.env"
    chmod 0600 "$ovl_dir/etc/reinstall/plan.env"
    cp "$embedded_installer" "$ovl_dir/usr/local/sbin/reinstall-installer.sh"
    chmod 0755 "$ovl_dir/usr/local/sbin/reinstall-installer.sh"

    if [[ -n "${FRPC_BOOTSTRAP_REL:-}" && -f "$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$FRPC_BOOTSTRAP_REL" ]]; then
        cp "$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$FRPC_BOOTSTRAP_REL" "$ovl_dir/etc/reinstall/frpc.toml"
        chmod 0600 "$ovl_dir/etc/reinstall/frpc.toml"
    fi
    if [[ -n "${POST_INSTALL_HOOK_BOOTSTRAP_REL:-}" && -f "$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$POST_INSTALL_HOOK_BOOTSTRAP_REL" ]]; then
        cp "$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$POST_INSTALL_HOOK_BOOTSTRAP_REL" "$ovl_dir/etc/reinstall/post-install-hook.sh"
        chmod 0700 "$ovl_dir/etc/reinstall/post-install-hook.sh"
    fi

    startfile="$ovl_dir/usr/local/sbin/reinstall-auto.sh"
    cat >"$startfile" <<'EOF'
#!/bin/sh
set -eu

LOG="/var/log/reinstall-auto.log"
mkdir -p /var/log
touch "$LOG"
# Keep output visible on the serial/system console. A diskless reinstall must not
# look idle at a login prompt while destructive work is running.
if [ -w /dev/console ]; then
    exec >/dev/console 2>&1
else
    exec >>"$LOG" 2>&1
fi

echo "===== reinstall-auto start $(date) ====="

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

[ -f /etc/reinstall/vars ] || {
    echo "Missing /etc/reinstall/vars"
    exit 1
}
# shellcheck disable=SC1091
. /etc/reinstall/vars

mount_bootstrap() {
    local base_mnt dev
    base_mnt=/media/bootstrap

    mkdir -p "$base_mnt"

    if is_mountpoint "$base_mnt"; then
        return 0
    fi

    if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
        if [ -n "${PLAN_EFI_PART:-}" ] && [ -e "${PLAN_EFI_PART}" ]; then
            echo "Trying bootstrap mount from PLAN_EFI_PART: ${PLAN_EFI_PART}"
            mount "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t vfat "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t msdos "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t msdosfs "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || true
        fi
    else
        if [ -n "${PLAN_EFI_PART:-}" ] && [ -e "${PLAN_EFI_PART}" ]; then
            echo "Trying bootstrap mount from PLAN_EFI_PART: ${PLAN_EFI_PART}"
            mount "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || true
        fi
    fi

    if is_mountpoint "$base_mnt"; then
        return 0
    fi

    if [ -n "${PLAN_EFI_UUID:-}" ]; then
        dev="$(blkid -U "$PLAN_EFI_UUID" 2>/dev/null || true)"
        if [ -n "$dev" ] && [ -e "$dev" ]; then
            echo "Trying bootstrap mount from PLAN_EFI_UUID: ${PLAN_EFI_UUID} -> ${dev}"
            if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
                mount "$dev" "$base_mnt" 2>/dev/null || \
                mount -t vfat "$dev" "$base_mnt" 2>/dev/null || \
                mount -t msdos "$dev" "$base_mnt" 2>/dev/null || \
                mount -t msdosfs "$dev" "$base_mnt" 2>/dev/null || true
            else
                mount "$dev" "$base_mnt" 2>/dev/null || true
            fi
        fi
    fi

    if is_mountpoint "$base_mnt"; then
        return 0
    fi

    echo "Falling back to conservative block-device scan for bootstrap storage"
    if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
        for dev in /dev/sd[a-z][0-9]* /dev/vd[a-z][0-9]* /dev/xvd[a-z][0-9]* /dev/nvme*n*p[0-9]* /dev/mmcblk*p[0-9]*; do
            [ -e "$dev" ] || continue
            echo "Trying candidate: $dev"
            mount "$dev" "$base_mnt" 2>/dev/null || \
            mount -t vfat "$dev" "$base_mnt" 2>/dev/null || \
            mount -t msdos "$dev" "$base_mnt" 2>/dev/null || \
            mount -t msdosfs "$dev" "$base_mnt" 2>/dev/null || true
            if [ -f "$base_mnt/${PLAN_DIR_REL}/${PLAN_FILE_NAME}" ]; then
                return 0
            fi
            umount "$base_mnt" 2>/dev/null || true
        done
    else
        for dev in /dev/sd[a-z][0-9]* /dev/vd[a-z][0-9]* /dev/xvd[a-z][0-9]* /dev/nvme*n*p[0-9]* /dev/mmcblk*p[0-9]*; do
            [ -e "$dev" ] || continue
            echo "Trying candidate: $dev"
            mount "$dev" "$base_mnt" 2>/dev/null || true
            if [ -f "$base_mnt/${PLAN_DIR_REL}/${PLAN_FILE_NAME}" ] || \
               [ -f "$base_mnt/boot/${PLAN_DIR_REL}/${PLAN_FILE_NAME}" ]; then
                return 0
            fi
            umount "$base_mnt" 2>/dev/null || true
        done
    fi

    echo "Failed to mount bootstrap storage"
    return 1
}

ensure_network() {
    local n

    if ip route 2>/dev/null | grep -q '^default '; then
        echo "Network already configured by Alpine initramfs."
        return 0
    fi

    echo "No default route found; retrying DHCP."
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        n="${n##*/}"
        [ "$n" = "lo" ] && continue
        ip link set dev "$n" up 2>/dev/null || true
        if command -v udhcpc >/dev/null 2>&1; then
            if udhcpc -i "$n" -f -q -n -t 5 2>/dev/null; then
                break
            fi
        fi
    done

    ip route 2>/dev/null | grep -q '^default ' || {
        echo "Failed to obtain a default route in Alpine RAM."
        exit 1
    }
}

install_runtime_deps_online() {
    cat > /etc/apk/repositories <<REPOEOF
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
REPOEOF

    echo "[stage] apk update (online)"
    apk update
    echo "[stage] apk add (online official repos)"
    apk add --no-cache \
        bash curl wget ca-certificates xz qemu-img util-linux coreutils grep sed gawk findutils file tar \
        e2fsprogs dosfstools sgdisk kmod
    update-ca-certificates 2>/dev/null || true

    # Fail here with a precise message instead of reaching the destructive stage
    # and discovering that a split Alpine subpackage was not installed.
    for cmd in sgdisk mkfs.ext4 qemu-img qemu-nbd xz curl lsblk blkid mount umount blockdev mknod; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Required Alpine runtime command is missing after apk add: $cmd"
            exit 1
        }
    done
}

setup_zram_swap() {
    local mem_kb zram_bytes min_bytes max_bytes

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [ -n "$mem_kb" ] || {
        echo "Could not determine MemTotal; refusing to continue without zram swap."
        exit 1
    }

    # Logical zram size = 2x physical RAM, minimum 1 GiB, maximum 8 GiB.
    zram_bytes=$((mem_kb * 1024 * 2))
    min_bytes=1073741824
    max_bytes=8589934592
    [ "$zram_bytes" -lt "$min_bytes" ] && zram_bytes="$min_bytes"
    [ "$zram_bytes" -gt "$max_bytes" ] && zram_bytes="$max_bytes"

    modprobe zram || {
        echo "zram kernel module is unavailable; virtual memory is required for this installer."
        exit 1
    }
    [ -e /dev/zram0 ] || mdev -s 2>/dev/null || true
    [ -b /dev/zram0 ] || {
        echo "zram0 block device was not created."
        exit 1
    }

    swapoff /dev/zram0 2>/dev/null || true
    if [ -e /sys/block/zram0/reset ]; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    echo "$zram_bytes" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0

    echo "$zram_bytes" > /run/reinstall-zram-bytes
    echo "Enabled zram swap: $((zram_bytes / 1024 / 1024)) MiB logical size"
    free -m 2>/dev/null || true
}

setup_work_tmpfs() {
    local mem_kb mem_bytes zram_bytes work_bytes reserve

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    mem_bytes=$((mem_kb * 1024))
    zram_bytes="$(cat /run/reinstall-zram-bytes 2>/dev/null || echo 0)"
    reserve=268435456
    work_bytes=$((mem_bytes + zram_bytes - reserve))
    [ "$work_bytes" -gt 536870912 ] || work_bytes=536870912

    mkdir -p /run/reinstall-work
    if is_mountpoint /run/reinstall-work; then
        umount /run/reinstall-work 2>/dev/null || true
    fi
    mount -t tmpfs -o "size=${work_bytes},mode=0700" tmpfs /run/reinstall-work
    echo "Created swap-backed tmpfs work area: $((work_bytes / 1024 / 1024)) MiB limit"
}

relocate_modloop_to_ram() {
    local loopdev backing ram_modloop kver new_loopdev boot_mnt

    kver="$(uname -r)"

    if ! is_mountpoint /.modloop; then
        echo "No /.modloop mount is active; no boot-media modloop relocation is needed."
        return 0
    fi

    loopdev="$(findmnt -rn -o SOURCE --target /.modloop 2>/dev/null | head -n1 || true)"
    [ -n "$loopdev" ] || {
        echo "Could not determine the block device backing /.modloop."
        exit 1
    }

    backing=""
    if command -v losetup >/dev/null 2>&1; then
        backing="$(losetup -n -O BACK-FILE "$loopdev" 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$backing" ]; then
        case "$loopdev" in
            /dev/loop*)
                backing="$(cat "/sys/class/block/${loopdev#/dev/}/loop/backing_file" 2>/dev/null || true)"
                [ -n "$backing" ] && backing="/${backing#/}"
                ;;
        esac
    fi

    [ -n "$backing" ] && [ -f "$backing" ] || {
        echo "Could not determine the modloop backing file for $loopdev."
        echo "Current mounts:"
        findmnt /.modloop 2>/dev/null || true
        losetup -a 2>/dev/null || true
        exit 1
    }

    ram_modloop="/run/reinstall-work/modloop.ram.squashfs"
    echo "Relocating Alpine modloop to RAM: $backing -> $ram_modloop"
    cp "$backing" "$ram_modloop"
    sync

    # Copy to our dedicated RAM work area and recreate /.modloop from there.
    # With current netboot the source was normally downloaded by initramfs into
    # RAM already; this still normalizes the state and guarantees no target-disk
    # filesystem can remain referenced by the active modloop.
    umount /.modloop || {
        echo "Failed to unmount the original /.modloop."
        exit 1
    }
    if command -v losetup >/dev/null 2>&1; then
        losetup -d "$loopdev" 2>/dev/null || true
    fi

    mount -o loop,ro "$ram_modloop" /.modloop || {
        echo "Failed to mount RAM-backed modloop."
        exit 1
    }

    [ -d "/.modloop/modules/$kver" ] || {
        echo "RAM-backed modloop does not contain modules for kernel $kver."
        exit 1
    }
    [ -e "/lib/modules/$kver" ] || {
        echo "/lib/modules/$kver is unavailable after modloop relocation."
        exit 1
    }

    new_loopdev="$(findmnt -rn -o SOURCE --target /.modloop 2>/dev/null | head -n1 || true)"
    echo "RAM-backed modloop active: ${new_loopdev:-unknown} -> $ram_modloop"

    # Show any remaining boot-media mounts. The installer will unmount the target
    # disk strictly before qemu-img writes to it.
    boot_mnt="$(dirname "$backing")"
    echo "Modloop relocation complete; original boot media is no longer used by /.modloop."
    findmnt -rn -S "${PLAN_EFI_PART:-}" 2>/dev/null || true
}

main() {
    PLAN_FILE="/etc/reinstall/plan.env"
    SCRIPT_FILE="/usr/local/sbin/reinstall-installer.sh"

    [ -f "$PLAN_FILE" ] || {
        echo "Embedded plan file not found: $PLAN_FILE"
        exit 1
    }
    [ -f "$SCRIPT_FILE" ] || {
        echo "Embedded installer script not found: $SCRIPT_FILE"
        exit 1
    }

    echo "[stage] using embedded apkovl plan and installer"

    echo "[stage] ensure_network"
    ensure_network

    echo "[stage] install_runtime_deps_online"
    install_runtime_deps_online

    echo "[stage] setup_zram_swap"
    setup_zram_swap

    echo "[stage] setup_work_tmpfs"
    setup_work_tmpfs

    cd /

    echo "[stage] relocate_modloop_to_ram"
    relocate_modloop_to_ram

    RUN_SCRIPT="/run/reinstall-installer.sh"
    cp "$SCRIPT_FILE" "$RUN_SCRIPT"
    chmod 0755 "$RUN_SCRIPT"

    echo "[stage] launch installer"
    echo "Launching installer phase..."
    bash "$RUN_SCRIPT" --phase installer --yes

    rc=$?
    echo "Installer phase finished with rc=$rc"

    if [ "$rc" -eq 0 ]; then
        if grep -q '^HOLD=2$' "$PLAN_FILE" 2>/dev/null || grep -q "^HOLD='2'$" "$PLAN_FILE" 2>/dev/null; then
            echo "HOLD=2 detected, not rebooting."
            exit 0
        fi
        sync
        sleep 2
        reboot -f || poweroff -f || true
    fi

    exit "$rc"
}

main
EOF
    chmod 0755 "$startfile"

    svcfile="$ovl_dir/etc/init.d/reinstall-auto"
    cat >"$svcfile" <<'EOF'
#!/sbin/openrc-run
name="reinstall-auto"
description="Automatic reinstall runner from bootstrap plan"
command="/usr/local/sbin/reinstall-auto.sh"
command_background="no"
depend() {
    need localmount
}
start() {
    ebegin "Starting reinstall-auto"
    ${command}
    eend $?
}
EOF
    chmod 0755 "$svcfile"

    runlevel_link="$ovl_dir/etc/runlevels/default/reinstall-auto"
    ln -s ../../init.d/reinstall-auto "$runlevel_link"

    tar -C "$ovl_dir" -czf "$ALPINE_APKOVL_ABS" .
    chmod 0644 "$ALPINE_APKOVL_ABS"
    rm -rf "$tmp"
    sync
    info "Built Alpine apkovl overlay: $ALPINE_APKOVL_ABS"
}

install_grub_entry_for_alpine() {
    ensure_grub_tools
    detect_current_console_args

    if [[ "$PLAN_STORAGE_MODE" == "efi" ]]; then
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
    linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} reinstall_alpine=1${CURRENT_CONSOLE_ARGS}
    initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
}
EOF
    else
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    linux /boot${ALPINE_VMLINUZ_REL} ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} reinstall_alpine=1${CURRENT_CONSOLE_ARGS}
    initrd /boot${ALPINE_INITRAMFS_REL}
}
EOF
    fi
    chmod 0755 "$GRUB_SCRIPT_PATH"

    info "Regenerating GRUB config..."
    "$GRUB_MKCONFIG_CMD" -o "$GRUB_CFG_PATH" >/dev/null

    info "Scheduling one-time GRUB boot into: ${ALPINE_ENTRY_TITLE}"
    "$GRUB_REBOOT_CMD" "${ALPINE_ENTRY_TITLE}"
}

build_freebsd_grub_efi() {
    ensure_freebsd_boot_tools

    [[ "$PLAN_STORAGE_MODE" == "efi" ]] || \
        error "FreeBSD automatic bootstrap requires EFI storage"
    [[ "$PLAN_EFI_UUID" =~ ^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]] || \
        error "Could not determine FAT EFI filesystem UUID on FreeBSD: ${PLAN_EFI_UUID:-unset}"

    local alpine_release iso_url efi_name
    local tmp iso member volid marker offset
    local old_cfg new_cfg old_len new_len pad
    local expected_file before_file patch_file

    alpine_release="${ALPINE_NETBOOT_SUBDIR#netboot-}"

    case "$ALPINE_NETBOOT_ARCH" in
        x86_64)
            efi_name="bootx64.efi"
            ;;
        aarch64)
            efi_name="bootaa64.efi"
            ;;
        *)
            error "Unsupported FreeBSD UEFI bootstrap arch: $ALPINE_NETBOOT_ARCH"
            ;;
    esac

    # Alpine's official virt ISO already contains a GRUB EFI image built with
    # the exact GRUB modules needed to load Linux + initramfs.  FreeBSD does not
    # ship grub-mkstandalone, so extract that official EFI binary and retarget
    # its tiny embedded early config from the ISO label to this machine's ESP UUID.
    iso_url="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/alpine-virt-${alpine_release}-${ALPINE_NETBOOT_ARCH}.iso"

    tmp=$(mktemp -d /tmp/reinstall-alpine-efi.XXXXXX)
    iso="$tmp/alpine-virt.iso"

    info "Downloading official Alpine virt ISO only for its GRUB EFI bootstrap:"
    info "  $iso_url"
    if ! http_download "$iso_url" "$iso"; then
        rm -rf "$tmp"
        error "Failed to download Alpine virt ISO for FreeBSD UEFI bootstrap"
    fi

    member=$(
        tar -tf "$iso" 2>/dev/null |
        awk -v want="efi/boot/${efi_name}" '
            {
                p=$0
                sub(/^\\.\\//, "", p)
                if (tolower(p) == tolower(want)) {
                    print $0
                    exit
                }
            }
        '
    )
    [[ -n "$member" ]] || {
        rm -rf "$tmp"
        error "Could not locate efi/boot/${efi_name} inside Alpine virt ISO"
    }

    mkdir -p "$(dirname "$ALPINE_FREEBSD_GRUB_EFI_ABS")"
    if ! tar -xOf "$iso" "$member" >"$ALPINE_FREEBSD_GRUB_EFI_ABS"; then
        rm -rf "$tmp"
        error "Failed to extract ${efi_name} from Alpine virt ISO"
    fi
    [[ -s "$ALPINE_FREEBSD_GRUB_EFI_ABS" ]] || {
        rm -rf "$tmp"
        error "Extracted Alpine GRUB EFI binary is empty"
    }

    # Alpine mkimg embeds:
    #   search --no-floppy --set=root --label "alpine-virt VERSION ARCH"
    #   set prefix=($root)/boot/grub
    #
    # That ISO label does not exist after copying the EFI binary to our ESP.
    # Patch only this embedded ASCII config, preserving its exact byte length,
    # so GRUB locates this ESP by its FAT UUID and reads our private grub.cfg.
    volid="alpine-virt ${alpine_release} ${ALPINE_NETBOOT_ARCH}"
    printf -v old_cfg \
        'search --no-floppy --set=root --label "%s"\nset prefix=($root)/boot/grub\n' \
        "$volid"
    printf -v new_cfg \
        'search --no-floppy --fs-uuid --set=root %s\nset prefix=($root)%s/grub\n' \
        "$PLAN_EFI_UUID" "$ALPINE_BOOT_DIR_REL"

    old_len=${#old_cfg}
    new_len=${#new_cfg}
    (( new_len <= old_len )) || {
        rm -rf "$tmp"
        error "Patched Alpine GRUB early config is larger than the embedded config (${new_len} > ${old_len})"
    }

    marker="search --no-floppy --set=root --label \"${volid}\""
    offset=$(
        LC_ALL=C grep -a -b -F "$marker" "$ALPINE_FREEBSD_GRUB_EFI_ABS" 2>/dev/null |
        head -n1 | cut -d: -f1
    )
    [[ "$offset" =~ ^[0-9]+$ ]] || {
        rm -rf "$tmp"
        error "Could not locate Alpine GRUB embedded early config; refusing to patch an unknown EFI binary"
    }

    expected_file="$tmp/expected.cfg"
    before_file="$tmp/before.cfg"
    patch_file="$tmp/patch.cfg"

    printf '%s' "$old_cfg" >"$expected_file"
    dd if="$ALPINE_FREEBSD_GRUB_EFI_ABS" of="$before_file" \
        bs=1 skip="$offset" count="$old_len" 2>/dev/null || {
        rm -rf "$tmp"
        error "Failed to read Alpine GRUB embedded config before patching"
    }

    cmp -s "$expected_file" "$before_file" || {
        rm -rf "$tmp"
        error "Alpine GRUB embedded config did not exactly match the expected ${alpine_release} virt image; refusing binary patch"
    }

    printf '%s' "$new_cfg" >"$patch_file"
    pad=$(( old_len - new_len ))
    if (( pad > 0 )); then
        printf '%*s' "$pad" '' >>"$patch_file"
    fi

    dd if="$patch_file" of="$ALPINE_FREEBSD_GRUB_EFI_ABS" \
        bs=1 seek="$offset" conv=notrunc 2>/dev/null || {
        rm -rf "$tmp"
        error "Failed to patch Alpine GRUB EFI embedded config"
    }

    if ! LC_ALL=C grep -a -F \
        "search --no-floppy --fs-uuid --set=root ${PLAN_EFI_UUID}" \
        "$ALPINE_FREEBSD_GRUB_EFI_ABS" >/dev/null 2>&1; then
        rm -rf "$tmp"
        error "Patched Alpine GRUB EFI verification failed"
    fi

    mkdir -p "$(dirname "$ALPINE_FREEBSD_GRUB_CFG_ABS")"
    cat >"$ALPINE_FREEBSD_GRUB_CFG_ABS" <<EOF
set timeout=0
set default=0
search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} reinstall_alpine=1 console=ttyS0 console=tty0
initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
boot
EOF

    chmod 0644 "$ALPINE_FREEBSD_GRUB_EFI_ABS" "$ALPINE_FREEBSD_GRUB_CFG_ABS"
    rm -rf "$tmp"
    sync

    info "Prepared Alpine official GRUB EFI bootstrap for FreeBSD:"
    info "  EFI: $ALPINE_FREEBSD_GRUB_EFI_ABS"
    info "  CFG: $ALPINE_FREEBSD_GRUB_CFG_ABS"
    info "  ESP UUID: $PLAN_EFI_UUID"
}


install_freebsd_bootnext_entry() {
    ensure_freebsd_boot_tools

    local before after newnum old

    while read -r old; do
        [[ -n "$old" ]] || continue
        efibootmgr -B -b "$old" >/dev/null 2>&1 || warn "Failed to delete old EFI boot entry: $old"
    done < <(
        efibootmgr 2>/dev/null | awk -v title="$ALPINE_ENTRY_TITLE" '
            $0 ~ title {
                n = substr($1, 5, 4)
                gsub(/\*/, "", n)
                print toupper(n)
            }
        '
    )

    before=$(
        efibootmgr 2>/dev/null |
        awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            n = substr($1, 5, 4)
            gsub(/\*/, "", n)
            print toupper(n)
        }' | sort -u
    )

    info "Creating FreeBSD UEFI boot entry: ${ALPINE_ENTRY_TITLE}"
    efibootmgr -a -c \
        -l "$ALPINE_FREEBSD_GRUB_EFI_ABS" \
        -L "$ALPINE_ENTRY_TITLE" >/dev/null

    after=$(
        efibootmgr 2>/dev/null |
        awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            n = substr($1, 5, 4)
            gsub(/\*/, "", n)
            print toupper(n)
        }' | sort -u
    )

    newnum=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1)
    [[ -n "$newnum" ]] || error "Failed to determine new EFI boot entry after creating ${ALPINE_ENTRY_TITLE}"

    info "Setting BootNext to EFI entry $newnum (${ALPINE_ENTRY_TITLE})"
    efibootmgr -n -b "$newnum" >/dev/null
}

prepare_and_boot_alpine_ram() {
    [[ "$OS" == "Linux" ]] || error "Automatic Alpine RAM bootstrap only supports Linux host in this function"

    prepare_alpine_paths
    cache_optional_inputs_to_bootstrap
    save_plan_to_efi
    copy_script_to_efi
    download_alpine_ram_files
    build_alpine_apkovl
    install_grub_entry_for_alpine

    info "Alpine RAM installer prepared."
    info "System will reboot now into one-time GRUB entry: ${ALPINE_ENTRY_TITLE}"
    sync
    sleep 2
    reboot
}

prepare_and_boot_alpine_ram_freebsd() {
    [[ "$OS" == "FreeBSD" ]] || error "Automatic FreeBSD BootNext bootstrap only supports FreeBSD host in this function"

    prepare_alpine_paths
    cache_optional_inputs_to_bootstrap
    save_plan_to_efi
    copy_script_to_efi
    download_alpine_ram_files
    build_alpine_apkovl
    build_freebsd_grub_efi
    install_freebsd_bootnext_entry

    info "Alpine RAM installer prepared for FreeBSD UEFI BootNext using Alpine official GRUB EFI."
    info "System will reboot now into one-time UEFI entry: ${ALPINE_ENTRY_TITLE}"
    sync
    sleep 2
    shutdown -r now
}

# ----------------- installer execution (Alpine download + direct write + NoCloud) -----------------

locate_bootstrap_image() {
    local root_abs="$1"
    local p1 p2

    p1="$root_abs/$PLAN_DIR_REL/cache/image.qcow2"
    p2="$root_abs/$PLAN_DIR_REL/cache/image.qcow2.xz"

    if [[ -f "$p1" ]]; then
        echo "$p1"
        return 0
    fi

    if [[ -f "$p2" ]]; then
        echo "$p2"
        return 0
    fi

    return 1
}

reread_partition_table_strict() {
    sync

    # Alpine RAM may retain stale partition mappings after an in-place disk-image
    # write. Do not make partprobe the single point of failure: try the kernel
    # reread ioctl and partx as well, then refresh /dev through mdev/udev.
    local reread_ok=0

    if command -v blockdev >/dev/null 2>&1; then
        if blockdev --rereadpt "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    if command -v partprobe >/dev/null 2>&1; then
        if partprobe "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    if command -v partx >/dev/null 2>&1; then
        if partx -u "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        elif partx -a "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    [[ "$reread_ok" -eq 1 ]] || {
        warn "Kernel could not reread the target partition table."
        lsblk -a -o NAME,PATH,TYPE,SIZE,PARTN,PARTLABEL "$DISK" >&2 2>/dev/null || true
        error "Failed to synchronize the target partition table with the kernel"
    }
}

create_nocloud_cidata_partition() {
    [[ "$OS" == "Linux" ]] || error "Creating the standard NoCloud CIDATA partition requires the Linux/Alpine installer environment"
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required to create a standard NoCloud CIDATA partition"
    command -v mkfs.vfat >/dev/null 2>&1 || error "mkfs.vfat is required to create a standard NoCloud CIDATA partition"

    if ! sgdisk -p "$DISK" >/dev/null 2>&1; then
        error "Target image does not expose a usable GPT; refusing non-standard EFI:/nocloud injection"
    fi

    info "Creating dedicated 16 MiB NoCloud CIDATA partition..."
    sgdisk -e "$DISK" >/dev/null || error "Failed to relocate GPT backup header on $DISK"
    sgdisk -n 0:0:+16M -t 0:0700 -c 0:CIDATA "$DISK" >/dev/null || \
        error "Failed to create CIDATA partition; target disk may not have enough unallocated GPT space"
    reread_partition_table_strict
    sleep 1

    local seed_part
    seed_part=$(lsblk -lnpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk '$2=="CIDATA" {print $1; exit}')
    [[ -n "$seed_part" && -b "$seed_part" ]] || error "Could not locate newly created CIDATA partition"
    mkfs.vfat -F 32 -n CIDATA "$seed_part" >/dev/null || error "Failed to format CIDATA partition: $seed_part"
    printf '%s\n' "$seed_part"
}

TEMP_STAGE_SIZE_BYTES=$((3072 * 1024 * 1024))
TEMP_STAGE_PART_NUM=1
TEMP_STAGE_LABEL="REINSTALL_TMP"
TEMP_STAGE_MNT="/mnt/reinstall-stage"
TEMP_STAGE_PART=""
TEMP_STAGE_START_SECTOR=""
TEMP_STAGE_START_BYTES=""
TEMP_STAGE_SECTOR_SIZE=""
QCOW_VIRTUAL_SIZE=""
QCOW_MAX_PART_END_BYTES=""
QCOW_MAX_PART_END_SECTOR=""
QCOW_NBD_DEV=""

partition_device_for_number() {
    local disk="$1" num="$2"
    case "$disk" in
        /dev/nvme*|/dev/mmcblk*|/dev/loop*)
            printf '%sp%s\n' "$disk" "$num"
            ;;
        *)
            printf '%s%s\n' "$disk" "$num"
            ;;
    esac
}

ensure_linux_block_node_from_sysfs() {
    local devpath="$1" name sysdev maj min

    [[ -n "$devpath" ]] || return 1
    [[ -b "$devpath" ]] && return 0

    name="${devpath#/dev/}"
    sysdev="/sys/class/block/$name/dev"

    [[ -r "$sysdev" ]] || return 1

    IFS=: read -r maj min <"$sysdev"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1

    # Alpine RAM may have the partition registered in the kernel/sysfs while
    # mdev has not recreated the corresponding /dev node after partx/rereadpt.
    # Only create the node when sysfs explicitly exposes the exact block device.
    if [[ -e "$devpath" && ! -b "$devpath" ]]; then
        rm -f "$devpath"
    fi

    mknod "$devpath" b "$maj" "$min" || return 1
    chmod 0600 "$devpath" 2>/dev/null || true

    [[ -b "$devpath" ]]
}

prepare_fixed_temp_staging_partition() {
    [[ "$OS" == "Linux" ]] || error "The fixed 3 GiB staging partition requires the Linux/Alpine installer environment"
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required for the fixed staging partition"
    command -v mkfs.ext4 >/dev/null 2>&1 || error "mkfs.ext4 is required for the fixed staging partition"
    command -v blockdev >/dev/null 2>&1 || error "blockdev is required for the fixed staging partition"

    local disk_size first_sector last_sector actual_bytes min_remaining
    disk_size=$(get_disk_size_bytes "$DISK" || true)
    [[ -n "$disk_size" ]] || error "Could not determine target disk size before creating staging partition"

    # Keep at least 2 GiB in front of the staging partition. The actual image-layout
    # check below is stricter and will refuse an image whose partitions cross the boundary.
    min_remaining=$((2 * 1024 * 1024 * 1024))
    if [[ "$disk_size" -le $((TEMP_STAGE_SIZE_BYTES + min_remaining)) ]]; then
        error "Target disk is too small for the mandatory 3 GiB staging partition. Disk=${disk_size} bytes"
    fi

    info "Preparing mandatory 3 GiB staging partition at the end of $DISK ..."
    info "This step destroys the old partition table; Alpine is already running from RAM."

    wipefs -a "$DISK" >/dev/null 2>&1 || true
    sgdisk -Z "$DISK" >/dev/null 2>&1 || true

    # Remove stale kernel partition mappings before creating the one temporary
    # partition. This matters on Alpine/mdev and virtio-blk after the original
    # boot disk partitions have just been removed.
    if command -v partx >/dev/null 2>&1; then
        partx -d "$DISK" >/dev/null 2>&1 || true
    fi
    command -v blockdev >/dev/null 2>&1 && blockdev --rereadpt "$DISK" >/dev/null 2>&1 || true
    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true

    sgdisk -o "$DISK" >/dev/null || error "Failed to create temporary GPT on $DISK"
    sgdisk -n "${TEMP_STAGE_PART_NUM}:-3072M:0" \
           -t "${TEMP_STAGE_PART_NUM}:8300" \
           -c "${TEMP_STAGE_PART_NUM}:${TEMP_STAGE_LABEL}" \
           "$DISK" >/dev/null || error "Failed to create mandatory 3 GiB staging partition"

    reread_partition_table_strict

    # Do not depend on PARTLABEL appearing in lsblk immediately. On minimal
    # Alpine with mdev that metadata may lag even though the partition node is
    # already valid. The partition number is known because the temporary GPT
    # contains exactly this explicitly numbered partition.
    TEMP_STAGE_PART=$(partition_device_for_number "$DISK" "$TEMP_STAGE_PART_NUM")
    local wait_i
    for wait_i in 1 2 3 4 5 6 7 8; do
        [[ -b "$TEMP_STAGE_PART" ]] && break

        command -v partx >/dev/null 2>&1 && {
            partx -u "$DISK" >/dev/null 2>&1 || partx -a "$DISK" >/dev/null 2>&1 || true
        }
        command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
        command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

        # If the kernel already exposes the partition in sysfs but minimal
        # Alpine has not populated /dev yet, create that exact block node from
        # the kernel-provided major:minor instead of guessing.
        ensure_linux_block_node_from_sysfs "$TEMP_STAGE_PART" && break

        sleep 1
    done

    if [[ ! -b "$TEMP_STAGE_PART" ]]; then
        warn "Temporary GPT as reported by sgdisk:"
        sgdisk -p "$DISK" >&2 || true
        warn "Current block-device view:"
        lsblk -a -o NAME,PATH,TYPE,SIZE,PARTN,PARTLABEL,MAJ:MIN "$DISK" >&2 || true
        warn "Relevant sysfs state:"
        local stage_name
        stage_name="${TEMP_STAGE_PART#/dev/}"
        if [[ -d "/sys/class/block/$stage_name" ]]; then
            ls -la "/sys/class/block/$stage_name" >&2 || true
            cat "/sys/class/block/$stage_name/dev" >&2 2>/dev/null || true
        fi
        error "Could not create/locate expected temporary staging partition node: $TEMP_STAGE_PART"
    fi

    info "Temporary staging partition node ready: $TEMP_STAGE_PART"

    TEMP_STAGE_SECTOR_SIZE=$(blockdev --getss "$DISK" 2>/dev/null || true)
    [[ "$TEMP_STAGE_SECTOR_SIZE" =~ ^[0-9]+$ && "$TEMP_STAGE_SECTOR_SIZE" -gt 0 ]] || \
        error "Could not determine target logical sector size"

    first_sector=$(sgdisk -i "$TEMP_STAGE_PART_NUM" "$DISK" 2>/dev/null | \
        awk '/First sector:/ {print $3; exit}')
    last_sector=$(sgdisk -i "$TEMP_STAGE_PART_NUM" "$DISK" 2>/dev/null | \
        awk '/Last sector:/ {print $3; exit}')
    [[ "$first_sector" =~ ^[0-9]+$ && "$last_sector" =~ ^[0-9]+$ ]] || \
        error "Could not determine temporary staging partition boundaries"

    TEMP_STAGE_START_SECTOR="$first_sector"
    TEMP_STAGE_START_BYTES=$((first_sector * TEMP_STAGE_SECTOR_SIZE))
    actual_bytes=$(((last_sector - first_sector + 1) * TEMP_STAGE_SECTOR_SIZE))

    # The start is normally aligned, so the actual size may differ from exactly 3 GiB
    # by less than one alignment unit. Reject a materially smaller partition.
    if [[ "$actual_bytes" -lt $((TEMP_STAGE_SIZE_BYTES - 2 * 1024 * 1024)) ]]; then
        error "Temporary staging partition is smaller than requested: ${actual_bytes} bytes"
    fi

    mkfs.ext4 -F -m 0 -L "$TEMP_STAGE_LABEL" "$TEMP_STAGE_PART" >/dev/null || \
        error "Failed to format temporary staging partition: $TEMP_STAGE_PART"
    mkdir -p "$TEMP_STAGE_MNT"
    mount -t ext4 -o noatime "$TEMP_STAGE_PART" "$TEMP_STAGE_MNT" || \
        error "Failed to mount temporary staging partition: $TEMP_STAGE_PART"

    # Deliberately invalidate the temporary GPT backup header after the kernel has
    # learned the partition mapping. Later the image primary GPT will replace the
    # temporary primary GPT, and sgdisk -e can rebuild a clean backup GPT without
    # accidentally preferring the stale temporary backup table.
    local disk_bytes total_sectors tail_start
    disk_bytes=$(blockdev --getsize64 "$DISK")
    total_sectors=$((disk_bytes / TEMP_STAGE_SECTOR_SIZE))
    tail_start=$((total_sectors - 34))
    if [[ "$tail_start" -gt "$last_sector" ]]; then
        dd if=/dev/zero of="$DISK" bs="$TEMP_STAGE_SECTOR_SIZE" \
           seek="$tail_start" count=34 conv=notrunc status=none || \
            error "Failed to invalidate temporary backup GPT"
        sync
    fi

    info "Temporary staging partition: $TEMP_STAGE_PART"
    info "Temporary staging mount:     $TEMP_STAGE_MNT"
    info "Staging boundary:            ${TEMP_STAGE_START_BYTES} bytes from disk start"
    df -h "$TEMP_STAGE_MNT" || true
}

cleanup_qcow_nbd() {
    if [[ -n "${QCOW_NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "$QCOW_NBD_DEV" >/dev/null 2>&1 || true
        QCOW_NBD_DEV=""
    fi
}

connect_qcow_readonly_nbd() {
    local img="$1" n dev size

    command -v qemu-nbd >/dev/null 2>&1 || error "qemu-nbd is required to inspect qcow2 partition layout"
    modprobe nbd max_part=64 >/dev/null 2>&1 || error "Could not load nbd kernel module"
    mdev -s 2>/dev/null || true

    for n in $(seq 0 15); do
        dev="/dev/nbd$n"
        [[ -b "$dev" ]] || continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [[ "$size" == "0" ]] || continue
        if qemu-nbd --connect="$dev" --read-only --format=qcow2 "$img" >/dev/null 2>&1; then
            QCOW_NBD_DEV="$dev"
            sleep 1
            return 0
        fi
    done

    error "Could not allocate a free NBD device for qcow2 inspection"
}

inspect_qcow_partition_layout() {
    local img="$1" nbd sector_size max_end table

    QCOW_VIRTUAL_SIZE=$(get_qcow_virtual_size_bytes "$img" || true)
    [[ "$QCOW_VIRTUAL_SIZE" =~ ^[0-9]+$ && "$QCOW_VIRTUAL_SIZE" -gt 0 ]] || \
        error "Could not determine qcow2 virtual size"

    connect_qcow_readonly_nbd "$img"
    nbd="$QCOW_NBD_DEV"

    if ! table=$(sgdisk -p "$nbd" 2>&1); then
        echo "$table" >&2
        error "Target qcow2 does not expose a usable GPT; cannot safely use an in-disk staging partition"
    fi

    sector_size=$(blockdev --getss "$nbd" 2>/dev/null || true)
    [[ "$sector_size" =~ ^[0-9]+$ && "$sector_size" -gt 0 ]] || \
        error "Could not determine qcow2 logical sector size"

    max_end=$(printf '%s\n' "$table" | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {
            if ($3 + 0 > max + 0) max=$3
        }
        END { if (max != "") print max }
    ')
    [[ "$max_end" =~ ^[0-9]+$ ]] || error "Could not determine the last partition sector inside qcow2"

    QCOW_MAX_PART_END_SECTOR="$max_end"
    QCOW_MAX_PART_END_BYTES=$(((max_end + 1) * sector_size))

    cleanup_qcow_nbd

    info "qcow2 virtual size:          ${QCOW_VIRTUAL_SIZE} bytes"
    info "qcow2 last partition end:    ${QCOW_MAX_PART_END_BYTES} bytes"
    info "temporary partition begins:  ${TEMP_STAGE_START_BYTES} bytes"

    # Keep 8 MiB of safety space before the live staging partition.
    if [[ "$QCOW_MAX_PART_END_BYTES" -gt $((TEMP_STAGE_START_BYTES - 8 * 1024 * 1024)) ]]; then
        error "The qcow2 partition layout reaches the mandatory 3 GiB staging area. Refusing a self-overwriting install. Image partition end=${QCOW_MAX_PART_END_BYTES}; staging start=${TEMP_STAGE_START_BYTES}"
    fi
}

download_target_image_in_alpine() {
    local dst="$1" tmp="${1}.part.$$" remote_size allocated

    rm -f "$tmp"
    info "Downloading target image onto the mandatory 3 GiB staging partition: $IMG_URL"

    remote_size=$(http_content_length "$IMG_URL" || true)
    if [[ "$remote_size" =~ ^[0-9]+$ && "$remote_size" -gt $((1450 * 1024 * 1024)) ]]; then
        error "Remote image payload is too large for the fixed 3 GiB staging partition: ${remote_size} bytes"
    fi

    if [[ "$IMG_URL" == *.xz ]]; then
        # Keep FreeBSD and other xz-wrapped qcow2 images as qcow2. We do not store
        # the compressed .xz separately: the network stream is decompressed directly
        # into a regular qcow2 file on the staging filesystem. xz recreates sparse
        # regions when the output is a seekable regular file.
        if command -v curl >/dev/null 2>&1; then
            if ! curl -L --fail "$IMG_URL" | xz -dc >"$tmp"; then
                rm -f "$tmp"
                error "Failed to download/decompress target qcow2.xz onto staging partition: $IMG_URL"
            fi
        elif command -v wget >/dev/null 2>&1; then
            if ! wget -O - "$IMG_URL" | xz -dc >"$tmp"; then
                rm -f "$tmp"
                error "Failed to download/decompress target qcow2.xz onto staging partition: $IMG_URL"
            fi
        else
            error "No curl or wget available in Alpine RAM"
        fi
    else
        http_download "$IMG_URL" "$tmp" || {
            rm -f "$tmp"
            error "Failed to download target image onto staging partition: $IMG_URL"
        }
    fi

    qemu-img info "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp"
        error "Downloaded target image is not a readable qcow2 image"
    }

    mv -f "$tmp" "$dst"
    sync
    allocated=$(du -B1 "$dst" 2>/dev/null | awk '{print $1; exit}' || true)
    info "Target qcow2 is ready on staging partition: $dst"
    [[ -n "$allocated" ]] && info "qcow2 allocated staging space: ${allocated} bytes"
    df -h "$TEMP_STAGE_MNT" || true
}

get_qcow_virtual_size_bytes() {
    local path="$1"
    qemu-img info --output=json "$path" 2>/dev/null | \
        awk -F': *' '/"virtual-size"/ {v=$2; gsub(/[,[:space:]]/, "", v); print v; exit}'
}

write_qcow_without_overwriting_staging() {
    local img="$1" bs_arg count_arg

    [[ -n "$TEMP_STAGE_START_BYTES" ]] || error "Temporary staging boundary is unknown"

    if [[ "$QCOW_VIRTUAL_SIZE" -le "$TEMP_STAGE_START_BYTES" ]]; then
        info "qcow2 virtual disk ends before the staging partition; converting the whole image."
        qemu-img convert -p -n -S 0 -f qcow2 -O raw "$img" "$DISK" || \
            error "qemu-img failed while writing the target disk"
        return 0
    fi

    # The image virtual disk extends beyond the staging boundary, but its real GPT
    # partitions were verified to end before the boundary. Copy only the safe prefix;
    # this intentionally omits trailing free space and the source backup GPT. The GPT
    # backup is rebuilt after the staging partition has been released.
    if (( TEMP_STAGE_START_BYTES % (4 * 1024 * 1024) == 0 )); then
        bs_arg="4M"
        count_arg=$((TEMP_STAGE_START_BYTES / (4 * 1024 * 1024)))
    elif (( TEMP_STAGE_START_BYTES % (1024 * 1024) == 0 )); then
        bs_arg="1M"
        count_arg=$((TEMP_STAGE_START_BYTES / (1024 * 1024)))
    else
        bs_arg="$TEMP_STAGE_SECTOR_SIZE"
        count_arg="$TEMP_STAGE_START_SECTOR"
    fi

    info "qcow2 virtual size crosses the staging area, but all image partitions fit before it."
    info "Writing only the safe prefix with qemu-img dd: bs=$bs_arg count=$count_arg"
    qemu-img dd -f qcow2 -O raw "bs=$bs_arg" "count=$count_arg" \
        "if=$img" "of=$DISK" || error "qemu-img dd failed while writing the safe image prefix"
}

release_temp_staging_partition() {
    local old_stage="${TEMP_STAGE_PART:-}"

    sync
    cd /

    if is_mountpoint "$TEMP_STAGE_MNT"; then
        umount "$TEMP_STAGE_MNT" || error "Failed to unmount temporary staging partition"
    fi

    # The on-disk primary GPT has already been replaced by the target image, but
    # the kernel can still remember the old tail REINSTALL_TMP partition. Drop
    # those stale mappings before manipulating the target GPT. This avoids
    # BLKRRPART/partprobe returning EBUSY even though the staging filesystem has
    # already been unmounted.
    if command -v partx >/dev/null 2>&1; then
        if ! partx -d "$DISK" >/dev/null 2>&1; then
            warn "Could not immediately delete stale staging partition mappings with partx; continuing with GPT repair."
        fi
    fi

    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    if [[ -n "$old_stage" ]]; then
        info "Released temporary staging partition: $old_stage"
    fi

    TEMP_STAGE_PART=""
}

find_last_growable_gpt_partition() {
    local line num start end code best_num="" best_end=0 best_code=""

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+.*[[:space:]]+([0-9A-Fa-f]{4})[[:space:]] ]] || continue
        num="${BASH_REMATCH[1]}"
        start="${BASH_REMATCH[2]}"
        end="${BASH_REMATCH[3]}"
        code="${BASH_REMATCH[4]}"
        code="${code^^}"
        if (( end > best_end )); then
            best_end="$end"
            best_num="$num"
            best_code="$code"
        fi
    done < <(sgdisk -p "$DISK" 2>/dev/null || true)

    [[ -n "$best_num" ]] || return 1
    case "$best_code" in
        EF00|EF02|8200|A502)
            warn "The physically last GPT partition is type $best_code; refusing to expand EFI/BIOS/swap partition automatically."
            return 1
            ;;
    esac

    printf '%s\n' "$best_num"
}

grow_last_partition_reserving_cidata() {
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required to expand the target GPT"

    local partnum info_text start end type_guid unique_guid attrs name
    local sector_size reserve_bytes reserve_sectors largest_end new_end

    sgdisk -e "$DISK" >/dev/null || error "Failed to relocate/rebuild target backup GPT after staging write"

    partnum=$(find_last_growable_gpt_partition || true)
    [[ -n "$partnum" ]] || error "Could not identify a safe final GPT data partition to expand"

    info_text=$(sgdisk -i "$partnum" "$DISK" 2>/dev/null) || error "Failed to inspect target partition $partnum"
    start=$(printf '%s\n' "$info_text" | awk '/First sector:/ {print $3; exit}')
    end=$(printf '%s\n' "$info_text" | awk '/Last sector:/ {print $3; exit}')
    type_guid=$(printf '%s\n' "$info_text" | awk '/Partition GUID code:/ {print $4; exit}')
    unique_guid=$(printf '%s\n' "$info_text" | awk '/Partition unique GUID:/ {print $4; exit}')
    attrs=$(printf '%s\n' "$info_text" | awk '/Attribute flags:/ {print $3; exit}')
    name=$(printf '%s\n' "$info_text" | sed -n "s/^Partition name: '\(.*\)'$/\1/p" | head -n1)

    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && -n "$type_guid" ]] || \
        error "Could not preserve partition metadata while preparing expansion"

    sector_size=$(blockdev --getss "$DISK")
    reserve_bytes=$((32 * 1024 * 1024))
    reserve_sectors=$(((reserve_bytes + sector_size - 1) / sector_size))
    largest_end=$(sgdisk -E "$DISK" 2>/dev/null || true)
    [[ "$largest_end" =~ ^[0-9]+$ && "$largest_end" -gt 0 ]] || \
        error "Could not determine free-space end for target partition expansion"

    new_end=$((largest_end - reserve_sectors))
    if [[ "$new_end" -le "$end" ]]; then
        warn "No useful room remains to expand target partition $partnum before CIDATA reservation."
        return 0
    fi

    info "Expanding target GPT partition $partnum from end sector $end to $new_end; reserving 32 MiB for CIDATA/alignment."
    sgdisk -d "$partnum" "$DISK" >/dev/null || error "Failed to delete partition $partnum for boundary-only resize"
    sgdisk -n "${partnum}:${start}:${new_end}" "$DISK" >/dev/null || error "Failed to recreate expanded partition $partnum"
    sgdisk -t "${partnum}:${type_guid}" "$DISK" >/dev/null || error "Failed to restore GPT type for partition $partnum"
    [[ -z "$unique_guid" ]] || sgdisk -u "${partnum}:${unique_guid}" "$DISK" >/dev/null || error "Failed to restore PARTUUID for partition $partnum"
    [[ -z "$name" ]] || sgdisk -c "${partnum}:${name}" "$DISK" >/dev/null || error "Failed to restore GPT name for partition $partnum"
    if [[ -n "$attrs" && "$attrs" != "0000000000000000" ]]; then
        sgdisk -A "${partnum}:=:${attrs}" "$DISK" >/dev/null || \
            error "Failed to restore GPT attributes for partition $partnum"
    fi

    reread_partition_table_strict
    sleep 1
}

do_install() {
    info "Host: OS=$OS ARCH=$ARCH ($MACHINE_ARCH)"
    info "Target: $TARGET_OS ${TARGET_VER:-"(no version)"}"
    info "Disk: $DISK"
    info "Image URL: $IMG_URL"

    if [[ "$HOLD" == "1" ]]; then
        info "--hold 1 is set: only parameter check and summary, no download or disk write."
        return 0
    fi

    if [[ -d /run/reinstall-work ]] && is_mountpoint /run/reinstall-work; then
        INSTALL_TMPDIR=$(mktemp -d /run/reinstall-work/install.XXXXXX)
    else
        error "Swap-backed Alpine work tmpfs is not mounted at /run/reinstall-work"
    fi

    local bootstrap_root_abs virtual_size disk_size staged_frpc staged_hook
    local CIDATA_PART MNT_CIDATA
    bootstrap_root_abs="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL"
    staged_frpc=""
    staged_hook=""

    cleanup_install_stage() {
        cleanup_qcow_nbd
        if is_mountpoint "$TEMP_STAGE_MNT"; then
            umount "$TEMP_STAGE_MNT" 2>/dev/null || true
        fi
        rm -rf "$INSTALL_TMPDIR" 2>/dev/null || true
    }
    trap cleanup_install_stage EXIT

    # Small optional inputs are staged in RAM before the old disk layout is destroyed.
    if [[ -n "${FRPC_TOML:-}" && "$FRPC_TOML" =~ ^https?:// ]]; then
        staged_frpc="$INSTALL_TMPDIR/frpc.toml"
        info "Downloading FRPC config from Alpine RAM: $FRPC_TOML"
        http_download "$FRPC_TOML" "$staged_frpc" || error "Failed to download FRPC config from Alpine RAM"
        FRPC_TOML="$staged_frpc"
    elif [[ -n "${FRPC_BOOTSTRAP_REL:-}" && -f "$bootstrap_root_abs$FRPC_BOOTSTRAP_REL" ]]; then
        staged_frpc="$INSTALL_TMPDIR/frpc.toml"
        cp "$bootstrap_root_abs$FRPC_BOOTSTRAP_REL" "$staged_frpc"
        FRPC_TOML="$staged_frpc"
    fi
    if [[ -n "${POST_INSTALL_HOOK_BOOTSTRAP_REL:-}" && -f "$bootstrap_root_abs$POST_INSTALL_HOOK_BOOTSTRAP_REL" ]]; then
        staged_hook="$INSTALL_TMPDIR/post-install-hook.sh"
        cp "$bootstrap_root_abs$POST_INSTALL_HOOK_BOOTSTRAP_REL" "$staged_hook"
        chmod 0700 "$staged_hook"
        POST_INSTALL_HOOK="$staged_hook"
    fi

    # A fixed 3 GiB tail partition is always used for image staging, even when
    # there is enough RAM. At this point modloop and the installer itself are in RAM.
    sync
    cd /
    unmount_target_disk_filesystems "$DISK"

    echo
    echo "WARNING: the target disk will now be repartitioned for a mandatory 3 GiB staging area."
    echo "ALL EXISTING DATA ON $DISK WILL BE LOST BEFORE THE IMAGE DOWNLOAD STARTS."

    if [[ "$AUTO_YES" -eq 1 ]]; then
        info "AUTO_YES=1, skipping interactive confirmation."
    else
        read -r -p "Type 'yes' or 'y' to continue: " ans
        case "$ans" in
            y|Y|yes|YES|Yes) ;;
            *) error "Operation cancelled by user." ;;
        esac
    fi

    prepare_fixed_temp_staging_partition
    IMG_QCOW="$TEMP_STAGE_MNT/image.qcow2"
    download_target_image_in_alpine "$IMG_QCOW"

    virtual_size=$(get_qcow_virtual_size_bytes "$IMG_QCOW" || true)
    disk_size=$(get_disk_size_bytes "$DISK" || true)
    [[ -n "$virtual_size" && -n "$disk_size" ]] || error "Could not determine qcow2 virtual size or target disk size before write"

    inspect_qcow_partition_layout "$IMG_QCOW"

    info "Writing qcow2 from the 3 GiB tail staging partition without overwriting its live source..."
    write_qcow_without_overwriting_staging "$IMG_QCOW"
    sync
    info "Safe qcow2 prefix write finished."

    # qemu-img has closed the source file. Release the temporary tail partition,
    # then make the image GPT authoritative and recover the 3 GiB for the target.
    release_temp_staging_partition
    sync

    # Work directly on the image GPT while no target partitions are mapped in the
    # kernel. grow_last_partition_reserving_cidata() repairs the backup GPT,
    # expands the final data partition, and then performs a single kernel reread.
    sgdisk -e "$DISK" >/dev/null || error "Failed to repair target GPT after releasing staging partition"

    grow_last_partition_reserving_cidata

    CIDATA_PART=$(create_nocloud_cidata_partition)
    info "Using NoCloud CIDATA partition: $CIDATA_PART"

    MNT_CIDATA="$INSTALL_TMPDIR/cidata"
    mkdir -p "$MNT_CIDATA"
    mount -t vfat "$CIDATA_PART" "$MNT_CIDATA" || error "Failed to mount CIDATA partition $CIDATA_PART"

    if [[ -n "$FRPC_TOML" && -f "$FRPC_TOML" ]]; then
        FRPC_PRESENT=1
    else
        FRPC_PRESENT=""
    fi

    info "Writing standard NoCloud seed to CIDATA:/ ..."
    write_nocloud_seed "$TARGET_OS" "$MNT_CIDATA/meta-data" "$MNT_CIDATA/user-data"

    sync
    umount "$MNT_CIDATA" || error "Failed to unmount CIDATA partition $CIDATA_PART"

    info "Image write, target-partition expansion, and cloud-init NoCloud injection completed."

    run_rhel_freebsd_hook
    show_partition_info

    FINAL_SSH_PORT="${SSH_PORT:-22}"

    echo
    echo "==================== Installation summary ===================="
    echo "Disk device:  $DISK"
    echo "Target OS:    $TARGET_OS ${TARGET_VER:-"(no version)"}"
    echo "Username:     root"
    echo "SSH port:     $FINAL_SSH_PORT"

    if [[ -n "$PASSWORD_HASH" ]]; then
        echo "Root password: configured (stored as hash; plain text is not kept in plan.env)"
    else
        echo "Root password: (not set; SSH key login only)"
    fi

    echo "SSH authorized keys:"
    if [[ -n "$SSH_KEYS_ALL" ]]; then
        while IFS= read -r k; do
            [[ -n "$k" ]] && echo "  $k"
        done <<<"$SSH_KEYS_ALL"
    else
        echo "  (none)"
    fi

    if [[ "$AUTO_PASSWORD" -eq 1 ]]; then
        echo
        echo "NOTE: The root password was auto-generated and should have been shown before reboot."
    fi
    echo "=============================================================="

    if [[ "$HOLD" == "2" ]]; then
        info "--hold 2 is set: will NOT reboot automatically. You can inspect or chroot into the new system manually."
        trap - EXIT
        cleanup_install_stage
        return 0
    fi

    trap - EXIT
    cleanup_install_stage

    echo
    echo "You can now reboot into the new system, for example:"
    if [[ "$OS" == "FreeBSD" ]]; then
        echo "  shutdown -r now"
    else
        echo "  reboot"
    fi
}

# ----------------- main -----------------

detect_env_mode

PHASE="auto"
if [[ "${1:-}" == "--phase" ]]; then
    shift
    [[ -n "${1:-}" ]] || error "Need value for --phase"
    PHASE="$1"
    shift || true
fi

if [[ "$PHASE" == "host" ]]; then
    ENV_MODE="host"
elif [[ "$PHASE" == "installer" ]]; then
    ENV_MODE="initramfs"
fi

# Installer phase: mfsBSD / initramfs / Alpine RAM / explicit --phase installer
if [[ "$ENV_MODE" == "initramfs" || "$ENV_MODE" == "mfsbsd" || "$ENV_MODE" == "alpine-ram" ]]; then
    TARGET_OS=""
    TARGET_VER=""
    DISK=""
    PASSWORD=""
    PASSWORD_HASH=""
    SSH_KEYS_ALL=""
    SSH_PORT=""
    WEB_PORT=""
    FRPC_TOML=""
    POST_INSTALL_HOOK=""
    FRPC_PRESENT=""
    HOLD="0"
    AUTO_PASSWORD=0
    AUTO_YES=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hold)
                shift
                [[ -n "${1:-}" ]] || error "Need value for --hold"
                [[ "$1" == "1" || "$1" == "2" ]] || error "Invalid --hold: $1 (must be 1 or 2)"
                HOLD="$1"
                ;;
            --yes|--force)
                AUTO_YES=1
                ;;
            *)
                warn "Ignoring argument in installer mode: $1"
                ;;
        esac
        shift || true
    done

    INSTALLER_HOLD_OVERRIDE="$HOLD"

    detect_os_arch
    load_plan_from_efi

    if [[ "$INSTALLER_HOLD_OVERRIDE" != "0" ]]; then
        HOLD="$INSTALLER_HOLD_OVERRIDE"
    fi
    if [[ "$HOLD" != "1" ]]; then
        ensure_dependencies
    fi

    if [[ -n "$DISK" && "$DISK" != /dev/* ]]; then
        DISK="/dev/$DISK"
    fi
    if [[ -z "$DISK" ]]; then
        auto_detect_disk
    else
        resolve_target_disk_from_identity
    fi

    validate_target_disk "$DISK"

    do_install
    exit 0
fi

# Host phase: validate the command line prefix before doing anything that can
# install packages, inspect/select disks, prompt for credentials, or modify state.
if [[ $# -lt 1 ]]; then
    error "Missing target OS. Supported targets: freebsd, rocky, almalinux, fedora, debian, redhat"
fi

case "$1" in
    -h|--help)
        usage
        ;;
esac

TARGET_OS=$(to_lower "$1")
shift || true

TARGET_VER=""
IMG_URL=""
DISK=""
PASSWORD=""
PASSWORD_HASH=""
SSH_KEYS_ALL=""
SSH_PORT=""
WEB_PORT=""
FRPC_TOML=""
POST_INSTALL_HOOK=""
FRPC_PRESENT=""
HOLD="0"
AUTO_PASSWORD=0

case "$TARGET_OS" in
    freebsd)
        [[ $# -gt 0 && "${1:-}" != --* ]] || \
            error "Missing FreeBSD major version. Use: $SCRIPT_NAME freebsd 14|15 [options...]"
        [[ "$1" == "14" || "$1" == "15" ]] || \
            error "Unsupported FreeBSD major version: $1 (supported: 14, 15)"
        TARGET_VER="$1"
        shift
        ;;
    rocky)
        [[ $# -gt 0 && "${1:-}" != --* ]] || \
            error "Missing Rocky Linux major version. Use: $SCRIPT_NAME rocky 10 [options...]"
        [[ "$1" == "10" ]] || \
            error "Unsupported Rocky Linux major version: $1 (supported: 10)"
        TARGET_VER="$1"
        shift
        ;;
    almalinux)
        [[ $# -gt 0 && "${1:-}" != --* ]] || \
            error "Missing AlmaLinux major version. Use: $SCRIPT_NAME almalinux 10 [options...]"
        [[ "$1" == "10" ]] || \
            error "Unsupported AlmaLinux major version: $1 (supported: 10)"
        TARGET_VER="$1"
        shift
        ;;
    fedora)
        [[ $# -gt 0 && "${1:-}" != --* ]] || \
            error "Missing Fedora version. Use: $SCRIPT_NAME fedora 44 [options...]"
        [[ "$1" == "44" ]] || \
            error "Unsupported Fedora version: $1 (supported: 44)"
        TARGET_VER="$1"
        shift
        ;;
    debian)
        [[ $# -gt 0 && "${1:-}" != --* ]] || \
            error "Missing Debian major version. Use: $SCRIPT_NAME debian 13 [options...]"
        [[ "$1" == "13" ]] || \
            error "Unsupported Debian major version: $1 (supported: 13)"
        TARGET_VER="$1"
        shift
        ;;
    redhat)
        if [[ $# -gt 0 && "${1:-}" != --* ]]; then
            error "Do not specify a version for redhat. Use: $SCRIPT_NAME redhat --img URL [options...]"
        fi
        ;;
    *)
        error "Unknown target OS: $TARGET_OS (supported: freebsd, rocky, almalinux, fedora, debian, redhat)"
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --disk)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --disk"
            DISK="$1"
            ;;
        --disk=*)
            DISK="${1#*=}"
            ;;
        --img)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --img"
            IMG_URL="$1"
            ;;
        --img=*)
            IMG_URL="${1#*=}"
            ;;
        --password|--passwd)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --password"
            PASSWORD="$1"
            ;;
        --ssh-key|--public-key)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --ssh-key"
            key_line=$(parse_ssh_key "$1")
            if [[ -n "$SSH_KEYS_ALL" ]]; then
                SSH_KEYS_ALL+=$'\n'
            fi
            SSH_KEYS_ALL+="$key_line"
            ;;
        --ssh-port)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --ssh-port"
            is_port_valid "$1" || error "Invalid --ssh-port: $1"
            SSH_PORT="$1"
            ;;
        --web-port)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --web-port"
            is_port_valid "$1" || error "Invalid --web-port: $1"
            WEB_PORT="$1"
            ;;
        --frpc-toml)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --frpc-toml"
            FRPC_TOML="$1"
            ;;
        --post-install-hook)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --post-install-hook"
            POST_INSTALL_HOOK="$1"
            ;;
        --hold)
            shift
            [[ -n "${1:-}" ]] || error "Need value for --hold"
            [[ "$1" == "1" || "$1" == "2" ]] || error "Invalid --hold: $1 (must be 1 or 2)"
            HOLD="$1"
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
    shift || true
done

if [[ "$TARGET_OS" == "redhat" && -z "$IMG_URL" ]]; then
    error "redhat requires --img URL. Use: $SCRIPT_NAME redhat --img URL [options...]"
fi

detect_os_arch
if [[ "$HOLD" != "1" ]]; then
    ensure_dependencies
fi

if [[ -n "$DISK" ]]; then
    if [[ "$DISK" != /dev/* ]]; then
        DISK="/dev/$DISK"
    fi
else
    auto_detect_disk
    confirm_auto_detected_disk_host
fi

validate_target_disk "$DISK"
capture_target_disk_identity "$DISK"

if [[ -z "$PASSWORD" ]] && [[ -z "$SSH_KEYS_ALL" ]]; then
    echo "No --password or --ssh-key specified."
    echo "You can set a root password now, or leave empty to auto-generate a random 20-character password."

    while :; do
        read -r -s -p "Enter root password (leave empty to auto-generate): " pw1
        echo

        if [[ -z "$pw1" ]]; then
            if command -v tr >/dev/null 2>&1; then
                PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
            fi
            if [[ -z "$PASSWORD" ]]; then
                error "Failed to generate random password."
            fi
            PASSWORD_TO_DISPLAY="$PASSWORD"
            AUTO_PASSWORD=1
            info "A random root password will be generated and shown before reboot."
            break
        fi

        read -r -s -p "Confirm root password: " pw2
        echo

        if [[ "$pw1" == "$pw2" ]]; then
            PASSWORD="$pw1"
            break
        else
            echo "Passwords do not match, please try again."
            echo
        fi
    done
fi

if [[ -n "$PASSWORD" ]]; then
    PASSWORD_HASH=$(hash_password "$PASSWORD")
    if [[ "$AUTO_PASSWORD" -ne 1 ]]; then
        unset PASSWORD
        PASSWORD=""
    fi
fi

if [[ -z "$IMG_URL" ]] && [[ "$TARGET_OS" != "redhat" ]]; then
    IMG_URL=$(get_default_image_url "$TARGET_OS" "$TARGET_VER")
fi

info "Host: OS=$OS ARCH=$ARCH ($MACHINE_ARCH)"
info "Target: $TARGET_OS ${TARGET_VER:-"(no version)"}"
info "Disk: $DISK"
info "Image URL: $IMG_URL"

if [[ "$HOLD" == "1" ]]; then
    info "--hold 1 is set: only parameter check and summary, no download or disk write."
    exit 0
fi

save_plan_to_efi

echo
echo "==================== Host stage summary ====================="
echo "Disk device:  $DISK"
if [[ "$DISK_AUTO_SELECTED" -eq 1 ]]; then
    echo "Disk reason:  $AUTO_DETECT_REASON"
fi
echo "Target OS:    $TARGET_OS ${TARGET_VER:-"(no version)"}"
echo "Username:     root"
echo "SSH port:     ${SSH_PORT:-22}"
if [[ -n "$PASSWORD_HASH" ]]; then
    if [[ "$AUTO_PASSWORD" -eq 1 ]]; then
        echo "Generated root password:"
        echo "  $PASSWORD_TO_DISPLAY"
    else
        echo "Root password: provided by user (plain text will NOT be saved to EFI)"
    fi
else
    echo "Root password: (not set; SSH key login only)"
fi
if [[ -n "$POST_INSTALL_HOOK" ]]; then
    echo "Post-install hook: $POST_INSTALL_HOOK"
fi
echo "============================================================"
echo

if [[ "$AUTO_PASSWORD" -eq 1 ]]; then
    unset PASSWORD
    PASSWORD=""
fi
unset PASSWORD_TO_DISPLAY
PASSWORD_TO_DISPLAY=""

if [[ "$OS" == "Linux" ]]; then
    prepare_and_boot_alpine_ram
    exit 0
fi

if [[ "$OS" == "FreeBSD" ]]; then
    prepare_and_boot_alpine_ram_freebsd
    exit 0
fi

echo
echo "Reinstall plan has been saved to EFI."
echo "Automatic installer bootstrap is not implemented on this host."
echo "Now configure your system to boot into the installer environment (mfsBSD or initramfs)"
echo "and reboot manually. When the installer environment starts, this script will"
echo "automatically load the saved plan and perform the DD + cloud-init NoCloud installation."
exit 0
