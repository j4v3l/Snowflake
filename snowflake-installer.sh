#!/usr/bin/env bash

# Snowflake NixOS Configuration Installer
# Installs the Snowflake NixOS configuration on an existing NixOS system
# Based on the Snowflake flake structure with yuki and minimal hosts

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="${FLAKE_DIR:-$SCRIPT_DIR}"
AVAILABLE_HOSTS=("yuki" "minimal")
DEFAULT_HOST="minimal"  # Changed to minimal as it's more universal
DEFAULT_USER="jager"

# Logging functions
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
        error "This script should not be executed as root! Run as regular user."
    fi
}

# Check if running on NixOS
check_nixos() {
    if [[ ! -f /etc/NIXOS ]] && [[ ! "$(grep -i nixos /etc/os-release 2>/dev/null)" ]]; then
        error "This installation script only works on NixOS! Download an iso at https://nixos.org/download/"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if flake directory exists and has required files
    if [[ ! -d "$FLAKE_DIR" ]]; then
        error "Flake directory not found: $FLAKE_DIR"
    fi
    
    if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
        error "flake.nix not found in: $FLAKE_DIR"
    fi
    
    # Check if git is available
    if ! command -v git &> /dev/null; then
        error "git is required but not installed"
    fi
    
    # Check if nix flakes are enabled
    if ! nix flake --version &> /dev/null; then
        error "Nix flakes are not enabled. Please enable experimental features."
    fi
    
    log "Prerequisites check passed"
}

# Detect current user
detect_user() {
    local current_user
    current_user=$(logname 2>/dev/null || whoami)
    
    if [[ -z "$current_user" ]]; then
        error "Unable to detect current user"
    fi
    
    echo "$current_user"
}

# Clean up conflicting files that interfere with home-manager
cleanup_conflicting_files() {
    local user="$1"
    local home_dir="/home/$user"
    
    log "Cleaning up files that conflict with home-manager..."
    
    # Files and directories that conflict with home-manager
    local paths=(
        "$home_dir/.mozilla/firefox/profiles.ini"
        "$home_dir/.zen/profiles.ini"
        "$home_dir/.gtkrc-*"
        "$home_dir/.config/gtk-*"
        "$home_dir/.config/cava"
        "$home_dir/.config/fontconfig"
        "$home_dir/.config/git"
        "$home_dir/.config/kitty"
        "$home_dir/.config/zsh"
        "$home_dir/.zshrc"
        "$home_dir/.bashrc"
        "$home_dir/.profile"
    )
    
    for pattern in "${paths[@]}"; do
        for file in $pattern; do
            if [[ -e "$file" ]] && [[ ! -L "$file" ]]; then
                log "Removing conflicting file/directory: $file"
                rm -rf "$file"
            fi
        done
    done
}

# Update user configuration in home-manager
update_user_config() {
    local user="$1"
    local home_config="$FLAKE_DIR/home/$user"
    
    log "Updating user configuration for: $user"
    
    # Create user directory if it doesn't exist
    if [[ ! -d "$home_config" ]]; then
        log "Creating home-manager configuration for user: $user"
        cp -r "$FLAKE_DIR/home/jager" "$home_config"
    fi
    
    # Update username in home.nix
    local home_nix="$home_config/home.nix"
    if [[ -f "$home_nix" ]]; then
        sed -i "s/username = \".*\"/username = \"$user\"/" "$home_nix"
        sed -i "s|homeDirectory = \"/home/.*\"|homeDirectory = \"/home/$user\"|" "$home_nix"
        log "Updated home.nix for user: $user"
    fi
    
    # Update users in home/default.nix
    local home_default="$FLAKE_DIR/home/default.nix"
    if [[ -f "$home_default" ]]; then
        # Check if user already exists in configuration
        if ! grep -q "$user = import" "$home_default"; then
            # Add user to the users configuration
            sed -i "/users = {/a\\      $user = import ./$user;" "$home_default"
            log "Added user $user to home-manager users configuration"
        fi
    fi
}

# Update system user configuration
update_system_user() {
    local user="$1"
    local users_nix="$FLAKE_DIR/hosts/config/system/users.nix"
    
    log "Updating system user configuration for: $user"
    
    if [[ -f "$users_nix" ]]; then
        # Replace jager with current user
        sed -i "s/users.users.jager/users.users.$user/" "$users_nix"
        log "Updated system users.nix for user: $user"
    fi
}

