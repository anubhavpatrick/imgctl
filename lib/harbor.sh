#!/bin/bash
# ============================================================================
# imgctl - Harbor Module (Parallel Processing)
# ============================================================================
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-12-02
# ============================================================================

# To ensure common.sh is sourced correctly irrespective of the directory the script is run from
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
    [[ "$HARBOR_VERIFY_SSL" != "true" ]] && ssl_opt="-k" # -k option is used to skip SSL verification
    
    log_debug "Harbor API call: ${endpoint}"
    
    curl -s --connect-timeout 10 --max-time 30 $ssl_opt \
        -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
        -H "Accept: application/json" \
        "${HARBOR_URL}${endpoint}" 2>/dev/null
}

# URL encode
url_encode() {
    # jq options
    # -s to read the input as a single string
    # -R to read the input as raw text
    # -r to output the result as a raw string
    # @uri to encode the input as a URI
    echo -n "$1" | jq -sRr @uri
}

# Double URL encode for proxy cache repos
double_url_encode() {
    local encoded=$(url_encode "$1")
    # Replace every '%' with '%25' to achieve double URL encoding (as Harbor proxy cache repos require)
    echo "${encoded//%/%25}"
}

# Fetch all pages from a paginated Harbor API endpoint
# Arguments:
#   $1 - The API endpoint to query (may already contain query parameters)
# Returns:
#   JSON array containing all results from all pages
harbor_api_get_all() {
    local endpoint="$1"
    local page_size="${HARBOR_PAGE_SIZE:-100}"  # Default to 100 items per page if not configured
    local page=1
    local all_results="[]"  # Initialize empty JSON array to accumulate results
    
    while true; do
        # Determine the correct query string separator
        # Use '&' if endpoint already has query params (contains '?'), otherwise use '?'
        # For example: /api/v2.0/projects?page=1&page_size=100 ; if endpoint is /api/v2.0/projects
        # For example: /api/v2.0/projects/project1/repositories?page=1&page_size=100
        local sep="?"
        [[ "$endpoint" == *"?"* ]] && sep="&"
        
        log_debug "Fetching page $page from ${endpoint}"
        
        # Fetch current page from the API
        local response
        response=$(harbor_curl "${endpoint}${sep}page=${page}&page_size=${page_size}")
        
        if [[ -z "$response" ]]; then
            log_warning "Empty response from Harbor API for endpoint: ${endpoint}"
            break
        fi
        
        # Validate that response is valid JSON
        # jq -e 'type' checks if the response is a valid JSON object
        # jq -e 'type' returns 0 if the response is valid JSON, 1 otherwise
        if ! echo "$response" | jq -e 'type' >/dev/null 2>&1; then
            log_warning "Invalid JSON response from Harbor API for endpoint: ${endpoint}"
            break
        fi
        
        # Check if response contains API errors
        if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
            log_warning "Harbor API returned errors for endpoint: ${endpoint}"
            break
        fi
        
        # Normalize response: wrap single objects in an array for consistent handling
        [[ $(echo "$response" | jq 'type') == '"object"' ]] && response="[$response]"
        
        # Get the number of items returned in this page
        local count=$(echo "$response" | jq 'length')
        [[ $count -eq 0 ]] && break  # No more results
        
        # Merge current page results into the accumulated results array
        all_results=$(echo "$all_results $response" | jq -s 'add')
        
        # If we got fewer items than page_size, this is the last page
        [[ $count -lt $page_size ]] && break
        
        ((page++))  # Move to the next page
        
        # Safety limit: prevent infinite loops by capping at 50 pages (5000 items max)
        [[ $page -gt 50 ]] && break
    done
    
    local total_results=$(echo "$all_results" | jq 'length')
    log_debug "Fetched $total_results total results from ${endpoint}"
    
    echo "$all_results"
}

