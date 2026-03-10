#!/usr/bin/env bash
# reinstall-freebsd-linux.sh
# Reinstall system on Linux / FreeBSD using DD + cloud-init (NoCloud) with:
#   - freebsd
#   - rocky
#   - almalinux
#   - fedora
#   - redhat
#
# All target systems use cloud-init to inject:
#   - root password (--password)
#   - SSH public key(s) (--ssh-key, multiple)
#   - SSH port (--ssh-port)
#   - optional FRPC config (--frpc-toml) stored as EFI:/nocloud/frpc.toml
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
    echo "==> $*"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME freebsd   14   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME rocky     10   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME almalinux 10   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME fedora    43   [--disk /dev/sdX] [options...]
  $SCRIPT_NAME redhat         [--disk /dev/sdX] --img URL [options...]

If --disk is not specified, the script will try to auto-detect the main disk:
  - On Linux, picks the largest non-removable disk from lsblk.
  - On FreeBSD, picks the largest non-cd disk from kern.disks using diskinfo.

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
                         - Local path: copy to EFI:/nocloud/frpc.toml
                         - HTTP(S): download to EFI:/nocloud/frpc.toml
                       cloud-init will add a runcmd section that tries to copy this to /etc/frp
                       and start frpc if available.

  --hold 1             Only validate and print planned actions, do not download or write disk.
  --hold 2             Perform dd + NoCloud injection but do NOT reboot.

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
    local url="$1" dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$dst" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$dst" "$url"
    elif command -v fetch >/dev/null 2>&1; then
        fetch -o "$dst" "$url"
    else
        error "No curl/wget/fetch found, cannot download: $url"
    fi
}

http_content_length() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsIL "$url" | awk '
            /^[Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); print $2; exit }
        '
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget --server-response --spider "$url" 2>&1 | awk '
            /^  [Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); print $2; exit }
        '
        return 0
    fi

    return 1
}

get_available_bytes() {
    local path="$1"
    df -Pk "$path" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'
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
        python3 - "$plain" <<'PY'
import crypt
import sys
pw = sys.argv[1]
print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))
PY
        return 0
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

    error "No password hashing tool found. Install openssl or python3 or perl, or use --ssh-key only."
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
    command -v grub-mkstandalone >/dev/null 2>&1 || command -v grub2-mkstandalone >/dev/null 2>&1 || missing+=("grub-mkstandalone")

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
            grub-mkstandalone) pkgs+=("grub2") ;;
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

auto_detect_disk() {
    info "Auto-detecting target disk..."

    if [[ "$OS" == "Linux" ]]; then
        if command -v lsblk >/dev/null 2>&1; then
            local best_name="" best_size=0
            while read -r name type rm size; do
                [[ "$type" == "disk" ]] || continue
                [[ "$rm" == "0" ]] || continue
                if [[ "$size" -gt "$best_size" ]]; then
                    best_size="$size"
                    best_name="$name"
                fi
            done < <(lsblk -b -ndo NAME,TYPE,RM,SIZE 2>/dev/null || true)

            if [[ -n "$best_name" ]]; then
                DISK="/dev/$best_name"
                info "Auto-detected disk: $DISK (largest non-removable disk)"
                return 0
            fi
        fi
        error "Unable to auto-detect target disk on Linux. Please specify --disk explicitly."
    else
        if command -v sysctl >/dev/null 2>&1; then
            local disks best_name="" best_size=0 size
            disks=$(sysctl -n kern.disks 2>/dev/null || true)
            for d in $disks; do
                case "$d" in
                    cd*|md*|lo*|ram*) continue ;;
                esac
                if command -v diskinfo >/dev/null 2>&1; then
                    size=$(diskinfo -v "/dev/$d" 2>/dev/null | awk '/^mediasize/ {print $2; exit}')
                else
                    size=0
                fi
                [[ -z "$size" ]] && size=0
                if [[ "$size" -gt "$best_size" ]]; then
                    best_size="$size"
                    best_name="$d"
                fi
            done
            if [[ -n "$best_name" ]]; then
                DISK="/dev/$best_name"
                info "Auto-detected disk: $DISK (largest non-cd disk via diskinfo)"
                return 0
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

