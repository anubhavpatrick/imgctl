# Crictl Module (crictl.sh) - Edge Case Test Cases

**Module:** `lib/crictl.sh`  
**Version:** 2.1.0  
**Author:** Anubhav Patrick  
**Last Updated:** 2025-12-02  

---

## Table of Contents

1. [Test Environment Setup](#1-test-environment-setup)
2. [Configuration Edge Cases](#2-configuration-edge-cases)
3. [Output Parsing Edge Cases](#3-output-parsing-edge-cases)
4. [SSH/Node Communication Edge Cases](#4-sshnode-communication-edge-cases)
5. [Caching Edge Cases](#5-caching-edge-cases)
6. [Parallel Processing Edge Cases](#6-parallel-processing-edge-cases)
7. [Image Filtering & Comparison Edge Cases](#7-image-filtering--comparison-edge-cases)

---

## 1. Test Environment Setup

### Required Tools
- `ssh`, `jq` installed
- Access to Kubernetes worker nodes with crictl
- GNU parallel (optional)

### Test Configuration
Configure in `/etc/imgctl/imgctl.conf`:

| Variable | Example Value |
|----------|--------------|
| `WORKER_NODES` | `worker1 worker2 worker3` |
| `SSH_USER` | `root` |
| `SSH_KEY` | `/root/.ssh/id_rsa` |
| `SSH_OPTIONS` | `-o StrictHostKeyChecking=no -o ConnectTimeout=10` |
| `CRICTL_PATH` | `/usr/bin/crictl` |
| `CRICTL_TIMEOUT` | `30` |
| `ENABLE_CACHE` | `true` |
| `CACHE_TTL` | `300` |

---

## 2. Configuration Edge Cases

### TC-CONF-001: Missing WORKER_NODES Configuration
| Field | Value |
|-------|-------|
| **Objective** | Verify graceful handling when WORKER_NODES is not set |
| **Test Command** | `unset WORKER_NODES && source lib/crictl.sh && get_all_nodes_images` |
| **Expected Result** | Returns empty JSON `{}`, returns exit code 1 |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-002: Invalid SSH Key Path
| Field | Value |
|-------|-------|
| **Objective** | Verify handling when SSH_KEY points to non-existent file |
| **Preconditions** | Set `SSH_KEY=/nonexistent/key` |
| **Test Command** | `SSH_KEY=/nonexistent/key source lib/crictl.sh && get_node_images_single worker1` |
| **Expected Result** | SSH command built without `-i` flag (key file check in `build_ssh_command`) |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-003: Custom CRICTL_PATH
| Field | Value |
|-------|-------|
| **Objective** | Verify custom crictl path is used in SSH command |
| **Test Command** | `CRICTL_PATH=/custom/path/crictl LOG_LEVEL=DEBUG source lib/crictl.sh && get_node_images_single worker1` |
| **Expected Result** | SSH command uses `/custom/path/crictl` instead of default `/usr/bin/crictl` |
| **Status** | ☐ Pass ☐ Fail |

---

## 3. Output Parsing Edge Cases

### TC-PARSE-001: Empty Crictl Output
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of empty crictl output |
| **Test Command** | `source lib/crictl.sh && parse_crictl_output ""` |
| **Expected Result** | Returns empty JSON array `[]` |
| **Status** | ☐ Pass ☐ Fail |

### TC-PARSE-002: Header-Only Output (No Images)
| Field | Value |
|-------|-------|
| **Objective** | Verify handling when crictl returns only header row |
| **Test Input** | `IMAGE                TAG       IMAGE ID       SIZE` |
| **Test Command** | `source lib/crictl.sh && parse_crictl_output "IMAGE                TAG       IMAGE ID       SIZE"` |
| **Expected Result** | Returns empty JSON array `[]` (header is skipped) |
| **Status** | ☐ Pass ☐ Fail |

### TC-PARSE-003: Special Characters in Repository Names
| Field | Value |
|-------|-------|
| **Objective** | Verify repositories with special characters are parsed and escaped correctly |
| **Test Input** | Repository containing quotes, backslashes: `registry.io/path/"test"` |
| **Expected Result** | JSON output has properly escaped characters (`\"` for quotes) |
| **Status** | ☐ Pass ☐ Fail |

### TC-PARSE-004: Missing Tag (`<none>` Handling)
| Field | Value |
|-------|-------|
| **Objective** | Verify images with empty/missing tags are assigned `<none>` |
| **Test Input** | Crictl output with empty TAG column |
| **Expected Result** | JSON shows `"tag":"<none>"` for untagged images |
| **Status** | ☐ Pass ☐ Fail |

### TC-PARSE-005: Variable Column Widths
| Field | Value |
|-------|-------|
| **Objective** | Verify parser handles different column alignments from various crictl versions |
| **Test Input** | Crictl output with different spacing/alignment |
| **Expected Result** | All fields (repository, tag, image_id, size) extracted correctly |
| **Status** | ☐ Pass ☐ Fail |

### TC-PARSE-006: Long Repository Names
| Field | Value |
|-------|-------|
| **Objective** | Verify very long repository names (>100 chars) don't break parsing |
| **Test Input** | `registry.example.com/very/long/nested/path/to/repository/image` |
| **Expected Result** | Full repository name preserved in JSON output |
| **Status** | ☐ Pass ☐ Fail |

---

## 4. SSH/Node Communication Edge Cases

### TC-SSH-001: Node Unreachable
| Field | Value |
|-------|-------|
| **Objective** | Verify handling when a node is unreachable (SSH fails) |
| **Preconditions** | Configure a non-existent node in WORKER_NODES |
| **Test Command** | `WORKER_NODES="unreachable-node" source lib/crictl.sh && get_node_images_single unreachable-node` |
| **Expected Result** | Returns `[]`, logs warning "Failed to retrieve images from node: unreachable-node" |
| **Status** | ☐ Pass ☐ Fail |

### TC-SSH-002: Crictl Timeout
| Field | Value |
|-------|-------|
| **Objective** | Verify timeout is enforced when crictl hangs |
| **Preconditions** | Set `CRICTL_TIMEOUT=2`, simulate slow response |
| **Test Steps** | Set very low timeout, query node with slow response |
| **Expected Result** | Command times out after 2 seconds, returns `[]` |
| **Status** | ☐ Pass ☐ Fail |

### TC-SSH-003: Partial Node Failure (Multi-Node)
| Field | Value |
|-------|-------|
| **Objective** | Verify successful nodes return data when some nodes fail |
| **Preconditions** | Configure mix of reachable and unreachable nodes |
| **Test Command** | `WORKER_NODES="good-node bad-node" source lib/crictl.sh && get_all_nodes_images` |
| **Expected Result** | Returns data for good-node, empty array for bad-node, logs warning with failure count |
| **Status** | ☐ Pass ☐ Fail |

### TC-SSH-004: SSH Options Applied Correctly
| Field | Value |
|-------|-------|
| **Objective** | Verify custom SSH_OPTIONS are included in SSH command |
| **Test Command** | `SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=5" source lib/crictl.sh && build_ssh_command worker1` |
| **Expected Result** | Output contains both `-o StrictHostKeyChecking=no` and `-o ConnectTimeout=5` |
| **Status** | ☐ Pass ☐ Fail |

### TC-SSH-005: Crictl Command Error (Non-Zero Exit)
| Field | Value |
|-------|-------|
| **Objective** | Verify handling when crictl returns error (permission denied, not found) |
| **Preconditions** | Node where crictl is not installed or user lacks permissions |
| **Expected Result** | Returns `[]`, logs warning about crictl error |
| **Status** | ☐ Pass ☐ Fail |

---

## 5. Caching Edge Cases

### TC-CACHE-001: Cache Hit (Valid Cache)
| Field | Value |
|-------|-------|
| **Objective** | Verify cached data is returned without SSH call when cache is valid |
| **Test Steps** | 1) Fetch images (populates cache), 2) Immediately fetch again |
| **Expected Result** | Second call returns cached data, no SSH connection made |
| **Status** | ☐ Pass ☐ Fail |

### TC-CACHE-002: Cache Miss (Expired Cache)
| Field | Value |
|-------|-------|
| **Objective** | Verify expired cache triggers fresh SSH fetch |
| **Preconditions** | Set `CACHE_TTL=1` (1 second) |
| **Test Steps** | 1) Fetch images, 2) Wait 2 seconds, 3) Fetch again |
| **Expected Result** | Second call makes SSH connection (cache expired) |
| **Status** | ☐ Pass ☐ Fail |

### TC-CACHE-003: Cache Disabled
| Field | Value |
|-------|-------|
| **Objective** | Verify cache is bypassed when ENABLE_CACHE=false |
| **Test Command** | `ENABLE_CACHE=false source lib/crictl.sh && get_node_images_single worker1` |
| **Expected Result** | Always fetches via SSH, no cache files created |
| **Status** | ☐ Pass ☐ Fail |

### TC-CACHE-004: Cache Key Sanitization
| Field | Value |
|-------|-------|
| **Objective** | Verify node names with special characters are sanitized for cache keys |
| **Test Steps** | Use node with special chars: `worker-1.example.com` |
| **Expected Result** | Cache key becomes `node_worker_1_example_com` (safe filename) |
| **Status** | ☐ Pass ☐ Fail |

### TC-CACHE-005: Cache Directory Not Writable
| Field | Value |
|-------|-------|
| **Objective** | Verify graceful handling when cache directory is not writable |
| **Preconditions** | Set `CACHE_DIR` to read-only path |
| **Expected Result** | Data still returned (just not cached), no crash |
| **Status** | ☐ Pass ☐ Fail |

---

## 6. Parallel Processing Edge Cases

### TC-PAR-001: GNU Parallel Available
| Field | Value |
|-------|-------|
| **Objective** | Verify GNU parallel is detected and used when available |
| **Preconditions** | GNU parallel installed |
| **Test Command** | `source lib/crictl.sh && echo $HAS_PARALLEL` |
| **Expected Result** | Returns `yes`, parallel used for multi-node fetch |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-002: Fallback to Background Jobs (No GNU Parallel)
| Field | Value |
|-------|-------|
| **Objective** | Verify fallback to bash background jobs when parallel unavailable |
| **Preconditions** | Temporarily rename/remove parallel binary |
| **Test Steps** | Hide parallel command, fetch images from multiple nodes |
| **Expected Result** | `HAS_PARALLEL=no`, uses bash `&` and `wait`, results returned correctly |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-003: Parallel vs Sequential Results Consistency
| Field | Value |
|-------|-------|
| **Objective** | Verify parallel and sequential execution produce identical results |
| **Test Steps** | 1) Fetch with parallel, save result 2) Force `HAS_PARALLEL=no`, fetch again, compare |
| **Expected Result** | Both methods return identical image data |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-004: Single Node (No Parallelization Needed)
| Field | Value |
|-------|-------|
| **Objective** | Verify single node doesn't unnecessarily use parallel |
| **Test Command** | `WORKER_NODES="single-node" source lib/crictl.sh && get_all_nodes_images` |
| **Expected Result** | Parallel skipped for ≤1 nodes (optimization) |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-005: Temporary File Cleanup
| Field | Value |
|-------|-------|
| **Objective** | Verify temp directory created for parallel jobs is cleaned up |
| **Test Command** | `ls /tmp | wc -l; get_all_nodes_images > /dev/null; ls /tmp | wc -l` |
| **Expected Result** | No orphaned temp directories after execution (trap EXIT works) |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-006: Environment Variables Exported for Parallel
| Field | Value |
|-------|-------|
| **Objective** | Verify required variables (SSH_OPTIONS, SSH_KEY, etc.) are exported for parallel subprocesses |
| **Test Steps** | Set custom SSH_USER, run parallel fetch, verify SSH uses correct user |
| **Expected Result** | Parallel subprocesses have access to all required env variables |
| **Status** | ☐ Pass ☐ Fail |

