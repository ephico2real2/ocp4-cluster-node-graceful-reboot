# OpenShift Node Reboot Tool User Guide

## Overview

The `ocp-graceful-reboot-nodes` script provides a safe and controlled way to reboot OpenShift nodes while ensuring proper validation and recovery. This tool is particularly useful for maintenance operations, troubleshooting, and applying OS-level changes that require reboots.

The script implements a truly graceful node reboot process that includes draining pods from nodes before rebooting and uncordoning nodes after they're back online, ensuring minimal service disruption during maintenance operations.

## Features
- Reboot nodes by role type (master, infra, worker)
- Reboot specific nodes by hostname
- Graceful node draining before reboot to safely evacuate workloads
- Parallel processing with role-appropriate defaults
- Interactive confirmation prompts
- Non-interactive mode for automation
- Dry run capability for testing
- Comprehensive status reporting and logging
- Node readiness verification
- Automated uncordoning of nodes after reboot

## Prerequisites

- OpenShift CLI (`oc`) installed and available in your PATH
- Active login to your OpenShift cluster with appropriate permissions
- Cluster administrator access to create and modify projects

## Installation

1. Download the script:
   ```bash
   curl -o ocp-graceful-reboot-nodes https://your-server/path/to/ocp-graceful-reboot-nodes
   ```

2. Make the script executable:
   ```bash
   chmod +x ocp-graceful-reboot-nodes
   ```

## Basic Usage

### Reboot by Node Role

To reboot all nodes with a specific role:

```bash
./ocp-graceful-reboot-nodes -t <role>
```

Where `<role>` can be:
- `master` - Control plane nodes
- `infra` - Infrastructure nodes
- `worker` - Application nodes

Example:
```bash
./ocp-graceful-reboot-nodes -t infra
```

### Reboot a Specific Node

To reboot a single specific node by hostname:

```bash
./ocp-graceful-reboot-nodes -n <node-hostname>
```

Example:
```bash
./ocp-graceful-reboot-nodes -n worker-01.money-prod-ewd.k8s.ephico2real.com
```

## Advanced Options

### Parallel Rebooting

The script defaults to safe parallelism levels (1 for master/infra, 2 for worker), but you can customize this:

```bash
./ocp-graceful-reboot-nodes -t <role> -p <parallel-count>
```

Example to reboot 4 worker nodes in parallel:
```bash
./ocp-graceful-reboot-nodes -t worker -p 4
```

### Non-Interactive Mode

For automation or scripted usage, use the `-y` flag to skip all confirmation prompts:

```bash
./ocp-graceful-reboot-nodes -t <role> -y
```

Example:
```bash
./ocp-graceful-reboot-nodes -t worker -y
```

### Dry Run Mode

To see what would happen without making any changes, use the `-d` flag:

```bash
./ocp-graceful-reboot-nodes -t <role> -d
```

Example:
```bash
./ocp-graceful-reboot-nodes -t master -d
```

## Option Combinations

The script supports the following useful combinations:

### Safe Testing (Recommended for First Usage)

Perform a dry run on a specific node type:
```bash
./ocp-graceful-reboot-nodes -t worker -d
```

### Faster Maintenance with Confirmation

Reboot worker nodes with higher parallelism but still confirm each node:
```bash
./ocp-graceful-reboot-nodes -t worker -p 4
```

### Full Automation

Reboot nodes without any prompts (for scheduled maintenance):
```bash
./ocp-graceful-reboot-nodes -t worker -p 3 -y
```

### Testing Automation Logic

Simulate an automated run without making changes:
```bash
./ocp-graceful-reboot-nodes -t infra -y -d
```

## Output and Reporting

The script provides:

1. Real-time status updates during execution
2. A summary report at the end of execution
3. A timestamped report file (`reboot-report-YYYYMMDD-HHMMSS.txt`) containing:
   - Total nodes processed
   - Successfully rebooted nodes
   - Failed nodes
   - Success rate percentage
## How It Works

The script operates as follows:

1. Validates prerequisites (oc client, login status)
2. Creates or updates a debug namespace with empty node selector
3. Identifies nodes to reboot (by role or hostname)
4. Displays nodes and asks for confirmation
5. Processes nodes in batches based on parallel count
6. For each node:
   - Asks for confirmation (unless `-y` is specified)
   - Drains the node using `oc adm drain` to safely evacuate pods
   - Reboots the node via `oc debug node/<node> -- chroot /host systemctl reboot`
   - Waits for the node to become Ready again
   - Verifies the node is accessible via debug
   - Uncordons the node to make it schedulable again
