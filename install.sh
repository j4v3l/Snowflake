#!/usr/bin/env bash

# Snowflake NixOS Installer
# Automated installer with hardware detection and disk setup
# Usage: ./install.sh [hostname] [target_disk]

set -euo pipefail

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Clean up temporary files
    find /tmp -name "*.tmp" -user "$(whoami)" -mmin +5 -delete 2>/dev/null || true
    
    # If there was an error, show memory info
    if [[ $exit_code -ne 0 ]]; then
        echo -e "\n${RED}[ERROR]${NC} Installation failed with exit code $exit_code"
        if [[ -f /proc/meminfo ]]; then
            local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
            echo -e "${YELLOW}[DEBUG]${NC} Available memory: $(( available_mem / 1024 ))MB"
        fi
    fi
    
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="${FLAKE_DIR:-$SCRIPT_DIR}"
DEFAULT_HOSTNAME="yuki"
DEFAULT_DISK="/dev/nvme0n1"

# Logging
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Run as nixos user."
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check available memory
    local total_mem=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    
    log "System memory: Total $(( total_mem / 1024 ))MB, Available $(( available_mem / 1024 ))MB"
    
    if [[ $available_mem -lt 256000 ]]; then  # Less than 256MB
        error "Insufficient memory for installation. Need at least 256MB available."
    elif [[ $available_mem -lt 512000 ]]; then  # Less than 512MB
        warn "Low memory detected. Installation may be slow or fail."
    fi
    
    # Check if we're in NixOS installer environment (skip in development)
    if [[ ! -f /etc/NIXOS ]] && [[ "${SKIP_NIXOS_CHECK:-}" != "1" ]]; then
        warn "Not running in NixOS installer environment (set SKIP_NIXOS_CHECK=1 to override)"
    fi
    
    # Check if flake directory exists and has required files
    if [[ ! -d "$FLAKE_DIR" ]]; then
        error "Flake directory not found: $FLAKE_DIR"
    fi
    
    if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
        error "flake.nix not found in: $FLAKE_DIR"
    fi
    
    log "Using flake directory: $FLAKE_DIR"
    
    # Check if we have internet connectivity (skip in development)
    if [[ "${SKIP_INTERNET_CHECK:-}" != "1" ]] && ! timeout 5 ping -c 1 nixos.org &> /dev/null; then
        warn "No internet connection detected (set SKIP_INTERNET_CHECK=1 to override)"
    fi
    
    # Check if nix command is available
    if ! command -v nix &> /dev/null; then
        error "Nix command not found. Make sure you're running this in a NixOS environment."
    fi
    
    success "Prerequisites check passed"
}

    # Sanity check for accidental corruptions in hosts/default.nix
    sanity_check_flake_hosts_file() {
        local file="$FLAKE_DIR/hosts/default.nix"
        if [[ ! -f "$file" ]]; then
            return 0
        fi

        # Detect lines where an unquoted attribute key contains '=' before mkNixosSystem
        # Example of corruption: SKIP_DRM_DETECTION=1 = mkNixosSystem {
        local bad_lines
        bad_lines=$(grep -nE '^[[:space:]]*[^"{[:space:}][^[:space:}]*=[[:space:]]*mkNixosSystem' "$file" | grep '=') || true
        if [[ -n "$bad_lines" ]]; then
            echo -e "\n$bad_lines" | sed 's/^/  -> /'
            error "Invalid attribute key detected in $file (contains '=' before mkNixosSystem).\nThis likely happened because a KEY=VALUE token was passed as a positional argument.\nFix: restore the file (e.g., git checkout -- hosts/default.nix) or remove the broken stanza, then rerun using VAR=VALUE ./install.sh [hostname] [disk]."
        fi
    }

# Detect available storage devices
detect_storage() {
    log "Detecting storage devices..."
    
    # Check available memory first to prevent OOM
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ $available_mem -lt 512000 ]]; then  # Less than 512MB
        warn "Low memory detected (${available_mem}KB available). Installation may fail."
    fi
    
    # List all block devices (with limited output to save memory)
    if command -v lsblk &> /dev/null; then
        lsblk -d -n -o NAME,SIZE,TYPE | grep -E "(disk|nvme)" | head -10 | while read -r name size type; do
            echo "  /dev/${name} (${size})"
        done
    fi
    
    # Auto-select the largest available disk
    LARGEST_DISK=$(lsblk -d -n -o NAME,SIZE -b 2>/dev/null | grep -E "(nvme|sd)" | sort -k2 -nr | head -1 | awk '{print "/dev/" $1}')
    
    if [[ -n "${1:-}" ]]; then
        TARGET_DISK="$1"
        log "Using specified disk: $TARGET_DISK"
    elif [[ -n "$LARGEST_DISK" ]]; then
        TARGET_DISK="$LARGEST_DISK"
        log "Auto-detected largest disk: $TARGET_DISK"
    else
        TARGET_DISK="$DEFAULT_DISK"
        warn "No suitable disk found, using default: $TARGET_DISK"
    fi
    
    # Verify disk exists
    if [[ ! -b "$TARGET_DISK" ]]; then
        error "Disk $TARGET_DISK does not exist or is not a block device"
    fi
}

# Attempt to auto-repair corrupted host entries in hosts/default.nix
# Specifically removes entries where the attribute key contains an '=' before mkNixosSystem,
# e.g., 'SKIP_DRM_DETECTION=1 = mkNixosSystem { ... };'
attempt_repair_flake_hosts_file() {
    local file="$FLAKE_DIR/hosts/default.nix"
    [[ -f "$file" ]] || return 1

    # Find suspicious lines (KEY=NUMBER = mkNixosSystem)
    local matches
    matches=$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[0-9]+[[:space:]]*=\s*mkNixosSystem\s*\{' "$file" || true)
    if [[ -z "$matches" ]]; then
        return 1
    fi

    warn "Detected corrupted host entries in $file:"; echo "$matches" | sed 's/^/  -> /'

    if [[ "${SKIP_CONFIRMATION:-}" != "1" ]]; then
        read -p "Attempt to auto-repair by removing these entries? (y/N): " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    sudo cp "$file" "$file.backup.$(date +%Y%m%d_%H%M%S)"

    # Build an awk script to skip from each matched start line until the closing '};'
    # This is a conservative heuristic based on typical formatting of mkNixosSystem blocks.
    local start_lines
    start_lines=$(echo "$matches" | cut -d: -f1 | tr '\n' ' ')

    awk -v starts="$start_lines" '
        BEGIN {
            n=split(starts, s, " ")
            for(i=1;i<=n;i++){ if (s[i] != "") skip_start[s[i]] = 1 }
        }
        {
            line_no = NR
            if (skip) {
                # End skip when we hit a line containing only "};" or a closing that ends the block
                if ($0 ~ /^[[:space:]]*};[[:space:]]*$/) {
                    skip = 0
                }
                next
            }
            if (skip_start[line_no]) {
                skip = 1
                next
            }
            print $0
        }
    ' "$file" | sudo tee "$file" > /dev/null

    success "Auto-repair applied to $file (backup created)."
    return 0
}

