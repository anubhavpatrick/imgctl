#!/bin/bash
# ============================================================================
# imgctl - Cluster Image Management Tool
# ============================================================================
# A scalable CLI tool for managing and viewing container images across a
# BCM cluster with NVIDIA DGX nodes and Harbor private registry.
#
# This tool provides:
#   - View images on worker nodes (via crictl)
#   - View images in Harbor registry
#   - Compare images across nodes
#   - Multiple output formats (table, json, csv)
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Organization: Global Info Ventures Pvt Ltd
# Date: 2025-06-11
# ============================================================================

set -o pipefail

# Resolve the actual installation directory
# This handles the case where imgctl is symlinked from /usr/local/bin
if [[ -L "${BASH_SOURCE[0]}" ]]; then
    # Follow the symlink to get the real path
    REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
    SCRIPT_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Library directory is relative to the actual script location
LIB_DIR="${SCRIPT_DIR}/../lib"

# Verify library directory exists
if [[ ! -d "$LIB_DIR" ]]; then
    echo "Error: Library directory not found at $LIB_DIR" >&2
    echo "Please ensure imgctl is properly installed." >&2
    exit 1
fi

# Source library modules
source "${LIB_DIR}/common.sh" || { echo "Error: Failed to load common.sh" >&2; exit 1; }
source "${LIB_DIR}/crictl.sh" || { echo "Error: Failed to load crictl.sh" >&2; exit 1; }
source "${LIB_DIR}/harbor.sh" || { echo "Error: Failed to load harbor.sh" >&2; exit 1; }
source "${LIB_DIR}/output.sh" || { echo "Error: Failed to load output.sh" >&2; exit 1; }

# ----------------------------------------------------------------------------
# USAGE AND HELP
# ----------------------------------------------------------------------------

show_usage() {
    cat << EOF
${BOLD}imgctl${NC} - View and manage container images across your BCM cluster

${BOLD}USAGE:${NC}
    imgctl COMMAND [OPTIONS]

${BOLD}COMMANDS:${NC}
    get [SCOPE]        Get container images
                       SCOPE options:
                         all      - All images (default)
                         harbor   - Harbor registry images only
                         nodes    - Worker node images only
                         <node>   - Specific node images

    compare            Compare images across worker nodes

    status             Show cluster connectivity status

    cache              Cache management
        clear          Clear image cache
        show           Show cache statistics

    config             Configuration management
        show           Show current configuration
        --server URL   Set Harbor server URL

    help               Show this help message

${BOLD}OPTIONS:${NC}
    -o, --output FORMAT    Output format: table|json|csv (default: table)
    -c, --config FILE      Use specific configuration file
    -n, --nodes NODES      Comma-separated list of nodes to query
    --no-cache             Disable caching for this request
    --no-color             Disable colored output
    -q, --quiet            Quiet mode (minimal output)
    -v, --verbose          Verbose mode (debug output)
    --version              Show version information

${BOLD}EXAMPLES:${NC}
    imgctl get                    # Get all images
    imgctl get harbor             # Get Harbor images only
    imgctl get nodes              # Get all node images
    imgctl get dgx001             # Get images from specific node
    imgctl get -o json            # Output in JSON format
    imgctl compare                # Compare images across nodes
    imgctl status                 # Check cluster connectivity
    imgctl cache clear            # Clear the image cache

${BOLD}CONFIGURATION:${NC}
    Configuration is loaded from (in order of priority):
      1. /etc/imgctl/imgctl.conf
      2. ~/.config/imgctl/imgctl.conf
      3. ./imgctl.conf

${BOLD}LOGGING:${NC}
    Logs are stored in: /var/log/giindia/imgctl/
    Log files are named: imgctl-YYYY-MM-DD.log

${BOLD}VERSION:${NC}
    $VERSION

EOF
}

show_version() {
    echo "imgctl version $VERSION"
    echo "Author: Anubhav Patrick <anubhav.patrick@giindia.com>"
    echo "Organization: Global Info Ventures Pvt Ltd"
}

# ----------------------------------------------------------------------------
# COMMAND HANDLERS
# ----------------------------------------------------------------------------

