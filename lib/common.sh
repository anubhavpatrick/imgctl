#!/bin/bash
# ============================================================================
# imgctl - Common Library Functions (Optimized)
# - Logging
# - SSH Operations
# - Cache Management
# - Configuration Handling
# ============================================================================
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-11-28
# ============================================================================

VERSION="2.1.0"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Log levels
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)
CURRENT_DATE=$(date +%Y-%m-%d)

# ----------------------------------------------------------------------------
# LOGGING FUNCTIONS
# ----------------------------------------------------------------------------

init_logging() {
    local log_dir="${LOG_DIR:-/var/log/giindia/imgctl}"
    
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || return 1
    fi
    
    LOG_FILE="${log_dir}/imgctl-${CURRENT_DATE}.log"
    touch "$LOG_FILE" 2>/dev/null || return 1
    return 0
}

log_message() {
    local level="${1:-INFO}"
    local message="$2"
    local configured_level="${LOG_LEVEL:-INFO}"
    
    # Decide if the message should be logged or not
    # Log only if the message level is greater than or equal to configured level
    if [[ ${LOG_LEVELS[$level]:-1} -ge ${LOG_LEVELS[$configured_level]:-1} ]]; then
        local log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
        [[ -n "$LOG_FILE" && -w "$LOG_FILE" ]] && echo "$log_entry" >> "$LOG_FILE"
        [[ "$level" == "ERROR" ]] && echo -e "${RED}ERROR:${NC} $message" >&2
    fi
}
# Convenience functions for different log levels
log_debug()   { log_message "DEBUG" "$1"; }
log_info()    { log_message "INFO" "$1"; }
log_warning() { log_message "WARNING" "$1"; }
log_error()   { log_message "ERROR" "$1"; }

# Cleanup old log files based on retention policy
cleanup_old_logs() {
    local log_dir="${LOG_DIR:-/var/log/giindia/imgctl}"
    [[ -d "$log_dir" ]] && find "$log_dir" -name "imgctl-*.log" -mtime +"${LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null
}

# ----------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ----------------------------------------------------------------------------
print_separator() { printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}$1${NC}"
    print_separator "${2:-80}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_dependencies() {
    local missing=()
    for dep in ssh curl jq; do
        command_exists "$dep" || missing+=("$dep")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# SSH FUNCTIONS (Optimized)
# ----------------------------------------------------------------------------

build_ssh_command() {
    local host="$1"
    local cmd="ssh"
    [[ -n "$SSH_OPTIONS" ]] && cmd+=" $SSH_OPTIONS"
    [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && cmd+=" -i $SSH_KEY"
    [[ -n "$SSH_USER" ]] && cmd+=" ${SSH_USER}@${host}" || cmd+=" $host"
    echo "$cmd"
}

test_ssh_connection() {
    local host="$1"
    $(build_ssh_command "$host") "echo OK" >/dev/null 2>&1
}

ssh_exec() {
    local host="$1"
    shift
    $(build_ssh_command "$host") "$@" 2>/dev/null
}

# ----------------------------------------------------------------------------
# CACHE FUNCTIONS (Optimized)
# ----------------------------------------------------------------------------

init_cache() {
    [[ "$ENABLE_CACHE" == "true" ]] && mkdir -p "${CACHE_DIR:-/var/cache/imgctl}" 2>/dev/null
}

# Retrieve cached data if valid otherwise delete stale cache
get_cache() {
    local key="$1"

    # SANITIZATION: Allow only alphanumeric characters, underscores, and hyphens
    # Helps prevent directory traversal and injection attacks
    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Security Alert: Invalid characters in cache key: $key"
        return 1
    fi

    local cache_file="${CACHE_DIR:-/var/cache/imgctl}/${key}.cache"
    
    [[ "$ENABLE_CACHE" != "true" ]] && return 1
    [[ ! -f "$cache_file" ]] && return 1
    
    local file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if [[ $file_age -lt ${CACHE_TTL:-300} ]]; then
        cat "$cache_file"
        return 0
    fi
    rm -f "$cache_file"
    return 1
}

set_cache() {
    local key="$1"
    local data="$2"
    [[ "$ENABLE_CACHE" == "true" ]] && echo "$data" > "${CACHE_DIR:-/var/cache/imgctl}/${key}.cache"
}

clear_cache() {
    rm -rf "${CACHE_DIR:-/var/cache/imgctl}"/*.cache 2>/dev/null
    log_info "Cache cleared"
}

# ----------------------------------------------------------------------------
# CONFIGURATION FUNCTIONS
# ----------------------------------------------------------------------------

load_config() {
    local config_file="$1"
    [[ -f "$config_file" ]] && source "$config_file" && return 0
    return 1
}

find_config() {
    local locations=(
        "/etc/imgctl/imgctl.conf"
        "/root/imgctl/conf/imgctl.conf"
    )
    
    for loc in "${locations[@]}"; do
        [[ -f "$loc" ]] && echo "$loc" && return 0
    done
    return 1
}

validate_config() {
    [[ -z "$WORKER_NODES" ]] && log_error "WORKER_NODES is not configured" && return 1
    [[ -z "$HARBOR_URL" ]] && log_warning "HARBOR_URL is not configured"
    return 0
}
