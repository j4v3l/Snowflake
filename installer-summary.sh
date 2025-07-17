#!/usr/bin/env bash

# Snowflake NixOS Installer Summary
# Shows what the installer provides and how to use it

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                 Snowflake NixOS Installer                     ║${NC}"
echo -e "${CYAN}║                   Audit & Installation                        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo

echo -e "${GREEN}✓ AUDIT COMPLETE${NC}"
echo "  • Analyzed NixOS flake configuration structure"
echo "  • Identified host configurations (yuki, minimal)"
echo "  • Reviewed hardware configurations and disk setups"
echo "  • Validated flake dependencies and modules"
echo

echo -e "${GREEN}✓ INSTALLER CREATED${NC}"
echo "  • Single script installer: ${YELLOW}./install.sh${NC}"
echo "  • Hardware detection: ${YELLOW}./hardware-detect.sh${NC}"
echo "  • Test suite: ${YELLOW}./test-installer.sh${NC}"
echo "  • Documentation: ${YELLOW}INSTALL.md${NC}"
echo

echo -e "${BLUE}FEATURES:${NC}"
echo "  • Automatic hardware detection (CPU, GPU, storage)"
echo "  • Zero-interaction installation after confirmation"
echo "  • Dynamic disk partitioning with BTRFS + compression"
echo "  • Generated hardware-specific configurations"
echo "  • Support for Intel/AMD CPUs and NVIDIA/AMD/Intel GPUs"
echo "  • UEFI boot with secure partitioning scheme"
echo

echo -e "${BLUE}USAGE:${NC}"
echo "  ${YELLOW}# Basic installation (auto-detect everything)${NC}"
echo "  ./install.sh"
echo
echo "  ${YELLOW}# Custom hostname${NC}"
echo "  ./install.sh myhostname"
echo
echo "  ${YELLOW}# Custom hostname and disk${NC}"
echo "  ./install.sh myhostname /dev/nvme0n1"
echo
echo "  ${YELLOW}# Hardware detection only${NC}"
echo "  ./hardware-detect.sh all"
echo
echo "  ${YELLOW}# Test installer validity${NC}"
echo "  ./test-installer.sh"
echo

echo -e "${BLUE}DISK LAYOUT:${NC}"
echo "  • EFI Boot: 1GB (FAT32)"
echo "  • Root: Remaining space (BTRFS with compression)"
echo "    ├── / (root subvolume)"
echo "    ├── /home (home subvolume)"
echo "    └── /nix (nix subvolume)"
echo

echo -e "${BLUE}HOST TYPES:${NC}"
echo "  • ${YELLOW}Full (yuki-style)${NC}: Complete desktop with Hyprland, development tools"
echo "  • ${YELLOW}Minimal${NC}: Basic NixOS setup, automatically used if no GPU detected"
echo

echo -e "${GREEN}CURRENT SYSTEM DETECTION:${NC}"
if command -v lscpu &> /dev/null; then
    CPU_VENDOR="Unknown"
    if lscpu | grep -qi intel; then
        CPU_VENDOR="Intel"
    elif lscpu | grep -qi amd; then
        CPU_VENDOR="AMD"
    fi
    echo "  • CPU: $CPU_VENDOR"
fi

if command -v lspci &> /dev/null; then
    GPU_COUNT=$(lspci | grep -i "vga\|3d\|display" | wc -l)
    echo "  • GPU(s): $GPU_COUNT detected"
    if [[ $GPU_COUNT -gt 0 ]]; then
        lspci | grep -i "vga\|3d\|display" | sed 's/^/    - /'
    fi
fi

if command -v lsblk &> /dev/null; then
    DISK_COUNT=$(lsblk -d | grep -E "(disk|nvme)" | wc -l)
    echo "  • Storage: $DISK_COUNT device(s)"
    lsblk -d -o NAME,SIZE,TYPE | grep -E "(disk|nvme)" | while read -r name size type; do
        echo "    - /dev/$name ($size)"
    done
fi

echo
echo -e "${YELLOW}⚠️  WARNING:${NC}"
echo "  • This installer will COMPLETELY ERASE the target disk"
echo "  • Ensure you have backups of any important data"
echo "  • Internet connection required for installation"
echo "  • Must be run from NixOS installer environment"
echo

echo -e "${GREEN}READY TO INSTALL!${NC}"
echo "Run ${YELLOW}./install.sh${NC} to begin installation"
echo
