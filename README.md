# imgctl - Cluster Image Management Tool

A scalable command-line tool for managing and viewing container images across NVIDIA BCM clusters with DGX nodes and Harbor private registry.

## Overview

`imgctl` provides a unified interface to:

- View container images in Harbor private registry
- View and compare container images across worker nodes via `crictl`
- Filter out Kubernetes system images using an ignore list
- Export data in multiple formats (table, JSON, CSV)

Designed for BCM (Base Command Manager) clusters running Kubernetes on NVIDIA DGX H200 servers.

## Features

- **Multi-node Support**: Scalable to any number of worker nodes
- **Harbor Integration**: Full support for Harbor API v2.0 with pagination
- **Image Filtering**: Exclude Kubernetes/system images via configurable ignore file
- **Automatic Tag Filtering**: Images without tags (`<none>`) are automatically excluded
- **Comparison Analysis**: Identify common and unique images across nodes
- **Parallel Processing**: Uses GNU `parallel` for faster execution
- **Multiple Output Formats**: Table, JSON, CSV
- **Caching**: Reduce API calls with configurable TTL cache
- **Day-wise Logging**: Automatic log rotation in `/var/log/giindia/imgctl/`

## Requirements

- Bash 4.0+
- `jq` (JSON processor)
- `curl` (HTTP client)
- `parallel` (GNU parallel - optional but recommended for performance)
- SSH access to worker nodes (key-based authentication recommended)
- `crictl` installed on worker nodes

## Quick Start

### Installation

```bash
# Clone or copy the project to the head node
cd ~/imgctl

# Ensure correct directory structure
tree
# Expected:
# .
# ├── bin/
# │   └── imgctl
# ├── conf/
# │   └── imgctl.conf
# ├── lib/
# │   ├── common.sh
# │   ├── crictl.sh
# │   ├── harbor.sh
# │   └── output.sh
# ├── images_to_ignore.txt
# ├── install.sh
# ├── uninstall.sh
# └── README.md

# Run installation
chmod +x install.sh
sudo ./install.sh
```

The installer will automatically:
- Install dependencies (`jq`, `curl`) if missing
- Copy files to `/opt/imgctl/`
- Install configuration to `/etc/imgctl/imgctl.conf`
- Copy the ignore list to `/etc/imgctl/images_to_ignore.txt`
- Create log and cache directories
- Create symlink at `/usr/local/bin/imgctl`

### Configuration

Edit the configuration file:

```bash
sudo nano /etc/imgctl/imgctl.conf
```

Key settings to update:

```bash
# Worker nodes (space-separated)
WORKER_NODES="k8s-worker1 k8s-worker2"

# Harbor configuration
HARBOR_URL="https://bcm11-headnode:9443"
HARBOR_USER="admin"
HARBOR_PASSWORD="your-password"
HARBOR_VERIFY_SSL="false"

# Ignore file path
IGNORE_FILE="/etc/imgctl/images_to_ignore.txt"
```

### Verify Installation

```bash
# Check version
imgctl --version

# Show help
imgctl help
```

## Usage

### Get Images

```bash
# Get all images (Harbor + node comparison)
imgctl get

# Same as above (explicit)
imgctl get all

# Get Harbor images only
imgctl get harbor

# Get images from all nodes (with comparison)
imgctl get nodes

# Output in JSON format
imgctl get -o json

# Output in CSV format
imgctl get -o csv
```

### Compare Images

```bash
# Compare images across all nodes
imgctl compare

# Output comparison in JSON
imgctl compare -o json
```

### Options

```bash
# Quiet mode (errors only)
imgctl -q get

# Disable colored output
imgctl --no-color get

# Show version
imgctl --version

# Show help
imgctl help
```

## Output Format

The default table output displays in this order:

1. **Harbor Registry Images** - All tagged images in Harbor
2. **Common Images** - Images present on all worker nodes (filtered)
3. **Unique Images per Node** - Images only on specific nodes (filtered)
4. **Summary** - Statistics

### Example Output