# Handle 'get' command
cmd_get() {
    local scope="${1:-all}"
    shift 2>/dev/null || true
    
    local harbor_images="[]"
    local node_images="{}"
    local comparison=""
    
    case "$scope" in
        all)
            log_info "Getting all images (Harbor + nodes)"
            harbor_images=$(get_harbor_images)
            node_images=$(get_all_nodes_images)
            comparison=$(compare_node_images "$node_images")
            ;;
        harbor)
            log_info "Getting Harbor images only"
            harbor_images=$(get_harbor_images)
            ;;
        nodes)
            log_info "Getting all node images"
            node_images=$(get_all_nodes_images)
            comparison=$(compare_node_images "$node_images")
            ;;
        *)
            # Assume it's a specific node name
            log_info "Getting images from node: $scope"
            local node_result
            node_result=$(get_node_images "$scope")
            node_images=$(jq -n --arg node "$scope" --argjson images "$node_result" '{($node): $images}')
            ;;
    esac
    
    # Display output
    display_output "$OUTPUT_FORMAT" "$harbor_images" "$node_images" "$comparison"
}

# Handle 'compare' command
cmd_compare() {
    log_info "Comparing images across nodes"
    
    local node_images
    node_images=$(get_all_nodes_images)
    
    local comparison
    comparison=$(compare_node_images "$node_images")
    
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "$comparison" | jq '.'
    else
        format_comparison_table "$comparison"
        
        # Print summary counts
        local common_count
        common_count=$(echo "$comparison" | jq '.common | length')
        
        echo ""
        print_header "Comparison Summary" 60
        echo -e "  ${GREEN}Common images:${NC} $common_count"
        
        echo "$comparison" | jq -r '.node_specific | to_entries[] | "  \(.key): \(.value | length) unique"'
        echo ""
    fi
}

# Handle 'status' command
cmd_status() {
    log_info "Checking cluster status"
    
    print_header "Cluster Status" 60
    
    # Check Harbor
    echo -e "\n${BOLD}Harbor Registry:${NC}"
    if [[ -n "$HARBOR_URL" ]]; then
        echo "  URL: $HARBOR_URL"
        if test_harbor_connection; then
            print_success "  Status: Connected"
        else
            print_error "  Status: Connection failed"
        fi
    else
        print_warning "  Not configured"
    fi
    
    # Check worker nodes
    echo -e "\n${BOLD}Worker Nodes:${NC}"
    
    local nodes
    read -ra nodes <<< "$WORKER_NODES"
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_warning "  No worker nodes configured"
    else
        for node in "${nodes[@]}"; do
            echo -n "  $node: "
            if test_ssh_connection "$node"; then
                print_success "Connected"
                
                # Check crictl availability
                local crictl_check
                crictl_check=$(ssh_exec "$node" "which crictl 2>/dev/null")
                if [[ -n "$crictl_check" ]]; then
                    echo "    crictl: $crictl_check"
                else
                    print_warning "    crictl: Not found"
                fi
            else
                print_error "Connection failed"
            fi
        done
    fi
    
    echo ""
}

# Handle 'cache' command
cmd_cache() {
    local action="${1:-show}"
    
    case "$action" in
        clear)
            clear_cache
            print_success "Cache cleared"
            ;;
        show)
            print_header "Cache Statistics" 50
            local cache_dir="${CACHE_DIR:-/tmp/imgctl-cache}"
            
            if [[ -d "$cache_dir" ]]; then
                local file_count
                file_count=$(find "$cache_dir" -name "*.cache" 2>/dev/null | wc -l)
                local total_size
                total_size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1)
                
                echo "  Directory: $cache_dir"
                echo "  Files: $file_count"
                echo "  Size: ${total_size:-0}"
                echo "  TTL: ${CACHE_TTL:-300} seconds"
                
                if [[ $file_count -gt 0 ]]; then
                    echo ""
                    echo "  Cached items:"
                    find "$cache_dir" -name "*.cache" -exec basename {} .cache \; 2>/dev/null | \
                        while read -r item; do
                            local age
                            age=$(( $(date +%s) - $(stat -c %Y "${cache_dir}/${item}.cache") ))
                            echo "    - $item (${age}s old)"
                        done
                fi
            else
                echo "  Cache directory does not exist"
            fi
            echo ""
            ;;
        *)
            print_error "Unknown cache action: $action"
            echo "Valid actions: clear, show"
            return 1
            ;;
    esac
}

