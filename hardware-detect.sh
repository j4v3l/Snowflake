#!/usr/bin/env bash

# Hardware Detection Utility for Snowflake NixOS
# Generates hardware-specific configuration snippets

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Detect and output hardware information
detect_hardware() {
    log "Detecting hardware configuration..."
    
    echo "# Hardware Detection Report"
    echo "# Generated on $(date)"
    echo
    
    # CPU Information
    echo "## CPU Information"
    if command -v lscpu &> /dev/null; then
        local cpu_info=$(lscpu)
        echo "Vendor: $(echo "$cpu_info" | grep "Vendor ID" | awk '{print $3}')"
        echo "Model: $(echo "$cpu_info" | grep "Model name" | cut -d: -f2 | xargs)"
        echo "Architecture: $(echo "$cpu_info" | grep "Architecture" | awk '{print $2}')"
        echo "CPU(s): $(echo "$cpu_info" | grep "^CPU(s):" | awk '{print $2}')"
    elif [[ -f /proc/cpuinfo ]]; then
        echo "Vendor: $(grep "vendor_id" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Model: $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Architecture: $(uname -m)"
        echo "CPU(s): $(grep -c "processor" /proc/cpuinfo)"
    fi
    echo
    
    # Memory Information
    echo "## Memory Information"
    if [[ -f /proc/meminfo ]]; then
        local total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        echo "Total RAM: $(( total_mem / 1024 / 1024 )) GB"
    fi
    echo
    
    # Storage Devices
    echo "## Storage Devices"
    if command -v lsblk &> /dev/null; then
        lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "(disk|nvme)"
    fi
    echo
    
    # GPU Information
    echo "## GPU Information"
    if command -v lspci &> /dev/null; then
        lspci | grep -i "vga\|3d\|display"
    elif [[ -d /sys/class/drm ]]; then
        echo "DRM devices found:"
        for drm in /sys/class/drm/card*; do
            if [[ -f "$drm/device/vendor" && -f "$drm/device/device" ]]; then
                vendor=$(cat "$drm/device/vendor" 2>/dev/null || echo "unknown")
                device=$(cat "$drm/device/device" 2>/dev/null || echo "unknown")
                echo "  Device: $vendor:$device"
            fi
        done
    elif [[ -d /proc/driver/nvidia ]]; then
        echo "NVIDIA driver detected"
        if [[ -f /proc/driver/nvidia/version ]]; then
            cat /proc/driver/nvidia/version
        fi
    else
        echo "No GPU detection method available"
    fi
    echo
    
    # Network Interfaces
    echo "## Network Interfaces"
    if command -v ip &> /dev/null; then
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/://'
    fi
    echo
    
    # USB Devices
    echo "## USB Controllers"
    if command -v lspci &> /dev/null; then
        lspci | grep -i usb
    elif command -v lsusb &> /dev/null; then
        echo "USB devices:"
        lsusb
    elif [[ -d /sys/class/usb_host ]]; then
        echo "USB host controllers found:"
        ls /sys/class/usb_host/ | wc -l | xargs echo "Count:"
    else
        echo "No USB detection method available"
    fi
    echo
    
    # Kernel Modules
    echo "## Currently Loaded Storage/Input Modules"
    if command -v lsmod &> /dev/null; then
        lsmod | grep -E "(nvme|sd_mod|xhci_pci|ahci|usb_storage|ideapad)" | awk '{print $1}' | sort || echo "No matching modules found"
    elif [[ -f /proc/modules ]]; then
        echo "Checking /proc/modules for storage/input modules:"
        grep -E "(nvme|sd_mod|xhci_pci|ahci|usb_storage|ideapad)" /proc/modules | awk '{print $1}' | sort || echo "No matching modules found"
    else
        echo "No module detection method available"
    fi
    
    # Additional hardware detection
    echo
    echo "## Additional Hardware Information"
    
    # Detect virtualization
    if [[ -f /proc/cpuinfo ]] && grep -q "hypervisor" /proc/cpuinfo; then
        echo "Virtualization: Detected (running in VM/container)"
    elif [[ -d /sys/class/dmi/id ]]; then
        local sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
        local product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
        echo "System: $sys_vendor $product_name"
    fi
    
    # Check for UEFI/BIOS
    if [[ -d /sys/firmware/efi ]]; then
        echo "Boot mode: UEFI"
    else
        echo "Boot mode: Legacy BIOS (or undetectable)"
    fi
    
    # Check for hardware-specific features
    if [[ -d /sys/class/thermal ]]; then
        local thermal_zones=$(ls /sys/class/thermal/thermal_zone* 2>/dev/null | wc -l)
        echo "Thermal zones: $thermal_zones"
    fi
}