# Create or update host configuration based on detected hardware
create_adaptive_host_config() {
    local hostname="$1"
    local host_dir="$FLAKE_DIR/hosts/$hostname"
    local host_config="$host_dir/default.nix"
    
    # Skip if this is an existing predefined host
    if [[ "$hostname" == "yuki" ]] || [[ "$hostname" == "minimal" ]]; then
        log "Using predefined host configuration for: $hostname"
        return 0
    fi
    
    log "Creating adaptive host configuration for: $hostname"
    
    # Detect hardware for dynamic configuration
    local cpu_vendor="unknown"
    local gpu_vendors=()
    
    # Detect CPU
    if command -v lscpu &> /dev/null && lscpu | grep -qi "intel"; then
        cpu_vendor="intel"
    elif command -v lscpu &> /dev/null && lscpu | grep -qi "amd"; then
        cpu_vendor="amd"
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -qi "intel" /proc/cpuinfo; then
            cpu_vendor="intel"
        elif grep -qi "amd" /proc/cpuinfo; then
            cpu_vendor="amd"
        fi
    fi
    
    # Detect GPU
    if command -v lspci &> /dev/null; then
        local gpu_info
        gpu_info=$(lspci | grep -i "vga\|3d\|display")
        
        if echo "$gpu_info" | grep -qi "intel"; then
            gpu_vendors+=("intel")
        fi
        
        if echo "$gpu_info" | grep -qi "nvidia"; then
            gpu_vendors+=("nvidia")
        fi
        
        if echo "$gpu_info" | grep -qi "amd\|ati\|radeon"; then
            gpu_vendors+=("amd")
        fi
    fi
    
    # Create host configuration
    mkdir -p "$host_dir"
    cat > "$host_config" << EOF
{pkgs, ...}: {
  imports = [
    ./disk-configuration.nix
    ./hardware-configuration.nix

    ../config/fonts
    ../config/hardware/acpi_call
    ../config/hardware/bluetooth
EOF

    # Add CPU configuration
    if [[ "$cpu_vendor" != "unknown" ]]; then
        echo "    ../config/hardware/cpu/$cpu_vendor" >> "$host_config"
    fi
    
    # Add GPU configurations
    for gpu in "${gpu_vendors[@]}"; do
        echo "    ../config/hardware/gpu/$gpu" >> "$host_config"
    done
    
    # Add common configurations
    cat >> "$host_config" << 'EOF'
    ../config/hardware/ssd
    ../config/window-managers/hyprland
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware = {
    graphics = {
      enable = true;
      enable32Bit = true;
    };
  };

  services = {
    btrfs.autoScrub.enable = true;
    fwupd.enable = true;
  };
}
EOF

    success "Created adaptive host configuration at: $host_config"
    
    # Create basic disk configuration if it doesn't exist
    local disk_config="$host_dir/disk-configuration.nix"
    if [[ ! -f "$disk_config" ]]; then
        log "Creating basic disk configuration"
        cat > "$disk_config" << 'EOF'
{
  # Basic disk configuration - modify as needed for your setup
  # This is a placeholder that should be customized for your specific disk layout
  
  # If using disko, replace this with your disko configuration
  # If using traditional partitioning, configure your filesystems here
  
  # Example for a simple setup:
  # fileSystems."/" = {
  #   device = "/dev/disk/by-label/nixos";
  #   fsType = "ext4";
  # };
  
  # fileSystems."/boot" = {
  #   device = "/dev/disk/by-label/boot";
  #   fsType = "vfat";
  # };
}
EOF
    fi
}
}

