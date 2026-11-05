#!/usr/bin/env bash
# Experiment 7: Install KVM in Linux
# Based only on the uploaded virtualization record, pages 32–34.

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
line() { printf '%s\n' '------------------------------------------------------------'; }
ok() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[NOTE]${RESET} $*"; }
fail() { echo -e "${RED}[ERROR]${RESET} $*"; }
pause() { echo; read -r -p "Press Enter to continue..."; }

require_sudo() {
    command -v sudo >/dev/null 2>&1 || { fail "sudo is not installed."; exit 1; }
    sudo -v || { fail "Administrator permission is required."; exit 1; }
}

detect_distro() {
    [[ -r /etc/os-release ]] || { echo unknown; return; }
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|linuxmint|pop) echo debian ;;
        fedora) echo fedora ;;
        centos|rhel|rocky|almalinux|ol) echo rhel ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*) echo debian ;;
                *rhel*|*fedora*) echo rhel ;;
                *) echo unknown ;;
            esac ;;
    esac
}

check_hardware() {
    line; echo "STEP 1: CHECK HARDWARE VIRTUALIZATION SUPPORT"; line
    echo "Command: egrep -c '(vmx|svm)' /proc/cpuinfo"
    local count
    count=$(egrep -c '(vmx|svm)' /proc/cpuinfo 2>/dev/null || true)
    count=${count:-0}
    echo "Detected flags: $count"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        ok "CPU virtualization extensions are visible."
    else
        warn "No vmx/svm flag detected. Enable Intel VT-x/AMD-V in BIOS/UEFI."
        warn "If Linux is running inside a VM, nested virtualization may not be exposed."
    fi
}

install_packages() {
    line; echo "STEP 2: INSTALL KVM PACKAGES"; line
    local distro; distro=$(detect_distro)
    case "$distro" in
        debian)
            sudo apt update &&
            sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y qemu-kvm libvirt virt-install bridge-utils virt-manager
            else
                sudo yum install -y qemu-kvm libvirt virt-install bridge-utils virt-manager
            fi ;;
        fedora)
            sudo dnf install -y @virtualization virt-manager ;;
        *)
            fail "Unsupported Linux distribution. Check the package commands in your record."
            return 1 ;;
    esac
    local result=$?
    if (( result == 0 )); then
        ok "Package installation completed."
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl list-unit-files | grep -q '^libvirtd\.service'; then
                sudo systemctl enable --now libvirtd
            elif systemctl list-unit-files | grep -q '^virtqemud\.service'; then
                sudo systemctl enable --now virtqemud
            else
                warn "libvirtd/virtqemud service unit was not found."
            fi
        fi
    else
        fail "Package installation failed. Check internet and repositories."
        return "$result"
    fi
}

verify_modules() {
    line; echo "STEP 3: VERIFY KVM KERNEL MODULES"; line
    echo "Command: lsmod | grep kvm"
    if lsmod | grep -E '(^kvm|kvm_)'; then
        ok "KVM module(s) are loaded."
    else
        warn "No KVM module is shown. Trying to load the CPU-specific module..."
        local vendor
        vendor=$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | xargs)
        case "$vendor" in
            GenuineIntel) sudo modprobe kvm_intel ;;
            AuthenticAMD) sudo modprobe kvm_amd ;;
            *) warn "CPU vendor could not be identified." ;;
        esac
        lsmod | grep -E '(^kvm|kvm_)' || warn "KVM modules are still not visible."
    fi
}

configure_permissions() {
    line; echo "STEP 4: CONFIGURE USER PERMISSIONS"; line
    local target_user="${SUDO_USER:-$USER}"
    echo "Command: sudo usermod -aG libvirt $target_user"
    if getent group libvirt >/dev/null 2>&1; then
        sudo usermod -aG libvirt "$target_user" && ok "User added to libvirt group."
        echo "Log out and log back in for the change to take effect."
        id "$target_user"
    else
        warn "The libvirt group does not exist. Install KVM/libvirt packages first."
    fi
}

