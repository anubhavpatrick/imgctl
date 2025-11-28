#!/bin/bash
# ============================================================================
# imgctl - Harbor Module (Parallel Processing)
# ============================================================================
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-06-11
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$VERSION" ]] && source "${SCRIPT_DIR}/common.sh"

# Check if GNU parallel is available
HAS_PARALLEL=$(command -v parallel >/dev/null 2>&1 && echo "yes" || echo "no")

# Maximum parallel jobs for Harbor API calls
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-10}"

# ----------------------------------------------------------------------------
# HARBOR API FUNCTIONS
# ----------------------------------------------------------------------------

# Single curl call
harbor_curl() {
    local endpoint="$1"
    local ssl_opt=""
    [[ "$HARBOR_VERIFY_SSL" != "true" ]] && ssl_opt="-k"
    
    curl -s --connect-timeout 10 --max-time 30 $ssl_opt \
        -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
        -H "Accept: application/json" \
        "${HARBOR_URL}${endpoint}" 2>/dev/null
}

# URL encode
url_encode() {
    echo -n "$1" | jq -sRr @uri
}

# Double URL encode for proxy cache repos
double_url_encode() {
    local encoded=$(url_encode "$1")
    echo "${encoded//%/%25}"
}

# Fetch all pages from an endpoint
harbor_api_get_all() {
    local endpoint="$1"
    local page_size="${HARBOR_PAGE_SIZE:-100}"
    local page=1
    local all_results="[]"
    
    while true; do
        local sep="?"
        [[ "$endpoint" == *"?"* ]] && sep="&"
        
        local response
        response=$(harbor_curl "${endpoint}${sep}page=${page}&page_size=${page_size}")
        
        [[ -z "$response" ]] && break
        
        # Validate and check errors
        if ! echo "$response" | jq -e 'type' >/dev/null 2>&1; then
            break
        fi
        
        if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
            break
        fi
        
        [[ $(echo "$response" | jq 'type') == '"object"' ]] && response="[$response]"
        
        local count=$(echo "$response" | jq 'length')
        [[ $count -eq 0 ]] && break
        
        all_results=$(echo "$all_results $response" | jq -s 'add')
        
        [[ $count -lt $page_size ]] && break
        ((page++))
        [[ $page -gt 50 ]] && break
    done
    
    echo "$all_results"
}