# Detect hardware and create missing configurations
detect_and_setup_hardware() {
    log "Detecting hardware and setting up configurations..."
    
    # Detect CPU vendor
    local cpu_vendor="unknown"
    if command -v lscpu &> /dev/null && lscpu | grep -qi "intel"; then
        cpu_vendor="intel"
        log "Detected Intel CPU"
    elif command -v lscpu &> /dev/null && lscpu | grep -qi "amd"; then
        cpu_vendor="amd"
        log "Detected AMD CPU"
    elif [[ -f /proc/cpuinfo ]]; then
        if grep -qi "intel" /proc/cpuinfo; then
            cpu_vendor="intel"
            log "Detected Intel CPU (from /proc/cpuinfo)"
        elif grep -qi "amd" /proc/cpuinfo; then
            cpu_vendor="amd"
            log "Detected AMD CPU (from /proc/cpuinfo)"
        fi
    fi
    
    # Create AMD CPU configuration if needed
    if [[ "$cpu_vendor" == "amd" ]] && [[ ! -d "$FLAKE_DIR/hosts/config/hardware/cpu/amd" ]]; then
        log "Creating AMD CPU configuration..."
        mkdir -p "$FLAKE_DIR/hosts/config/hardware/cpu/amd"
        cat > "$FLAKE_DIR/hosts/config/hardware/cpu/amd/default.nix" << 'EOF'
{lib, ...}: {
  # AMD CPU microcode updates
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  
  # AMD specific kernel parameters
  boot.kernelParams = [
    "amd_pstate=active"
  ];
}
EOF
        success "Created AMD CPU configuration"
    fi
    
    # Detect GPU vendor
    local gpu_vendors=()
    if command -v lspci &> /dev/null; then
        local gpu_info
        gpu_info=$(lspci | grep -i "vga\|3d\|display")
        
        if echo "$gpu_info" | grep -qi "intel"; then
            gpu_vendors+=("intel")
            log "Detected Intel GPU"
        fi
        
        if echo "$gpu_info" | grep -qi "nvidia"; then
            gpu_vendors+=("nvidia")
            log "Detected NVIDIA GPU"
        fi
        
        if echo "$gpu_info" | grep -qi "amd\|ati\|radeon"; then
            gpu_vendors+=("amd")
            log "Detected AMD GPU"
        fi
    fi
    
    # Create AMD GPU configuration if needed
    if [[ " ${gpu_vendors[*]} " =~ " amd " ]] && [[ ! -d "$FLAKE_DIR/hosts/config/hardware/gpu/amd" ]]; then
        log "Creating AMD GPU configuration..."
        mkdir -p "$FLAKE_DIR/hosts/config/hardware/gpu/amd"
        cat > "$FLAKE_DIR/hosts/config/hardware/gpu/amd/default.nix" << 'EOF'
{pkgs, ...}: {
  # AMD GPU configuration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      amdvlk
      rocmPackages.clr.icd
    ];
    extraPackages32 = with pkgs; [
      driversi686Linux.amdvlk
    ];
  };
  
  services.xserver.videoDrivers = ["amdgpu"];
  
  # ROCm support
  systemd.tmpfiles.rules = [
    "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
  ];
  
  environment.variables = {
    ROC_ENABLE_PRE_VEGA = "1";
  };
}
EOF
        success "Created AMD GPU configuration"
    fi
}

# Generate or copy hardware configuration
setup_hardware_config() {
    local hostname="$1"
    local host_dir="$FLAKE_DIR/hosts/$hostname"
    local hw_config="$host_dir/hardware-configuration.nix"
    
    log "Setting up hardware configuration for host: $hostname"
    
    # Create host directory if it doesn't exist
    mkdir -p "$host_dir"
    
    # Try to find existing hardware configuration
    if [[ -f "/etc/nixos/hardware-configuration.nix" ]]; then
        log "Using existing hardware configuration from /etc/nixos"
        cp "/etc/nixos/hardware-configuration.nix" "$hw_config"
    elif [[ -f "/etc/nixos/hosts/$hostname/hardware-configuration.nix" ]]; then
        log "Using existing hardware configuration from /etc/nixos/hosts/$hostname"
        cp "/etc/nixos/hosts/$hostname/hardware-configuration.nix" "$hw_config"
    else
        log "Generating new hardware configuration"
        nixos-generate-config --show-hardware-config > "$hw_config"
    fi
    
    # Add to git if we're in a git repository
    if [[ -d "$FLAKE_DIR/.git" ]]; then
        git -C "$FLAKE_DIR" add "$hw_config" 2>/dev/null || warn "Could not add hardware config to git"
    fi
    
    success "Hardware configuration set up at: $hw_config"
}

# Show available hosts
show_available_hosts() {
    log "Available host configurations:"
    for host in "${AVAILABLE_HOSTS[@]}"; do
        if [[ -d "$FLAKE_DIR/hosts/$host" ]]; then
            echo "  ✅ $host"
        else
            echo "  ❌ $host (missing)"
        fi
    done
}