# Process a single repository (called by parallel)
process_harbor_repo() {
    local project_name="$1"
    local full_repo_name="$2"
    
    log_debug "Processing repository: ${full_repo_name}"
    
    # Get repo name for API
    local repo_name="${full_repo_name#${project_name}/}"
    
    # Encode for URL
    local encoded_repo
    # If repo name contains a slash like "project/repo", double URL encode it
    if [[ "$repo_name" == *"/"* ]]; then 
        encoded_repo=$(double_url_encode "$repo_name")
    else
        # Otherwise, just URL encode it
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
    
    if [[ -z "$artifacts" ]]; then
        log_warning "No artifacts found for repository: ${full_repo_name}"
        return
    fi
    
    # -------------------------------------------------------------------------
    # Process artifacts to images - Data Transformation Pipeline
    # -------------------------------------------------------------------------
    # Input:  Harbor API artifact JSON array
    # Output: Normalized JSON array with fields: repository, tag, digest, size, project
    #
    # This jq script acts as a Translator performing three transformations:
    #
    # 1. FLATTENING (One-to-Many)
    #    Converts "Parent with Children" to "Individual Rows"
    #    Example: One artifact with tags ["v1.0", "latest"] becomes two rows,
    #    each with the parent's digest/size but different tags.
    #
    # 2. NORMALIZATION (Handling Nulls)
    #    Ensures consistent data shapes when data is missing.
    #    Example: Untagged images (tags: null) get placeholder "<none>"
    #    so the row isn't lost.
    #
    # 3. FORMATTING (Humanization)
    #    Translates machine language (Bytes) to human language (KB/MB/GB).
    #    Example: 5690831667 bytes → "5.3GB"
    # -------------------------------------------------------------------------
    echo "$artifacts" | jq --arg repo "$full_repo_name" --arg project "$project_name" '
        if type == "array" then
            # .[] is used to iterate over the array of artifacts
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

# Fetch repositories for a single project (called by parallel)
fetch_project_repos() {
    local project_name="$1"
    
    local repos
    repos=$(harbor_api_get_all "/api/v2.0/projects/${project_name}/repositories")
    
    [[ "$repos" == "[]" || -z "$repos" ]] && return
    
    # Output in tab-separated format: project_name\tfull_repo_name
    echo "$repos" | jq -r --arg p "$project_name" '.[] | "\($p)\t\(.name)"'
}

# Export functions for GNU parallel
# Also export shared functions from common.sh that may be used
export -f process_harbor_repo fetch_project_repos url_encode double_url_encode harbor_api_get_all harbor_curl log_debug log_warning get_cache set_cache 2>/dev/null

# Get all Harbor images with parallel processing
get_harbor_images() {
    local cache_key="harbor_images"
    
    if [[ -z "$HARBOR_URL" ]]; then
        log_warning "HARBOR_URL is not configured, skipping Harbor image fetch"
        echo "[]"
        return 1
    fi
    
    # Check cache using shared function from common.sh
    local cached_data
    if cached_data=$(get_cache "$cache_key"); then
        log_debug "Returning cached Harbor images"
        echo "$cached_data"
        return 0
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
    
    local project_names=$(echo "$projects" | jq -r '.[].name') #-r is used to output the result as a raw string
    
    # Fetch repositories for all projects in parallel
    local project_count=$(echo "$project_names" | grep -c .)
    
    if [[ "$HAS_PARALLEL" == "yes" && $project_count -gt 1 ]]; then
        log_debug "Fetching repos from $project_count projects in parallel"
        
        # Export variables for parallel
        export HARBOR_URL HARBOR_USER HARBOR_PASSWORD HARBOR_VERIFY_SSL HARBOR_PAGE_SIZE
        
        echo "$project_names" | parallel --will-cite -j "$MAX_PARALLEL_JOBS" \
            "source '${SCRIPT_DIR}/harbor.sh' 2>/dev/null; fetch_project_repos {}" > "$repo_list"
    else
        log_debug "Fetching repos from $project_count projects sequentially"
        while IFS= read -r project_name; do
            [[ -z "$project_name" ]] && continue
            fetch_project_repos "$project_name" >> "$repo_list"
        done <<< "$project_names"
    fi
    
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
    # -f checks if file exists, -s checks if file has content (size > 0)
    if [[ -f "$results_file" && -s "$results_file" ]]; then
        # -------------------------------------------------------------------------
        # Combine parallel job results into a single JSON array
        # -------------------------------------------------------------------------
        # Input: Multiple JSON arrays (one per line from each parallel job)
        #   [{nginx...}]
        #   [{redis...}]
        #   []           <- empty (no artifacts found)
        #   null         <- failed job
        #
        # Pipeline:
        #   jq -s                              : Slurp all lines into one array of arrays
        #   map(select(. != null and . != [])) : Remove nulls and empty arrays
        #   add                                : Flatten [[a],[b]] into [a,b]
        #   // []                              : Fallback to empty array if result is null
        #
        # Output: Single flat array of all images
        #   [{nginx...}, {redis...}]
        # -------------------------------------------------------------------------
        all_images=$(cat "$results_file" | jq -s 'map(select(. != null and . != [])) | add // []')
    fi
    
    local image_count=$(echo "$all_images" | jq 'length')
    log_info "Retrieved $image_count images from Harbor"
    
    # Cache result using shared function from common.sh
    set_cache "$cache_key" "$all_images"
    
    echo "$all_images"
}

# Test Harbor connectivity
test_harbor_connection() {
    log_debug "Testing Harbor connection to ${HARBOR_URL}"
    
    [[ -z "$HARBOR_URL" ]] && return 1
    
    local response
    response=$(harbor_curl "/api/v2.0/health")
    
    if [[ -z "$response" ]]; then
        log_warning "Harbor connection test failed: no response from ${HARBOR_URL}"
        return 1
    fi
    
    local status=$(echo "$response" | jq -r '.status // empty')
    if [[ "$status" == "healthy" ]]; then
        log_debug "Harbor connection test successful: status is healthy"
        return 0
    fi
    
    log_warning "Harbor connection test failed: status is '${status}'"
    return 1
}
