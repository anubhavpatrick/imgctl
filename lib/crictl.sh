#!/bin/bash
# ============================================================================
# imgctl - Crictl Module (with filtering support)
# ============================================================================
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-11-29
#Key Capabilities:
#   - Output Parsing: Robustly converts 'crictl images' text tables into structured JSON.
#   - Parallel Fetching: Orchestrates concurrent SSH data retrieval using GNU Parallel 
#     or native Bash background jobs (auto-detects capability).
#   - Advanced Filtering: Applies regex-based blocklists (from CSV) and removes 
#     dangling (<none>) images using optimized 'jq' pipelines.
#   - Comparative Analysis: Implements a Map-Reduce engine to pivot data from 
#     "Node-Centric" to "Image-Centric" views, identifying Global vs. Unique images.
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
    
    # Check cache using shared function from common.sh
    local cached_data
    if cached_data=$(get_cache "$cache_key"); then
        echo "$cached_data"
        return 0
    fi
    
    # Get images via SSH using shared function from common.sh
    local output
    output=$(ssh_exec "$node" "timeout ${CRICTL_TIMEOUT:-30} ${CRICTL_PATH:-/usr/bin/crictl} images 2>/dev/null")
    
    # If ssh command fails or output is empty, log warning and return empty JSON
    if [[ $? -ne 0 || -z "$output" ]]; then
        log_warning "Failed to retrieve images from node: $node (unreachable or crictl error)"
        echo "[]"
        return 1
    fi
    
    local images_json
    images_json=$(parse_crictl_output "$output")
    
    # Cache result using shared function from common.sh (unfiltered - filtering happens at display time)
    set_cache "$cache_key" "$images_json"
    
    echo "$images_json"
}

# Export functions to be used in parallel otherwise the subprocesses will not have access to the functions
# Also export shared functions from common.sh that are now used by get_node_images_single
export -f parse_crictl_output get_node_images_single build_ssh_command ssh_exec get_cache set_cache log_message log_warning 2>/dev/null

# Get images from all nodes
get_all_nodes_images() {
    local nodes
    read -ra nodes <<< "$WORKER_NODES" # read raw string into an array of nodes
    
    [[ ${#nodes[@]} -eq 0 ]] && echo "{}" && return 1
    
    log_info "Fetching images from ${#nodes[@]} worker nodes..."
    
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
    
    # Combine results and track failures
    local result="{"
    local first=true
    local failed_nodes=()
    local success_count=0
    
    for node in "${nodes[@]}"; do
        local node_file="$tmpdir/${node}.json"
        if [[ -f "$node_file" ]]; then
            local content=$(cat "$node_file")
            if [[ -z "$content" || "$content" == "[]" ]]; then
                failed_nodes+=("$node")
            else
                ((success_count++))
            fi
            [[ -z "$content" ]] && content="[]"
            
            $first && first=false || result+=","
            result+="\"$node\":$content"
        else
            failed_nodes+=("$node")
            $first && first=false || result+=","
            result+="\"$node\":[]"
        fi
    done
    result+="}"
    
    # Log summary with failure info
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_warning "Failed to retrieve images from ${#failed_nodes[@]} node(s): ${failed_nodes[*]}"
    fi
    log_info "Successfully retrieved images from $success_count of ${#nodes[@]} nodes"
    
    echo "$result"
}

# Compare images between nodes with filtering
# Input -> json of all nodes images
# Output -> json of common and node specific images
compare_node_images() {
    local all_nodes_images="$1"
    local ignore_file="${IGNORE_FILE:-/etc/imgctl/images_to_ignore.txt}"
    
    # Build ignore list (CSV -> JSON) for jq
    # The ignore file input and output conversion looks as follows:
    # Input:
    # IMAGE,TAG,IMAGE ID,SIZE
    # docker.io/calico/cni,v3.29.2,cda13293c895a,99.3MB
    # docker.io/calico/node,v3.29.2,048bf7af1f8c6,142MB
    #
    # Output:
    # [
    #   "docker.io/calico/cni,v3.29.2",
    #   "docker.io/calico/node,v3.29.2"
    # ]
    local ignore_array="[]"
    if [[ -f "$ignore_file" ]]; then
        ignore_array=$(tail -n +2 "$ignore_file" | awk -F',' '{print $1","$2}' | jq -R -s 'split("\n") | map(select(. != ""))')
    fi
    
    
    echo "$all_nodes_images" | jq --argjson ignore "$ignore_array" '
    
    # Each image is a JSON object with the following fields:
    # - repository: the repository of the image
    # - tag: the tag of the image
    # - image_id: the image ID of the image
    # - size: the size of the image

    # Filter function - exclude <none> tags and ignored images
    # Search for the image in the ignore list and if it is not found, keep it
    def should_keep: 
        .tag != "<none>" and .tag != "" and 
        (("\(.repository),\(.tag)") as $key | ($ignore | index($key)) == null);
    
    # Filter all node images first
    # Example input to map_values():
    # {
    #   "node1": [
    #     {"repository": "repo/a", "tag": "1.0", "image_id": "abc123", "size": "50MB"},
    #     {"repository": "repo/b", "tag": "<none>", "image_id": "def456", "size": "70MB"}
    #   ],
    #   "node2": [
    #     {"repository": "repo/a", "tag": "1.0", "image_id": "abc123", "size": "50MB"}
    #   ]
    # }
    #
    # Example output after map_values([.[] | select(should_keep)]):
    # {
    #   "node1": [
    #     {"repository": "repo/a", "tag": "1.0", "image_id": "abc123", "size": "50MB"}
    #   ],
    #   "node2": [
    #     {"repository": "repo/a", "tag": "1.0", "image_id": "abc123", "size": "50MB"}
    #   ]
    # }
    map_values([.[] | select(should_keep)]) |
    
    # Capture node names BEFORE transforming the data structure
    keys as $nodes |
    
    # -----------------------------------------------------------
    # Input:
    # {
    #   "node1": [
    #     {"repository": "nginx", "tag": "latest", "image_id": "123", "size": "50MB"},
    #     {"repository": "busybox", "tag": "1.0", "image_id": "456", "size": "5MB"}
    #   ],
    #   "node2": [
    #     {"repository": "nginx", "tag": "latest", "image_id": "123", "size": "50MB"}
    #   ]
    # }
    #
    # Output:
    # {
    #   "nginx:latest": {
    #     "image": {
    #       "repository": "nginx",
    #       "tag": "latest",
    #       "image_id": "123",
    #       "size": "50MB"
    #     },
    #     "nodes": [
    #       "node1",
    #       "node2"
    #     ]
    #   },
    #   "busybox:1.0": {
    #     "image": {
    #       "repository": "busybox",
    #       "tag": "1.0",
    #       "image_id": "456",
    #       "size": "5MB"
    #     },
    #     "nodes": [
    #       "node1"
    #     ]
    #   }
    # }
    # -----------------------------------------------------------
    # The following block transforms the filtered node-images map into
    # a map from 'repository:tag' to an object with { image, nodes }.
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
        # Find common images (present on all nodes)
        common: [$map | to_entries[] | select(.value.nodes | length == $node_count) | .value.image],
        
        # Which unique items does EACH specific node possess?
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
