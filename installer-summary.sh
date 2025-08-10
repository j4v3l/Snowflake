#!/usr/bin/env bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                 Snowflake NixOS Installer                     ║${NC}"
echo -e "${CYAN}║                      Summary & Usage                          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo

echo -e "${BLUE}FEATURES:${NC}"
echo "  • Automatic hardware detection (CPU, GPU, storage)"
echo "  • Disk setup via disko (GPT + BTRFS with compression)"
echo "  • Predefined hosts: minimal, yuki"
echo "  • Home Manager integrated"
echo

echo -e "${BLUE}SCRIPTS:${NC}"
echo "  • Installer:            ${YELLOW}./install.sh${NC}"
echo "  • Hardware detection:   ${YELLOW}./hardware-detect.sh${NC}"
echo "  • Test suite:           ${YELLOW}./test-installer.sh${NC}"
echo "  • Post-install verify:  ${YELLOW}./verify-install.sh${NC}"
echo "  • Docs:                 ${YELLOW}README.md${NC}"
echo

echo -e "${BLUE}USAGE:${NC}"
echo "  ${YELLOW}# Basic installation (auto-detect)${NC}"
echo "  ./install.sh"
echo
echo "  ${YELLOW}# Custom hostname and disk (WIPES DISK)${NC}"
echo "  ./install.sh myhost /dev/nvme0n1"
echo
echo "  ${YELLOW}# Rebuild on an existing system (no partitioning)${NC}"
echo "  REINSTALL_MODE=1 ./install.sh yuki"
echo
echo "  ${YELLOW}# Hardware info dump${NC}"
echo "  ./hardware-detect.sh all"
echo

echo -e "${BLUE}ENV FLAGS (optional):${NC}"
echo "  SKIP_INTERNET_CHECK=1    # Skip connectivity check"
echo "  SKIP_CONFIRMATION=1      # Don’t prompt"
echo "  FORCE_DISK_CONFIG=1      # Overwrite disk-configuration.nix"
echo "  REGENERATE_HW_CONFIG=1   # Overwrite hardware-configuration.nix"
echo "  REGENERATE_HOST=1        # Overwrite hosts/<name>/default.nix"
echo

echo -e "${BLUE}DISK LAYOUT (default):${NC}"
echo "  • EFI /boot: 1GB (FAT32)"
echo "  • Root (BTRFS): subvolumes /, /home, /nix with zstd"
echo

echo -e "${BLUE}HOST TYPES:${NC}"
echo "  • ${YELLOW}yuki${NC}: Desktop with Hyprland and dev tooling"
echo "  • ${YELLOW}minimal${NC}: Basic NixOS setup"
echo

echo -e "${YELLOW}⚠️  WARNING:${NC}"
echo "  • Fresh install will ERASE the target disk"
echo "  • Ensure you have backups"
echo

echo -e "${GREEN}Ready:${NC} run ${YELLOW}./install.sh${NC} to begin."

