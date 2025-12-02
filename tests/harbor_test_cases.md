# Harbor Module (harbor.sh) - Edge Case Test Cases

**Module:** `lib/harbor.sh`  
**Version:** 2.1.0  
**Author:** Anubhav Patrick  
**Last Updated:** 2025-12-02  

---

## Table of Contents

1. [Test Environment Setup](#1-test-environment-setup)
2. [Configuration Edge Cases](#2-configuration-edge-cases)
3. [URL Encoding Edge Cases](#3-url-encoding-edge-cases)
4. [API Pagination Edge Cases](#4-api-pagination-edge-cases)
5. [Image Retrieval Edge Cases](#5-image-retrieval-edge-cases)
6. [Parallel Processing Edge Cases](#6-parallel-processing-edge-cases)
7. [Error Handling Edge Cases](#7-error-handling-edge-cases)

---

## 1. Test Environment Setup

### Required Tools
- `curl`, `jq` installed
- Access to a Harbor registry instance
- GNU parallel (optional)

### Test Configuration
Configure in `/etc/imgctl/imgctl.conf`:

| Variable | Example Value |
|----------|--------------|
| `HARBOR_URL` | `https://harbor.example.com` |
| `HARBOR_USER` | `admin` |
| `HARBOR_PASSWORD` | `Harbor12345` |
| `HARBOR_VERIFY_SSL` | `true` or `false` |

---

## 2. Configuration Edge Cases

### TC-CONF-001: Missing HARBOR_URL Configuration
| Field | Value |
|-------|-------|
| **Objective** | Verify graceful handling when HARBOR_URL is not set |
| **Test Command** | `unset HARBOR_URL && source lib/harbor.sh && get_harbor_images` |
| **Expected Result** | Returns empty array `[]`, logs warning "HARBOR_URL is not configured" |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-002: SSL Verification Disabled (Self-Signed Cert)
| Field | Value |
|-------|-------|
| **Objective** | Verify connection succeeds with self-signed cert when SSL verification disabled |
| **Preconditions** | Self-signed certificate on Harbor |
| **Test Command** | `HARBOR_VERIFY_SSL=false source lib/harbor.sh && test_harbor_connection` |
| **Expected Result** | Connection succeeds, `-k` flag used in curl |
| **Status** | ☐ Pass ☐ Fail |

---

## 3. URL Encoding Edge Cases

### TC-URL-001: Special Characters URL Encoding
| Field | Value |
|-------|-------|
| **Objective** | Verify special characters are encoded correctly |
| **Test Command** | `source lib/harbor.sh && url_encode "test/path:tag@sha256"` |
| **Expected Result** | `test%2Fpath%3Atag%40sha256` |
| **Status** | ☐ Pass ☐ Fail |

### TC-URL-002: Double URL Encoding for Proxy Cache
| Field | Value |
|-------|-------|
| **Objective** | Verify double encoding for proxy cache repositories with nested paths |
| **Test Command** | `source lib/harbor.sh && double_url_encode "library/nginx"` |
| **Expected Result** | `library%252Fnginx` (% becomes %25, / becomes %2F, so %2F becomes %252F) |
| **Status** | ☐ Pass ☐ Fail |

### TC-URL-003: Empty String URL Encoding
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of empty string doesn't cause errors |
| **Test Command** | `source lib/harbor.sh && url_encode ""` |
| **Expected Result** | Empty string (no error) |
| **Status** | ☐ Pass ☐ Fail |

---

## 4. API Pagination Edge Cases

### TC-PAGE-001: Empty Results
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of endpoints that return empty arrays |
| **Preconditions** | Empty Harbor project (no repositories) |
| **Test Command** | `source lib/harbor.sh && harbor_api_get_all "/api/v2.0/projects/empty-project/repositories"` |
| **Expected Result** | Returns `[]` without errors |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAGE-002: API Error Response (Non-Existent Project)
| Field | Value |
|-------|-------|
| **Objective** | Verify graceful handling of API errors |
| **Test Command** | `source lib/harbor.sh && harbor_api_get_all "/api/v2.0/projects/nonexistent12345/repositories"` |
| **Expected Result** | Returns `[]`, logs warning about API errors |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAGE-003: Safety Limit (50 Pages Max)
| Field | Value |
|-------|-------|
| **Objective** | Verify the 50-page safety limit prevents infinite loops |
| **Preconditions** | Harbor with >50 repos, set `HARBOR_PAGE_SIZE=1` |
| **Test Steps** | Enable DEBUG logging, query project with >50 repos |
| **Expected Result** | Pagination stops at page 50, doesn't hang |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAGE-004: Endpoint with Existing Query Parameters
| Field | Value |
|-------|-------|
| **Objective** | Verify pagination appends correctly to URLs with existing params (uses `&` not `?`) |
| **Test Command** | `LOG_LEVEL=DEBUG source lib/harbor.sh && harbor_api_get_all "/api/v2.0/projects?name=test"` |
| **Expected Result** | URL becomes `?name=test&page=1&page_size=100` (not `?name=test?page=1`) |
| **Status** | ☐ Pass ☐ Fail |

---

## 5. Image Retrieval Edge Cases

### TC-IMG-001: Untagged Images
| Field | Value |
|-------|-------|
| **Objective** | Verify untagged images show `<none>` as tag (null handling in jq) |
| **Preconditions** | Harbor has an untagged artifact |
| **Test Command** | `source lib/harbor.sh && get_harbor_images \| jq '.[] \| select(.tag == "<none>")'` |
| **Expected Result** | Untagged images show tag as `<none>`, not missing or null |
| **Status** | ☐ Pass ☐ Fail |

### TC-IMG-002: Proxy Cache Repository (Nested Path with Slash)
| Field | Value |
|-------|-------|
| **Objective** | Verify proxy cache repositories with nested paths (containing `/`) are double-encoded |
| **Preconditions** | Harbor proxy cache with repos like `dockerhub/library/nginx` |
| **Test Steps** | Set up proxy cache, pull through cache, fetch images |
| **Expected Result** | Images with nested paths are retrieved correctly |
| **Status** | ☐ Pass ☐ Fail |

### TC-IMG-003: Multiple Tags Same Digest
| Field | Value |
|-------|-------|
| **Objective** | Verify images with multiple tags are listed as separate entries (jq flattening) |
| **Preconditions** | Image with multiple tags (e.g., `latest` and `v1.0`) |
| **Test Command** | `source lib/harbor.sh && get_harbor_images \| jq '[.[] \| select(.repository == "project/myimage")] \| length'` |
| **Expected Result** | Returns count matching number of tags, not 1 |
| **Status** | ☐ Pass ☐ Fail |

---

## 6. Parallel Processing Edge Cases

### TC-PAR-001: Fallback to Background Jobs (No GNU Parallel)
| Field | Value |
|-------|-------|
| **Objective** | Verify fallback works when GNU parallel not available |
| **Preconditions** | GNU parallel is NOT installed (or temporarily renamed) |
| **Test Steps** | Ensure parallel unavailable, fetch images, check logs |
| **Expected Result** | `HAS_PARALLEL=no`, logs show "Using background jobs", results returned |
| **Status** | ☐ Pass ☐ Fail |

### TC-PAR-002: Parallel vs Sequential Results Consistency
| Field | Value |
|-------|-------|
| **Objective** | Verify parallel and sequential produce identical results |
| **Test Steps** | Fetch with `HAS_PARALLEL=yes`, save count; force `HAS_PARALLEL=no`, fetch again, compare |
| **Expected Result** | Both methods return same image count |
| **Status** | ☐ Pass ☐ Fail |

---

## 7. Error Handling Edge Cases

### TC-ERR-001: Invalid JSON Response
| Field | Value |
|-------|-------|
| **Objective** | Verify handling of non-JSON responses (e.g., HTML error page) |
| **Preconditions** | Harbor returns HTML error page (502 gateway error) |
| **Expected Result** | Graceful handling, warning logged, doesn't crash |
| **Status** | ☐ Pass ☐ Fail |

### TC-ERR-002: Empty Artifacts Response
| Field | Value |
|-------|-------|
| **Objective** | Verify handling when repository has no artifacts |
| **Preconditions** | Empty repository in Harbor |
| **Test Steps** | Create empty repo, fetch images |
| **Expected Result** | Logs "No artifacts found", continues to next repo without crash |
| **Status** | ☐ Pass ☐ Fail |

### TC-ERR-003: Temporary File Cleanup
| Field | Value |
|-------|-------|
| **Objective** | Verify temporary files are cleaned up after execution |
| **Test Command** | `ls /tmp \| grep -c tmp; get_harbor_images > /dev/null; ls /tmp \| grep -c tmp` |
| **Expected Result** | No orphaned temp directories after completion |
| **Status** | ☐ Pass ☐ Fail |

---

## Test Summary Report

| Category | Total Tests | Passed | Failed |
|----------|-------------|--------|--------|
| Configuration | 2 | | |
| URL Encoding | 3 | | |
| API Pagination | 4 | | |
| Image Retrieval | 3 | | |
| Parallel Processing | 2 | | |
| Error Handling | 3 | | |
| **TOTAL** | **17** | | |

---

## Sign-Off

| Role | Name | Date |
|------|------|------|
| Tester | | |
| Reviewer | | |

