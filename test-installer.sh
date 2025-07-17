#!/usr/bin/env bash

# Test script for Snowflake NixOS Installer
# Validates installer functionality without running actual installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test flake validity
test_flake() {
    log "Testing flake configuration..."
    
    cd "$FLAKE_DIR"
    
    if ! nix flake check --no-build 2>/dev/null; then
        error "Flake configuration is invalid"
    fi
    
    success "Flake configuration is valid"
}

# Test that required files exist
test_required_files() {
    log "Checking required files..."
    
    local required_files=(
        "flake.nix"
        "hosts/default.nix"
        "hosts/yuki/default.nix"
        "hosts/yuki/disk-configuration.nix"
        "hosts/yuki/hardware-configuration.nix"
        "hosts/minimal/default.nix"
        "hosts/minimal/disk-configuration.nix"
        "hosts/minimal/hardware-configuration.nix"
        "install.sh"
        "hardware-detect.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$FLAKE_DIR/$file" ]]; then
            error "Required file missing: $file"
        fi
    done
    
    success "All required files present"
}

# Test installer script syntax
test_installer_syntax() {
    log "Testing installer script syntax..."
    
    if ! bash -n "$FLAKE_DIR/install.sh"; then
        error "Installer script has syntax errors"
    fi
    
    if ! bash -n "$FLAKE_DIR/hardware-detect.sh"; then
        error "Hardware detection script has syntax errors"
    fi
    
    success "Installer scripts have valid syntax"
}

# Test host configurations can be built
test_host_builds() {
    log "Testing host configuration builds..."
    
    cd "$FLAKE_DIR"
    
    # Test that each host can be evaluated (dry-run build)
    local hosts=("yuki" "minimal")
    
    for host in "${hosts[@]}"; do
        log "Testing build for host: $host"
        
        if ! nix build ".#nixosConfigurations.$host.config.system.build.toplevel" --dry-run 2>/dev/null; then
            error "Host configuration '$host' cannot be built"
        fi
        
        success "Host '$host' configuration is buildable"
    done
}

# Test hardware detection
test_hardware_detection() {
    log "Testing hardware detection..."
    
    if ! "$FLAKE_DIR/hardware-detect.sh" all > /dev/null; then
        error "Hardware detection script failed"
    fi
    
    success "Hardware detection script works"
}

# Test disk configuration generation
test_disk_config_generation() {
    log "Testing disk configuration generation..."
    
    # Create a test hostname and see if we can generate config
    local test_hostname="test-host"
    local test_disk="/dev/null"  # Safe non-existent disk for testing
    
    # Test that the functions would work (source the script in a subshell)
    if ! (
        source "$FLAKE_DIR/install.sh"
        # Test detect_storage function exists
        declare -f detect_storage > /dev/null
        # Test generate_disk_config function exists  
        declare -f generate_disk_config > /dev/null
        # Test generate_hardware_config function exists
        declare -f generate_hardware_config > /dev/null
    ); then
        error "Required functions missing from installer script"
    fi
    
    success "Disk configuration functions are available"
}

# Test directory permissions
test_permissions() {
    log "Testing file permissions..."
    
    if [[ ! -x "$FLAKE_DIR/install.sh" ]]; then
        error "Installer script is not executable"
    fi
    
    if [[ ! -x "$FLAKE_DIR/hardware-detect.sh" ]]; then
        error "Hardware detection script is not executable"
    fi
    
    success "Scripts have correct permissions"
}

# Main test function
main() {
    log "Starting Snowflake installer tests..."
    echo
    
    test_required_files
    test_permissions
    test_installer_syntax
    test_hardware_detection
    test_disk_config_generation
    test_flake
    test_host_builds
    
    echo
    success "All tests passed! Installer appears to be working correctly."
    echo
    log "To run the installer: ./install.sh [hostname] [disk]"
    log "To detect hardware: ./hardware-detect.sh all"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
