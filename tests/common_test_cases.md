# Common/Integration Test Cases

**Module:** `bin/imgctl`, `lib/common.sh`, `lib/output.sh`  
**Version:** 2.1.0  
**Author:** Anubhav Patrick  
**Last Updated:** 2025-12-02  

---

## Table of Contents

1. [CLI Command & Option Tests](#1-cli-command--option-tests)
2. [Dependency & Configuration Tests](#2-dependency--configuration-tests)
3. [Output Format Tests](#3-output-format-tests)
4. [Integration Tests](#4-integration-tests)

---

## 1. CLI Command & Option Tests

### TC-CLI-001: Valid Commands Routing
| Field | Value |
|-------|-------|
| **Objective** | Verify all valid commands are routed correctly |
| **Test Commands** | `imgctl get`, `imgctl compare`, `imgctl help` |
| **Expected Result** | Each command executes its corresponding handler without errors |
| **Status** | ☐ Pass ☐ Fail |

### TC-CLI-002: Invalid Command Handling
| Field | Value |
|-------|-------|
| **Objective** | Verify unknown commands show error and exit with non-zero status |
| **Test Command** | `imgctl invalidcmd; echo "Exit code: $?"` |
| **Expected Result** | Error message "Unknown command: invalidcmd", exit code 1 |
| **Status** | ☐ Pass ☐ Fail |

### TC-CLI-003: Output Format Option
| Field | Value |
|-------|-------|
| **Objective** | Verify `-o` / `--output` option sets format correctly |
| **Test Commands** | `imgctl get -o json`, `imgctl get --output csv`, `imgctl get -o table` |
| **Expected Result** | Output rendered in specified format (json/csv/table) |
| **Status** | ☐ Pass ☐ Fail |

### TC-CLI-004: Invalid Output Format
| Field | Value |
|-------|-------|
| **Objective** | Verify invalid output format falls back to table |
| **Test Command** | `imgctl get -o invalidformat` |
| **Expected Result** | Falls back to table format (default case in switch) |
| **Status** | ☐ Pass ☐ Fail |

### TC-CLI-005: Quiet Mode
| Field | Value |
|-------|-------|
| **Objective** | Verify `-q` / `--quiet` suppresses info logs |
| **Test Command** | `imgctl get -q 2>&1` |
| **Expected Result** | No INFO level output, only ERROR messages if any |
| **Status** | ☐ Pass ☐ Fail |

---

## 2. Dependency & Configuration Tests

### TC-DEP-001: Missing Critical Dependency
| Field | Value |
|-------|-------|
| **Objective** | Verify graceful handling when jq/curl/ssh is missing |
| **Test Steps** | Temporarily rename `jq` binary, run `imgctl get` |
| **Expected Result** | Error "Missing dependencies: jq", exit code 1 |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-001: Configuration File Discovery
| Field | Value |
|-------|-------|
| **Objective** | Verify config is found in standard locations |
| **Preconditions** | Config exists at `/etc/imgctl/imgctl.conf` |
| **Test Command** | `LOG_LEVEL=DEBUG imgctl get 2>&1 | grep -i config` |
| **Expected Result** | Logs show config loaded from expected location |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-002: No Configuration File
| Field | Value |
|-------|-------|
| **Objective** | Verify tool runs with defaults when no config found |
| **Preconditions** | Temporarily remove/rename config files |
| **Test Command** | `imgctl get` |
| **Expected Result** | Warning "No configuration file found, using defaults", continues execution |
| **Status** | ☐ Pass ☐ Fail |

### TC-CONF-003: Configuration Validation
| Field | Value |
|-------|-------|
| **Objective** | Verify validate_config reports missing WORKER_NODES |
| **Test Command** | `unset WORKER_NODES && source lib/common.sh && validate_config; echo $?` |
| **Expected Result** | Logs error "WORKER_NODES is not configured", returns 1 |
| **Status** | ☐ Pass ☐ Fail |

---

## 3. Output Format Tests

### TC-OUT-001: JSON Output Structure
| Field | Value |
|-------|-------|
| **Objective** | Verify JSON output is valid and contains required fields |
| **Test Command** | `imgctl get -o json | jq '.timestamp, .harbor_images, .comparison'` |
| **Expected Result** | Valid JSON with timestamp, harbor_images array, comparison object |
| **Status** | ☐ Pass ☐ Fail |

### TC-OUT-002: CSV Output Structure
| Field | Value |
|-------|-------|
| **Objective** | Verify CSV output has correct header and format |
| **Test Command** | `imgctl get -o csv | head -1` |
| **Expected Result** | Header: `source,repository,tag,id,size` |
| **Status** | ☐ Pass ☐ Fail |

### TC-OUT-003: Harbor Image Filtering in Output
| Field | Value |
|-------|-------|
| **Objective** | Verify `<none>` tagged images are filtered from Harbor output |
| **Test Command** | `imgctl get harbor -o json | jq '[.harbor_images[] | select(.tag == "<none>")] | length'` |
| **Expected Result** | Returns `0` (no `<none>` tags in filtered output) |
| **Status** | ☐ Pass ☐ Fail |

---

## 4. Integration Tests

### TC-INT-001: Parallel Harbor + Nodes Fetch
| Field | Value |
|-------|-------|
| **Objective** | Verify `get all` fetches Harbor and node images in parallel |
| **Test Command** | `time imgctl get all -o json` |
| **Expected Result** | Execution time < sum of individual fetches (parallelism works) |
| **Status** | ☐ Pass ☐ Fail |

### TC-INT-002: End-to-End Get Scope Filtering
| Field | Value |
|-------|-------|
| **Objective** | Verify scope filtering works correctly |
| **Test Commands** | `imgctl get harbor`, `imgctl get nodes`, `imgctl get all` |
| **Expected Result** | `harbor` returns only Harbor images, `nodes` returns only node images, `all` returns both |
| **Status** | ☐ Pass ☐ Fail |

### TC-INT-003: Correlation ID Tracing
| Field | Value |
|-------|-------|
| **Objective** | Verify correlation ID appears in logs for traceability |
| **Test Steps** | 1) Run `imgctl get`, 2) Check log file for correlation ID pattern |
| **Expected Result** | All log entries contain same 8-char correlation ID: `[XXXXXXXX]` |
| **Status** | ☐ Pass ☐ Fail |

---

## Test Summary Report

| Category | Total Tests | Passed | Failed |
|----------|-------------|--------|--------|
| CLI Command & Options | 5 | | |
| Dependency & Configuration | 4 | | |
| Output Format | 3 | | |
| Integration | 3 | | |
| **TOTAL** | **15** | | |

---

## Sign-Off

| Role | Name | Date |
|------|------|------|
| Tester | | |
| Reviewer | | |