# Canonically reset the nixosConfigurations block to known-good entries
canonical_reset_nixos_configurations() {
    local file="$FLAKE_DIR/hosts/default.nix"
    [[ -f "$file" ]] || return 1

    warn "Performing canonical reset of nixosConfigurations in $file"
    if [[ "${SKIP_CONFIRMATION:-}" != "1" ]]; then
        read -p "This will rewrite the nixosConfigurations block. Proceed? (y/N): " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    sudo cp "$file" "$file.backup.reset.$(date +%Y%m%d_%H%M%S)"

    local have_yuki=""
    local have_minimal=""
    [[ -d "$FLAKE_DIR/hosts/yuki" ]] && have_yuki=1 || true
    [[ -d "$FLAKE_DIR/hosts/minimal" ]] && have_minimal=1 || true

    awk -v have_yuki="$have_yuki" -v have_minimal="$have_minimal" '
        BEGIN { inblock=0 }
        {
            if (!inblock) {
                print $0
                # Detect start of nixosConfigurations attrset
                if ($0 ~ /nixosConfigurations[[:space:]]*=[[:space:]]*\{[[:space:]]*$/) {
                    inblock=1
                    # Insert canonical entries on next lines
                    if (have_yuki==1) {
                        print "    yuki = mkNixosSystem {"
                        print "      hostname = \"yuki\";"
                        print "      system = \"x86_64-linux\";"
                        print "      modules = [nixosModules homeModules];"
                        print "    };"
                    }
                    if (have_minimal==1) {
                        print "    minimal = mkNixosSystem {"
                        print "      hostname = \"minimal\";"
                        print "      system = \"x86_64-linux\";"
                        print "      modules = [nixosModules];"
                        print "    };"
                    }
                }
            } else {
                # Inside block: skip everything until we reach the closing '};'
                if ($0 ~ /^[[:space:]]*};[[:space:]]*$/) {
                    print $0
                    inblock=0
                }
            }
        }
    ' "$file" | sudo tee "$file" > /dev/null

    success "nixosConfigurations block reset in $file (backup created)."
    return 0
}

# Detect CPU vendor
detect_cpu() {
    log "Detecting CPU..."
    
    if command -v lscpu &> /dev/null && lscpu | grep -qi "intel"; then
        CPU_VENDOR="intel"
        log "Detected Intel CPU"
    elif command -v lscpu &> /dev/null && lscpu | grep -qi "amd"; then
        CPU_VENDOR="amd"
        log "Detected AMD CPU"
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -qi "intel" /proc/cpuinfo; then
            CPU_VENDOR="intel"
            log "Detected Intel CPU (from /proc/cpuinfo)"
        elif grep -qi "amd" /proc/cpuinfo; then
            CPU_VENDOR="amd"
            log "Detected AMD CPU (from /proc/cpuinfo)"
        else
            CPU_VENDOR="unknown"
            warn "Unknown CPU vendor, using generic configuration"
        fi
    else
        CPU_VENDOR="unknown"
        warn "Cannot detect CPU vendor, using generic configuration"
    fi
}

