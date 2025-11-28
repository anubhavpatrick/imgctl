#!/bin/bash
# ============================================================================
# imgctl - Uninstall Script
# ============================================================================
# This script removes imgctl from the system.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-06-11
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/opt/imgctl"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/imgctl"
LOG_DIR="/var/log/giindia/imgctl"
CACHE_DIR="/var/cache/imgctl"

echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║              imgctl - Uninstaller                          ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error:${NC} This script must be run as root (use sudo)"
    exit 1
fi

# Show what will be removed
echo -e "${BOLD}The following will be removed:${NC}"
[[ -L "$BIN_DIR/imgctl" ]] && echo "  • $BIN_DIR/imgctl (symlink)"
[[ -d "$INSTALL_DIR" ]] && echo "  • $INSTALL_DIR (installation directory)"
[[ -d "$CONFIG_DIR" ]] && echo "  • $CONFIG_DIR (configuration) - optional"
[[ -d "$LOG_DIR" ]] && echo "  • $LOG_DIR (logs) - optional"
[[ -d "$CACHE_DIR" ]] && echo "  • $CACHE_DIR (cache)"
echo ""

# Confirm uninstallation
read -p "Are you sure you want to uninstall imgctl? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Removing imgctl...${NC}"
echo ""

# Remove symlink
if [[ -L "$BIN_DIR/imgctl" ]]; then
    rm -f "$BIN_DIR/imgctl"
    echo -e "${GREEN}✓${NC} Removed $BIN_DIR/imgctl"
else
    echo -e "${YELLOW}!${NC} Symlink $BIN_DIR/imgctl not found"
fi

# Remove installation directory
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}✓${NC} Removed $INSTALL_DIR"
else
    echo -e "${YELLOW}!${NC} Installation directory $INSTALL_DIR not found"
fi

# Ask about configuration
echo ""
if [[ -d "$CONFIG_DIR" ]]; then
    read -p "Remove configuration files ($CONFIG_DIR)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}✓${NC} Removed $CONFIG_DIR"
    else
        echo -e "${YELLOW}!${NC} Configuration preserved at $CONFIG_DIR"
    fi
fi

# Ask about logs
if [[ -d "$LOG_DIR" ]]; then
    read -p "Remove log files ($LOG_DIR)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        echo -e "${GREEN}✓${NC} Removed $LOG_DIR"
        
        # Also remove parent if empty
        rmdir --ignore-fail-on-non-empty /var/log/giindia 2>/dev/null || true
    else
        echo -e "${YELLOW}!${NC} Logs preserved at $LOG_DIR"
    fi
fi

# Clean up cache (always remove)
if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    echo -e "${GREEN}✓${NC} Removed cache directory $CACHE_DIR"
fi

# Clean up user config directories
if [[ -d "$HOME/.config/imgctl" ]]; then
    read -p "Remove user configuration ($HOME/.config/imgctl)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$HOME/.config/imgctl"
        echo -e "${GREEN}✓${NC} Removed $HOME/.config/imgctl"
    fi
fi

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Uninstall Completed Successfully!             ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