# Validate host selection
validate_host() {
    local hostname="$1"
    
    # Check if hostname is in available predefined hosts
    for host in "${AVAILABLE_HOSTS[@]}"; do
        if [[ "$host" == "$hostname" ]]; then
            return 0
        fi
    done
    
    # If not a predefined host, validate hostname format
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#hostname} -gt 1 ]]; then
        error "Invalid hostname format: $hostname. Use alphanumeric characters and hyphens only."
    elif [[ ${#hostname} -eq 1 ]] && [[ ! "$hostname" =~ ^[a-zA-Z0-9]$ ]]; then
        error "Invalid hostname format: $hostname. Single character hostnames must be alphanumeric."
    fi
    
    warn "Using custom hostname: $hostname (will create adaptive configuration)"
    return 0
}

# Perform the NixOS rebuild
perform_rebuild() {
    local hostname="$1"
    local flake_path="$FLAKE_DIR#$hostname"
    
    log "Building and switching to configuration: $hostname"
    log "Flake path: $flake_path"
    
    # Change to flake directory to ensure relative paths work
    cd "$FLAKE_DIR"
    
    # First try to build the configuration to check for errors
    log "Testing configuration build..."
    if ! nix build "$flake_path" --no-link 2>/dev/null; then
        warn "Configuration build test failed, trying with verbose output..."
        if ! nix build "$flake_path" --no-link; then
            error "Configuration has build errors. Please check the configuration and try again."
        fi
    fi
    
    # Run nixos-rebuild switch
    log "Applying configuration..."
    if sudo nixos-rebuild switch --flake "$flake_path"; then
        success "Successfully switched to configuration: $hostname"
        return 0
    else
        error "Failed to switch to configuration: $hostname"
    fi
}

# Show summary of changes
show_summary() {
    local hostname="$1"
    local user="$2"
    
    echo
    echo "=== Installation Summary ==="
    echo "Host configuration: $hostname"
    echo "User: $user"
    echo "Flake directory: $FLAKE_DIR"
    echo "Home directory: /home/$user"
    echo
    
    if command -v nixos-rebuild &> /dev/null; then
        log "Current system generation:"
        nixos-rebuild list-generations | tail -1 | sed 's/^/  /'
    fi
    
    echo
    success "Installation completed successfully!"
    echo
    echo "Recommended next steps:"
    echo "1. Reboot your system: sudo reboot"
    echo "2. Log out and log back in to reload the shell"
    echo "3. Run verification: ./verify-install.sh"
    echo
}

# Main installation function
main() {
    local hostname="${1:-$DEFAULT_HOST}"
    local user
    
    echo "=== Snowflake NixOS Configuration Installer ==="
    echo
    
    # Perform checks
    check_root
    check_nixos
    check_prerequisites
    
    # Detect current user
    user=$(detect_user)
    log "Detected user: $user"
    
    # Show available hosts
    show_available_hosts
    echo
    
    # Validate hostname
    validate_host "$hostname"
    log "Selected host configuration: $hostname"
    
    # Confirm installation
    echo
    echo "About to install Snowflake configuration:"
    echo "  Host: $hostname"
    echo "  User: $user"
    echo "  Directory: $FLAKE_DIR"
    echo
    read -p "Continue with installation? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Installation cancelled by user"
        exit 0
    fi
    
    # Perform installation steps
    log "Starting installation..."
    
    # Detect and setup hardware configurations first
    detect_and_setup_hardware
    
    # Create or update host configuration
    create_adaptive_host_config "$hostname"
    
    cleanup_conflicting_files "$user"
    
    if [[ "$user" != "jager" ]]; then
        update_user_config "$user"
        update_system_user "$user"
    fi
    
    setup_hardware_config "$hostname"
    
    perform_rebuild "$hostname"
    
    show_summary "$hostname" "$user"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [hostname]"
        echo
        echo "Predefined hostnames:"
        printf "  %s\n" "${AVAILABLE_HOSTS[@]}"
        echo
        echo "You can also specify a custom hostname to create an adaptive configuration"
        echo "based on detected hardware."
        echo
        echo "Default hostname: $DEFAULT_HOST"
        echo
        echo "Examples:"
        echo "  $0                # Install with default host (minimal)"
        echo "  $0 minimal        # Install minimal configuration"
        echo "  $0 yuki           # Install full yuki configuration"
        echo "  $0 myhostname     # Create adaptive config for custom hostname"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
