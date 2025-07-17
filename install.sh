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
    
    # Try to use nixos-generate-config if available (with timeout and memory limit)
    if command -v nixos-generate-config &> /dev/null; then
        log "Using nixos-generate-config for accurate hardware detection"
        
        # Run with timeout and redirect to avoid memory issues
        if timeout 30 nixos-generate-config --show-hardware-config > "$config_file.tmp" 2>/dev/null; then
            # Add our custom header and any modifications
            cat > "$config_file" << EOF
# Generated hardware configuration for $hostname
# Generated on $(date)
{lib, ...}: {
EOF
            # Extract the main configuration from nixos-generate-config output
            grep -v "^{" "$config_file.tmp" | grep -v "^}" | sed 's/^  //' >> "$config_file" 2>/dev/null || true
            echo "}" >> "$config_file"
            rm -f "$config_file.tmp"
        else
            warn "nixos-generate-config failed or timed out, using manual configuration"
            generate_manual_hardware_config "$hostname" "$config_file"
        fi
    else
        generate_manual_hardware_config "$hostname" "$config_file"
    fi
    
    success "Generated hardware configuration: $config_file"
}

# Generate manual hardware configuration (fallback)
generate_manual_hardware_config() {
    local hostname="$1"
    local config_file="$2"
    
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

    echo "}" >> "$config_file"
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
    
    # Check memory before disk operations
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    log "Available memory before disk setup: $(( available_mem / 1024 ))MB"
    
    # Change to flake directory
    cd "$FLAKE_DIR" || error "Failed to change to flake directory: $FLAKE_DIR"
    
    # Format the disk using disko
    log "Partitioning and formatting $TARGET_DISK..."
    
    # Run disko with timeout and better error handling
    if timeout 300 sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --flake ".#$hostname" 2>&1; then
        success "Disk partitioning completed successfully"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            error "Disk setup timed out after 5 minutes. The disk might be too slow or the network connection is poor."
            error "Try running the installer again or use a faster disk."
        else
            error "Disk setup failed with exit code $exit_code. Check if disk $TARGET_DISK exists and is not in use."
            error "Make sure the disk is not mounted and no other processes are using it."
        fi
        return 1
    fi
    
    success "Disk setup completed"
}

# Install NixOS
install_nixos() {
    local hostname="$1"
    
    log "Installing NixOS configuration for $hostname..."
    
    # Check memory before installation
    local available_mem=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    log "Available memory before NixOS installation: $(( available_mem / 1024 ))MB"
    
    cd "$FLAKE_DIR" || error "Failed to change to flake directory: $FLAKE_DIR"
    
    # Install NixOS with the flake configuration
    log "Running: sudo nixos-install --flake \".#$hostname\" --no-root-passwd"
    
    if ! sudo nixos-install --flake ".#$hostname" --no-root-passwd 2>&1; then
        error "NixOS installation failed. Check the above output for specific errors."
    fi
    
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
    
    # Enable debug mode if requested
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "Debug mode enabled"
        set -x
    fi
    
    log "Step 1: Checking if running as root..."
    check_root
    
    log "Step 2: Checking prerequisites..."
    check_prerequisites
    
    log "Step 3: Validating hostname..."
    validate_hostname "$hostname"
    
    log "Step 4: Detecting storage devices..."
    detect_storage "$target_disk"
    
    log "Step 5: Detecting CPU..."
    detect_cpu
    
    log "Step 6: Detecting GPU..."
    detect_gpu
    
    log "Hardware summary:"
    log "  CPU: $CPU_VENDOR"
    log "  GPU: ${GPU_VENDORS[*]:-none}"
    log "  Target disk: $TARGET_DISK"
    
    # Confirm installation
    echo
    warn "This will COMPLETELY ERASE $TARGET_DISK and install NixOS!"
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
    generate_hardware_config "$hostname"
    
    log "Step 9: Setting up host configuration..."
    setup_host_config "$hostname"
    
    log "Step 10: Creating service files..."
    create_service_files "$hostname"
    
    log "Step 11: Updating flake configuration..."
    update_flake_config "$hostname"
    
    # Install system
    log "Step 12: Setting up disks..."
    setup_disks "$hostname"
    
    log "Step 13: Installing NixOS..."
    install_nixos "$hostname"
    
    log "Step 14: Setting up user..."
    setup_user
    
    success "Installation completed successfully!"
    log "The system will be available after reboot."
    log "Remove the installation media and reboot to start using your new NixOS system."
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
    echo "  DEBUG=1                - Enable debug mode with verbose output"
    echo
    echo "Examples:"
    echo "  $0                           # Use defaults"
    echo "  $0 myhostname               # Custom hostname"
    echo "  $0 myhostname /dev/sda      # Custom hostname and disk"
    echo "  FLAKE_DIR=/path/to/flake $0 # Custom flake location"
    echo "  DEBUG=1 $0                  # Enable debug mode"
    echo "  SKIP_CONFIRMATION=1 $0      # Skip confirmation prompt"
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