# Optional RHEL hook (does not affect initramfs auto-reinstall)
run_rhel_freebsd_hook() {
    if [[ "$OS" == "Linux" ]] && [[ -f /etc/redhat-release ]]; then
        if [[ -f "./reinstall-fbl.sh" ]]; then
            info "RHEL detected, running: bash reinstall-fbl.sh freebsd 14"
            if ! bash ./reinstall-fbl.sh freebsd 14; then
                warn "reinstall-fbl.sh freebsd 14 failed, continuing anyway."
            fi
        else
            warn "RHEL detected, but ./reinstall-fbl.sh not found; skipping RHEL hook."
        fi
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
                14|14.*)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        aarch64)
                            echo "https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/aarch64/Latest/FreeBSD-14.3-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"
                            ;;
                        *)
                            error "Current arch $MACHINE_ARCH is not supported for automatic FreeBSD image selection, please specify --img manually"
                            ;;
                    esac
                    ;;
                *)
                    error "Unsupported FreeBSD version: $ver (only 14.x is baked in; use --img for others)"
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
                        *)
                            error "Rocky 10 default image is only provided for x86_64; use --img for other arches"
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
                43)
                    case "$MACHINE_ARCH" in
                        x86_64)
                            echo "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
                            ;;
                        aarch64)
                            echo "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2"
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
        if command -v lsblk >/dev/null 2>&1; then
            local base part line name type parttype fstype partlabel partflags
            base="${disk#/dev/}"
            while read -r line; do
                name=$(lsblk_get_kv "$line" "NAME")
                type=$(lsblk_get_kv "$line" "TYPE")
                parttype=$(lsblk_get_kv "$line" "PARTTYPE")
                fstype=$(lsblk_get_kv "$line" "FSTYPE")
                partlabel=$(lsblk_get_kv "$line" "PARTLABEL")
                partflags=$(lsblk_get_kv "$line" "PARTFLAGS")

                [[ "$type" == "part" ]] || continue
                case "$name" in
                    "$base"*) ;;
                    *) continue ;;
                esac

                if [[ "$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                    part="/dev/$name"
                    echo "$part"
                    return 0
                fi
                if echo "$partlabel" | grep -qiE 'efi|esp'; then
                    part="/dev/$name"
                    echo "$part"
                    return 0
                fi
                if [[ "$fstype" == "vfat" ]] && echo "$partflags" | grep -qi 'boot,esp'; then
                    part="/dev/$name"
                    echo "$part"
                    return 0
                fi
            done < <(lsblk -P -o NAME,TYPE,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS "$disk" 2>/dev/null || true)
        fi

        case "$disk" in
            */nvme*|*/*nvd*)
                echo "${disk}p1"
                ;;
            *)
                echo "${disk}1"
                ;;
        esac
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
        echo "${disk}p1"
    fi
}

write_nocloud_seed() {
    local os="$1" meta_path="$2" user_path="$3"

    mkdir -p "$(dirname "$meta_path")"

    cat >"$meta_path" <<EOF
instance-id: iid-$(date +%s)
local-hostname: $os
EOF

    {
        echo "#cloud-config"

        if [[ -n "$PASSWORD_HASH" || -n "$SSH_KEYS_ALL" ]]; then
            echo "ssh_pwauth: true"
            echo "disable_root: false"
            echo "users:"
            echo "  - name: root"

            if [[ -n "$PASSWORD_HASH" ]]; then
                echo "    lock_passwd: false"
                echo "    passwd: \"${PASSWORD_HASH}\""
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

        if [[ -n "$WEB_PORT" ]]; then
            cat <<EOF

write_files:
  - path: /etc/reinstall-web-port
    permissions: '0644'
    owner: root:root
    content: |
      $WEB_PORT
EOF
        fi

        if [[ -n "$SSH_PORT" ]] || [[ -n "$FRPC_PRESENT" ]]; then
            echo
            echo "runcmd:"
        fi

        if [[ -n "$SSH_PORT" ]]; then
            cat <<EOF
  - |
      # Try to change SSH port on Linux / FreeBSD
      if [ -f /etc/ssh/sshd_config ]; then
        sed -i -e 's/^#Port .*/Port ${SSH_PORT}/' -e 's/^Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config 2>/dev/null || \
        sed -i '' -e 's/^#Port .*/Port ${SSH_PORT}/' -e 's/^Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config 2>/dev/null || true
      fi
      service sshd restart 2>/dev/null || systemctl restart sshd 2>/dev/null || true
EOF
        fi

        if [[ -n "$FRPC_PRESENT" ]]; then
            cat <<'EOF'
  - |
      # If EFI nocloud contains frpc.toml, copy to /etc/frp and try to start frpc
      if [ -f /boot/efi/nocloud/frpc.toml ]; then
        mkdir -p /etc/frp
        cp /boot/efi/nocloud/frpc.toml /etc/frp/frpc.toml
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

# Alpine RAM preparation
ALPINE_ENTRY_TITLE="Reinstall Alpine RAM"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.22"
ALPINE_NETBOOT_SUBDIR="netboot-3.22.3"
ALPINE_BOOT_SUBDIR="alpine"
ALPINE_BOOT_DIR_REL=""
ALPINE_BOOT_DIR_ABS=""
ALPINE_VMLINUZ_REL=""
ALPINE_INITRAMFS_REL=""
ALPINE_MODLOOP_REL=""
ALPINE_APKOVL_REL=""
ALPINE_VMLINUZ_ABS=""
ALPINE_INITRAMFS_ABS=""
ALPINE_MODLOOP_ABS=""
ALPINE_APKOVL_ABS=""
ALPINE_SCRIPT_COPY_ABS=""
ALPINE_FREEBSD_GRUB_EFI_REL=""
ALPINE_FREEBSD_GRUB_EFI_ABS=""
ALPINE_NETBOOT_ARCH=""
ALPINE_KERNEL_FLAVOR=""
GRUB_SCRIPT_PATH=""
GRUB_CFG_PATH=""
GRUB_MKCONFIG_CMD=""
GRUB_REBOOT_CMD=""
GRUB_DEFAULT_CMD=""
GRUB_MKSTANDALONE_CMD=""
GRUB_EFI_TARGET=""
CURRENT_CONSOLE_ARGS=""
AUTO_YES=0

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
        if command -v lsblk >/dev/null 2>&1; then
            local line name type parttype partlabel partflags fstype
            while read -r line; do
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
                    echo "/dev/$name"
                    return 0
                fi
            done < <(lsblk -P -o NAME,TYPE,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS 2>/dev/null || true)
        fi
    elif [[ "$os" == "FreeBSD" ]]; then
        if command -v sysctl >/dev/null 2>&1 && command -v gpart >/dev/null 2>&1; then
            local d p
            for d in $(sysctl -n kern.disks 2>/dev/null || true); do
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
    if command -v fstyp >/dev/null 2>&1; then
        fstyp -u "$dev" 2>/dev/null || true
    fi
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
        if [[ -d "/boot/efi" ]] && mountpoint -q "/boot/efi" 2>/dev/null; then
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
                if mountpoint -q "/boot" 2>/dev/null; then
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

    if [[ -d "$EFI_MOUNT_POINT" ]] && mountpoint -q "$EFI_MOUNT_POINT" 2>/dev/null; then
        PLAN_STORAGE_MODE="efi"
        PLAN_PATH_PREFIX_REL=""
        PLAN_EFI_MOUNTED_BY_SCRIPT=0
        if [[ -z "$PLAN_EFI_PART" ]]; then
            PLAN_EFI_PART=$(mount | awk -v mnt="$EFI_MOUNT_POINT" '$3 == "on" && $4 == mnt {print $1; exit}' || true)
        fi
        if [[ -n "$PLAN_EFI_PART" ]]; then
            PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
            PLAN_EFI_FS_TYPE=$(get_fs_type_freebsd "$PLAN_EFI_PART")
            split_freebsd_part_device "$PLAN_EFI_PART"
        fi
        return 0
    fi

    mkdir -p "$EFI_MOUNT_POINT"
    local efi_part
    efi_part=$(find_efi_for_plan 2>/dev/null || true)
    [[ -n "$efi_part" ]] || error "Could not find EFI partition for plan storage"

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
        printf 'IMG_URL=%q\n' "$IMG_URL"
        printf 'PASSWORD_HASH=%q\n' "$PASSWORD_HASH"
        printf 'SSH_KEYS_ALL=%q\n' "$SSH_KEYS_ALL"
        printf 'SSH_PORT=%q\n' "$SSH_PORT"
        printf 'WEB_PORT=%q\n' "$WEB_PORT"
        printf 'FRPC_TOML=%q\n' "$FRPC_TOML"
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

    sync
    info "Saved reinstall plan to $plan_file"
}

load_plan_from_efi() {
    local boot_mnt="/media/bootstrap"
    local plan_file=""
    local candidate=""
    local vars_loaded=0

    if [[ -f /etc/reinstall/vars ]]; then
        # shellcheck disable=SC1091
        . /etc/reinstall/vars
        vars_loaded=1
    fi

    if [[ "$OS" == "Linux" ]]; then
        mkdir -p "$boot_mnt"

        # 1) 优先按 /etc/reinstall/vars 提供的信息尝试挂载
        if [[ "$vars_loaded" -eq 1 ]] && ! mountpoint -q "$boot_mnt" 2>/dev/null; then
            if [[ -n "${PLAN_EFI_PART:-}" && -e "${PLAN_EFI_PART}" ]]; then
                if [[ "${PLAN_STORAGE_MODE:-efi}" == "efi" ]]; then
                    mount "${PLAN_EFI_PART}" "$boot_mnt" 2>/dev/null || \
                    mount -t vfat "${PLAN_EFI_PART}" "$boot_mnt" 2>/dev/null || \
                    mount -t msdos "${PLAN_EFI_PART}" "$boot_mnt" 2>/dev/null || \
                    mount -t msdosfs "${PLAN_EFI_PART}" "$boot_mnt" 2>/dev/null || true
                else
                    mount "${PLAN_EFI_PART}" "$boot_mnt" 2>/dev/null || true
                fi
            fi
            if ! mountpoint -q "$boot_mnt" 2>/dev/null && [[ -n "${PLAN_EFI_UUID:-}" ]]; then
                candidate="$(blkid -U "$PLAN_EFI_UUID" 2>/dev/null || true)"
                if [[ -n "$candidate" && -e "$candidate" ]]; then
                    if [[ "${PLAN_STORAGE_MODE:-efi}" == "efi" ]]; then
                        mount "$candidate" "$boot_mnt" 2>/dev/null || \
                        mount -t vfat "$candidate" "$boot_mnt" 2>/dev/null || \
                        mount -t msdos "$candidate" "$boot_mnt" 2>/dev/null || \
                        mount -t msdosfs "$candidate" "$boot_mnt" 2>/dev/null || true
                    else
                        mount "$candidate" "$boot_mnt" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        # 2) 如果还没挂上，就扫描常见块设备，同时探测两种路径：
        #    /REINSTALL/plan.env
        #    /boot/REINSTALL/plan.env
        if ! mountpoint -q "$boot_mnt" 2>/dev/null; then
            for candidate in /dev/sd* /dev/vd* /dev/xvd* /dev/nvme*n* /dev/mmcblk*p* /dev/mapper/*; do
                [[ -e "$candidate" ]] || continue

                mount "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t ext4 "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t xfs "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t btrfs "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t vfat "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t msdos "$candidate" "$boot_mnt" 2>/dev/null || \
                mount -t msdosfs "$candidate" "$boot_mnt" 2>/dev/null || true

                if mountpoint -q "$boot_mnt" 2>/dev/null; then
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
                fi
            done
        fi

        # 3) 如果已挂载但 plan_file 还没定，再查一次
        if [[ -z "$plan_file" && -d "$boot_mnt" ]] && mountpoint -q "$boot_mnt" 2>/dev/null; then
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
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        GRUB_MKSTANDALONE_CMD="grub-mkstandalone"
    elif command -v grub2-mkstandalone >/dev/null 2>&1; then
        GRUB_MKSTANDALONE_CMD="grub2-mkstandalone"
    else
        error "grub-mkstandalone is required on FreeBSD host"
    fi
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

    # Use generic destination names on bootstrap storage so different source flavors/arches can be normalized.
    ALPINE_VMLINUZ_REL="$ALPINE_BOOT_DIR_REL/vmlinuz"
    ALPINE_INITRAMFS_REL="$ALPINE_BOOT_DIR_REL/initramfs"
    ALPINE_MODLOOP_REL="$ALPINE_BOOT_DIR_REL/modloop"
    ALPINE_APKOVL_REL="$ALPINE_BOOT_DIR_REL/reinstall.apkovl.tar.gz"

    ALPINE_VMLINUZ_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_VMLINUZ_REL"
    ALPINE_INITRAMFS_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_INITRAMFS_REL"
    ALPINE_MODLOOP_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_MODLOOP_REL"
    ALPINE_APKOVL_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_APKOVL_REL"

    ALPINE_SCRIPT_COPY_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL/$PLAN_DIR_REL/$SCRIPT_NAME"
    ALPINE_FREEBSD_GRUB_EFI_ABS="$EFI_MOUNT_POINT$PLAN_PATH_PREFIX_REL$ALPINE_FREEBSD_GRUB_EFI_REL"
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
    ALPINE_KERNEL_FLAVOR="lts"

    info "Using fixed Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}, source=${base}"

    if ! http_download "$base/vmlinuz-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/vmlinuz"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine kernel"
    fi
    if ! http_download "$base/initramfs-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/initramfs"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine initramfs"
    fi
    if ! http_download "$base/modloop-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/modloop"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine modloop"
    fi

    mv "$tmpdir/vmlinuz" "$ALPINE_VMLINUZ_ABS"
    mv "$tmpdir/initramfs" "$ALPINE_INITRAMFS_ABS"
    mv "$tmpdir/modloop" "$ALPINE_MODLOOP_ABS"

    chmod 0644 "$ALPINE_VMLINUZ_ABS" "$ALPINE_INITRAMFS_ABS" "$ALPINE_MODLOOP_ABS"
    rm -rf "$tmpdir"
    sync

    info "Selected Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}"
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

    repofile="$ovl_dir/etc/apk/repositories"
    cat >"$repofile" <<EOF
${ALPINE_REPO_BASE}/main
${ALPINE_REPO_BASE}/community
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

    startfile="$ovl_dir/usr/local/sbin/reinstall-auto.sh"
    cat >"$startfile" <<'EOF'
#!/bin/bash
set -eu

LOG="/var/log/reinstall-auto.log"
mkdir -p /var/log
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "===== reinstall-auto start $(date) ====="

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

[ -f /etc/reinstall/vars ] || {
    echo "Missing /etc/reinstall/vars"
    exit 1
}
# shellcheck disable=SC1091
. /etc/reinstall/vars

ensure_network() {
    local dev candidates="" preferred=""

    if ip route 2>/dev/null | grep -q '^default'; then
        echo "[net] default route already exists"
        return 0
    fi

    echo "[net] probing network interfaces"

    for dev in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true); do
        [ -n "$dev" ] || continue
        if [ -r "/sys/class/net/$dev/carrier" ] && [ "$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)" = "1" ]; then
            preferred="$preferred $dev"
        else
            candidates="$candidates $dev"
        fi
    done

    candidates="$preferred $candidates"

    for dev in $candidates; do
        echo "[net] trying interface: $dev"
        ip link set "$dev" up 2>/dev/null || true
        ip addr flush dev "$dev" 2>/dev/null || true
        udhcpc -n -q -t 3 -T 3 -i "$dev" 2>/dev/null || true
        if ip route 2>/dev/null | grep -q '^default'; then
            echo "[net] DHCP succeeded on $dev"
            return 0
        fi
    done

    echo "[net] no DHCP lease obtained, continuing anyway"
    return 0
}

mount_bootstrap() {
    local base_mnt dev
    base_mnt=/media/bootstrap

    mkdir -p "$base_mnt"

    if mountpoint -q "$base_mnt" 2>/dev/null; then
        return 0
    fi

    if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
        if [ -n "${PLAN_EFI_PART:-}" ] && [ -e "${PLAN_EFI_PART}" ]; then
            mount "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t vfat "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t msdos "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || \
            mount -t msdosfs "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || true
        fi
    else
        if [ -n "${PLAN_EFI_PART:-}" ] && [ -e "${PLAN_EFI_PART}" ]; then
            mount "${PLAN_EFI_PART}" "$base_mnt" 2>/dev/null || true
        fi
    fi

    if mountpoint -q "$base_mnt" 2>/dev/null; then
        return 0
    fi

    if [ -n "${PLAN_EFI_UUID:-}" ]; then
        dev="$(blkid -U "$PLAN_EFI_UUID" 2>/dev/null || true)"
        if [ -n "$dev" ] && [ -e "$dev" ]; then
            if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
                mount "$dev" "$base_mnt" 2>/dev/null || \
                mount -t vfat "$dev" "$base_mnt" 2>/dev/null || \
                mount -t msdos "$dev" "$base_mnt" 2>/dev/null || \
                mount -t msdosfs "$dev" "$base_mnt" 2>/dev/null || true
            else
                mount "$dev" "$base_mnt" 2>/dev/null || true
            fi
        fi
    }

    if mountpoint -q "$base_mnt" 2>/dev/null; then
        return 0
    fi

    if [ "${PLAN_STORAGE_MODE:-efi}" = "efi" ]; then
        for dev in /dev/sd* /dev/vd* /dev/xvd* /dev/nvme*n* /dev/mmcblk*p*; do
            [ -e "$dev" ] || continue
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
        for dev in /dev/sd* /dev/vd* /dev/xvd* /dev/nvme*n* /dev/mmcblk*p* /dev/mapper/*; do
            [ -e "$dev" ] || continue
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

install_runtime_deps() {
    echo "[stage] ensure_network"
    ensure_network
    echo "[stage] apk update"
    apk update || true
    echo "[stage] apk add runtime packages"
    apk add --no-cache \
        bash curl wget xz qemu-img util-linux coreutils grep sed gawk findutils file tar \
        e2fsprogs dosfstools || true
}

main() {
    local bootstrap_prefix=""
    echo "[stage] mount_bootstrap"
    mount_bootstrap
    echo "[stage] install_runtime_deps"
    install_runtime_deps

    if [ -f "/media/bootstrap/${PLAN_DIR_REL}/${PLAN_FILE_NAME}" ]; then
        bootstrap_prefix=""
    elif [ -f "/media/bootstrap/boot/${PLAN_DIR_REL}/${PLAN_FILE_NAME}" ]; then
        bootstrap_prefix="/boot"
    else
        echo "Plan file not found under /media/bootstrap or /media/bootstrap/boot"
        exit 1
    fi

    PLAN_FILE="/media/bootstrap${bootstrap_prefix}/${PLAN_DIR_REL}/${PLAN_FILE_NAME}"
    SCRIPT_FILE="/media/bootstrap${bootstrap_prefix}/${PLAN_DIR_REL}/${SCRIPT_NAME}"

    [ -f "$PLAN_FILE" ] || {
        echo "Plan file not found: $PLAN_FILE"
        exit 1
    }
    [ -f "$SCRIPT_FILE" ] || {
        echo "Script file not found: $SCRIPT_FILE"
        exit 1
    }

    chmod 0755 "$SCRIPT_FILE" || true

    echo "[stage] launch installer"
    echo "Launching installer phase..."
    bash "$SCRIPT_FILE" --phase installer --yes

    rc=$?
    echo "Installer phase finished with rc=$rc"

    if [ "$rc" -eq 0 ]; then
        if grep -q "^HOLD='2'$" /etc/reinstall/vars 2>/dev/null || grep -q '^HOLD=2$' "$PLAN_FILE" 2>/dev/null; then
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
    use networking
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
    linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} ip=none alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_REL} apkovl=${ALPINE_APKOVL_REL} reinstall_alpine=1${CURRENT_CONSOLE_ARGS}
    initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
}
EOF
    else
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    linux /boot${ALPINE_VMLINUZ_REL} ip=none alpine_repo=${ALPINE_REPO_BASE}/main modloop=/boot${ALPINE_MODLOOP_REL} apkovl=/boot${ALPINE_APKOVL_REL} reinstall_alpine=1${CURRENT_CONSOLE_ARGS}
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

    local tmp cfg
    tmp=$(mktemp -d /tmp/reinstall-freebsd-grub.XXXXXX)

    cfg="$tmp/grub.cfg"
    cat >"$cfg" <<EOF
search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} ip=none alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_REL} apkovl=${ALPINE_APKOVL_REL} reinstall_alpine=1 console=ttyS0 console=tty0
initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
boot
EOF

    info "Building standalone GRUB EFI binary for FreeBSD BootNext..."
    "$GRUB_MKSTANDALONE_CMD" \
        -O "$GRUB_EFI_TARGET" \
        -o "$ALPINE_FREEBSD_GRUB_EFI_ABS" \
        "boot/grub/grub.cfg=$cfg" \
        --modules="part_gpt fat search search_fs_uuid linux normal echo"
    chmod 0644 "$ALPINE_FREEBSD_GRUB_EFI_ABS"
    rm -rf "$tmp"
    sync
}

install_freebsd_bootnext_entry() {
    ensure_freebsd_boot_tools

    local before after newnum old

    [[ -n "${PLAN_EFI_PART_DISK:-}" ]] || split_freebsd_part_device "$PLAN_EFI_PART"
    [[ -n "${PLAN_EFI_PART_NUM:-}" ]] || error "Missing FreeBSD EFI partition number"

    while read -r old; do
        [[ -n "$old" ]] || continue
        efibootmgr -b "$old" -B >/dev/null 2>&1 || warn "Failed to delete old EFI boot entry: $old"
    done < <(
        efibootmgr 2>/dev/null | awk -v title="$ALPINE_ENTRY_TITLE" '
            $0 ~ title {
                n = substr($1, 5, 4)
                gsub(/\*/, "", n)
                print n
            }
        '
    )

    before=$(
        efibootmgr 2>/dev/null |
        awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            n = substr($1, 5, 4)
            gsub(/\*/, "", n)
            printf "%d\n", strtonum("0x" n)
        }' | sort -n -u
    )

    info "Creating FreeBSD UEFI boot entry: ${ALPINE_ENTRY_TITLE}"
    efibootmgr -c \
        --disk "$PLAN_EFI_PART_DISK" \
        --part "$PLAN_EFI_PART_NUM" \
        -l "$(printf '%s' "$ALPINE_FREEBSD_GRUB_EFI_REL" | tr '/' '\\')" \
        -L "$ALPINE_ENTRY_TITLE" >/dev/null

    after=$(
        efibootmgr 2>/dev/null |
        awk '/^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            n = substr($1, 5, 4)
            gsub(/\*/, "", n)
            printf "%d\n", strtonum("0x" n)
        }' | sort -n -u
    )

    newnum=$(
        comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1
    )

    [[ -n "$newnum" ]] || error "Failed to determine new EFI boot entry after creating ${ALPINE_ENTRY_TITLE}"

    printf -v newnum '%04X' "$newnum"

    info "Setting BootNext to EFI entry $newnum (${ALPINE_ENTRY_TITLE})"
    efibootmgr -n "$newnum" >/dev/null
}