nested_virtualization() {
    line; echo "STEP 5: ENABLE NESTED VIRTUALIZATION (OPTIONAL)"; line
    warn "Only needed when running a VM inside a KVM guest."
    warn "It may not work if this Linux system is itself a VM without nested virtualization support."
    read -r -p "Enable nested virtualization now? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Skipped."; return 0; }
    local vendor
    vendor=$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | xargs)
    case "$vendor" in
        GenuineIntel)
            echo 'options kvm-intel nested=1' | sudo tee /etc/modprobe.d/kvm-intel.conf >/dev/null
            sudo modprobe -r kvm_intel 2>/dev/null || true
            sudo modprobe kvm_intel ;;
        AuthenticAMD)
            echo 'options kvm-amd nested=1' | sudo tee /etc/modprobe.d/kvm-amd.conf >/dev/null
            sudo modprobe -r kvm_amd 2>/dev/null || true
            sudo modprobe kvm_amd ;;
        *) fail "Could not identify Intel/AMD CPU."; return 1 ;;
    esac
    ok "Nested virtualization configuration attempted. Reboot may be required."
}

install_virt_manager() {
    line; echo "STEP 6: INSTALL VIRT-MANAGER"; line
    case "$(detect_distro)" in
        debian) sudo apt update && sudo apt install -y virt-manager ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then sudo dnf install -y virt-manager
            else sudo yum install -y virt-manager; fi ;;
        fedora) sudo dnf install -y virt-manager ;;
        *) fail "Unknown distribution; install virt-manager with your package manager."; return 1 ;;
    esac
    if [[ $? -eq 0 ]]; then ok "Virt-Manager installed. Start it with: virt-manager"
    else fail "Virt-Manager installation failed."; return 1; fi
}

show_summary() {
    line; echo "KVM INSTALLATION VERIFICATION"; line
    echo "Hardware virtualization flags:"
    egrep -c '(vmx|svm)' /proc/cpuinfo 2>/dev/null || true
    echo; echo "Loaded KVM modules:"
    lsmod | grep -E '(^kvm|kvm_)' || true
    echo; echo "Libvirt service:"
    systemctl is-active libvirtd 2>/dev/null || systemctl is-active virtqemud 2>/dev/null || true
    echo; echo "User/groups:"; id
    echo; echo "Virt-Manager:"; command -v virt-manager || echo "Not installed / not in PATH."
    line
}

main() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================================"
    echo "             EXPERIMENT 7: INSTALL KVM IN LINUX"
    echo -e "============================================================${RESET}"
    echo "Based only on the uploaded virtualization record."
    echo "Supported: Ubuntu/Debian, CentOS/RHEL and Fedora."
    check_hardware
    echo
    echo "1) Install KVM packages and enable libvirt"
    echo "2) Verify KVM kernel modules"
    echo "3) Configure libvirt user permissions"
    echo "4) Enable nested virtualization (optional)"
    echo "5) Install Virt-Manager"
    echo "6) Run main steps (install, verify, permissions, Virt-Manager)"
    echo "7) Show final verification summary"
    echo "0) Exit"
    while true; do
        echo
        read -r -p "Enter choice: " choice
        case "$choice" in
            1) require_sudo; install_packages; pause ;;
            2) require_sudo; verify_modules; pause ;;
            3) require_sudo; configure_permissions; pause ;;
            4) require_sudo; nested_virtualization; pause ;;
            5) require_sudo; install_virt_manager; pause ;;
            6)
                require_sudo
                install_packages
                verify_modules
                configure_permissions
                install_virt_manager
                warn "Nested virtualization is optional and was not enabled automatically."
                pause ;;
            7) show_summary; pause ;;
            0) echo "Exiting."; exit 0 ;;
            *) echo "Invalid choice. Enter 0–7." ;;
        esac
    done
}
main "$@"
