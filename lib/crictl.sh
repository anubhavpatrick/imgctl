#!/bin/bash
# ============================================================================
# imgctl - Crictl Module (with filtering support)
# ============================================================================
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-11-29
# ============================================================================

# Get the directory where the script is located
# Useful when the script is run from a different directory
# Get the relative path to the script with respect to the current working directory
RELATIVE_PATH="$(dirname "${BASH_SOURCE[0]}")" 
SCRIPT_DIR="$(cd "$RELATIVE_PATH" && pwd)"

# To prevent double sourcing of common.sh
[[ -z "$VERSION" ]] && source "${SCRIPT_DIR}/common.sh"

# Parallel is used to run commands in parallel
HAS_PARALLEL=$(command -v parallel >/dev/null 2>&1 && echo "yes" || echo "no")

# ----------------------------------------------------------------------------
# CRICTL FUNCTIONS
# ----------------------------------------------------------------------------

# Parse crictl (crictl images) output to JSON with filtering
parse_crictl_output() {
    # Input -> crictl images output
    # Output -> JSON with filtering
    local output="$1"
    
    [[ -z "$output" ]] && echo "[]" && return
    
    echo "$output" | awk '
    BEGIN { 
        print "[" 
        first = 1
    }
    NR == 1 {
        # NR is the number of the current line
        # Dynamically extract the repository, tag, image ID, and size from the output
        tag_pos = index($0, "TAG")
        id_pos = index($0, "IMAGE ID")
        size_pos = index($0, "SIZE")
        next
    }
    NF > 0 { 
        #NF is the number of fields in the current line
        repo = substr($0, 1, tag_pos - 1)
        tag = substr($0, tag_pos, id_pos - tag_pos)
        image_id = substr($0, id_pos, size_pos - id_pos)
        size = substr($0, size_pos)
        
        # remove leading and trailing whitespace from the repository, tag, image ID, and size
        gsub(/^[ \t]+|[ \t]+$/, "", repo)
        gsub(/^[ \t]+|[ \t]+$/, "", tag)
        gsub(/^[ \t]+|[ \t]+$/, "", image_id)
        gsub(/^[ \t]+|[ \t]+$/, "", size)
        
        # Skip header and empty lines
        if (repo != "" && repo != "IMAGE") {
            # If not the first line, print a comma
            if (!first) print ","
            first = 0
            gsub(/"/, "\\\"", repo) 
            gsub(/"/, "\\\"", tag)
            printf "{\"repository\":\"%s\",\"tag\":\"%s\",\"image_id\":\"%s\",\"size\":\"%s\"}", repo, (tag == "" ? "<none>" : tag), image_id, size
        }
    }
    END { print "]" }
    '
}

# Get images from a single node
get_node_images_single() {
    local node="$1"
    # cache key is the node name with special characters replaced with underscores
    local cache_key="node_${node//[^a-zA-Z0-9]/_}" 
    
    # Check cache
    local cache_file="${CACHE_DIR:-/var/cache/imgctl}/${cache_key}.cache"
    if [[ "$ENABLE_CACHE" == "true" && -f "$cache_file" ]]; then
        local file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $file_age -lt ${CACHE_TTL:-300} ]]; then
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Build SSH command
    local ssh_cmd="ssh"
    [[ -n "$SSH_OPTIONS" ]] && ssh_cmd+=" $SSH_OPTIONS"
    [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && ssh_cmd+=" -i $SSH_KEY"
    [[ -n "$SSH_USER" ]] && ssh_cmd+=" ${SSH_USER}@${node}" || ssh_cmd+=" $node"
    
    # Get images
    local output
    output=$($ssh_cmd "timeout ${CRICTL_TIMEOUT:-30} ${CRICTL_PATH:-/usr/bin/crictl} images 2>/dev/null" 2>/dev/null)
    
    # If ssh command fails or output is empty, return empty JSON
    if [[ $? -ne 0 || -z "$output" ]]; then
        echo "[]"
        return 1
    fi
    
    local images_json
    images_json=$(parse_crictl_output "$output")
    
    # Cache result (unfiltered - filtering happens at display time)
    if [[ "$ENABLE_CACHE" == "true" ]]; then
        mkdir -p "${CACHE_DIR:-/var/cache/imgctl}" 2>/dev/null
        echo "$images_json" > "$cache_file"
    fi
    
    echo "$images_json"
}