7. Generates a status report

## Script Design and Implementation

The script employs a robust, multi-level system to track and process nodes:

### Node Selection and Tracking

1. **Node List Creation**:
   - The script creates a temporary file containing all target nodes
   - This list is generated either via `get_nodes_by_role()` for node types or `create_single_node_file()` for individual nodes
   - This file serves as the master list of all nodes to be processed

2. **Counter Variables**:
   - `total_nodes`: Total number of nodes to be processed (determined from the list size)
   - `successful_nodes`: Tracks successfully rebooted nodes
   - `failed_nodes`: Tracks nodes that failed to reboot properly
   - `node_success`: A boolean flag for tracking the success of individual node operations

### Batch Processing Logic

1. **Parallel Execution**:
   - The script processes nodes in batches based on the `parallel_count` parameter
   - It uses variables like `batch_start` and `batch_end` to track the current batch
   - An index variable tracks progress through the node list

2. **Graceful Node Reboot Process**:
   - **Draining**: Each node is drained to safely evacuate workloads
   - **Rebooting**: A debug pod executes the reboot command
   - **Verification**: After reboot, the script:
     - Waits for node to become Ready
     - Checks if node is accessible via debug
     - Uncordons the node to make it schedulable again
   - If any step fails, the node is marked as failed and reported

### Error Handling and Reporting

1. **Status Reporting**:
   - A comprehensive `generate_status_report()` function tracks:
     - Total nodes processed
     - Successfully rebooted nodes
     - Failed nodes
     - Success rate percentage
   - This report is generated at completion and if interrupted

2. **Error Recovery**:
   - If a node fails during processing, the script:
     - Increments the `failed_nodes` counter
     - Sets `node_success` to false
     - Prompts the user to continue or abort (if not in automatic mode)
     - Continues with the next batch if appropriate

This architecture ensures reliable processing by:
- Maintaining clear counters for total, successful, and failed nodes
- Processing nodes in manageable batches
- Providing detailed status information throughout the process
- Generating comprehensive reports for auditing and troubleshooting

## Unsupported Combinations
The following combinations are not supported:

- `-t <role> -n <node>` - Cannot specify both role and specific node
- `-p` with a negative number - Parallel count must be positive
- `-n <node> -p <n>` where n > 1 - For single node reboot, parallelism is always 1
## Troubleshooting

If a node doesn't come back after reboot:

1. The script will timeout after 5 minutes waiting for Ready status
2. The script will timeout after 2 minutes waiting for debug access
3. You'll be asked if you want to continue with other nodes
4. The node will be marked as failed in the final report
5. For drain failures, the script makes multiple retry attempts before giving up

The script always tries to leave the cluster in a consistent state, even when errors occur:

1. If node draining fails, the reboot is aborted
2. If reboot fails after successful drain, the script attempts to uncordon the node
3. Failed nodes are clearly identified in the status report
## Best Practices

1. Always perform a dry run first (`-d` flag)
2. Start with lower parallelism values and increase gradually
3. Be cautious with master nodes - use parallelism of 1
4. For critical systems, reboot one node at a time
5. Schedule maintenance window for node reboots
6. Back up important data before beginning
7. Ensure sufficient capacity in the cluster to handle evacuated workloads during draining
8. Consider the implications of draining nodes on stateful applications
9. Review the generated status reports to understand any failures

## Security Considerations

This script requires high privileges in your OpenShift cluster. It:

1. Creates/modifies a namespace
2. Accesses nodes directly via debug pods
3. Executes systemctl commands on nodes

Ensure proper access controls and review the script before using in production environments.

## Examples

### Example 1: Reboot all infra nodes one at a time with confirmation

```bash
./ocp-graceful-reboot-nodes -t infra
```

### Example 2: Reboot all worker nodes two at a time without prompts

```bash
./ocp-graceful-reboot-nodes -t worker -p 2 -y
```

### Example 3: Test what would happen for worker nodes with higher parallelism 

```bash
./ocp-graceful-reboot-nodes -t worker -p 4 -d
```

### Example 4: Reboot a specific problem node

```bash
./ocp-graceful-reboot-nodes -n worker-05.money-prod-ewd.k8s.ephico2real.com
```
# ocp4-cluster-node-graceful-reboot