prepare_and_boot_alpine_ram() {
    [[ "$OS" == "Linux" ]] || error "Automatic Alpine RAM bootstrap only supports Linux host in this function"

    prepare_alpine_paths
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
    copy_script_to_efi
    download_alpine_ram_files
    build_alpine_apkovl
    build_freebsd_grub_efi
    install_freebsd_bootnext_entry

    info "Alpine RAM installer prepared for FreeBSD UEFI BootNext."
    info "System will reboot now into one-time UEFI entry: ${ALPINE_ENTRY_TITLE}"
    sync
    sleep 2
    shutdown -r now
}

# ----------------- installer execution (download + dd + NoCloud) -----------------

do_install() {
    info "Host: OS=$OS ARCH=$ARCH ($MACHINE_ARCH)"
    info "Target: $TARGET_OS ${TARGET_VER:-"(no version)"}"
    info "Disk: $DISK"
    info "Image URL: $IMG_URL"

    if [[ "$HOLD" == "1" ]]; then
        info "--hold 1 is set: only parameter check and summary, no download or disk write."
        return 0
    fi

    INSTALL_TMPDIR=$(mktemp -d /tmp/reinstall-cloudinit.XXXXXX)
    trap 'rm -rf "$INSTALL_TMPDIR"' EXIT

    IMG_QCOW="$INSTALL_TMPDIR/image.qcow2"
    IMG_RAW="$INSTALL_TMPDIR/image.raw"

    info "Prechecking temporary space..."
    precheck_tmp_space_for_image "$IMG_URL"

    info "Downloading image..."
    http_download "$IMG_URL" "$IMG_QCOW"

    if file "$IMG_QCOW" | grep -qi 'xz compressed'; then
        info "Detected xz compressed image, decompressing (progress may be shown)..."
        mv "$IMG_QCOW" "$IMG_QCOW.xz"
        if command -v pv >/dev/null 2>&1; then
            xz -dc "$IMG_QCOW.xz" | pv >"$IMG_QCOW"
        else
            xz -dc "$IMG_QCOW.xz" >"$IMG_QCOW"
        fi
    fi

    info "Converting qcow2 to raw with qemu-img (with progress)..."
    qemu-img convert -p -O raw "$IMG_QCOW" "$IMG_RAW"

    echo
    echo "WARNING: dd will be run on $DISK. ALL DATA ON THIS DISK WILL BE LOST!"

    if [[ "$AUTO_YES" -eq 1 ]]; then
        info "AUTO_YES=1, skipping interactive confirmation."
    else
        read -r -p "Type 'yes' or 'y' to continue: " ans
        case "$ans" in
            y|Y|yes|YES|Yes)
                ;;
            *)
                error "Operation cancelled by user."
                ;;
        esac
    fi

    info "Writing image to disk with dd, this may take a while..."
    if [[ "$OS" == "FreeBSD" ]]; then
        if command -v pv >/dev/null 2>&1; then
            pv "$IMG_RAW" | dd of="$DISK" bs=4M conv=fsync
        else
            echo "TIP: Press Ctrl+T to see dd progress on FreeBSD."
            dd if="$IMG_RAW" of="$DISK" bs=4M conv=fsync
        fi
    else
        dd if="$IMG_RAW" of="$DISK" bs=4M conv=fsync status=progress
    fi
    sync
    info "dd finished."

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK" || true
    elif command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$DISK" || true
    fi

    sleep 2

    EFI_PART=$(find_efi_partition "$DISK")
    info "Trying EFI partition: $EFI_PART"

    MNT_EFI="$INSTALL_TMPDIR/efi"
    mkdir -p "$MNT_EFI"

    if [[ "$OS" == "FreeBSD" ]]; then
        if ! mount -t msdosfs "$EFI_PART" "$MNT_EFI" 2>/dev/null; then
            warn "Failed to mount EFI partition $EFI_PART, skipping cloud-init NoCloud injection."
            EFI_PART=""
        fi
    else
        if ! mount "$EFI_PART" "$MNT_EFI" 2>/dev/null; then
            if ! mount -t vfat "$EFI_PART" "$MNT_EFI" 2>/dev/null && ! mount -t msdos "$EFI_PART" "$MNT_EFI" 2>/dev/null; then
                warn "Failed to mount EFI partition $EFI_PART, skipping cloud-init NoCloud injection."
                EFI_PART=""
            fi
        fi
    fi

    if [[ -n "$EFI_PART" ]]; then
        NOCLOUD_DIR="$MNT_EFI/nocloud"
        mkdir -p "$NOCLOUD_DIR"

        if [[ -n "$FRPC_TOML" ]]; then
            FRPC_PRESENT=1
            if [[ "$FRPC_TOML" =~ ^https?:// ]]; then
                info "Downloading FRPC config: $FRPC_TOML"
                if ! http_download "$FRPC_TOML" "$NOCLOUD_DIR/frpc.toml"; then
                    warn "Failed to download FRPC config, ignoring"
                    FRPC_PRESENT=""
                fi
            elif [[ -f "$FRPC_TOML" ]]; then
                info "Copying FRPC config from: $FRPC_TOML"
                cp "$FRPC_TOML" "$NOCLOUD_DIR/frpc.toml"
            else
                warn "Invalid FRPC config path: $FRPC_TOML, ignoring"
                FRPC_PRESENT=""
            fi
        fi

        info "Writing NoCloud seed to EFI:/nocloud/ ..."
        write_nocloud_seed "$TARGET_OS" "$NOCLOUD_DIR/meta-data" "$NOCLOUD_DIR/user-data"

        sync
        umount "$MNT_EFI" || true
    else
        warn "EFI could not be mounted; target system can still boot, but cloud-init configuration may not be applied."
    fi

    info "Image write and cloud-init NoCloud injection completed."

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
        return 0
    fi

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

    detect_os_arch
    ensure_dependencies

    load_plan_from_efi

    if [[ -n "$DISK" && "$DISK" != /dev/* ]]; then
        DISK="/dev/$DISK"
    fi
    if [[ -z "$DISK" ]]; then
        auto_detect_disk
    fi

    if [[ ! -b "$DISK" && ! -c "$DISK" ]]; then
        error "Target disk $DISK does not exist or is not a block/char device"
    fi

    do_install
    exit 0
fi

# Host phase: collect config and save plan, do not dd here
if [[ $# -lt 1 ]]; then
    usage
fi

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
FRPC_PRESENT=""
HOLD="0"
AUTO_PASSWORD=0

if [[ $# -gt 0 ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
    case "$TARGET_OS" in
        freebsd|rocky|almalinux|fedora)
            TARGET_VER="$1"
            shift
            ;;
        redhat)
            error "Do not specify a version for redhat. Use: $SCRIPT_NAME redhat --img URL [--disk /dev/XXX] ..."
            ;;
        *)
            ;;
    esac
fi

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

detect_os_arch
ensure_dependencies

if [[ -n "$DISK" ]]; then
    if [[ "$DISK" != /dev/* ]]; then
        DISK="/dev/$DISK"
    fi
else
    auto_detect_disk
fi

if [[ ! -b "$DISK" ]] && [[ ! -c "$DISK" ]]; then
    error "Target disk $DISK does not exist or is not a block/char device"
fi

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
fi

if [[ -z "$TARGET_VER" ]]; then
    case "$TARGET_OS" in
        freebsd)   TARGET_VER="14" ;;
        rocky)     TARGET_VER="10" ;;
        almalinux) TARGET_VER="10" ;;
        fedora)    TARGET_VER="43" ;;
        redhat)    TARGET_VER="" ;;
        *)         ;;
    esac
fi

if [[ -z "$IMG_URL" ]] && [[ "$TARGET_OS" != "redhat" ]]; then
    IMG_URL=$(get_default_image_url "$TARGET_OS" "$TARGET_VER")
fi
if [[ -z "$IMG_URL" ]] && [[ "$TARGET_OS" == "redhat" ]]; then
    error "For redhat you must specify image URL with --img"
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
echo "Target OS:    $TARGET_OS ${TARGET_VER:-"(no version)"}"
echo "Username:     root"
echo "SSH port:     ${SSH_PORT:-22}"
if [[ -n "$PASSWORD_HASH" ]]; then
    if [[ "$AUTO_PASSWORD" -eq 1 ]]; then
        echo "Generated root password:"
        echo "  $PASSWORD"
    else
        echo "Root password: provided by user (plain text will NOT be saved to EFI)"
    fi
else
    echo "Root password: (not set; SSH key login only)"
fi
echo "============================================================"
echo

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
