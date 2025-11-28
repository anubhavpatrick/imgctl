#!/bin/bash
# ============================================================================
# imgctl - Installation Script
# ============================================================================
# This script installs imgctl on the BCM head node.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-06-11
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Installation paths
INSTALL_DIR="/opt/imgctl"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/imgctl"
LOG_DIR="/var/log/giindia/imgctl"
COMMAND_NAME="imgctl"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║              imgctl - Installation                         ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error:${NC} This script must be run as root (use sudo)"
    exit 1
fi

# Check dependencies
echo -e "${BLUE}[1/6]${NC} Checking dependencies..."

missing_deps=()

if ! command -v jq >/dev/null 2>&1; then
    missing_deps+=("jq")
fi

if ! command -v curl >/dev/null 2>&1; then
    missing_deps+=("curl")
fi

if ! command -v ssh >/dev/null 2>&1; then
    missing_deps+=("openssh-client")
fi

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Installing missing dependencies: ${missing_deps[*]}${NC}"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y "${missing_deps[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing_deps[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing_deps[@]}"
    else
        echo -e "${RED}Error:${NC} Cannot install dependencies. Please install manually: ${missing_deps[*]}"
        exit 1
    fi
fi
echo -e "${GREEN}✓${NC} Dependencies satisfied"

# Create directories
echo -e "${BLUE}[2/6]${NC} Creating directories..."

mkdir -p "$INSTALL_DIR"/{bin,lib,conf}
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

chmod 755 "$INSTALL_DIR"
chmod 755 "$CONFIG_DIR"
chmod 755 "$LOG_DIR"

echo -e "${GREEN}✓${NC} Directories created"

# Copy files - handle both naming conventions
echo -e "${BLUE}[3/6]${NC} Installing files..."

# Function to find and copy a file with fallback names
copy_file() {
    local dest="$1"
    shift
    local sources=("$@")
    
    for src in "${sources[@]}"; do
        if [[ -f "$src" ]]; then
            cp -f "$src" "$dest"
            return 0
        fi
    done
    
    echo -e "${RED}Error:${NC} Could not find source file. Tried: ${sources[*]}"
    return 1
}

# Copy library files (handle lib-*.sh or *.sh naming)
copy_file "$INSTALL_DIR/lib/common.sh" \
    "${SCRIPT_DIR}/lib/common.sh" \
    "${SCRIPT_DIR}/lib/lib-common.sh" || exit 1

copy_file "$INSTALL_DIR/lib/crictl.sh" \
    "${SCRIPT_DIR}/lib/crictl.sh" \
    "${SCRIPT_DIR}/lib/lib-crictl.sh" || exit 1

copy_file "$INSTALL_DIR/lib/harbor.sh" \
    "${SCRIPT_DIR}/lib/harbor.sh" \
    "${SCRIPT_DIR}/lib/lib-harbor.sh" || exit 1

copy_file "$INSTALL_DIR/lib/output.sh" \
    "${SCRIPT_DIR}/lib/output.sh" \
    "${SCRIPT_DIR}/lib/lib-output.sh" || exit 1

chmod 644 "$INSTALL_DIR/lib/"*.sh

# Copy binary (handle imgctl or imgctl.sh naming)
copy_file "$INSTALL_DIR/bin/imgctl" \
    "${SCRIPT_DIR}/bin/imgctl" \
    "${SCRIPT_DIR}/bin/imgctl.sh" || exit 1

chmod 755 "$INSTALL_DIR/bin/imgctl"

echo -e "${GREEN}✓${NC} Files installed"

# Create symlink
echo -e "${BLUE}[4/6]${NC} Creating command symlink..."

ln -sf "$INSTALL_DIR/bin/imgctl" "$BIN_DIR/$COMMAND_NAME"

echo -e "${GREEN}✓${NC} Symlink created: $BIN_DIR/$COMMAND_NAME"

# Install configuration
echo -e "${BLUE}[5/6]${NC} Installing configuration..."

if [[ ! -f "$CONFIG_DIR/imgctl.conf" ]]; then
    copy_file "$CONFIG_DIR/imgctl.conf" \
        "${SCRIPT_DIR}/conf/imgctl.conf" \
        "${SCRIPT_DIR}/imgctl.conf" || exit 1
    chmod 644 "$CONFIG_DIR/imgctl.conf"
    echo -e "${GREEN}✓${NC} Default configuration installed"
    echo -e "${YELLOW}!${NC} Please edit $CONFIG_DIR/imgctl.conf with your cluster details"
else
    echo -e "${YELLOW}!${NC} Configuration already exists, not overwriting"
    echo "  New default config available at: ${SCRIPT_DIR}/conf/imgctl.conf"
fi

# Verify installation
echo -e "${BLUE}[6/6]${NC} Verifying installation..."

if command -v imgctl >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Installation verified"
else
    echo -e "${RED}Error:${NC} Installation verification failed"
    exit 1
fi

# Print summary
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Installation Completed Successfully!          ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Installation Summary:${NC}"
echo "  • Install directory:  $INSTALL_DIR"
echo "  • Configuration:      $CONFIG_DIR/imgctl.conf"
echo "  • Log directory:      $LOG_DIR"
echo "  • Command:            imgctl"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo "  1. Edit the configuration file:"
echo "     ${CYAN}sudo nano $CONFIG_DIR/imgctl.conf${NC}"
echo ""
echo "  2. Update the following settings:"
echo "     • WORKER_NODES  - Your DGX worker node hostnames"
echo "     • HARBOR_URL    - Your Harbor registry URL"
echo "     • HARBOR_USER   - Harbor username"
echo "     • HARBOR_PASSWORD - Harbor password"
echo ""
echo "  3. Test the installation:"
echo "     ${CYAN}imgctl status${NC}"
echo ""
echo -e "${BOLD}Quick Commands:${NC}"
echo "  imgctl get              # Get all images"
echo "  imgctl get harbor       # Get Harbor images only"
echo "  imgctl get nodes        # Get node images only"
echo "  imgctl compare          # Compare images across nodes"
echo "  imgctl help             # Show full help"
echo ""