# Generate kernel module list for hardware-configuration.nix
generate_kernel_modules() {
    log "Generating kernel module configuration..."
    
    echo '# Add these to your hardware-configuration.nix:'
    echo 'boot = {'
    echo '  initrd = {'
    echo '    availableKernelModules = ['
    
    # Common storage and input modules
    local modules=(
        "nvme"
        "sd_mod" 
        "xhci_pci"
        "ahci"
        "usb_storage"
        "usbhid"
        "sr_mod"
    )
    
    for module in "${modules[@]}"; do
        if command -v lsmod &> /dev/null && lsmod | grep -q "^$module "; then
            echo "      \"$module\""
        elif [[ -f /proc/modules ]] && grep -q "^$module " /proc/modules; then
            echo "      \"$module\""
        fi
    done
    
    echo '    ];'
    echo '    kernelModules = [];'
    echo '  };'
    
    # CPU-specific modules
    if command -v lscpu &> /dev/null; then
        if lscpu | grep -qi intel; then
            echo '  kernelModules = ["kvm-intel"];'
        elif lscpu | grep -qi amd; then
            echo '  kernelModules = ["kvm-amd"];'
        fi
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -qi intel /proc/cpuinfo; then
            echo '  kernelModules = ["kvm-intel"];'
        elif grep -qi amd /proc/cpuinfo; then
            echo '  kernelModules = ["kvm-amd"];'
        fi
    fi
    
    echo '};'
}

# Output disk information
show_disk_info() {
    log "Available storage devices:"
    
    if command -v lsblk &> /dev/null; then
        echo "Device | Size | Type | Model"
        echo "-------|------|------|------"
        lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "(disk|nvme)" | while read -r name size type model; do
            echo "/dev/$name | $size | $type | $model"
        done
    elif [[ -d /sys/class/block ]]; then
        echo "Block devices from /sys/class/block:"
        for dev in /sys/class/block/*; do
            local name=$(basename "$dev")
            if [[ ! "$name" =~ [0-9]$ ]]; then  # Skip partitions
                local size="unknown"
                if [[ -f "$dev/size" ]]; then
                    local sectors=$(cat "$dev/size")
                    size="$(( sectors * 512 / 1024 / 1024 ))MB"
                fi
                echo "/dev/$name | $size | disk | unknown"
            fi
        done
    fi
}

# Generate nixos-generate-config equivalent
generate_nixos_config() {
    log "Generating NixOS hardware configuration..."
    
    if command -v nixos-generate-config &> /dev/null; then
        echo "# Run this command to generate accurate hardware config:"
        echo "sudo nixos-generate-config --show-hardware-config"
    else
        echo "# nixos-generate-config not available"
        echo "# Use this basic template and adjust as needed:"
        echo "{ config, lib, pkgs, ... }:"
        echo "{"
        echo "  imports = [ ];"
        echo ""
        echo "  boot.initrd.availableKernelModules = ["
        
        # Try to detect actual modules
        local modules=()
        if [[ -f /proc/modules ]]; then
            while IFS= read -r line; do
                local module=$(echo "$line" | awk '{print $1}')
                case "$module" in
                    nvme|sd_mod|xhci_pci|ahci|usb_storage|usbhid|sr_mod)
                        modules+=("$module")
                        ;;
                esac
            done < /proc/modules
        fi
        
        # Add default modules if none detected
        if [[ ${#modules[@]} -eq 0 ]]; then
            modules=("nvme" "sd_mod" "xhci_pci" "ahci" "usb_storage")
        fi
        
        for module in "${modules[@]}"; do
            echo "    \"$module\""
        done
        
        echo "  ];"
        echo "  boot.initrd.kernelModules = [ ];"
        
        # CPU detection
        local kvm_module="kvm-intel"
        if [[ -f /proc/cpuinfo ]] && grep -qi amd /proc/cpuinfo; then
            kvm_module="kvm-amd"
        fi
        echo "  boot.kernelModules = [ \"$kvm_module\" ];"
        echo "  boot.extraModulePackages = [ ];"
        echo ""
        echo "  hardware.enableRedistributableFirmware = lib.mkDefault true;"
        echo "}"
    fi
}

# Main function
main() {
    case "${1:-help}" in
        "detect"|"info")
            detect_hardware
            ;;
        "modules")
            generate_kernel_modules
            ;;
        "disks")
            show_disk_info
            ;;
        "generate"|"config")
            generate_nixos_config
            ;;
        "all")
            detect_hardware
            echo
            generate_kernel_modules
            echo
            show_disk_info
            echo
            generate_nixos_config
            ;;
        *)
            echo "Hardware Detection Utility for Snowflake NixOS"
            echo
            echo "Usage: $0 [command]"
            echo
            echo "Commands:"
            echo "  detect, info     - Show detailed hardware information"
            echo "  modules          - Generate kernel module configuration"
            echo "  disks            - Show available storage devices"
            echo "  generate, config - Generate NixOS hardware configuration"
            echo "  all              - Show all information"
            echo "  help             - Show this help message"
            ;;
    esac
}

main "$@"