```
Harbor Registry Images (10 images)
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       DIGEST          SIZE
-----------------------------------------------------------------------------------------------------------
nvcr/nvidia/pytorch                                     20.12-py3                 sha256:cc14c0cf 5.8GB
nvcr/nvidia/pytorch                                     24.04-py3                 sha256:a1b2c3d4 9.3GB
test/custom                                             v1                        sha256:b992cbf6 9.3GB
...

=== Worker Node Images (Filtered) ===

Common Images (Present on all worker nodes) - 25 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
bcm11-headnode:9443/nvcr/nvidia/pytorch                 20.12-py3                 ad0f29ddeb63e   6.26GB
nvcr.io/nvidia/pytorch                                  24.10-py3                 295f8a46d16eb   10.7GB
...

Unique Images on k8s-worker1 - 3 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
docker.io/kubeflow/training-operator                    v1-855e096                29b5090daeb1a   27.8MB
...

Unique Images on k8s-worker2 - 5 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
docker.io/library/nginx                                 latest                    07ccdb7838758   62.7MB
...

Summary
------------------------------------------------------------
  Harbor Registry:         10 images
  Common across nodes:     25 images
  Unique to k8s-worker1:   3 images
  Unique to k8s-worker2:   5 images

  Total images per node (before filtering):
    k8s-worker1: 35 images
    k8s-worker2: 48 images
```

## Image Filtering

### Ignore File Format

The ignore file (`/etc/imgctl/images_to_ignore.txt`) uses CSV format:

```csv
IMAGE,TAG,IMAGE ID,SIZE
docker.io/calico/cni,v3.29.2,cda13293c895a,99.3MB
docker.io/calico/node,v3.29.2,048bf7af1f8c6,142MB
registry.k8s.io/pause,3.8,4873874c08efc,311kB
registry.k8s.io/kube-proxy,v1.30.13,a6946560b0b08,29.2MB
```

**Note**: Only the `IMAGE` and `TAG` columns are used for matching. The `IMAGE ID` and `SIZE` columns are for reference only.

### Automatic Filtering

The following are automatically filtered:

- Images without tags (`<none>`)
- Images matching entries in the ignore file

### Managing the Ignore List

```bash
# View current ignore list
cat /etc/imgctl/images_to_ignore.txt

# Add a new image to ignore
echo "docker.io/library/busybox,latest,abc123,2MB" >> /etc/imgctl/images_to_ignore.txt

# Clear cache after modifying ignore list (to see changes immediately)
sudo rm -rf /var/cache/imgctl/*.cache
```

## Directory Structure

### Installation Paths

```
/opt/imgctl/                    # Installation directory
├── bin/
│   └── imgctl                  # Main executable
├── lib/
│   ├── common.sh               # Core utilities, logging, SSH, cache
│   ├── crictl.sh               # Worker node image retrieval
│   ├── harbor.sh               # Harbor API integration
│   └── output.sh               # Output formatting
└── conf/
    └── imgctl.conf             # Default configuration template

/etc/imgctl/                    # Configuration directory
├── imgctl.conf                 # System configuration
└── images_to_ignore.txt        # Images to exclude from output

/var/log/giindia/imgctl/        # Log directory
└── imgctl-YYYY-MM-DD.log       # Daily log files

/var/cache/imgctl/              # Cache directory
└── *.cache                     # Cached data files

/usr/local/bin/imgctl           # Symlink to executable
```

## Configuration Reference

| Setting | Description | Default |
|---------|-------------|---------|
| `CLUSTER_NAME` | Cluster identifier | `dgx-cluster` |
| `WORKER_NODES` | Space-separated node list | - |
| `SSH_USER` | SSH username | `root` |
| `SSH_OPTIONS` | SSH command options | `-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` |
| `SSH_KEY` | Path to SSH key file | - |
| `HARBOR_URL` | Harbor registry URL | - |
| `HARBOR_USER` | Harbor username | - |
| `HARBOR_PASSWORD` | Harbor password | - |
| `HARBOR_VERIFY_SSL` | Verify SSL certificate | `false` |
| `HARBOR_PAGE_SIZE` | API pagination size | `100` |
| `IGNORE_FILE` | Path to ignore list CSV | `/etc/imgctl/images_to_ignore.txt` |
| `MAX_PARALLEL_JOBS` | Parallel job limit | `10` |
| `CRICTL_PATH` | Path to crictl on workers | `/usr/bin/crictl` |
| `CRICTL_TIMEOUT` | Crictl command timeout (seconds) | `30` |
| `LOG_DIR` | Log file directory | `/var/log/giindia/imgctl` |
| `LOG_LEVEL` | Logging level (DEBUG/INFO/WARNING/ERROR) | `INFO` |
| `LOG_RETENTION_DAYS` | Days to keep logs | `30` |
| `MAX_LOG_SIZE` | Maximum log file size in bytes | `104857600` (100MB) |
| `ENABLE_CACHE` | Enable caching | `true` |
| `CACHE_DIR` | Cache directory | `/var/cache/imgctl` |
| `CACHE_TTL` | Cache TTL in seconds | `300` |
| `DEFAULT_OUTPUT_FORMAT` | Default output format | `table` |