---

## 7. Image Filtering & Comparison Edge Cases

### TC-FILTER-001: Ignore File Missing
| Field | Value |
|-------|-------|
| **Objective** | Verify comparison works when ignore file doesn't exist |
| **Preconditions** | Remove `/etc/imgctl/images_to_ignore.txt` |
| **Test Command** | `source lib/crictl.sh && compare_node_images '{"node1":[...]}'` |
| **Expected Result** | No filtering applied (empty ignore list `[]`), no errors |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-002: Ignore File Empty
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of empty ignore file (only header or blank) |
| **Preconditions** | Ignore file contains only header: `IMAGE,TAG,IMAGE ID,SIZE` |
| **Expected Result** | No images filtered, comparison proceeds normally |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-003: `<none>` Tag Filtering
| Field | Value |
|-------|-------|
| **Objective** | Verify images with `<none>` tag are automatically excluded from comparison |
| **Test Input** | JSON with images having `"tag":"<none>"` |
| **Expected Result** | `<none>` tagged images excluded from both common and node_specific results |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-004: Ignored Images Excluded
| Field | Value |
|-------|-------|
| **Objective** | Verify images listed in ignore file are excluded from comparison |
| **Test Input** | Ignore file: `docker.io/calico/cni,v3.29.2` |
| **Expected Result** | `docker.io/calico/cni:v3.29.2` not in common or node_specific output |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-005: All Images Common Across Nodes
| Field | Value |
|-------|-------|
| **Objective** | Verify correct output when all nodes have identical images |
| **Test Input** | All nodes have same image list |
| **Expected Result** | `common` array contains all images, `node_specific` has empty arrays for each node |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-006: No Common Images
| Field | Value |
|-------|-------|
| **Objective** | Verify correct output when nodes have completely different images |
| **Test Input** | Each node has unique images |
| **Expected Result** | `common` array is empty, `node_specific` contains each node's images |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-007: Single Node Comparison
| Field | Value |
|-------|-------|
| **Objective** | Verify comparison logic handles single node gracefully |
| **Test Input** | JSON with only one node's data |
| **Expected Result** | All images in `common` (present on all 1 nodes), `node_specific` empty |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-008: Empty Node Results in Multi-Node
| Field | Value |
|-------|-------|
| **Objective** | Verify comparison handles nodes with empty image lists |
| **Test Input** | `{"node1":[...images...], "node2":[]}` |
| **Expected Result** | No images marked as common (node2 has none), all in node_specific for node1 |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-009: Duplicate Image Reference Handling
| Field | Value |
|-------|-------|
| **Objective** | Verify same image on multiple nodes is correctly deduplicated |
| **Test Input** | `nginx:latest` on node1 and node2 |
| **Expected Result** | Single entry in `common` with both nodes listed (not duplicated) |
| **Status** | ☐ Pass ☐ Fail |

### TC-FILTER-010: Invalid JSON in Ignore File
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of malformed entries in ignore file |
| **Test Input** | Ignore file with missing columns or extra commas |
| **Expected Result** | Graceful handling, valid entries still processed |
| **Status** | ☐ Pass ☐ Fail |

---

## Test Summary Report

| Category | Total Tests | Passed | Failed |
|----------|-------------|--------|--------|
| Configuration | 3 | | |
| Output Parsing | 6 | | |
| SSH/Node Communication | 5 | | |
| Caching | 5 | | |
| Parallel Processing | 6 | | |
| Image Filtering & Comparison | 10 | | |
| **TOTAL** | **35** | | |

---

## Sign-Off

| Role | Name | Date |
|------|------|------|
| Tester | | |
| Reviewer | | |

