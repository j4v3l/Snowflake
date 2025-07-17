#!/usr/bin/env bash

# Snowflake NixOS Installer
# Automated installer with hardware detection and disk setup
# Usage: ./install.sh [hostname] [target_disk]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FLAKE_DIR="/home/nixos/Snowflake"
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
    
    # Check if we're in NixOS installer environment
    if [[ ! -f /etc/NIXOS ]]; then
        error "This script must be run from a NixOS installer environment"
    fi
    
    # Check if flake directory exists
    if [[ ! -d "$FLAKE_DIR" ]]; then
        error "Flake directory not found: $FLAKE_DIR"
    fi
    
    # Check if we have internet connectivity
    if ! ping -c 1 nixos.org &> /dev/null; then
        error "No internet connection. Internet is required for installation."
    fi
    
    # Check if nix command is available
    if ! command -v nix &> /dev/null; then
        error "Nix command not found. Make sure you're running this in a NixOS environment."
    fi
    
    success "Prerequisites check passed"
}

# Detect available storage devices
detect_storage() {
    log "Detecting storage devices..."
    
    # List all block devices
    lsblk -d -n -o NAME,SIZE,TYPE | grep -E "(disk|nvme)" | while read -r name size type; do
        echo "  /dev/${name} (${size})"
    done
    
    # Auto-select the largest available disk
    LARGEST_DISK=$(lsblk -d -n -o NAME,SIZE -b | grep -E "(nvme|sd)" | sort -k2 -nr | head -1 | awk '{print "/dev/" $1}')
    
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
    
    # Try lspci first
    if command -v lspci &> /dev/null; then
        if lspci | grep -qi nvidia; then
            GPU_VENDORS+=("nvidia")
            log "Detected NVIDIA GPU"
        fi
        
        if lspci | grep -qi "amd\|radeon"; then
            GPU_VENDORS+=("amd")
            log "Detected AMD GPU"
        fi
        
        if lspci | grep -qi intel; then
            GPU_VENDORS+=("intel")
            log "Detected Intel GPU"
        fi
    # Fallback to DRM detection
    elif [[ -d /sys/class/drm ]]; then
        log "Using DRM detection for GPU..."
        for drm in /sys/class/drm/card*; do
            if [[ -f "$drm/device/vendor" ]]; then
                local vendor=$(cat "$drm/device/vendor" 2>/dev/null || echo "")
                case "$vendor" in
                    "0x10de") GPU_VENDORS+=("nvidia"); log "Detected NVIDIA GPU (via DRM)" ;;
                    "0x1002") GPU_VENDORS+=("amd"); log "Detected AMD GPU (via DRM)" ;;
                    "0x8086") GPU_VENDORS+=("intel"); log "Detected Intel GPU (via DRM)" ;;
                esac
            fi
        done
    # Check for NVIDIA driver
    elif [[ -d /proc/driver/nvidia ]]; then
        GPU_VENDORS+=("nvidia")
        log "Detected NVIDIA GPU (driver present)"
    fi
    
    # Remove duplicates
    GPU_VENDORS=($(printf "%s\n" "${GPU_VENDORS[@]}" | sort -u))
    
    if [[ ${#GPU_VENDORS[@]} -eq 0 ]]; then
        warn "No supported GPU detected"
    fi
}

# Generate dynamic disk configuration
generate_disk_config() {
    local hostname="$1"
    local disk="$2"
    local config_file="$FLAKE_DIR/hosts/$hostname/disk-configuration.nix"
    
    log "Generating disk configuration for $hostname using $disk"
    
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
}
EOF
    
    success "Generated disk configuration: $config_file"
}

# Generate hardware configuration
generate_hardware_config() {
    local hostname="$1"
    local config_file="$FLAKE_DIR/hosts/$hostname/hardware-configuration.nix"
    
    log "Generating hardware configuration for $hostname"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$config_file")"
    
    # Try to use nixos-generate-config if available
    if command -v nixos-generate-config &> /dev/null; then
        log "Using nixos-generate-config for accurate hardware detection"
        nixos-generate-config --show-hardware-config > "$config_file.tmp"
        
        # Add our custom header and any modifications
        cat > "$config_file" << EOF
# Generated hardware configuration for $hostname
# Generated on $(date)
{lib, ...}: {
EOF
        # Extract the main configuration from nixos-generate-config output
        grep -v "^{" "$config_file.tmp" | grep -v "^}" | sed 's/^  //' >> "$config_file"
        echo "}" >> "$config_file"
        rm -f "$config_file.tmp"
    else
        # Generate basic hardware config manually
        cat > "$config_file" << EOF
{lib, ...}: {
  boot = {
    initrd = {
      availableKernelModules = [
        "nvme"
        "sd_mod"
        "xhci_pci"
        "ahci"
        "usb_storage"
        "usbhid"
        "sr_mod"
      ];
      kernelModules = [];
    };
    kernelModules = ["kvm-$CPU_VENDOR"];
    kernelParams = ["nowatchdog"];
  };

  hardware.enableRedistributableFirmware = lib.mkDefault true;
EOF

        # Add hardware-specific configuration
        if [[ "$CPU_VENDOR" == "intel" ]]; then
            echo "  # Intel CPU optimizations" >> "$config_file"
            echo '  boot.kernelParams = ["i915.force_probe=*"];' >> "$config_file"
        elif [[ "$CPU_VENDOR" == "amd" ]]; then
            echo "  # AMD CPU optimizations" >> "$config_file"
            echo '  boot.kernelParams = ["amd_pstate=active"];' >> "$config_file"
        fi

        # Add DPI setting if we can detect display
        if command -v xrandr &> /dev/null && xrandr &> /dev/null; then
            local dpi=$(xrandr | grep -oP '\d+x\d+' | head -1 | awk -F'x' '{print int(sqrt($1*$1 + $2*$2) / 14)}')
            if [[ -n "$dpi" && "$dpi" -gt 0 ]]; then
                echo "  services.xserver.dpi = $dpi;" >> "$config_file"
            fi
        fi
        
        echo "}" >> "$config_file"
    fi
    
    success "Generated hardware configuration: $config_file"
}

# Create or update host configuration
setup_host_config() {
    local hostname="$1"
    local host_dir="$FLAKE_DIR/hosts/$hostname"
    local host_config="$host_dir/default.nix"
    
    log "Setting up host configuration for $hostname"
    
    # Create directory if it doesn't exist
    mkdir -p "$host_dir"
    
    # Determine if this should be a minimal or full config
    local config_type="full"
    if [[ "$hostname" == "minimal" || ${#GPU_VENDORS[@]} -eq 0 ]]; then
        config_type="minimal"
    fi
    
    if [[ "$config_type" == "minimal" ]]; then
        cat > "$host_config" << EOF
{pkgs, ...}: {
  imports = [
    ./disk-configuration.nix
    ./hardware-configuration.nix
  ];

  boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;
  services.btrfs.autoScrub.enable = true;
}
EOF
    else
        # Full configuration with hardware-specific imports
        cat > "$host_config" << 'EOF'
{pkgs, ...}: {
  imports = [
    ./disk-configuration.nix
    ./hardware-configuration.nix
    ./power-management.nix

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

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services = {
    btrfs.autoScrub.enable = true;
    fwupd.enable = true;
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
    
    # Check if hostname already exists in hosts/default.nix
    if grep -q "\"$hostname\"" "$FLAKE_DIR/hosts/default.nix"; then
        log "Host $hostname already exists in flake configuration"
        return
    fi
    
    # Add the new host configuration
    # This is a simplified approach - in practice you might want more sophisticated parsing
    local temp_file=$(mktemp)
    awk -v hostname="$hostname" '
    /^  in \{$/ {
        print $0
        print ""
        print "    " hostname " = mkNixosSystem {"
        print "      hostname = \"" hostname "\";"
        print "      system = \"x86_64-linux\";"
        print "      modules = [nixosModules homeModules];"
        print "    };"
        next
    }
    { print }
    ' "$FLAKE_DIR/hosts/default.nix" > "$temp_file"
    
    mv "$temp_file" "$FLAKE_DIR/hosts/default.nix"
    success "Updated flake configuration"
}

# Partition and format disks
setup_disks() {
    local hostname="$1"
    
    log "Setting up disks using disko..."
    
    # Change to flake directory
    cd "$FLAKE_DIR"
    
    # Format the disk using disko
    log "Partitioning and formatting $TARGET_DISK..."
    sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --flake ".#$hostname"
    
    success "Disk setup completed"
}

# Install NixOS
install_nixos() {
    local hostname="$1"
    
    log "Installing NixOS configuration for $hostname..."
    
    cd "$FLAKE_DIR"
    
    # Install NixOS with the flake configuration
    sudo nixos-install --flake ".#$hostname" --no-root-passwd
    
    success "NixOS installation completed"
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
    
    # Check hostname format
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#hostname} -gt 1 ]]; then
        if [[ ${#hostname} -eq 1 ]] && [[ ! "$hostname" =~ ^[a-zA-Z0-9]$ ]]; then
            error "Invalid hostname format: $hostname"
        fi
    fi
    
    # Check hostname length
    if [[ ${#hostname} -gt 63 ]]; then
        error "Hostname too long (max 63 characters): $hostname"
    fi
    
    if [[ ${#hostname} -eq 0 ]]; then
        error "Hostname cannot be empty"
    fi
    
    log "Hostname validation passed: $hostname"
}

# Main installation process
# Main installation process
main() {
    local hostname="${1:-$DEFAULT_HOSTNAME}"
    local target_disk="${2:-}"
    
    log "Starting Snowflake NixOS installation..."
    log "Hostname: $hostname"
    
    check_root
    check_prerequisites
    validate_hostname "$hostname"
    detect_storage "$target_disk"
    detect_cpu
    detect_gpu
    detect_storage "$target_disk"
    detect_cpu
    detect_gpu
    
    log "Hardware summary:"
    log "  CPU: $CPU_VENDOR"
    log "  GPU: ${GPU_VENDORS[*]:-none}"
    log "  Target disk: $TARGET_DISK"
    
    # Confirm installation
    echo
    warn "This will COMPLETELY ERASE $TARGET_DISK and install NixOS!"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Installation cancelled"
    fi
    
    # Generate configurations
    generate_disk_config "$hostname" "$TARGET_DISK"
    generate_hardware_config "$hostname"
    setup_host_config "$hostname"
    create_service_files "$hostname"
    update_flake_config "$hostname"
    
    # Install system
    setup_disks "$hostname"
    install_nixos "$hostname"
    setup_user
    
    success "Installation completed successfully!"
    log "The system will be available after reboot."
    log "Remove the installation media and reboot to start using your new NixOS system."
}

# Handle script arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