## Performance Tuning

### Enable GNU Parallel

For best performance with many nodes/repositories, install GNU parallel:

```bash
# Ubuntu/Debian
sudo apt-get install parallel

# RHEL/CentOS
sudo yum install parallel
```

The tool auto-detects GNU parallel and uses it when available. Otherwise, it falls back to native Bash background jobs.

### Adjust Parallel Jobs

Edit `/etc/imgctl/imgctl.conf`:

```bash
# Increase for faster Harbor processing (default: 10)
MAX_PARALLEL_JOBS="20"
```

### Cache Settings

Edit `/etc/imgctl/imgctl.conf`:

```bash
# Shorter TTL for more frequent updates (default: 300 seconds)
CACHE_TTL="60"

# Disable cache for always-fresh data
ENABLE_CACHE="false"
```

To manually clear the cache:

```bash
sudo rm -rf /var/cache/imgctl/*.cache
```

## Troubleshooting

### SSH Connection Issues

```bash
# Test SSH manually
ssh -o BatchMode=yes root@k8s-worker1 "echo OK"

# Check SSH key permissions
chmod 600 ~/.ssh/id_rsa

# Verify SSH config
cat ~/.ssh/config
```

### Harbor Connection Issues

```bash
# Test Harbor API
curl -k -u admin:password https://harbor:9443/api/v2.0/health

# Check Harbor certificate
openssl s_client -connect harbor:9443
```

### crictl Issues

```bash
# Verify crictl on worker node
ssh k8s-worker1 "which crictl"
ssh k8s-worker1 "crictl images"

# Check containerd status
ssh k8s-worker1 "systemctl status containerd"
```

### Check Logs

```bash
# View today's log file
tail -f /var/log/giindia/imgctl/imgctl-$(date +%Y-%m-%d).log

# Enable debug logging by editing config
sudo nano /etc/imgctl/imgctl.conf
# Set: LOG_LEVEL="DEBUG"
```

### Clear Cache

If you see stale data:

```bash
sudo rm -rf /var/cache/imgctl/*.cache
imgctl get
```

## Uninstallation

```bash
sudo ./uninstall.sh
```

The uninstaller will prompt before removing configuration and logs.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Head Node                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                        imgctl                             │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │  │
│  │  │ common   │  │ crictl   │  │ harbor   │  │ output   │  │  │
│  │  │   .sh    │  │   .sh    │  │   .sh    │  │   .sh    │  │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│           │                │                                    │
│           │ SSH            │ HTTPS                              │
│           ▼                ▼                                    │
│  ┌────────────────┐  ┌────────────────┐                        │
│  │   DGX Worker   │  │    Harbor      │                        │
│  │    Nodes       │  │    Registry    │                        │
│  │   (crictl)     │  │                │                        │
│  └────────────────┘  └────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.1.0 | 2025-12-02 | Added ignore file support, `<none>` tag filtering, new display order |
| 2.0.0 | 2025-11-28 | Complete rewrite in shell with parallel processing |
| 1.0.0 | 2025-11-27 | Initial Python-based implementation |

## Author

- **Anubhav Patrick**
- Email: anubhav.patrick@giindia.com
- Organization: Global Info Ventures Pvt Ltd

## License

Copyright © 2025 Global Info Ventures Pvt Ltd. All rights reserved.
