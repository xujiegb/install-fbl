#!/usr/bin/env bash
# Destructive unattended reinstall for Linux/FreeBSD hosts.

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

ensure_dependencies() {
    local missing=()

    if [[ "$OS" == "Linux" ]]; then
        [[ -f /etc/alpine-release ]] && return 0
        detect_linux_family
        mapfile -t missing < <(missing_deps_linux_common)
        ((${#missing[@]})) || return 0
        [[ "$LINUX_FAMILY" == "redhat" ]] || \
            error "Unsupported Linux family for dependency auto-install. Missing: ${missing[*]}"
        install_deps_redhat "${missing[@]}"
        mapfile -t missing < <(missing_deps_linux_common)
        ((${#missing[@]} == 0)) || error "Failed to install Linux dependencies: ${missing[*]}"
        return 0
    fi

    mapfile -t missing < <(missing_deps_freebsd_host)
    ((${#missing[@]})) && install_deps_freebsd_host "${missing[@]}"
    mapfile -t missing < <(missing_deps_freebsd_host)
    ((${#missing[@]} == 0)) || error "Failed to install FreeBSD dependencies: ${missing[*]}"
}

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

is_mountpoint() {
    local path="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path" 2>/dev/null
        return $?
    fi

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

    for d in $disks; do
        case "$provider" in
            "$d"|"$d"p[0-9]*|"$d"s[0-9]*)
                printf '/dev/%s\n' "$d"
                return 0
                ;;
        esac
    done

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

run_post_install_hook() {
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

write_nocloud_seed() {
    local os="$1" meta_path="$2" user_path="$3"
    local frpc_b64=""

    mkdir -p "$(dirname "$meta_path")"

    cat >"$meta_path" <<EOF
instance-id: iid-$(date +%s)
local-hostname: localhost
EOF

    if [[ -n "${FRPC_PRESENT:-}" && -n "${FRPC_TOML:-}" && -f "$FRPC_TOML" ]]; then
        frpc_b64=$(base64 <"$FRPC_TOML" | tr -d '\n')
    fi

    {
        echo "#cloud-config"

        if [[ "$os" == "freebsd" ]]; then
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
            echo "preserve_hostname: false"
            echo "hostname: localhost"
            echo "prefer_fqdn_over_hostname: false"

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

# ----------------- bootstrap state -----------------

EFI_MOUNT_POINT="/boot/efi"
PLAN_DIR_REL="REINSTALL"
PLAN_EFI_PART=""
PLAN_EFI_UUID=""
PLAN_STORAGE_MODE="efi"

ALPINE_ENTRY_TITLE="Reinstall Alpine RAM"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.22"
ALPINE_NETBOOT_SUBDIR="netboot-3.22.6"
ALPINE_BOOT_SUBDIR="alpine"
ALPINE_BOOT_DIR_REL=""
ALPINE_BOOT_DIR_ABS=""
ALPINE_VMLINUZ_REL=""
ALPINE_INITRAMFS_REL=""
ALPINE_MODLOOP_URL=""
ALPINE_APKOVL_REL="/reinstall.apkovl.tar.gz"
ALPINE_VMLINUZ_ABS=""
ALPINE_INITRAMFS_ABS=""
ALPINE_APKOVL_ABS=""
ALPINE_FREEBSD_GRUB_EFI_REL=""
ALPINE_FREEBSD_GRUB_EFI_ABS=""
ALPINE_FREEBSD_GRUB_CFG_REL=""
ALPINE_FREEBSD_GRUB_CFG_ABS=""
ALPINE_NETBOOT_ARCH=""
ALPINE_KERNEL_FLAVOR="virt"

GRUB_SCRIPT_PATH=""
GRUB_CFG_PATH=""
GRUB_MKCONFIG_CMD=""
GRUB_REBOOT_CMD=""
CURRENT_CONSOLE_ARGS=""
AUTO_YES=0
PASSWORD_TO_DISPLAY=""

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

            if [[ -n "${DISK:-}" ]]; then
                preferred="${DISK#/dev/}"
                p=$(gpart show -p "$preferred" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [[ -n "$p" ]]; then
                    echo "/dev/$p"
                    return 0
                fi
            fi

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

get_fs_uuid_freebsd() {
    local dev="$1"
    local desc="" serial=""

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

mount_efi_for_plan() {
    if [[ "$OS" == "Linux" ]]; then
        if [[ -d /boot/efi ]] && is_mountpoint /boot/efi; then
            EFI_MOUNT_POINT="/boot/efi"
            PLAN_STORAGE_MODE="efi"
            PLAN_EFI_PART=$(findmnt -n -o SOURCE --target /boot/efi 2>/dev/null | head -n1 || true)
        else
            local efi_part
            efi_part=$(find_efi_for_plan 2>/dev/null || true)
            if [[ -n "$efi_part" ]]; then
                EFI_MOUNT_POINT="/boot/efi"
                mkdir -p "$EFI_MOUNT_POINT"
                mount "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    mount -t vfat "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    error "Failed to mount EFI partition $efi_part"
                PLAN_STORAGE_MODE="efi"
                PLAN_EFI_PART="$efi_part"
            else
                [[ -d /boot ]] || error "No EFI partition and no /boot fallback"
                EFI_MOUNT_POINT="/boot"
                PLAN_STORAGE_MODE="boot"
                if is_mountpoint /boot; then
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --target /boot 2>/dev/null | head -n1 || true)
                else
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --target / 2>/dev/null | head -n1 || true)
                fi
            fi
        fi
        [[ -n "$PLAN_EFI_PART" ]] && PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
        return 0
    fi

    local mounted_src="" efi_part=""
    if [[ -d "$EFI_MOUNT_POINT" ]] && is_mountpoint "$EFI_MOUNT_POINT"; then
        mounted_src=$(freebsd_mount_source_for "$EFI_MOUNT_POINT" || true)
        efi_part=$(find_efi_for_plan 2>/dev/null || true)
        PLAN_EFI_PART="${efi_part:-$mounted_src}"
        [[ "$PLAN_EFI_PART" == /dev/*p[0-9]* ]] || error "Could not resolve the physical FreeBSD EFI partition"
        PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
        PLAN_STORAGE_MODE="efi"
        info "Using FreeBSD EFI: ${mounted_src:-$PLAN_EFI_PART} -> $PLAN_EFI_PART"
        return 0
    fi

    efi_part=$(find_efi_for_plan 2>/dev/null || true)
    [[ -n "$efi_part" ]] || error "Could not find FreeBSD EFI partition"
    mkdir -p "$EFI_MOUNT_POINT"
    if command -v mount_msdosfs >/dev/null 2>&1; then
        mount_msdosfs "$efi_part" "$EFI_MOUNT_POINT" || error "Failed to mount $efi_part"
    else
        mount -t msdosfs "$efi_part" "$EFI_MOUNT_POINT" || error "Failed to mount $efi_part"
    fi
    PLAN_STORAGE_MODE="efi"
    PLAN_EFI_PART="$efi_part"
    PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
}

write_install_plan() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
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
        printf 'AUTO_PASSWORD=%q\n' "$AUTO_PASSWORD"
        printf 'HOLD=%q\n' "$HOLD"
        printf 'PLAN_EFI_UUID=%q\n' "$PLAN_EFI_UUID"
    } >"$path"
    chmod 0600 "$path" 2>/dev/null || true
}

load_install_plan() {
    local plan="/etc/reinstall/plan.env"
    [[ -f "$plan" ]] || error "Embedded install plan not found: $plan"
    # shellcheck disable=SC1090
    . "$plan"
    PASSWORD=""
    PASSWORD_HASH="${PASSWORD_HASH:-}"
    [[ ! -f /etc/reinstall/frpc.toml ]] || FRPC_TOML="/etc/reinstall/frpc.toml"
    [[ ! -f /etc/reinstall/post-install-hook.sh ]] || POST_INSTALL_HOOK="/etc/reinstall/post-install-hook.sh"
    info "Loaded embedded install plan"
}

# ----------------- Alpine RAM / boot bootstrap -----------------

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
    [[ "$OS" == "Linux" ]] || error "GRUB bootstrap requires Linux host"

    if command -v grub2-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub2-mkconfig"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub-mkconfig"
    else
        error "grub-mkconfig not found"
    fi

    if command -v grub2-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub2-reboot"
    elif command -v grub-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub-reboot"
    else
        error "grub-reboot not found"
    fi

    [[ -d /etc/grub.d ]] || error "/etc/grub.d not found"
    GRUB_SCRIPT_PATH="/etc/grub.d/09_reinstall_alpine"

    if [[ -f /boot/grub2/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub2/grub.cfg"
    elif [[ -f /boot/grub/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub/grub.cfg"
    else
        error "GRUB config not found"
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
            ALPINE_NETBOOT_ARCH="x86_64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubx64.efi"
            ;;
        aarch64)
            ALPINE_NETBOOT_ARCH="aarch64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubaa64.efi"
            ;;
        *)
            error "Alpine RAM bootstrap supports only x86_64 and aarch64"
            ;;
    esac

    [[ "$PLAN_STORAGE_MODE" != "efi" || -n "$PLAN_EFI_UUID" ]] || error "Bootstrap filesystem UUID unavailable"

    ALPINE_BOOT_DIR_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR"
    ALPINE_BOOT_DIR_ABS="$EFI_MOUNT_POINT$ALPINE_BOOT_DIR_REL"
    ALPINE_FREEBSD_GRUB_CFG_REL="$ALPINE_BOOT_DIR_REL/grub/grub.cfg"
    ALPINE_FREEBSD_GRUB_CFG_ABS="$EFI_MOUNT_POINT$ALPINE_FREEBSD_GRUB_CFG_REL"
    ALPINE_VMLINUZ_REL="$ALPINE_BOOT_DIR_REL/vmlinuz"
    ALPINE_INITRAMFS_REL="$ALPINE_BOOT_DIR_REL/initramfs"
    ALPINE_MODLOOP_URL="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}/modloop-${ALPINE_KERNEL_FLAVOR}"
    ALPINE_VMLINUZ_ABS="$EFI_MOUNT_POINT$ALPINE_VMLINUZ_REL"
    ALPINE_INITRAMFS_ABS="$EFI_MOUNT_POINT$ALPINE_INITRAMFS_REL"
    ALPINE_APKOVL_ABS="$EFI_MOUNT_POINT$ALPINE_APKOVL_REL"
    ALPINE_FREEBSD_GRUB_EFI_ABS="$EFI_MOUNT_POINT$ALPINE_FREEBSD_GRUB_EFI_REL"
}

download_alpine_ram_files() {
    mkdir -p "$ALPINE_BOOT_DIR_ABS"

    local base tmpdir
    tmpdir=$(mktemp -d /tmp/reinstall-alpine-netboot.XXXXXX)

    base="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}"

    rm -f "$ALPINE_BOOT_DIR_ABS/modloop"
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

build_alpine_apkovl() {
    local tmp ovl_dir startfile initfile self
    tmp=$(mktemp -d /tmp/reinstall-alpine-apkovl.XXXXXX)
    ovl_dir="$tmp/ovl"

    mkdir -p "$ovl_dir/etc/apk" "$ovl_dir/etc/reinstall" "$ovl_dir/usr/local/sbin"
    : >"$ovl_dir/etc/.default_boot_services"

    cat >"$ovl_dir/etc/apk/repositories" <<EOF
${ALPINE_REPO_BASE}/main/${ALPINE_NETBOOT_ARCH}
${ALPINE_REPO_BASE}/community/${ALPINE_NETBOOT_ARCH}
EOF

    write_install_plan "$ovl_dir/etc/reinstall/plan.env"

    self="$0"
    if command -v readlink >/dev/null 2>&1; then
        self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")
    elif command -v realpath >/dev/null 2>&1; then
        self=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
    fi
    [[ -f "$self" ]] || error "Cannot locate current script: $self"
    cp "$self" "$ovl_dir/usr/local/sbin/reinstall-installer.sh"
    chmod 0755 "$ovl_dir/usr/local/sbin/reinstall-installer.sh"

    if [[ -n "${FRPC_TOML:-}" && ! "$FRPC_TOML" =~ ^https?:// && -f "$FRPC_TOML" ]]; then
        cp "$FRPC_TOML" "$ovl_dir/etc/reinstall/frpc.toml"
        chmod 0600 "$ovl_dir/etc/reinstall/frpc.toml"
    fi
    if [[ -n "${POST_INSTALL_HOOK:-}" ]]; then
        [[ -f "$POST_INSTALL_HOOK" ]] || error "Post-install hook not found: $POST_INSTALL_HOOK"
        cp "$POST_INSTALL_HOOK" "$ovl_dir/etc/reinstall/post-install-hook.sh"
        chmod 0700 "$ovl_dir/etc/reinstall/post-install-hook.sh"
    fi

    startfile="$ovl_dir/usr/local/sbin/reinstall-auto.sh"
    cat >"$startfile" <<'EOF'
#!/bin/sh
set -eu

LOG="/var/log/reinstall-auto.log"
mkdir -p /var/log
touch "$LOG"
# look idle at a login prompt while destructive work is running.
if [ -w /dev/console ]; then
    exec >/dev/console 2>&1
else
    exec >>"$LOG" 2>&1
fi

echo "===== reinstall-auto start $(date) ====="

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

is_mountpoint() {
    local p="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$p" 2>/dev/null
        return $?
    fi

    awk -v p="$p" '$2 == p { found=1; exit } END { exit(found ? 0 : 1) }' /proc/mounts 2>/dev/null
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
        e2fsprogs e2fsprogs-extra dosfstools sgdisk kmod lvm2 xfsprogs xfsprogs-extra
    update-ca-certificates 2>/dev/null || true

    # Fail here with a precise message instead of reaching the destructive stage
    for cmd in sgdisk mkfs.ext4 qemu-img qemu-nbd xz curl lsblk blkid mount umount blockdev mknod pvresize xfs_db dumpe2fs resize2fs e2fsck; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Required Alpine runtime command is missing after apk add: $cmd"
            echo "Installed matching packages:"
            apk info 2>/dev/null | grep -E '^(xfsprogs|e2fsprogs|lvm2)' || true
            exit 1
        }
    done
}

ensure_modloop_ready() {
    local kver attempt modloop_file

    kver="$(uname -r)"
    modloop_file="/lib/modloop-${ALPINE_KERNEL_FLAVOR:-virt}"

    if is_mountpoint /.modloop && [ -d "/.modloop/modules/$kver" ] && [ -e "/lib/modules/$kver" ]; then
        echo "Alpine modloop is already mounted and matches kernel $kver."
        return 0
    fi

    echo "[stage] ensuring Alpine modloop for kernel $kver"
    echo "Remote modloop: ${ALPINE_MODLOOP_URL:-from-kernel-cmdline}"

    for attempt in 1 2 3 4 5; do
        echo "Starting Alpine modloop service (attempt $attempt/5)..."

        rc-service modloop stop >/dev/null 2>&1 || true
        if is_mountpoint /.modloop; then
            umount /.modloop >/dev/null 2>&1 || true
        fi

        rm -f "$modloop_file"
        rm -f /lib/modloop-virt /lib/modloop-lts 2>/dev/null || true

        if rc-service modloop start; then
            if is_mountpoint /.modloop && \
               [ -d "/.modloop/modules/$kver" ] && \
               [ -e "/lib/modules/$kver" ]; then
                echo "Alpine modloop mounted successfully for kernel $kver."
                findmnt /.modloop 2>/dev/null || true
                return 0
            fi
        fi

        echo "Modloop attempt $attempt failed; removing any partial download before retry."
        rc-service modloop stop >/dev/null 2>&1 || true
        rm -f "$modloop_file" /lib/modloop-virt /lib/modloop-lts 2>/dev/null || true
        sleep 3
    done

    echo "Failed to obtain a valid Alpine modloop after 5 attempts."
    echo "Expected URL: ${ALPINE_MODLOOP_URL:-see /proc/cmdline}"
    echo "Kernel cmdline:"
    cat /proc/cmdline 2>/dev/null || true
    ls -lh /lib/modloop-* 2>/dev/null || true
    exit 1
}

setup_zram_swap() {
    local mem_kb zram_bytes min_bytes max_bytes

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [ -n "$mem_kb" ] || {
        echo "Could not determine MemTotal; refusing to continue without zram swap."
        exit 1
    }

    zram_bytes=$((mem_kb * 1024 * 2))
    min_bytes=1073741824
    max_bytes=8589934592
    [ "$zram_bytes" -lt "$min_bytes" ] && zram_bytes="$min_bytes"
    [ "$zram_bytes" -gt "$max_bytes" ] && zram_bytes="$max_bytes"

    modprobe zram || {
        echo "zram kernel module is unavailable even after modloop setup."
        echo "Kernel: $(uname -r)"
        echo "/lib/modules:"
        ls -la /lib/modules 2>/dev/null || true
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

    echo "Modloop relocation complete."
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

    echo "[stage] ensure_modloop_ready"
    ensure_modloop_ready

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

    initfile="$ovl_dir/usr/local/sbin/reinstall-init.sh"
    cat >"$initfile" <<'EOF'
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

echo "===== reinstall-init start $(date) ====="
echo "[init] deferring Alpine modloop until full network download tools are installed"
rm -f /etc/runlevels/sysinit/modloop 2>/dev/null || true

echo "[init] bringing up Alpine sysinit services"

if ! /sbin/openrc sysinit; then
    echo "[init] openrc sysinit failed; falling back to normal Alpine init."
    exec /sbin/init
fi

echo "[init] bringing up Alpine boot services"
if ! /sbin/openrc boot; then
    echo "[init] openrc boot failed; falling back to normal Alpine init."
    exec /sbin/init
fi

echo "[init] launching reinstall runner directly"
if /usr/local/sbin/reinstall-auto.sh; then
    rc=0
else
    rc=$?
fi

echo "[init] reinstall runner returned rc=$rc"
echo "[init] entering normal Alpine init for troubleshooting/HOLD mode."
exec /sbin/init
EOF
    chmod 0755 "$initfile"

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
    linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
    initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
}
EOF
    else
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    linux /boot${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
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
    local FREEBSD_ALPINE_CONSOLE_ARGS
    local tmp iso member volid marker offset
    local old_cfg new_cfg old_len new_len pad
    local expected_file before_file patch_file

    alpine_release="${ALPINE_NETBOOT_SUBDIR#netboot-}"

    case "$ALPINE_NETBOOT_ARCH" in
        x86_64)
            efi_name="bootx64.efi"
            FREEBSD_ALPINE_CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8"
            ;;
        aarch64)
            efi_name="bootaa64.efi"
            FREEBSD_ALPINE_CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8 console=ttyAMA0,115200n8"
            ;;
        *)
            error "Unsupported FreeBSD UEFI bootstrap arch: $ALPINE_NETBOOT_ARCH"
            ;;
    esac

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
        while IFS= read -r p; do
            local normalized
            normalized="${p#./}"
            if [[ "${normalized,,}" == "efi/boot/${efi_name,,}" ]]; then
                printf '%s\n' "$p"
                break
            fi
        done < <(tar -tf "$iso" 2>/dev/null)
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
        LC_ALL=C grep -a -b -o -F "$marker" "$ALPINE_FREEBSD_GRUB_EFI_ABS" 2>/dev/null |
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

    if ! cmp -s "$expected_file" "$before_file"; then
        warn "Alpine GRUB embedded config verification failed at byte offset $offset."
        warn "Expected the official Alpine early config beginning with: $marker"
        rm -rf "$tmp"
        error "Alpine GRUB embedded config did not exactly match the expected ${alpine_release} virt image; refusing binary patch"
    fi

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
linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh ${FREEBSD_ALPINE_CONSOLE_ARGS}
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

    local before after newnum old bootnext

    while read -r old; do
        [[ -n "$old" ]] || continue
        info "Deleting old EFI boot entry $old (${ALPINE_ENTRY_TITLE})"
        efibootmgr -B -b "$old" >/dev/null 2>&1 || \
            warn "Failed to delete old EFI boot entry: $old"
    done < <(
        efibootmgr 2>/dev/null | awk -v title="$ALPINE_ENTRY_TITLE" '
            index($0, title) {
                if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
                    n = substr($0, RSTART + 4, 4)
                    print toupper(n)
                }
            }
        ' | sort -u
    )

    before=$(
        efibootmgr 2>/dev/null |
        awk '{
            if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
                n = substr($0, RSTART + 4, 4)
                print toupper(n)
            }
        }' | sort -u
    )

    info "Creating FreeBSD UEFI boot entry: ${ALPINE_ENTRY_TITLE}"
    efibootmgr -a -c \
        -l "$ALPINE_FREEBSD_GRUB_EFI_ABS" \
        -L "$ALPINE_ENTRY_TITLE" >/dev/null || \
        error "efibootmgr failed to create EFI boot entry: ${ALPINE_ENTRY_TITLE}"

    newnum=$(
        efibootmgr 2>/dev/null | awk -v title="$ALPINE_ENTRY_TITLE" '
            index($0, title) {
                if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
                    n = substr($0, RSTART + 4, 4)
                    print toupper(n)
                    exit
                }
            }
        '
    )

    if [[ -z "$newnum" ]]; then
        after=$(
            efibootmgr 2>/dev/null |
            awk '{
                if (match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
                    n = substr($0, RSTART + 4, 4)
                    print toupper(n)
                }
            }' | sort -u
        )
        newnum=$(comm -13 \
            <(printf '%s\n' "$before") \
            <(printf '%s\n' "$after") |
            head -n1)
    fi

    [[ "$newnum" =~ ^[0-9A-Fa-f]{4}$ ]] || {
        efibootmgr -v >&2 2>/dev/null || true
        error "Failed to determine new EFI boot entry after creating ${ALPINE_ENTRY_TITLE}"
    }

    info "Setting BootNext to EFI entry $newnum (${ALPINE_ENTRY_TITLE})"
    efibootmgr -n -b "$newnum" >/dev/null || \
        error "Failed to set BootNext to EFI entry $newnum"

    bootnext=$(
        efibootmgr 2>/dev/null |
        awk '
            /^BootNext[[:space:]]*:/ {
                v=$0
                sub(/^[^:]*:[[:space:]]*/, "", v)
                gsub(/[[:space:]]/, "", v)
                print toupper(v)
                exit
            }
        '
    )

    if [[ -n "$bootnext" && "$bootnext" != "${newnum^^}" ]]; then
        efibootmgr -v >&2 2>/dev/null || true
        error "BootNext verification failed: expected ${newnum^^}, got $bootnext"
    fi

    info "BootNext verified: ${newnum^^} (${ALPINE_ENTRY_TITLE})"
}

prepare_and_boot_alpine_ram() {
    prepare_alpine_paths
    download_alpine_ram_files
    build_alpine_apkovl

    case "$OS" in
        Linux)
            install_grub_entry_for_alpine
            info "Rebooting into one-time GRUB entry: $ALPINE_ENTRY_TITLE"
            sync
            sleep 2
            reboot
            ;;
        FreeBSD)
            build_freebsd_grub_efi
            install_freebsd_bootnext_entry
            info "Rebooting into one-time UEFI entry: $ALPINE_ENTRY_TITLE"
            sync
            sleep 2
            shutdown -r now
            ;;
        *)
            error "Unsupported bootstrap host: $OS"
            ;;
    esac
}

# ----------------- installer execution -----------------

reread_partition_table_strict() {
    sync

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
QCOW_PARTITION_CROSSES_STAGE=0
QCOW_NBD_DEV=""
TEMP_STAGE_RELEASED=0

partition_device_for_number() {
    local disk="$1" num="$2"
    case "$disk" in
        /dev/nvme*|/dev/mmcblk*|/dev/loop*|/dev/nbd*)
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

    min_remaining=$((2 * 1024 * 1024 * 1024))
    if [[ "$disk_size" -le $((TEMP_STAGE_SIZE_BYTES + min_remaining)) ]]; then
        error "Target disk is too small for the mandatory 3 GiB staging partition. Disk=${disk_size} bytes"
    fi

    info "Preparing mandatory 3 GiB staging partition at the end of $DISK ..."
    info "This step destroys the old partition table; Alpine is already running from RAM."

    wipefs -a "$DISK" >/dev/null 2>&1 || true
    sgdisk -Z "$DISK" >/dev/null 2>&1 || true

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

    # already valid. The partition number is known because the temporary GPT
    TEMP_STAGE_PART=$(partition_device_for_number "$DISK" "$TEMP_STAGE_PART_NUM")
    local wait_i
    for wait_i in 1 2 3 4 5 6 7 8; do
        [[ -b "$TEMP_STAGE_PART" ]] && break

        command -v partx >/dev/null 2>&1 && {
            partx -u "$DISK" >/dev/null 2>&1 || partx -a "$DISK" >/dev/null 2>&1 || true
        }
        command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
        command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

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

    local nbd_virtual_size
    nbd_virtual_size=$(blockdev --getsize64 "$nbd" 2>/dev/null || true)
    [[ "$nbd_virtual_size" =~ ^[0-9]+$ && "$nbd_virtual_size" -gt 0 ]] ||         error "Could not determine qcow2 guest-visible size through qemu-nbd"
    if [[ "$QCOW_VIRTUAL_SIZE" != "$nbd_virtual_size" ]]; then
        warn "qemu-img reported ${QCOW_VIRTUAL_SIZE} bytes, but qemu-nbd exposes ${nbd_virtual_size} bytes; using qemu-nbd size."
    fi
    QCOW_VIRTUAL_SIZE="$nbd_virtual_size"

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

    QCOW_PARTITION_CROSSES_STAGE=0

    # A cloud image may deliberately describe a GPT/LVM layout much larger than
    # the qcow2 payload stored on disk. Do not reject it merely because the GPT
    # sparse-shadow path so the source is first copied into RAM/zram, resized
    if [[ "$QCOW_MAX_PART_END_BYTES" -gt $((TEMP_STAGE_START_BYTES - 8 * 1024 * 1024)) ]]; then
        QCOW_PARTITION_CROSSES_STAGE=1
        warn "qcow2 GPT layout reaches the mandatory 3 GiB staging area."
        warn "Using sparse RAM/zram shadow mode to avoid self-overwriting the live staging source."
    fi

    # device. If qemu-img reported otherwise, treat the GPT extent as the minimum
    if [[ "$QCOW_VIRTUAL_SIZE" -lt "$QCOW_MAX_PART_END_BYTES" ]]; then
        warn "qemu-img virtual-size (${QCOW_VIRTUAL_SIZE}) is smaller than GPT partition end (${QCOW_MAX_PART_END_BYTES}); refusing to trust the smaller value for write-safety decisions."
        QCOW_VIRTUAL_SIZE="$QCOW_MAX_PART_END_BYTES"
        QCOW_PARTITION_CROSSES_STAGE=1
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
        # into a regular qcow2 file on the staging filesystem. xz recreates sparse
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
        sed -n 's/^[[:space:]]*"virtual-size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | \
        head -n1
}

connect_raw_rw_nbd() {
    local img="$1" n dev size

    command -v qemu-nbd >/dev/null 2>&1 || error "qemu-nbd is required for sparse-shadow preparation"
    modprobe nbd max_part=64 >/dev/null 2>&1 || error "Could not load nbd kernel module"
    mdev -s 2>/dev/null || true

    for n in $(seq 0 15); do
        dev="/dev/nbd$n"
        [[ -b "$dev" ]] || continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [[ "$size" == "0" ]] || continue

        if qemu-nbd --connect="$dev" --format=raw "$img" >/dev/null 2>&1; then
            QCOW_NBD_DEV="$dev"
            sleep 1
            command -v partx >/dev/null 2>&1 && {
                partx -u "$dev" >/dev/null 2>&1 || partx -a "$dev" >/dev/null 2>&1 || true
            }
            mdev -s 2>/dev/null || true
            return 0
        fi
    done

    error "Could not allocate a free NBD device for sparse-shadow preparation"
}

prepare_sparse_shadow_for_target() {
    local img="$1" shadow="$2"
    local allocated logical_size
    local nbd table sector_size target_sector_size target_disk_bytes target_total_sectors
    local reserve_bytes reserve_sectors target_end
    local line partnum="" part_start="" part_end=0 part_code=""
    local info_text type_guid unique_guid attrs name new_part_bytes partdev wait_i

    rm -f "$shadow"

    info "Creating sparse raw shadow in RAM/zram because the image GPT overlaps the live 3 GiB staging partition..."
    info "This file is logically as large as the cloud disk, but sparse holes do not consume tmpfs/zram pages."

    qemu-img convert -p -S 4k -f qcow2 -O raw "$img" "$shadow" || {
        rm -f "$shadow"
        error "Failed to create sparse raw shadow from qcow2"
    }

    logical_size=$(stat -c %s "$shadow" 2>/dev/null || true)
    allocated=$(du -B1 "$shadow" 2>/dev/null | awk '{print $1; exit}' || true)
    [[ "$logical_size" =~ ^[0-9]+$ && "$logical_size" -gt 0 ]] || \
        error "Could not determine sparse-shadow logical size"

    info "Sparse shadow logical size:   ${logical_size} bytes"
    [[ "$allocated" =~ ^[0-9]+$ ]] && info "Sparse shadow allocated RAM/zram: ${allocated} bytes"
    df -h /run/reinstall-work || true

    connect_raw_rw_nbd "$shadow"
    nbd="$QCOW_NBD_DEV"

    table=$(sgdisk -p "$nbd" 2>&1) || {
        echo "$table" >&2
        cleanup_qcow_nbd
        error "Sparse shadow does not expose a usable GPT"
    }

    sector_size=$(blockdev --getss "$nbd" 2>/dev/null || true)
    target_sector_size=$(blockdev --getss "$DISK" 2>/dev/null || true)
    [[ "$sector_size" =~ ^[0-9]+$ && "$sector_size" -gt 0 ]] || {
        cleanup_qcow_nbd
        error "Could not determine sparse-shadow sector size"
    }
    [[ "$target_sector_size" == "$sector_size" ]] || {
        cleanup_qcow_nbd
        error "Sparse-shadow sector size ($sector_size) differs from target disk sector size ($target_sector_size)"
    }

    target_disk_bytes=$(get_disk_size_bytes "$DISK" || true)
    [[ "$target_disk_bytes" =~ ^[0-9]+$ && "$target_disk_bytes" -gt 0 ]] || {
        cleanup_qcow_nbd
        error "Could not determine target disk size while preparing sparse shadow"
    }

    target_total_sectors=$((target_disk_bytes / sector_size))
    reserve_bytes=$((32 * 1024 * 1024))
    reserve_sectors=$(((reserve_bytes + sector_size - 1) / sector_size))
    target_end=$((target_total_sectors - 34 - reserve_sectors))

    if (( target_end <= 2048 )); then
        cleanup_qcow_nbd
        error "Target disk is too small to reserve GPT metadata and CIDATA"
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+.*[[:space:]]+([0-9A-Fa-f]{4})[[:space:]] ]] || continue
        if (( BASH_REMATCH[3] > part_end )); then
            partnum="${BASH_REMATCH[1]}"
            part_start="${BASH_REMATCH[2]}"
            part_end="${BASH_REMATCH[3]}"
            part_code="${BASH_REMATCH[4]^^}"
        fi
    done <<<"$table"

    [[ -n "$partnum" && "$part_start" =~ ^[0-9]+$ && "$part_end" =~ ^[0-9]+$ ]] || {
        cleanup_qcow_nbd
        error "Could not identify the final GPT partition inside sparse shadow"
    }

    if (( part_end <= target_end )); then
        info "Sparse-shadow GPT already fits the target disk with 32 MiB reserved for CIDATA."
        cleanup_qcow_nbd
        return 0
    fi

    info "Sparse-shadow final partition $partnum extends to sector $part_end; target-safe end is $target_end."

    # GPT type codes describe intended use, not necessarily the on-disk content.
    # even when the payload is an LVM PV or a directly formatted root filesystem.
    partdev=$(partition_device_for_number "$nbd" "$partnum")
    for wait_i in 1 2 3 4 5; do
        [[ -b "$partdev" ]] && break
        command -v partx >/dev/null 2>&1 && partx -u "$nbd" >/dev/null 2>&1 || true
        mdev -s 2>/dev/null || true
        ensure_linux_block_node_from_sysfs "$partdev" && break
        sleep 1
    done
    [[ -b "$partdev" ]] || {
        cleanup_qcow_nbd
        error "Could not create sparse-shadow partition node: $partdev"
    }

    new_part_bytes=$(((target_end - part_start + 1) * sector_size))
    (( new_part_bytes > 0 )) || {
        cleanup_qcow_nbd
        error "Target disk is smaller than the start of the Rocky LVM partition"
    }

    local content_type="" pv_detected=0 fs_block_size="" fs_blocks="" fs_bytes=""
    local target_fs_blocks="" e2fsck_rc=0

    # Prefer explicit LVM probing. Do not infer LVM from the GPT type code.
    if pvs --noheadings -o pv_name "$partdev" 2>/dev/null | grep -Fq "$partdev"; then
        pv_detected=1
    fi

    if [[ "$pv_detected" -eq 1 ]]; then
        info "Detected LVM PV inside GPT type $part_code on $partdev."
        info "Shrinking LVM PV to fit ${new_part_bytes} bytes before changing the GPT boundary..."
        if ! pvresize --yes --setphysicalvolumesize "${new_part_bytes}B" "$partdev"; then
            cleanup_qcow_nbd
            error "LVM allocated extents cannot fit inside ${new_part_bytes} bytes. The target disk is genuinely too small."
        fi
    else
        content_type=$(blkid -p -o value -s TYPE "$partdev" 2>/dev/null || true)
        info "Final partition GPT type=$part_code; detected content=${content_type:-unknown}"

        case "$content_type" in
            xfs)
                fs_block_size=$(xfs_db -r -c 'sb 0' -c 'p blocksize' "$partdev" 2>/dev/null |                     awk -F'= *' '/blocksize =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
                fs_blocks=$(xfs_db -r -c 'sb 0' -c 'p dblocks' "$partdev" 2>/dev/null |                     awk -F'= *' '/dblocks =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
                [[ "$fs_block_size" =~ ^[0-9]+$ && "$fs_blocks" =~ ^[0-9]+$ ]] || {
                    cleanup_qcow_nbd
                    error "Could not determine XFS filesystem size on $partdev"
                }
                fs_bytes=$((fs_block_size * fs_blocks))
                info "XFS filesystem size: ${fs_bytes} bytes; target partition capacity: ${new_part_bytes} bytes"
                if (( fs_bytes > new_part_bytes )); then
                    cleanup_qcow_nbd
                    error "XFS filesystem is larger than the target-safe partition size and XFS cannot be shrunk offline. Target disk is too small for this image."
                fi
                info "XFS filesystem already fits; only the GPT partition boundary needs to be reduced."
                ;;
            ext2|ext3|ext4)
                fs_block_size=$(dumpe2fs -h "$partdev" 2>/dev/null | awk -F': *' '/^Block size:/ {print $2; exit}')
                fs_blocks=$(dumpe2fs -h "$partdev" 2>/dev/null | awk -F': *' '/^Block count:/ {print $2; exit}')
                [[ "$fs_block_size" =~ ^[0-9]+$ && "$fs_blocks" =~ ^[0-9]+$ ]] || {
                    cleanup_qcow_nbd
                    error "Could not determine ext filesystem size on $partdev"
                }
                fs_bytes=$((fs_block_size * fs_blocks))
                info "ext filesystem size: ${fs_bytes} bytes; target partition capacity: ${new_part_bytes} bytes"

                if (( fs_bytes > new_part_bytes )); then
                    target_fs_blocks=$((new_part_bytes / fs_block_size - 256))
                    (( target_fs_blocks > 0 )) || {
                        cleanup_qcow_nbd
                        error "Target partition is too small for a valid ext filesystem"
                    }

                    e2fsck -f -p "$partdev" >/dev/null 2>&1 || e2fsck_rc=$?
                    if (( e2fsck_rc > 1 )); then
                        cleanup_qcow_nbd
                        error "e2fsck failed before ext filesystem shrink (rc=$e2fsck_rc)"
                    fi

                    info "Shrinking ext filesystem to ${target_fs_blocks} filesystem blocks..."
                    resize2fs "$partdev" "$target_fs_blocks" >/dev/null || {
                        cleanup_qcow_nbd
                        error "resize2fs failed while shrinking the root filesystem"
                    }
                else
                    info "ext filesystem already fits; only the GPT partition boundary needs to be reduced."
                fi
                ;;
            *)
                pvs "$partdev" 2>&1 || true
                blkid -p "$partdev" 2>&1 || true
                cleanup_qcow_nbd
                error "Cannot safely shrink final partition content '${content_type:-unknown}' (GPT type $part_code). Refusing to modify its boundary blindly."
                ;;
        esac
    fi

    info_text=$(sgdisk -i "$partnum" "$nbd" 2>/dev/null) || {
        cleanup_qcow_nbd
        error "Failed to inspect sparse-shadow partition metadata"
    }
    type_guid=$(printf '%s\n' "$info_text" | awk '/Partition GUID code:/ {print $4; exit}')
    unique_guid=$(printf '%s\n' "$info_text" | awk '/Partition unique GUID:/ {print $4; exit}')
    attrs=$(printf '%s\n' "$info_text" | awk '/Attribute flags:/ {print $3; exit}')
    name=$(printf '%s\n' "$info_text" | sed -n "s/^Partition name: '\(.*\)'$/\1/p" | head -n1)

    sgdisk -d "$partnum" "$nbd" >/dev/null || {
        cleanup_qcow_nbd
        error "Failed to delete sparse-shadow partition $partnum for resize"
    }
    sgdisk -n "${partnum}:${part_start}:${target_end}" "$nbd" >/dev/null || {
        cleanup_qcow_nbd
        error "Failed to recreate sparse-shadow partition $partnum at target-safe size"
    }
    sgdisk -t "${partnum}:${type_guid}" "$nbd" >/dev/null || {
        cleanup_qcow_nbd
        error "Failed to restore sparse-shadow GPT type"
    }
    [[ -z "$unique_guid" ]] || sgdisk -u "${partnum}:${unique_guid}" "$nbd" >/dev/null || {
        cleanup_qcow_nbd
        error "Failed to restore sparse-shadow PARTUUID"
    }
    [[ -z "$name" ]] || sgdisk -c "${partnum}:${name}" "$nbd" >/dev/null || {
        cleanup_qcow_nbd
        error "Failed to restore sparse-shadow GPT name"
    }
    if [[ -n "$attrs" && "$attrs" != "0000000000000000" ]]; then
        sgdisk -A "${partnum}:=:${attrs}" "$nbd" >/dev/null || {
            cleanup_qcow_nbd
            error "Failed to restore sparse-shadow GPT attributes"
        }
    fi

    sync
    cleanup_qcow_nbd

    info "Sparse-shadow root/GPT boundary adjusted successfully."
}

write_sparse_shadow_to_target_after_releasing_stage() {
    local shadow="$1" disk_bytes

    disk_bytes=$(get_disk_size_bytes "$DISK" || true)
    [[ "$disk_bytes" =~ ^[0-9]+$ && "$disk_bytes" -gt 0 ]] || \
        error "Could not determine target disk size for sparse-shadow write"

    release_temp_staging_partition
    TEMP_STAGE_RELEASED=1
    sync

    info "Writing sparse shadow to the target disk after releasing the 3 GiB staging partition..."
    info "Copy length: ${disk_bytes} bytes"

    # truncated to a smaller VPS disk after pvresize/GPT preparation.
    dd if="$shadow" of="$DISK" bs=16M iflag=count_bytes count="$disk_bytes" \
        status=progress conv=fsync || error "Failed to write sparse shadow to target disk"

    sync
    rm -f "$shadow"
}

write_qcow_without_overwriting_staging() {
    local img="$1" bs_arg count_arg shadow

    [[ -n "$TEMP_STAGE_START_BYTES" ]] || error "Temporary staging boundary is unknown"
    TEMP_STAGE_RELEASED=0

    if [[ "${QCOW_PARTITION_CROSSES_STAGE:-0}" == "1" ]]; then
        shadow="/run/reinstall-work/target-shadow.raw"
        prepare_sparse_shadow_for_target "$img" "$shadow"
        write_sparse_shadow_to_target_after_releasing_stage "$shadow"
        return 0
    fi

    if [[ "$QCOW_VIRTUAL_SIZE" -le "$TEMP_STAGE_START_BYTES" ]]; then
        info "qcow2 virtual disk ends before the staging partition; converting the whole image."
        qemu-img convert -p -n -S 0 -f qcow2 -O raw "$img" "$DISK" || \
            error "qemu-img failed while writing the target disk"
        return 0
    fi

    # The image virtual disk extends beyond the staging boundary, but its GPT
    # prefix; trailing free space and the source backup GPT are intentionally
    # omitted. The backup GPT is rebuilt after staging has been released.
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
    # those stale mappings before manipulating the target GPT. This avoids
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
    if [[ "$new_end" -eq "$end" ]]; then
        info "Target partition $partnum already ends at the CIDATA-safe boundary."
        return 0
    fi
    if [[ "$new_end" -lt "$end" ]]; then
        error "Target partition $partnum still extends beyond the CIDATA-safe boundary after image preparation; refusing an unsafe blind shrink"
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

    local staged_frpc
    local CIDATA_PART MNT_CIDATA
    staged_frpc=""

    cleanup_install_stage() {
        cleanup_qcow_nbd
        if is_mountpoint "$TEMP_STAGE_MNT"; then
            umount "$TEMP_STAGE_MNT" 2>/dev/null || true
        fi
        rm -rf "$INSTALL_TMPDIR" 2>/dev/null || true
    }
    trap cleanup_install_stage EXIT

    if [[ -n "${FRPC_TOML:-}" && "$FRPC_TOML" =~ ^https?:// ]]; then
        staged_frpc="$INSTALL_TMPDIR/frpc.toml"
        info "Downloading FRPC config: $FRPC_TOML"
        http_download "$FRPC_TOML" "$staged_frpc" || error "Failed to download FRPC config"
        FRPC_TOML="$staged_frpc"
    fi

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

    inspect_qcow_partition_layout "$IMG_QCOW"

    info "Writing qcow2 from the 3 GiB tail staging partition without overwriting its live source..."
    write_qcow_without_overwriting_staging "$IMG_QCOW"
    sync
    info "Safe qcow2 prefix write finished."

    # In sparse-shadow mode the staging partition has already been released
    if [[ "${TEMP_STAGE_RELEASED:-0}" != "1" ]]; then
        release_temp_staging_partition
    fi
    sync

    # Work directly on the image GPT while no target partitions are mapped in the
    # kernel. grow_last_partition_reserving_cidata() repairs the backup GPT,
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

    run_post_install_hook
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

PHASE="host"
if [[ "${1:-}" == "--phase" ]]; then
    shift
    [[ -n "${1:-}" ]] || error "Need value for --phase"
    PHASE="$1"
    shift
fi

if [[ "$PHASE" == "installer" ]]; then
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
                [[ "${1:-}" == "1" || "${1:-}" == "2" ]] || error "Invalid --hold"
                HOLD="$1"
                ;;
            --yes|--force)
                AUTO_YES=1
                ;;
            *)
                error "Unknown installer argument: $1"
                ;;
        esac
        shift
    done

    INSTALLER_HOLD_OVERRIDE="$HOLD"
    detect_os_arch
    load_install_plan
    [[ "$INSTALLER_HOLD_OVERRIDE" == "0" ]] || HOLD="$INSTALLER_HOLD_OVERRIDE"
    [[ "$HOLD" == "1" ]] || ensure_dependencies

    [[ -z "$DISK" || "$DISK" == /dev/* ]] || DISK="/dev/$DISK"
    if [[ -z "$DISK" ]]; then
        auto_detect_disk
    else
        resolve_target_disk_from_identity
    fi
    validate_target_disk "$DISK"
    do_install
    exit 0
fi

[[ "$PHASE" == "host" ]] || error "Unsupported phase: $PHASE"

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

prepare_and_boot_alpine_ram
exit 0
