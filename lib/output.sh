#!/bin/bash
# ============================================================================
# imgctl - Output Formatting Module (Updated display order)
# ============================================================================
# Display order:
#   1. Harbor images
#   2. Common images across nodes
#   3. Unique images per node
#   4. Summary statistics
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-12-02
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$VERSION" ]] && source "${SCRIPT_DIR}/common.sh"

# ----------------------------------------------------------------------------
# FILTERING
# ----------------------------------------------------------------------------

# Filter Harbor images (remove <none> tags)
# harbor.sh collects all the images; this function filters out the images with no tag
filter_harbor_images() {
    local images_json="$1"
    echo "$images_json" | jq '[.[] | select(.tag != "<none>" and .tag != "")]'
}

# ----------------------------------------------------------------------------
# SPINNER / PROGRESS INDICATOR
# ----------------------------------------------------------------------------

# Global variable to track spinner PID
SPINNER_PID=""

# Start a spinner with a message
# Usage: start_spinner "Collecting images..."
start_spinner() {
    local message="${1:-Working...}"
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    # Only show spinner if stdout is a terminal
    [[ ! -t 1 ]] && return
    
    (
        local i=0
        while true; do
            printf "\r${CYAN}${spin_chars:$i:1}${NC} %s" "$message"
            i=$(( (i + 1) % ${#spin_chars} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    
    # Ensure spinner is killed on script exit
    trap "stop_spinner" EXIT
}

# Stop the spinner and clear the line
stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        # Clear the spinner line only if stdout is a terminal
        [[ -t 1 ]] && printf "\r\033[K"
    fi
}

# ----------------------------------------------------------------------------
# TABLE FORMATTING
# ----------------------------------------------------------------------------

format_table() {
    local images_json="$1"
    local title="${2:-Images}"
    local id_field="${3:-image_id}"
    
    local count=$(echo "$images_json" | jq 'length')
    
    print_header "$title ($count images)"
    
    [[ $count -eq 0 ]] && print_info "No images found" && return
    
    local id_label="IMAGE ID"
    [[ "$id_field" == "digest" ]] && id_label="DIGEST"
    
    printf "${BOLD}%-55s %-25s %-15s %-12s${NC}\n" "REPOSITORY" "TAG" "$id_label" "SIZE"
    print_separator 107
    
    echo "$images_json" | jq -r --arg id "$id_field" '.[] | [.repository, .tag, .[$id], .size] | @tsv' | \
    awk -F'\t' '{printf "%-55s %-25s %-15s %-12s\n", substr($1,1,55), substr($2,1,25), substr($3,1,15), substr($4,1,12)}'
}

format_comparison_table() {
    local comparison_json="$1"
    
    # 1. Common images first
    local common=$(echo "$comparison_json" | jq '.common')
    local common_count=$(echo "$common" | jq 'length')
    
    print_header "Common Images (Present on all worker nodes) - $common_count images" 107
    
    if [[ $common_count -gt 0 ]]; then
        printf "${BOLD}%-55s %-25s %-15s %-12s${NC}\n" "REPOSITORY" "TAG" "IMAGE ID" "SIZE"
        print_separator 107
        echo "$common" | jq -r '.[] | [.repository, .tag, .image_id, .size] | @tsv' | \
        awk -F'\t' '{printf "%-55s %-25s %-15s %-12s\n", substr($1,1,55), substr($2,1,25), substr($3,1,15), substr($4,1,12)}'
    else
        print_info "No common images found"
    fi
    
    # 2. Node-specific images (in order)
    local nodes=$(echo "$comparison_json" | jq -r '.node_specific | keys[]' | sort)
    
    # Here IFS is used to read the input line by line verbatim
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        
        local node_images=$(echo "$comparison_json" | jq --arg n "$node" '.node_specific[$n]')
        local node_count=$(echo "$node_images" | jq 'length')
        
        print_header "Unique Images on $node - $node_count images" 107
        
        if [[ $node_count -gt 0 ]]; then
            printf "${BOLD}%-55s %-25s %-15s %-12s${NC}\n" "REPOSITORY" "TAG" "IMAGE ID" "SIZE"
            print_separator 107
            echo "$node_images" | jq -r '.[] | [.repository, .tag, .image_id, .size] | @tsv' | \
            awk -F'\t' '{printf "%-55s %-25s %-15s %-12s\n", substr($1,1,55), substr($2,1,25), substr($3,1,15), substr($4,1,12)}'
        else
            print_info "No unique images on this node"
        fi
    done <<< "$nodes"
}

# ----------------------------------------------------------------------------
# JSON/CSV FORMATTING
# ----------------------------------------------------------------------------

format_report_json() {
    local harbor_images="$1"
    local node_images="$2"
    local comparison="$3"
    
    jq -n \
        --argjson harbor "$harbor_images" \
        --argjson nodes "$node_images" \
        --argjson comparison "${comparison:-null}" \
        '{
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            harbor_images: $harbor,
            comparison: $comparison
        }'
}

format_report_csv() {
    local harbor_images="$1"
    local comparison="$2"
    
    echo "source,repository,tag,id,size"
    
    # Harbor images
    echo "$harbor_images" | jq -r '.[] | ["harbor", .repository, .tag, .digest, .size] | @csv' 2>/dev/null
    
    # Common images
    echo "$comparison" | jq -r '.common[] | ["common", .repository, .tag, .image_id, .size] | @csv' 2>/dev/null
    
    # Node-specific images
    echo "$comparison" | jq -r '.node_specific | to_entries[] | .key as $node | .value[] | [$node, .repository, .tag, .image_id, .size] | @csv' 2>/dev/null
}

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------

print_summary() {
    local harbor_images="$1"
    local comparison="$2"
    local node_images="$3"
    
    echo ""
    print_header "Summary" 60
    
    # Harbor count
    local harbor_count=$(echo "$harbor_images" | jq 'length')
    echo -e "  ${CYAN}Harbor Registry:${NC}         $harbor_count images"
    
    # Common count
    if [[ -n "$comparison" && "$comparison" != "null" ]]; then
        local common_count=$(echo "$comparison" | jq '.common | length')
        echo -e "  ${GREEN}Common across nodes:${NC}     $common_count images"
        
        # Node-specific counts
        local nodes=$(echo "$comparison" | jq -r '.node_specific | keys[]' | sort)
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            local unique_count=$(echo "$comparison" | jq --arg n "$node" '.node_specific[$n] | length')
            echo -e "  ${YELLOW}Unique to $node:${NC}  $unique_count images"
        done <<< "$nodes"
    fi
    
    # Total per node (before filtering)
    if [[ -n "$node_images" && "$node_images" != "{}" ]]; then
        echo ""
        echo -e "  ${BOLD}Total images per node (before filtering):${NC}"
        echo "$node_images" | jq -r 'to_entries[] | "    \(.key): \(.value | length) images"'
    fi
    
    echo ""
}

# ----------------------------------------------------------------------------
# MAIN OUTPUT - NEW ORDER
# ----------------------------------------------------------------------------

display_output() {
    local output_format="${1:-table}"
    local harbor_images="$2"
    local node_images="$3"
    local comparison="$4"
    
    # Filter harbor images (remove <none> tags)
    local filtered_harbor
    filtered_harbor=$(filter_harbor_images "$harbor_images")
    
    case "$output_format" in
        json)
            format_report_json "$filtered_harbor" "$node_images" "$comparison"
            ;;
        csv)
            format_report_csv "$filtered_harbor" "$comparison"
            ;;
        table|*)
            # 1. Harbor images FIRST
            if [[ $(echo "$filtered_harbor" | jq 'length') -gt 0 ]]; then
                format_table "$filtered_harbor" "Harbor Registry Images" "digest"
            else
                print_header "Harbor Registry Images (0 images)"
                print_info "No tagged images found in Harbor"
            fi
            
            # 2. Common images + Node-specific images
            if [[ -n "$comparison" && "$comparison" != "null" && "$comparison" != "{}" ]]; then
                echo ""
                echo -e "${BOLD}${CYAN}=== Worker Node Images (Filtered) ===${NC}"
                format_comparison_table "$comparison"
            fi
            
            # 3. Summary at the end
            print_summary "$filtered_harbor" "$comparison" "$node_images"
            ;;
    esac
}