# Export functions to be used in parallel otherwise the subprocesses will not have access to the functions
export -f parse_crictl_output get_node_images_single 2>/dev/null

# Get images from all nodes
get_all_nodes_images() {
    local nodes
    read -ra nodes <<< "$WORKER_NODES" # read raw string into an array of nodes
    
    [[ ${#nodes[@]} -eq 0 ]] && echo "{}" && return 1
    
    local tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    
    # Unnecessary to use parallel if there are two or less nodes
    if [[ "$HAS_PARALLEL" == "yes" && ${#nodes[@]} -gt 1 ]]; then
        export SSH_OPTIONS SSH_KEY SSH_USER CRICTL_PATH CRICTL_TIMEOUT
        export CACHE_DIR CACHE_TTL ENABLE_CACHE
        
        printf '%s\n' "${nodes[@]}" | parallel --will-cite -j "${#nodes[@]}" \
            "source '${SCRIPT_DIR}/crictl.sh' 2>/dev/null; get_node_images_single {} > '$tmpdir/{}.json'"
    else
        local pids=()
        for node in "${nodes[@]}"; do
            (get_node_images_single "$node" > "$tmpdir/${node}.json") &
            pids+=($!)
        done
        
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null
        done
    fi
    
    # Combine results
    local result="{"
    local first=true
    
    for node in "${nodes[@]}"; do
        local node_file="$tmpdir/${node}.json"
        if [[ -f "$node_file" ]]; then
            local content=$(cat "$node_file")
            [[ -z "$content" ]] && content="[]"
            
            $first && first=false || result+=","
            result+="\"$node\":$content"
        else
            $first && first=false || result+=","
            result+="\"$node\":[]"
        fi
    done
    result+="}"
    
    echo "$result"
}

# Compare images between nodes with filtering
compare_node_images() {
    local all_nodes_images="$1"
    local ignore_file="${IGNORE_FILE:-/etc/imgctl/images_to_ignore.txt}"
    
    # Build ignore list for jq
    local ignore_array="[]"
    if [[ -f "$ignore_file" ]]; then
        ignore_array=$(tail -n +2 "$ignore_file" | awk -F',' '{print $1","$2}' | jq -R -s 'split("\n") | map(select(. != ""))')
    fi
    
    echo "$all_nodes_images" | jq --argjson ignore "$ignore_array" '
    # Filter function - exclude <none> tags and ignored images
    def should_keep: 
        .tag != "<none>" and .tag != "" and 
        (("\(.repository),\(.tag)") as $key | ($ignore | index($key)) == null);
    
    # Filter all node images first
    map_values([.[] | select(should_keep)]) |
    
    # Now do the comparison
    keys as $nodes |
    reduce (to_entries[] | .key as $node | .value[] | {
        ref: "\(.repository):\(.tag)",
        node: $node,
        image: .
    }) as $item (
        {};
        .[$item.ref] = (.[$item.ref] // {image: $item.image, nodes: []}) | 
        .[$item.ref].nodes += [$item.node]
    ) |
    . as $map |
    ($nodes | length) as $node_count |
    {
        common: [$map | to_entries[] | select(.value.nodes | length == $node_count) | .value.image],
        node_specific: (reduce $nodes[] as $node ({}; 
            .[$node] = [$map | to_entries[] | 
                select(.value.nodes | length < $node_count) | 
                select(.value.nodes | contains([$node])) | 
                .value.image
            ]
        ))
    }
    '
}