# Handle 'config' command
cmd_config() {
    local action="${1:-show}"
    shift 2>/dev/null || true
    
    case "$action" in
        show)
            print_header "Current Configuration" 60
            echo "  Configuration file: ${CONFIG_FILE:-Not loaded}"
            echo ""
            echo "  ${BOLD}Cluster:${NC}"
            echo "    Name: ${CLUSTER_NAME:-not set}"
            echo "    Worker nodes: ${WORKER_NODES:-not set}"
            echo ""
            echo "  ${BOLD}SSH:${NC}"
            echo "    User: ${SSH_USER:-root}"
            echo "    Options: ${SSH_OPTIONS:-default}"
            echo ""
            echo "  ${BOLD}Harbor:${NC}"
            echo "    URL: ${HARBOR_URL:-not configured}"
            echo "    User: ${HARBOR_USER:-not set}"
            echo "    SSL Verify: ${HARBOR_VERIFY_SSL:-true}"
            echo ""
            echo "  ${BOLD}Logging:${NC}"
            echo "    Directory: ${LOG_DIR:-/var/log/giindia/imgctl}"
            echo "    Level: ${LOG_LEVEL:-INFO}"
            echo ""
            ;;
        --server)
            local url="$1"
            if [[ -z "$url" ]]; then
                print_error "Server URL required"
                return 1
            fi
            
            local user_config_dir="$HOME/.config/imgctl"
            mkdir -p "$user_config_dir"
            
            # Update or create user config
            local user_config="$user_config_dir/imgctl.conf"
            if [[ -f "$user_config" ]]; then
                # Update existing config
                sed -i "s|^HARBOR_URL=.*|HARBOR_URL=\"$url\"|" "$user_config" 2>/dev/null || \
                    echo "HARBOR_URL=\"$url\"" >> "$user_config"
            else
                echo "HARBOR_URL=\"$url\"" > "$user_config"
            fi
            
            print_success "Harbor server URL set to: $url"
            echo "Configuration saved to: $user_config"
            ;;
        *)
            print_error "Unknown config action: $action"
            echo "Valid actions: show, --server URL"
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# MAIN ENTRY POINT
# ----------------------------------------------------------------------------

main() {
    # Default values
    OUTPUT_FORMAT="${DEFAULT_OUTPUT_FORMAT:-table}"
    local config_file=""
    local no_cache=false
    local no_color=false
    local quiet=false
    local verbose=false
    
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -n|--nodes)
                WORKER_NODES="${2//,/ }"
                shift 2
                ;;
            --no-cache)
                no_cache=true
                shift
                ;;
            --no-color)
                no_color=true
                shift
                ;;
            -q|--quiet)
                quiet=true
                LOG_LEVEL="ERROR"
                shift
                ;;
            -v|--verbose)
                verbose=true
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --version)
                show_version
                exit 0
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                echo "Use 'imgctl help' for usage information"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Disable colors if requested
    if $no_color; then
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        CYAN=""
        NC=""
        BOLD=""
    fi
    
    # Disable cache if requested
    if $no_cache; then
        ENABLE_CACHE="false"
    fi
    
    # Load configuration
    if [[ -n "$config_file" ]]; then
        load_config "$config_file" || exit 1
        CONFIG_FILE="$config_file"
    else
        local found_config
        if found_config=$(find_config); then
            load_config "$found_config"
            CONFIG_FILE="$found_config"
        else
            log_warning "No configuration file found, using defaults"
        fi
    fi
    
    # Initialize
    check_dependencies || exit 1
    init_logging
    init_cache
    
    # Validate configuration
    validate_config
    
    # Get command
    local command="${1:-get}"
    shift 2>/dev/null || true
    
    # Execute command
    case "$command" in
        get)
            cmd_get "$@"
            ;;
        compare)
            cmd_compare "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        cache)
            cmd_cache "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        help|-h|--help)
            show_usage
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Use 'imgctl help' for usage information"
            exit 1
            ;;
    esac
    
    # Cleanup old logs periodically
    cleanup_old_logs
}

# Run main function
main "$@"