# Detect GPU
detect_gpu() {
    log "Detecting GPU..."
    
    GPU_VENDORS=()
    
    # Try lspci first (most reliable method)
    if command -v lspci &> /dev/null; then
        local lspci_output
        if lspci_output=$(timeout 10 lspci 2>/dev/null); then
            if echo "$lspci_output" | grep -qi nvidia; then
                GPU_VENDORS+=("nvidia")
                log "Detected NVIDIA GPU"
            fi
            
            if echo "$lspci_output" | grep -qi "amd\|radeon"; then
                GPU_VENDORS+=("amd")
                log "Detected AMD GPU"
            fi
            
            if echo "$lspci_output" | grep -qi intel; then
                GPU_VENDORS+=("intel")
                log "Detected Intel GPU"
            fi
            
            # If lspci worked, we're done - don't try other methods
            if [[ ${#GPU_VENDORS[@]} -gt 0 ]]; then
                log "GPU detection completed via lspci"
                return 0
            fi
        else
            warn "lspci command timed out or failed, trying alternative methods"
        fi
    fi
    
    # Only check for NVIDIA driver if lspci didn't work
    if [[ -d /proc/driver/nvidia ]]; then
        GPU_VENDORS+=("nvidia")
        log "Detected NVIDIA GPU (driver present)"
        return 0
    fi
    
    # Last resort: very safe DRM detection (skip entirely in VMs if problematic)
    if [[ -d /sys/class/drm ]] && [[ "${SKIP_DRM_DETECTION:-}" != "1" ]]; then
        log "Attempting safe DRM detection (set SKIP_DRM_DETECTION=1 to skip)..."
        
        # Use find with limits to be extra safe
        local drm_files
        if drm_files=$(find /sys/class/drm -maxdepth 1 -name "card[0-9]*" -type d 2>/dev/null | head -3); then
            local drm_count=0
            
            while IFS= read -r drm && [[ $drm_count -lt 3 ]]; do
                [[ -z "$drm" ]] && continue
                
                if [[ -f "$drm/device/vendor" ]]; then
                    local vendor
                    if vendor=$(timeout 2 cat "$drm/device/vendor" 2>/dev/null); then
                        case "$vendor" in
                            "0x10de") GPU_VENDORS+=("nvidia"); log "Detected NVIDIA GPU (via DRM)" ;;
                            "0x1002") GPU_VENDORS+=("amd"); log "Detected AMD GPU (via DRM)" ;;
                            "0x8086") GPU_VENDORS+=("intel"); log "Detected Intel GPU (via DRM)" ;;
                        esac
                    fi
                fi
                ((drm_count++))
            done <<< "$drm_files"
        fi
    fi
    
    # Remove duplicates
    if [[ ${#GPU_VENDORS[@]} -gt 0 ]]; then
        readarray -t GPU_VENDORS < <(printf '%s\n' "${GPU_VENDORS[@]}" | sort -u)
        log "Final GPU detection: ${GPU_VENDORS[*]}"
    else
        warn "No supported GPU detected (common in VMs)"
        log "This is normal for virtual machines and will use minimal configuration"
    fi
}

# Generate dynamic disk configuration
generate_disk_config() {
    local hostname="$1"
    local disk="$2"
    local config_file="$FLAKE_DIR/hosts/$hostname/disk-configuration.nix"
    
    log "Generating disk configuration for $hostname using $disk"
    
    # Respect existing curated configs unless forced
    if [[ -f "$config_file" ]] && [[ "${FORCE_DISK_CONFIG:-0}" != "1" ]]; then
        log "Existing disk-configuration.nix found for $hostname, skipping generation (set FORCE_DISK_CONFIG=1 to overwrite)"
        return 0
    fi

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$config_file")"
    
    cat > "$config_file" << EOF
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "$disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = ["-f"];
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/home" = {
                    mountpoint = "/home";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
  
  # Ensure proper filesystem creation order
  fileSystems = {};
}
EOF
    
    success "Generated disk configuration: $config_file"
}

# Generate hardware configuration
generate_hardware_config() {
    local hostname="$1"
    local config_file="$FLAKE_DIR/hosts/$hostname/hardware-configuration.nix"
    local reinstall_mode="${2:-0}"  # Pass reinstall mode as parameter
    
    log "Generating hardware configuration for $hostname"
    
    # Respect existing curated configs unless forced
    if [[ -f "$config_file" ]] && [[ "${REGENERATE_HW_CONFIG:-0}" != "1" ]]; then
        log "Existing hardware-configuration.nix found for $hostname, skipping generation (set REGENERATE_HW_CONFIG=1 to overwrite)"
        return 0
    fi

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$config_file")"
    
    # For disko-based installations, we should NOT use nixos-generate-config
    # because it will conflict with disko's filesystem definitions
    log "Using manual hardware configuration (compatible with disko)"
    generate_manual_hardware_config "$hostname" "$config_file" "$reinstall_mode"
    
    success "Generated hardware configuration: $config_file"
}

# Generate manual hardware configuration (fallback)
generate_manual_hardware_config() {
    local hostname="$1"
    local config_file="$2"
    local reinstall_mode="${3:-0}"  # Pass reinstall mode as parameter
    
    log "Generating manual hardware configuration compatible with disko"
    
    # Detect hardware modules from the running system
    local kernel_modules=()
    local initrd_modules=()
    
    # Common storage and USB modules
    initrd_modules=(
        "nvme"
        "sd_mod"
        "xhci_pci"
        "ahci"
        "usb_storage"
        "usbhid"
        "sr_mod"
    )
    
    # Add SATA modules if detected
    if lspci 2>/dev/null | grep -qi "sata\|ahci"; then
        initrd_modules+=("sata_nv" "sata_via" "sata_sis" "sata_uli")
    fi
    
    # Add virtio modules for VMs
    if lspci 2>/dev/null | grep -qi "virtio\|qemu"; then
        initrd_modules+=("virtio_pci" "virtio_blk" "virtio_scsi" "virtio_net")
        log "Detected virtualized environment, adding virtio modules"
    fi
    
    # CPU-specific modules
    if [[ "$CPU_VENDOR" == "intel" ]]; then
        kernel_modules+=("kvm-intel")
    elif [[ "$CPU_VENDOR" == "amd" ]]; then
        kernel_modules+=("kvm-amd")
    fi
    
    # Generate the configuration
    cat > "$config_file" << EOF
# Generated hardware configuration for $hostname
# Generated on $(date)
# This configuration is compatible with disko disk management
{lib, ...}: {
  boot = {
    initrd = {
      availableKernelModules = [
$(printf '        "%s"\n' "${initrd_modules[@]}")
      ];
      kernelModules = [];
    };
    kernelModules = [$(printf '"%s" ' "${kernel_modules[@]}")];
EOF

    # Build kernel parameters array
    local kernel_params=("nowatchdog")
    
    # Add CPU-specific kernel parameters
    if [[ "$CPU_VENDOR" == "intel" ]]; then
        kernel_params+=("intel_pstate=active")
    elif [[ "$CPU_VENDOR" == "amd" ]]; then
        kernel_params+=("amd_pstate=active")
    fi
    
    # Add kernel parameters as a single line
    cat >> "$config_file" << EOF
    kernelParams = [$(printf '"%s" ' "${kernel_params[@]}")];
  };

  # Enable firmware loading
  hardware.enableRedistributableFirmware = lib.mkDefault true;
EOF

    # Add CPU-specific microcode updates
    if [[ "$CPU_VENDOR" == "intel" ]]; then
        cat >> "$config_file" << 'EOF'
  
  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
EOF
    elif [[ "$CPU_VENDOR" == "amd" ]]; then
        cat >> "$config_file" << 'EOF'
  
  # AMD CPU microcode updates
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
EOF
    fi

    # Add VM-specific optimizations
    if lspci 2>/dev/null | grep -qi "virtio\|qemu\|vmware\|virtualbox"; then
        cat >> "$config_file" << 'EOF'
  
  # Virtual machine optimizations
  services.qemuGuest.enable = lib.mkDefault true;
  services.spice-vdagentd.enable = lib.mkDefault true;
EOF
    fi

    # For reinstall mode, we need to handle filesystem configuration differently
    if [[ "$reinstall_mode" == "1" ]]; then
        # Extract current filesystem information and create minimal config
        log "Extracting current filesystem configuration for rebuild mode"
        
        # Get root filesystem info
        local root_fs_type=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "ext4")
        local root_device=$(findmnt -n -o SOURCE / 2>/dev/null || echo "/dev/sda1")
        
        cat >> "$config_file" << EOF
  
  # Minimal filesystem configuration for rebuild mode
  fileSystems."/" = {
    device = "$root_device";
    fsType = "$root_fs_type";
  };
EOF

        # Add boot partition if it exists
        local boot_device=$(findmnt -n -o SOURCE /boot 2>/dev/null || echo "")
        if [[ -n "$boot_device" ]]; then
            local boot_fs_type=$(findmnt -n -o FSTYPE /boot 2>/dev/null || echo "vfat")
            cat >> "$config_file" << EOF
  
  fileSystems."/boot" = {
    device = "$boot_device";
    fsType = "$boot_fs_type";
  };
EOF
        fi
    else
        cat >> "$config_file" << 'EOF'
  
  # Fresh install - filesystem configuration handled by disko
EOF
    fi

    echo "}" >> "$config_file"
    
    log "Generated hardware configuration with ${#initrd_modules[@]} initrd modules and ${#kernel_modules[@]} kernel modules"
}

# Create or update host configuration
setup_host_config() {
    local hostname="$1"
    local host_dir="$FLAKE_DIR/hosts/$hostname"
    local host_config="$host_dir/default.nix"
    local reinstall_mode="${2:-0}"  # Pass reinstall mode as parameter
    
    log "Setting up host configuration for $hostname"
    
    # If a curated host config already exists, don't overwrite unless forced
    if [[ -f "$host_config" ]] && [[ "${REGENERATE_HOST:-0}" != "1" ]]; then
        log "Existing host configuration detected at $host_config, skipping (set REGENERATE_HOST=1 to overwrite)"
        return 0
    fi

    # Create directory if it doesn't exist
    mkdir -p "$host_dir"
    
    # Determine if this should be a minimal or full config
    local config_type="full"
    # Only use minimal for explicitly named "minimal" hostname, not for missing GPU
    if [[ "$hostname" == "minimal" ]]; then
        config_type="minimal"
    fi
    
    if [[ "$config_type" == "minimal" ]]; then
        cat > "$host_config" << EOF
{pkgs, lib, ...}: {
  imports = [
EOF
        # Only import disk configuration for fresh installs
        if [[ "$reinstall_mode" != "1" ]]; then
            echo "    ./disk-configuration.nix" >> "$host_config"
        fi
        
        cat >> "$host_config" << EOF
    ./hardware-configuration.nix
    
    # Essential system configuration (includes bootloader)
    ../config/system
    ../config/nix
    ../config/security
    ../config/services
    
    # Basic desktop services for minimal config
    ./services/greetd.nix
    ./services/dbus.nix
    ./services/pipewire.nix
  ];

  boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;
  
  # Enable basic graphics for minimal config
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
EOF

        # In reinstall mode, disable bootloader installation to avoid conflicts
        if [[ "$reinstall_mode" == "1" ]]; then
            cat >> "$host_config" << 'EOF'
  
  # Disable bootloader installation in reinstall mode - use existing bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
EOF
        fi

        # Only enable btrfs.autoScrub for fresh installs with btrfs
        if [[ "$reinstall_mode" != "1" ]]; then
            echo "  services.btrfs.autoScrub.enable = true;" >> "$host_config"
        fi
        
        echo "}" >> "$host_config"
    else
        # Full configuration with hardware-specific imports
        cat > "$host_config" << 'EOF'
{pkgs, lib, ...}: {
  imports = [
EOF
        # Only import disk configuration for fresh installs
        if [[ "$reinstall_mode" != "1" ]]; then
            echo "    ./disk-configuration.nix" >> "$host_config"
        fi
        
        cat >> "$host_config" << 'EOF'
    ./hardware-configuration.nix
    ./power-management.nix

    # Essential system configuration (includes bootloader)
    ../config/system
    ../config/nix
    ../config/security
    ../config/services
    ../config/shell

    ./programs/dconf.nix
    ./programs/gnupg.nix
    ./programs/thunar.nix
    ./services/blueman.nix
    ./services/dbus.nix
    ./services/gnome-keyring.nix
    ./services/greetd.nix
    ./services/gvfs.nix
    ./services/pipewire.nix
    ./virtualisation/containers.nix
    ./virtualisation/docker.nix

    ../config/fonts
    ../config/hardware/bluetooth
    ../config/hardware/ssd
    ../config/window-managers/hyprland
EOF

        # Add CPU-specific imports
        if [[ "$CPU_VENDOR" == "intel" ]]; then
            echo "    ../config/hardware/cpu/intel" >> "$host_config"
        elif [[ "$CPU_VENDOR" == "amd" ]]; then
            echo "    ../config/hardware/cpu/amd" >> "$host_config"
        fi
        
        # Add GPU-specific imports
        for gpu in "${GPU_VENDORS[@]}"; do
            echo "    ../config/hardware/gpu/$gpu" >> "$host_config"
        done
        
        cat >> "$host_config" << 'EOF'
  ];

  boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;
EOF

        # In reinstall mode, disable bootloader installation to avoid conflicts
        if [[ "$reinstall_mode" == "1" ]]; then
            cat >> "$host_config" << 'EOF'
  
  # Disable bootloader installation in reinstall mode - use existing bootloader
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
EOF
        fi

        cat >> "$host_config" << 'EOF'

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services = {
    fwupd.enable = true;
EOF

        # Only enable btrfs.autoScrub for fresh installs with btrfs
        if [[ "$reinstall_mode" != "1" ]]; then
            echo "    btrfs.autoScrub.enable = true;" >> "$host_config"
        fi
        
        cat >> "$host_config" << 'EOF'
  };
EOF

        # Add GPU-specific configuration
        if [[ " ${GPU_VENDORS[*]} " =~ " nvidia " ]]; then
            cat >> "$host_config" << 'EOF'

  # NVIDIA Configuration
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia-container-toolkit.enable = true;
EOF
        fi
        
        echo "}" >> "$host_config"
    fi
    
    success "Generated host configuration: $host_config"
}

# Create required service files
create_service_files() {
    local hostname="$1"
    local host_dir="$FLAKE_DIR/hosts/$hostname"
    
    log "Creating required service configuration files..."
    
    # Create minimal service files to avoid import errors
    local services=(
        "programs/dconf.nix"
        "programs/gnupg.nix" 
        "programs/thunar.nix"
        "services/blueman.nix"
        "services/dbus.nix"
        "services/gnome-keyring.nix"
        "services/greetd.nix"
        "services/gvfs.nix"
        "services/pipewire.nix"
        "virtualisation/containers.nix"
        "virtualisation/docker.nix"
        "power-management.nix"
    )
    
    for service in "${services[@]}"; do
        local service_file="$host_dir/$service"
        mkdir -p "$(dirname "$service_file")"
        
        if [[ ! -f "$service_file" ]]; then
            echo "{}" > "$service_file"
        fi
    done
}

# Update flake to include new host
update_flake_config() {
    local hostname="$1"
    
    log "Updating flake configuration to include $hostname"
    
    # Ensure host directory exists
    if [[ ! -d "$FLAKE_DIR/hosts/$hostname" ]]; then
        warn "Host directory hosts/$hostname does not exist; skipping flake update"
        return
    fi

    # Check if hostname already exists in nixosConfigurations block (quoted or unquoted)
    if grep -Eq "(^|[^A-Za-z0-9_])$hostname[[:space:]]*=[[:space:]]*mkNixosSystem" "$FLAKE_DIR/hosts/default.nix" \
       || grep -Fq '"'$hostname'" = mkNixosSystem' "$FLAKE_DIR/hosts/default.nix"; then
        log "Host $hostname already exists in flake configuration"
        return
    fi

    # Insert the new host into the nixosConfigurations attribute set
    # We locate the nixosConfigurations = { ... }; block and inject before its closing brace
    local src="$FLAKE_DIR/hosts/default.nix"
    local tmp
    tmp=$(mktemp) || error "Failed to create temporary file"

    awk -v hostname="$hostname" '
        BEGIN { in_nixos = 0; brace = 0 }
        {
            line = $0
            # Detect start of nixosConfigurations block
            if (in_nixos == 0 && line ~ /(^|[^a-zA-Z0-9_])nixosConfigurations[[:space:]]*=[[:space:]]*\{/ ) {
                in_nixos = 1
                brace = 1
                print line
                next
            }
            if (in_nixos == 1) {
                # Track nested braces within the block
                openCount = gsub(/\{/, "{", line)
                closeCount = gsub(/\}/, "}", line)
                brace += openCount - closeCount

                # If this line closes the nixosConfigurations block (brace == 0 after processing),
                # inject our host before printing the closing line
                if (brace == 0) {
                    print "    \"" hostname "\" = mkNixosSystem {"
                    print "      hostname = \"" hostname "\";"
                    print "      system = \"x86_64-linux\";"
                    print "      modules = [nixosModules homeModules];"
                    print "    };"
                    print line
                    in_nixos = 0
                    next
                }
            }
            print line
        }
    ' "$src" > "$tmp" || error "Failed to update flake hosts/default.nix"

    mv "$tmp" "$src"
    success "Updated flake configuration to include host: $hostname"
}

# Set up flake integration for existing system
setup_flake_integration() {
    local hostname="$1"
    
    log "Setting up flake integration for existing system..."
    
    # Create /etc/nixos directory if it doesn't exist
    sudo mkdir -p /etc/nixos
    
    # Backup existing configuration if it exists
    if [[ -f /etc/nixos/configuration.nix ]]; then
        log "Backing up existing configuration.nix..."
        sudo mv /etc/nixos/configuration.nix /etc/nixos/configuration.nix.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Copy our entire flake to /etc/nixos for direct use
    log "Copying Snowflake configuration to /etc/nixos..."
    sudo cp -r "$FLAKE_DIR"/* /etc/nixos/
    
    # Ensure proper permissions
    sudo chown -R root:root /etc/nixos
    sudo chmod -R 644 /etc/nixos
    sudo chmod 755 /etc/nixos /etc/nixos/hosts /etc/nixos/home /etc/nixos/flake
    sudo find /etc/nixos -type d -exec chmod 755 {} \;
    sudo find /etc/nixos -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    
    # Initialize the flake in /etc/nixos
    log "Initializing flake in /etc/nixos..."
    cd /etc/nixos

    # Initialize/lock flake without leaking HOME from the caller
    if ! sudo -H nix --extra-experimental-features 'nix-command flakes' flake lock; then
        error "Failed to initialize flake in /etc/nixos"
    fi
    
    # Verify flake is working
    log "Verifying flake configuration..."
    local _flake_tmp
    _flake_tmp=$(mktemp)
    if sudo -H nix --extra-experimental-features 'nix-command flakes' flake show . > "$_flake_tmp" 2>/dev/null; then
        if grep -q "nixosConfigurations\.$hostname" "$_flake_tmp"; then
            log "✅ Flake contains $hostname configuration"
        else
            warn "⚠️  $hostname configuration not found in flake"
            log "Available configurations:"
            sed -n '/nixosConfigurations/,$p' "$_flake_tmp" | head -n 30 || true
        fi
    else
        warn "⚠️  Failed to evaluate flake in /etc/nixos"
    fi
    rm -f "$_flake_tmp" 2>/dev/null || true
    
    success "Flake integration configured - system will use /etc/nixos flake"
}

# In rebuild mode, disable bootloader installation by injecting a small module into the
# copied flake at /etc/nixos for curated hosts (so bootloader checks do not fail when /boot isn't mounted).
disable_bootloader_in_rebuild() {
    local hostname="$1"
    local host_dir="/etc/nixos/hosts/$hostname"
    local host_default="$host_dir/default.nix"
    local overlay="$host_dir/_reinstall-disable-boot.nix"

    [[ -f "$host_default" ]] || return 0

    sudo mkdir -p "$host_dir"
    if [[ ! -f "$overlay" ]]; then
        sudo tee "$overlay" > /dev/null <<'EOF'
{ lib, ... }: {
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
}
EOF
    fi

    # If the overlay isn't imported yet, append it to the imports list
    if ! grep -q "_reinstall-disable-boot\.nix" "$host_default"; then
        sudo cp "$host_default" "$host_default.backup.$(date +%Y%m%d_%H%M%S)"
        # Insert after the first 'imports = [' occurrence
        sudo sed -i '/imports[[:space:]]*=[[:space:]]*\[/a\    .\/_reinstall-disable-boot.nix' "$host_default"
    fi
}

# Partition and format disks
setup_disks() {
    local hostname="$1"
    
    log "Setting up disks using disko..."
    
    # Check memory before disk operations
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    log "Available memory before disk setup: $(( available_mem / 1024 ))MB"
    
    # Ensure target disk is not mounted
    log "Unmounting any existing partitions on $TARGET_DISK..."
    sudo umount ${TARGET_DISK}* 2>/dev/null || true
    
    # Wipe any existing filesystem signatures
    log "Wiping filesystem signatures on $TARGET_DISK..."
    sudo wipefs -af "$TARGET_DISK" 2>/dev/null || true
    
    # Wait for kernel to update partition table
    sudo partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
    
    # Change to flake directory
    cd "$FLAKE_DIR" || error "Failed to change to flake directory: $FLAKE_DIR"
    
    # Format the disk using disko
    log "Partitioning and formatting $TARGET_DISK..."

    # Pre-validate flake host to fail fast with actionable error if broken
    log "Validating flake host '.#$hostname' before disko..."
    if ! nix --extra-experimental-features 'nix-command flakes' flake show ".#$hostname" >/dev/null 2>&1; then
        warn "Flake evaluation failed for host '$hostname'. Attempting auto-repair..."
        if attempt_repair_flake_hosts_file; then
            log "Retrying flake evaluation after repair..."
            if nix --extra-experimental-features 'nix-command flakes' flake show ".#$hostname" >/dev/null 2>&1; then
                :
            else
                warn "Auto-repair failed. Attempting canonical reset of nixosConfigurations..."
                if canonical_reset_nixos_configurations; then
                    log "Retrying flake evaluation after canonical reset..."
                    if ! nix --extra-experimental-features 'nix-command flakes' flake show ".#$hostname" >/dev/null 2>&1; then
                        error "Flake evaluation still failing after canonical reset.\nRun: nix --extra-experimental-features 'nix-command flakes' flake show . | cat\nand ensure 'hosts/default.nix' is valid. You can restore it with: git checkout -- hosts/default.nix"
                    fi
                else
                    error "Flake evaluation failed and canonical reset declined.\nRestore hosts/default.nix (git checkout -- hosts/default.nix) and rerun."
                fi
            fi
        else
            warn "Auto-repair declined or not applicable. Offering canonical reset..."
            if canonical_reset_nixos_configurations; then
                log "Retrying flake evaluation after canonical reset..."
                if ! nix --extra-experimental-features 'nix-command flakes' flake show ".#$hostname" >/dev/null 2>&1; then
                    error "Flake evaluation still failing after canonical reset.\nRun: nix --extra-experimental-features 'nix-command flakes' flake show . | cat\nand ensure 'hosts/default.nix' is valid. You can restore it with: git checkout -- hosts/default.nix"
                fi
            else
                error "Flake evaluation failed for host '$hostname'.\nRun: nix --extra-experimental-features 'nix-command flakes' flake show . | cat\nand ensure 'hosts/default.nix' has no invalid entries. If you see lines like 'SKIP_DRM_DETECTION=1 = mkNixosSystem', restore the file (git checkout -- hosts/default.nix) and rerun."
            fi
        fi
    fi
    
    # Run disko with timeout and better error handling
    if timeout 300 sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --flake ".#$hostname" 2>&1; then
        success "Disk partitioning completed successfully"
        
        # Wait for device nodes to be created
        log "Waiting for device nodes to be created..."
        sleep 3
        
        # Verify that the target disk is properly mounted
        log "Verifying disk mounts..."
        if mountpoint -q /mnt; then
            log "Root filesystem mounted at /mnt"
            # Show mount info for verification
            local mount_device=$(findmnt -n -o SOURCE /mnt 2>/dev/null || echo "unknown")
            log "Root mount source: $mount_device"
            
            # Check available space on target disk
            local available_space=$(df -h /mnt 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
            log "Available space on target: $available_space"
        else
            error "Target disk not mounted at /mnt after disko setup. Check disko configuration."
        fi
        
        # Verify boot partition is mounted
        if mountpoint -q /mnt/boot; then
            log "Boot partition mounted at /mnt/boot"
        else
            warn "Boot partition not mounted at /mnt/boot (this may be normal for some configurations)"
        fi
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            error "Disk setup timed out after 5 minutes. The disk might be too slow or the network connection is poor."
        else
            error "Disk setup failed with exit code $exit_code."
            log "This could be caused by:"
            log "  - Disk $TARGET_DISK is in use or mounted"
            log "  - Insufficient permissions"
            log "  - Hardware or virtualization issues"
            log "  - Network connectivity problems"
            
            # Show some diagnostic information
            log "Disk information:"
            lsblk "$TARGET_DISK" 2>/dev/null || log "  Cannot read disk information"
            
            log "Mount information:"
            mount | grep "$TARGET_DISK" || log "  No mounts found for $TARGET_DISK"
        fi
        return 1
    fi
    
    success "Disk setup completed"
}

# Install NixOS
install_nixos() {
    local hostname="$1"
    
    log "Installing NixOS configuration for $hostname..."
    
    # Verify we have a properly mounted target
    if ! mountpoint -q /mnt; then
        error "Target filesystem not mounted at /mnt. Run disk setup first."
    fi
    
    # Check available space on target disk (not the live environment)
    local available_space_kb=$(df --output=avail /mnt | tail -1)
    local available_space_mb=$((available_space_kb / 1024))
    log "Available space on target disk: ${available_space_mb}MB"
    
    if [[ $available_space_mb -lt 2048 ]]; then  # Less than 2GB
        error "Insufficient space on target disk. Need at least 2GB, found ${available_space_mb}MB"
    fi
    
    # Check memory before installation
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    log "Available memory before NixOS installation: $(( available_mem / 1024 ))MB"
    
    cd "$FLAKE_DIR" || error "Failed to change to flake directory: $FLAKE_DIR"
    
    # Copy the flake configuration to target system for future rebuilds
    log "Copying flake configuration to target system..."
    sudo mkdir -p /mnt/etc/nixos
    sudo cp -r "$FLAKE_DIR"/* /mnt/etc/nixos/
    sudo chown -R root:root /mnt/etc/nixos
    sudo chmod -R 644 /mnt/etc/nixos
    sudo chmod 755 /mnt/etc/nixos /mnt/etc/nixos/hosts /mnt/etc/nixos/home /mnt/etc/nixos/flake
    sudo find /mnt/etc/nixos -type d -exec chmod 755 {} \;
    
    # Install NixOS with the flake configuration to the mounted target
    log "Running: sudo nixos-install --root /mnt --flake \".#$hostname\" --no-root-passwd"
    
    if ! sudo nixos-install --root /mnt --flake ".#$hostname" --no-root-passwd 2>&1; then
        error "NixOS installation failed. Check the above output for specific errors."
    fi
    
    success "NixOS installation completed"
}

# Rebuild NixOS configuration (for already installed systems)
rebuild_nixos() {
    local hostname="$1"
    
    log "Rebuilding NixOS configuration for $hostname..."
    
    # Check available space on root filesystem
    local available_space_kb=$(df --output=avail / | tail -1)
    local available_space_mb=$((available_space_kb / 1024))
    log "Available space on root filesystem: ${available_space_mb}MB"
    
    if [[ $available_space_mb -lt 1024 ]]; then  # Less than 1GB
        warn "Low disk space detected: ${available_space_mb}MB. Rebuild may fail."
    fi
    
    cd "$FLAKE_DIR" || error "Failed to change to flake directory: $FLAKE_DIR"
    
    # Show current system info before rebuild
    log "Current system info before rebuild:"
    if [[ -f /run/current-system/nixos-version ]]; then
        log "  Current NixOS version: $(cat /run/current-system/nixos-version)"
    fi
    
    # Rebuild and switch to the new configuration
    log "Running: sudo nixos-rebuild switch --flake \"/etc/nixos#$hostname\""

    # Change to /etc/nixos to ensure we're using the copied flake
    cd /etc/nixos || error "Failed to change to /etc/nixos directory"

    # Use the flake from /etc/nixos directly
    if ! sudo -H nixos-rebuild switch --flake ".#$hostname" --option experimental-features 'nix-command flakes'; then
        warn "Flake rebuild failed, trying with explicit path..."
        # Try with explicit path as fallback
    if ! sudo -H nixos-rebuild switch --flake "/etc/nixos#$hostname" --option experimental-features 'nix-command flakes'; then
            error "NixOS configuration rebuild failed with both methods. Check the above output for specific errors."
        fi
    fi
    
    # Change back to original directory
    cd "$FLAKE_DIR" || warn "Could not change back to original flake directory"
    
    # Verify the rebuild was successful
    log "Verifying rebuild success..."
    
    # Show current generations and what we're running
    log "Current system information:"
    log "- Current kernel: $(uname -r)"
    log "- Current hostname: $(hostname)"
    log "- Current user: $(whoami)"
    
    if [[ -f /run/current-system/nixos-version ]]; then
        log "- NixOS version: $(cat /run/current-system/nixos-version)"
    fi
    
    # Check if our configuration files are in place
    local config_path="/etc/nixos"
    if [[ -L "$config_path" ]]; then
        log "- Configuration symlink target: $(readlink -f "$config_path")"
    elif [[ -d "$config_path" ]]; then
        log "- Configuration directory exists at: $config_path"
        if [[ -f "$config_path/flake.nix" ]]; then
            log "- Flake configuration found in /etc/nixos"
        fi
    fi
    
    # Show current system path
    if [[ -L /run/current-system ]]; then
        log "- Current system path: $(readlink -f /run/current-system)"
    fi
    
    # Show system generations
    log "System generations (last 3):"
    if command -v nixos-rebuild &> /dev/null; then
        nixos-rebuild list-generations 2>/dev/null | tail -3 | while read -r line; do
            log "  $line"
        done
    fi
    if command -v nix-env &> /dev/null; then
        sudo -H nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -3 | while read -r line; do
            log "  $line"
        done
    fi
    
    # Check for indicators of our configuration
    log "Configuration indicators:"
    
    # Check for Xanmod kernel
    if uname -r | grep -q "xanmod"; then
        log "- ✅ Xanmod kernel is active"
    else
        log "- ⚠️  Standard kernel detected (Xanmod not active yet)"
    fi
    
    # Check for correct hostname
    if [[ "$(hostname)" == "$hostname" ]]; then
        log "- ✅ Hostname is correct: $hostname"
    else
        log "- ⚠️  Hostname mismatch. Expected: $hostname, Current: $(hostname)"
    fi
    
    # Debug: Check what configuration is actually being used
    log "Debug: Checking system configuration source..."
    
    # Check if there's a flake.lock in current system
    current_system_path=$(readlink -f /run/current-system 2>/dev/null || echo "unknown")
    log "- Current system derivation: $current_system_path"
    
    # Check if the system was built from a flake
    if [[ -f /run/current-system/etc/os-release ]]; then
        version_info=$(grep BUILD_ID /run/current-system/etc/os-release 2>/dev/null || echo "No BUILD_ID found")
        log "- System BUILD_ID: $version_info"
    fi
    
    # Check what's in /etc/nixos
    if [[ -d /etc/nixos ]]; then
        log "- Files in /etc/nixos:"
        ls -la /etc/nixos | while read -r line; do
            log "    $line"
        done
    fi
    
    # Most importantly: Check if the system will use our flake on next rebuild
    log "- Testing flake resolution:"
    if cd /etc/nixos && nix --extra-experimental-features 'nix-command flakes' flake show >/dev/null 2>&1; then
        log "  ✅ Flake is valid and accessible"
    else
        log "  ⚠️  Flake may not be properly accessible"
    fi
    
    success "NixOS configuration rebuild completed"
    
    # Important notice about configuration changes
    if ! uname -r | grep -q "xanmod"; then
        log ""
        log "⚠️  IMPORTANT: Configuration changes may require a reboot to take effect."
        log "   The Xanmod kernel and other system changes will be active after reboot."
        log "   Current kernel: $(uname -r)"
        log ""
    fi
    
    log "📋 VERIFICATION: You can run './verify-install.sh' to check if the configuration applied correctly."
    log "   Copy this script to your VM and run it after reboot to verify the installation."
}

# Set up user password
setup_user() {
    log "Setting up user password..."
    
    # Set password for the nixos user in the new system
    echo "Please set a password for the 'jager' user:"
    sudo nixos-enter --root /mnt -c 'passwd jager'
    
    success "User setup completed"
}

# Validate hostname
validate_hostname() {
    local hostname="$1"

    # Disallow empty and KEY=VALUE patterns passed as positional args
    if [[ -z "$hostname" ]]; then
        error "Hostname cannot be empty"
    fi
    if [[ "$hostname" == *"="* ]]; then
        error "Invalid hostname '$hostname'. To set env vars, prefix them: VAR=VALUE ./install.sh [hostname] [disk]"
    fi

    # Enforce valid chars: letters, digits, hyphens; must start/end alphanumeric
    if [[ ! "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
        error "Invalid hostname format: $hostname (use letters, digits, hyphens; must start/end with alphanumeric)"
    fi

    # Check hostname length
    if [[ ${#hostname} -gt 63 ]]; then
        error "Hostname too long (max 63 characters): $hostname"
    fi

    log "Hostname validation passed: $hostname"
}

# Main installation process
main() {
    # Sanitize accidental KEY=VALUE tokens passed positionally
    local _args=()
    for _a in "$@"; do
        if [[ "$_a" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            warn "Ignoring positional token '$_a'. To set env vars, prefix them before the command."
            continue
        fi
        _args+=("$_a")
    done

    local hostname="${_args[0]:-$DEFAULT_HOSTNAME}"
    local target_disk="${_args[1]:-}"
    
    log "Starting Snowflake NixOS installation..."
    log "Hostname: $hostname"

    # Detect environment: live ISO vs installed system
    local reinstall_mode
    reinstall_mode="${REINSTALL_MODE:-}"

    detect_environment() {
        local fs_type
        fs_type=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
        local cur_user cur_host root_src
        cur_user=$(whoami 2>/dev/null || echo "unknown")
        cur_host=$(hostname 2>/dev/null || echo "unknown")
        root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")

        log "Environment probe: root.fs=$fs_type root.src=$root_src user=$cur_user host=$cur_host"

        # Heuristics: NixOS live ISO typically has root on overlay (with squashfs lower)
        # Treat overlay/squashfs/tmpfs root as live installer environment
        case "$fs_type" in
            overlay|squashfs|tmpfs)
                echo "live"
                return 0
                ;;
        esac

        # Additional weak signal: default live host/user is often 'nixos'
        if [[ "$cur_user" == "nixos" || "$cur_host" == "nixos" ]]; then
            echo "live"
            return 0
        fi

        echo "installed"
    }

    if [[ -z "$reinstall_mode" ]]; then
        local env_kind
        env_kind=$(detect_environment)
        if [[ "$env_kind" == "installed" ]]; then
            log "Detected already installed NixOS system"
            log "Automatically enabling reinstall mode (use REINSTALL_MODE=0 to override)"
            reinstall_mode="1"
        else
            log "Detected NixOS live installer environment"
            reinstall_mode="0"
        fi
    fi

    if [[ "$reinstall_mode" == "1" ]]; then
        log "Running in configuration rebuild mode (no disk partitioning)"
    else
        log "Running in fresh install mode (will partition target disk)"
    fi
    
    # Enable debug mode if requested
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "Debug mode enabled"
        set -x
    fi
    

    log "Step 1: Checking if running as root..."
    check_root

    log "Step 1.5: Ensuring home directory ownership..."
    local current_user
    current_user=$(whoami)
    local home_dir="/home/$current_user"
    if [[ -d "$home_dir" ]]; then
        owner=$(stat -c '%U' "$home_dir")
        if [[ "$owner" != "$current_user" ]]; then
            warn "Home directory $home_dir is owned by $owner, changing ownership to $current_user..."
            if sudo chown -R "$current_user:$current_user" "$home_dir"; then
                success "Changed ownership of $home_dir to $current_user."
            else
                error "Failed to change ownership of $home_dir to $current_user."
            fi
        fi
    fi

    log "Step 2: Checking prerequisites..."
    check_prerequisites

    log "Step 2.1: Checking flake host definitions integrity..."
    sanity_check_flake_hosts_file

    log "Step 3: Validating hostname..."
    validate_hostname "$hostname"
    
    if [[ "$reinstall_mode" != "1" ]]; then
        log "Step 4: Detecting storage devices..."
        detect_storage "$target_disk"
    else
        log "Step 4: Skipping storage detection (reinstall mode)"
        TARGET_DISK="${target_disk:-/dev/sda}"  # Dummy value for config generation
    fi
    
    log "Step 5: Detecting CPU..."
    detect_cpu
    
    log "Step 6: Detecting GPU..."
    detect_gpu
    
    log "Hardware summary:"
    log "  CPU: $CPU_VENDOR"
    log "  GPU: ${GPU_VENDORS[*]:-none}"
    if [[ "$reinstall_mode" != "1" ]]; then
        log "  Target disk: $TARGET_DISK"
    fi
    
    # Confirm installation/rebuild
    echo
    if [[ "$reinstall_mode" == "1" ]]; then
        warn "This will rebuild the NixOS configuration and switch to it!"
    else
        warn "This will COMPLETELY ERASE $TARGET_DISK and install NixOS!"
    fi
    
    if [[ "${SKIP_CONFIRMATION:-}" != "1" ]]; then
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Installation cancelled"
        fi
    else
        log "Skipping confirmation (SKIP_CONFIRMATION=1)"
    fi
    
    # Generate configurations
    log "Step 7: Generating disk configuration..."
    generate_disk_config "$hostname" "$TARGET_DISK"
    
    log "Step 8: Generating hardware configuration..."
    generate_hardware_config "$hostname" "$reinstall_mode"
    
    log "Step 9: Setting up host configuration..."
    setup_host_config "$hostname" "$reinstall_mode"
    
    log "Step 10: Creating service files..."
    create_service_files "$hostname"
    
    log "Step 11: Updating flake configuration..."
    update_flake_config "$hostname"
    
    # In reinstall mode, ensure the system uses our flake configuration
    if [[ "$reinstall_mode" == "1" ]]; then
        log "Step 11.5: Setting up flake integration for existing system..."
        setup_flake_integration "$hostname"
    log "Step 11.6: Disabling bootloader installation for rebuild mode..."
    disable_bootloader_in_rebuild "$hostname"
    fi
    
    # Install or rebuild system
    if [[ "$reinstall_mode" == "1" ]]; then
        log "Step 12: Rebuilding NixOS configuration..."
        rebuild_nixos "$hostname"
        
        # Additional verification steps
        log "Performing post-rebuild verification..."
        
        # Check if the flake configuration is being used
        if [[ -f /etc/nixos/flake.nix ]]; then
            log "Flake configuration found at /etc/nixos/flake.nix"
        else
            warn "No flake.nix found in /etc/nixos - system may be using legacy configuration"
        fi
        
        # Check what configuration files are in /etc/nixos
        log "Configuration files in /etc/nixos:"
        sudo ls -la /etc/nixos/ | while read -r line; do
            log "  $line"
        done
        
        # Check if the system is using our kernel
        local current_kernel=$(uname -r)
        log "Current kernel: $current_kernel"
        if [[ "$current_kernel" == *"xanmod"* ]]; then
            log "✓ System is using Xanmod kernel (configuration applied)"
        else
            warn "⚠ System is not using Xanmod kernel (configuration may not be applied)"
        fi
        
        # Check if our hostname was applied
        local current_hostname=$(hostname)
        if [[ "$current_hostname" == "$hostname" ]]; then
            log "✓ Hostname correctly set to: $current_hostname"
        else
            warn "⚠ Hostname mismatch: expected '$hostname', got '$current_hostname'"
        fi
        
        # Check the current system generation
        local current_gen=$(sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -1)
        log "Current system generation: $current_gen"
        
        # Check what flake the system was built from
        if [[ -L /run/current-system ]]; then
            local system_path=$(readlink -f /run/current-system)
            log "Current system path: $system_path"
            
            # Check if the system was built with a flake
            if [[ -f "$system_path/etc/nix/registry.json" ]]; then
                log "System appears to be flake-based"
            else
                warn "System may not be flake-based"
            fi
        fi
        
        # Check if systemd services are active
        log "Checking critical services..."
        if systemctl is-active --quiet systemd-logind; then
            log "✓ systemd-logind is active"
        else
            warn "⚠ systemd-logind is not active"
        fi
        
        success "Configuration rebuild completed successfully!"
        log "The new configuration is now active."
        
        # If verification shows the config didn't apply, offer to force rebuild
        local needs_force_rebuild=false
        
        local current_kernel=$(uname -r)
        if [[ "$current_kernel" != *"xanmod"* ]]; then
            warn "Configuration may not have applied properly (kernel not changed)"
            needs_force_rebuild=true
        fi
        
        if [[ "$needs_force_rebuild" == "true" ]]; then
            log "Attempting force rebuild to ensure configuration is applied..."
            
            # Force rebuild with explicit profile switching
            if sudo nixos-rebuild switch --flake ".#$hostname" --install-bootloader 2>&1; then
                log "Force rebuild completed"
            else
                warn "Force rebuild failed, but basic rebuild succeeded"
            fi
        fi
        
        log "Reboot to ensure all changes take effect."
        
        # Ask if user wants to reboot now
        if [[ "${SKIP_CONFIRMATION:-}" != "1" ]]; then
            echo
            read -p "Would you like to reboot now to ensure all changes are applied? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log "Rebooting system..."
                sudo reboot
            else
                log "Reboot skipped. Please reboot manually when convenient."
            fi
        fi
    else
        log "Step 12: Setting up disks..."
        setup_disks "$hostname"
        
        log "Step 13: Installing NixOS..."
        install_nixos "$hostname"
        
        log "Step 14: Setting up user..."
        setup_user
        
        success "Installation completed successfully!"
        log "The system will be available after reboot."
        log "Remove the installation media and reboot to start using your new NixOS system."
    fi
}

# Handle script arguments
show_usage() {
    echo "Snowflake NixOS Installer"
    echo
    echo "Usage: $0 [hostname] [target_disk]"
    echo
    echo "Arguments:"
    echo "  hostname     - Hostname for the new system (default: $DEFAULT_HOSTNAME)"
    echo "  target_disk  - Target disk for installation (auto-detected if not specified)"
    echo
    echo "Environment Variables:"
    echo "  FLAKE_DIR              - Path to flake directory (default: script directory)"
    echo "  SKIP_NIXOS_CHECK=1     - Skip NixOS installer environment check"
    echo "  SKIP_INTERNET_CHECK=1  - Skip internet connectivity check"
    echo "  SKIP_CONFIRMATION=1    - Skip installation confirmation prompt"
    echo "  SKIP_DRM_DETECTION=1   - Skip DRM GPU detection (useful for VMs)"
    echo "  REINSTALL_MODE=1       - Force rebuild mode on installed system"
    echo "  REINSTALL_MODE=0       - Force fresh install mode (ignores auto-detection)"
    echo "  DEBUG=1                - Enable debug mode with verbose output"
    echo "  FORCE_DISK_CONFIG=1    - Overwrite existing disk-configuration.nix"
    echo "  REGENERATE_HW_CONFIG=1 - Overwrite existing hardware-configuration.nix"
    echo "  REGENERATE_HOST=1      - Overwrite existing hosts/<name>/default.nix"
    echo
    echo "Examples:"
    echo "  $0                           # Use defaults"
    echo "  $0 myhostname               # Custom hostname"
    echo "  $0 myhostname /dev/sda      # Custom hostname and disk"
    echo "  FLAKE_DIR=/path/to/flake $0 # Custom flake location"
    echo "  DEBUG=1 $0                  # Enable debug mode"
    echo "  SKIP_CONFIRMATION=1 $0      # Skip confirmation prompt"
    echo "  REINSTALL_MODE=1 $0         # Run on already installed system"
    echo "  SKIP_DRM_DETECTION=1 $0     # Skip GPU detection for VMs"
    echo
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        -h|--help|help)
            show_usage
            exit 0
            ;;
        *)
            main "$@"
            ;;
    esac
fi