# Process a single repository (called by parallel)
process_harbor_repo() {
    local project_name="$1"
    local full_repo_name="$2"
    
    # Get repo name for API
    local repo_name="${full_repo_name#${project_name}/}"
    
    # Encode for URL
    local encoded_repo
    if [[ "$repo_name" == *"/"* ]]; then
        encoded_repo=$(double_url_encode "$repo_name")
    else
        encoded_repo=$(url_encode "$repo_name")
    fi
    
    # Fetch artifacts
    local ssl_opt=""
    [[ "$HARBOR_VERIFY_SSL" != "true" ]] && ssl_opt="-k"
    
    local artifacts
    artifacts=$(curl -s --connect-timeout 10 --max-time 30 $ssl_opt \
        -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
        -H "Accept: application/json" \
        "${HARBOR_URL}/api/v2.0/projects/${project_name}/repositories/${encoded_repo}/artifacts?with_tag=true&page_size=100" 2>/dev/null)
    
    [[ -z "$artifacts" ]] && return
    
    # Process artifacts to images
    echo "$artifacts" | jq --arg repo "$full_repo_name" --arg project "$project_name" '
        if type == "array" then
            [.[] | 
                . as $artifact |
                (if .tags then .tags else [{name: "<none>"}] end) |
                .[] |
                {
                    repository: $repo,
                    tag: (.name // "<none>"),
                    digest: ($artifact.digest[0:15] // ""),
                    size: (
                        if $artifact.size < 1048576 then "\(($artifact.size / 1024) | floor)KB"
                        elif $artifact.size < 1073741824 then "\(($artifact.size / 1048576) | floor)MB"
                        else "\((($artifact.size / 1073741824) * 10 | floor) / 10)GB"
                        end
                    ),
                    project: $project
                }
            ]
        else [] end
    ' 2>/dev/null
}

# Export functions for GNU parallel
export -f process_harbor_repo url_encode double_url_encode 2>/dev/null

# Get all Harbor images with parallel processing
get_harbor_images() {
    local cache_key="harbor_images"
    
    [[ -z "$HARBOR_URL" ]] && echo "[]" && return 1
    
    # Check cache
    local cache_file="${CACHE_DIR:-/tmp/imgctl-cache}/${cache_key}.cache"
    if [[ "$ENABLE_CACHE" == "true" && -f "$cache_file" ]]; then
        local file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $file_age -lt ${CACHE_TTL:-300} ]]; then
            cat "$cache_file"
            return 0
        fi
    fi
    
    log_info "Fetching images from Harbor (parallel mode)..."
    
    # Get all projects first
    local projects
    projects=$(harbor_api_get_all "/api/v2.0/projects")
    
    [[ "$projects" == "[]" || -z "$projects" ]] && echo "[]" && return 0
    
    local tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    
    # Build list of all repositories across all projects
    local repo_list="$tmpdir/repos.txt"
    > "$repo_list"
    
    local project_names=$(echo "$projects" | jq -r '.[].name')
    
    # Fetch repositories for all projects (can also be parallelized)
    while IFS= read -r project_name; do
        [[ -z "$project_name" ]] && continue
        
        local repos
        repos=$(harbor_api_get_all "/api/v2.0/projects/${project_name}/repositories")
        
        [[ "$repos" == "[]" || -z "$repos" ]] && continue
        
        # Add each repo to the list
        echo "$repos" | jq -r --arg p "$project_name" '.[] | "\($p)\t\(.name)"' >> "$repo_list"
    done <<< "$project_names"
    
    local repo_count=$(wc -l < "$repo_list")
    log_info "Found $repo_count repositories to process"
    
    if [[ $repo_count -eq 0 ]]; then
        echo "[]"
        return 0
    fi
    
    # Process all repositories in parallel
    local results_file="$tmpdir/results.json"
    
    if [[ "$HAS_PARALLEL" == "yes" && $repo_count -gt 1 ]]; then
        log_info "Using GNU parallel with $MAX_PARALLEL_JOBS jobs"
        
        # Export variables for parallel
        export HARBOR_URL HARBOR_USER HARBOR_PASSWORD HARBOR_VERIFY_SSL
        
        cat "$repo_list" | parallel --will-cite -j "$MAX_PARALLEL_JOBS" --colsep '\t' \
            "source '${SCRIPT_DIR}/harbor.sh' 2>/dev/null; process_harbor_repo {1} {2}" > "$results_file"
    else
        log_info "Using background jobs for $repo_count repositories"
        
        local pids=()
        local job_count=0
        
        while IFS=$'\t' read -r project_name full_repo_name; do
            [[ -z "$project_name" ]] && continue
            
            (process_harbor_repo "$project_name" "$full_repo_name") >> "$results_file" &
            pids+=($!)
            ((job_count++))
            
            # Limit concurrent jobs
            if [[ $job_count -ge $MAX_PARALLEL_JOBS ]]; then
                wait "${pids[0]}" 2>/dev/null
                pids=("${pids[@]:1}")
                ((job_count--))
            fi
        done < "$repo_list"
        
        # Wait for remaining jobs
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null
        done
    fi
    
    # Combine all results
    local all_images="[]"
    if [[ -f "$results_file" && -s "$results_file" ]]; then
        # Filter out empty arrays and combine
        all_images=$(cat "$results_file" | jq -s 'map(select(. != null and . != [])) | add // []')
    fi
    
    local image_count=$(echo "$all_images" | jq 'length')
    log_info "Retrieved $image_count images from Harbor"
    
    # Cache result
    if [[ "$ENABLE_CACHE" == "true" ]]; then
        mkdir -p "${CACHE_DIR:-/tmp/imgctl-cache}" 2>/dev/null
        echo "$all_images" > "$cache_file"
    fi
    
    echo "$all_images"
}

# Test Harbor connectivity
test_harbor_connection() {
    [[ -z "$HARBOR_URL" ]] && return 1
    
    local response
    response=$(harbor_curl "/api/v2.0/health")
    
    [[ -z "$response" ]] && return 1
    
    local status=$(echo "$response" | jq -r '.status // empty')
    [[ "$status" == "healthy" ]] && return 0
    return 1
}
