#!/bin/bash

# ocp-graceful-reboot-nodes
# Script to gracefully reboot OpenShift nodes of a specific type/role or a specific node
# Usage: ./ocp-graceful-reboot-nodes -t <node_type> | -n <node_name> [-p <parallel_count>] [-y] [-d]
# Example: ./ocp-graceful-reboot-nodes -t infra
# Example: ./ocp-graceful-reboot-nodes -n worker-01.money-prod-ewd.k8s.ephico2real.com
# Example: ./ocp-graceful-reboot-nodes -t worker -p 4

set -e

# Configuration variables
# Timeouts and retry attempts
NODE_READY_TIMEOUT=30      # Number of attempts to check if node is Ready (~ 5 minutes with 10s interval)
NODE_DEBUG_TIMEOUT=12      # Number of attempts to check if node is accessible via debug (~ 2 minutes with 10s interval)
RETRY_INTERVAL=10          # Seconds to wait between retry attempts
OC_COMMAND_TIMEOUT=60      # Timeout in seconds for oc commands
NODE_DRAIN_TIMEOUT=300     # Timeout in seconds for node drain operations (5 minutes)
DRAIN_RETRY_COUNT=3        # Number of attempts to drain a node before giving up

# Default parallel counts by node type
MASTER_PARALLEL_DEFAULT=1
INFRA_PARALLEL_DEFAULT=1
WORKER_PARALLEL_DEFAULT=2
OTHER_PARALLEL_DEFAULT=1

# Log levels
LOG_LEVEL_INFO="INFO"
LOG_LEVEL_WARNING="WARNING"
LOG_LEVEL_ERROR="ERROR"

# Temporary files
NODE_LIST_FILE=""

# Logging function
log() {
    local level=$1
    shift
    local message=$*
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "$LOG_LEVEL_INFO")
            echo "[$timestamp] $level: $message"
            ;;
        "$LOG_LEVEL_WARNING")
            echo "[$timestamp] $level: $message" >&2
            ;;
        "$LOG_LEVEL_ERROR")
            echo "[$timestamp] $level: $message" >&2
            ;;
        *)
            echo "[$timestamp] $level: $message"
            ;;
    esac
}

# Cleanup function
cleanup() {
    if [[ -f "$NODE_LIST_FILE" ]]; then
        log "$LOG_LEVEL_INFO" "Cleaning up temporary files..."
        rm -f "$NODE_LIST_FILE"
    fi
}

# Set trap handlers
trap cleanup EXIT
trap 'log "$LOG_LEVEL_ERROR" "Script interrupted by user"; exit 1' INT TERM

# Check if timeout command is available
check_timeout_command() {
    if ! command -v timeout &> /dev/null; then
        log "$LOG_LEVEL_WARNING" "The 'timeout' command is not available on this system."
        log "$LOG_LEVEL_WARNING" "MacOS users can install it via 'brew install coreutils'."
        log "$LOG_LEVEL_WARNING" "Falling back to running commands without timeout protection."
        
        # Define a fallback function that ignores the timeout and just runs the command
        timeout() {
            # Skip the first argument (timeout value)
            shift
            # Run the actual command
            "$@"
        }
    else
        log "$LOG_LEVEL_INFO" "Timeout command is available."
    fi
}

# Function to display usage
usage() {
    log "$LOG_LEVEL_INFO" "Usage: $0 [-t <node_type> | -n <node_name>] [-y] [-d] [-p <parallel_count>]"
    log "$LOG_LEVEL_INFO" "  -t <node_type>   Node type/role to reboot (e.g., infra, master, worker)"
    log "$LOG_LEVEL_INFO" "  -n <node_name>   Specific node name to reboot"
    log "$LOG_LEVEL_INFO" "  -y               Skip all confirmation prompts (use with caution)"
    log "$LOG_LEVEL_INFO" "  -d               Dry run - show what would happen without making changes"
    log "$LOG_LEVEL_INFO" "  -p <count>       Number of nodes to reboot in parallel (default: varies by node type)"
    log "$LOG_LEVEL_INFO" "                   Default is 1 for master/infra, 2 for worker, 1 for other types"
    log "$LOG_LEVEL_INFO" "  -h               Display this help message"
    exit 1
}
check_oc_client() {
    if ! command -v oc &> /dev/null; then
        log "$LOG_LEVEL_ERROR" "OpenShift CLI (oc) is not installed or not in PATH."
        exit 1
    fi

    # Get oc version for diagnosis
    log "$LOG_LEVEL_INFO" "OpenShift CLI version: $(oc version 2>&1 | head -n 1)"

    # Debug output before checking login
    log "$LOG_LEVEL_INFO" "Checking OpenShift login status..."
    
    # Run oc whoami with explicit output capture
    login_check=$(oc whoami 2>&1)
    login_status=$?
    
    if [ $login_status -ne 0 ]; then
        log "$LOG_LEVEL_ERROR" "Not logged into OpenShift. Error was: $login_check"
        exit 1
    fi
    
    log "$LOG_LEVEL_INFO" "OpenShift CLI check passed. Logged in as: $login_check"
}
# Function to ensure debug namespace exists with empty node selector
ensure_debug_namespace() {
    log "$LOG_LEVEL_INFO" "Ensuring debug namespace exists with empty node selector..."
    
    # Check if debug namespace already exists
    if timeout $OC_COMMAND_TIMEOUT oc get namespace debug &> /dev/null; then
        log "$LOG_LEVEL_INFO" "Debug namespace already exists. Ensuring it has an empty node selector..."
        if ! timeout $OC_COMMAND_TIMEOUT oc patch namespace debug -p '{"metadata":{"annotations":{"openshift.io/node-selector":""}}}' --type=merge; then
            log "$LOG_LEVEL_ERROR" "Failed to patch debug namespace with empty node selector"
            exit 1
        fi
    else
        log "$LOG_LEVEL_INFO" "Creating debug namespace with empty node selector..."
        if ! timeout $OC_COMMAND_TIMEOUT oc adm new-project --node-selector="" debug; then
            log "$LOG_LEVEL_ERROR" "Failed to create debug namespace"
            exit 1
        fi
    fi
    
    # Switch to debug namespace
    if ! timeout $OC_COMMAND_TIMEOUT oc project debug; then
        log "$LOG_LEVEL_ERROR" "Failed to switch to debug namespace"
        exit 1
    fi
    log "$LOG_LEVEL_INFO" "Now using project debug"
}
# Function to get nodes by role
get_nodes_by_role() {
    local role=$1
    log "$LOG_LEVEL_INFO" "Finding nodes with role: $role"
    
    # Create temporary file to store node names with role as prefix
    NODE_LIST_FILE=$(mktemp -t "${role}-nodes-XXXXXX")
    
    # Get nodes with the specified role
    if ! timeout $OC_COMMAND_TIMEOUT oc get nodes -l "node-role.kubernetes.io/$role=" -o name | cut -d'/' -f2 > "$NODE_LIST_FILE"; then
        log "$LOG_LEVEL_ERROR" "Failed to get nodes with role '$role' or command timed out"
        rm "$NODE_LIST_FILE"
        exit 1
    fi
    
    # Check if any nodes were found
    if [[ ! -s "$NODE_LIST_FILE" ]]; then
        log "$LOG_LEVEL_ERROR" "No nodes found with role '$role'"
        rm "$NODE_LIST_FILE"
        exit 1
    fi
    
    # Display found nodes
    log "$LOG_LEVEL_INFO" "Found the following nodes:"
    cat "$NODE_LIST_FILE"
    log "$LOG_LEVEL_INFO" ""
    
    log "$LOG_LEVEL_INFO" "Node list saved to temporary file: $NODE_LIST_FILE"
}
# Function to create a node list file with a single node
create_single_node_file() {
    local node=$1
    
    # Extract role from node name if possible
    local role="custom"
    if [[ "$node" =~ ^(infra|master|worker) ]]; then
        role=$(echo "$node" | sed 's/\([^-]*\).*/\1/')
    fi
    
    # Create temporary file to store node name with role as prefix
    NODE_LIST_FILE=$(mktemp -t "${role}-node-XXXXXX")
    
    # Check if node exists
    if ! timeout $OC_COMMAND_TIMEOUT oc get node "$node" &> /dev/null; then
        log "$LOG_LEVEL_ERROR" "Node '$node' not found or command timed out"
        rm "$NODE_LIST_FILE"
        exit 1
    fi
    
    # Write the node name to the file
    echo "$node" > "$NODE_LIST_FILE"
    
    log "$LOG_LEVEL_INFO" "Node saved to temporary file: $NODE_LIST_FILE"
}
# Function to wait for node to be ready
wait_for_node_ready() {
    local node=$1
    local dry_run=$2
    local max_attempts=$NODE_READY_TIMEOUT
    local attempt=1
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would wait for node $node to be Ready"
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would check node status up to $max_attempts times at $RETRY_INTERVAL second intervals"
        return 0
    fi
    
    log "$LOG_LEVEL_INFO" "Waiting for node $node to be Ready..."
    
    while (( attempt <= max_attempts )); do
        log "$LOG_LEVEL_INFO" "Attempt $attempt/$max_attempts: Checking if node $node is Ready..."
        
        # Check node status with timeout
        if timeout $OC_COMMAND_TIMEOUT oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
            log "$LOG_LEVEL_INFO" "Node $node is Ready!"
            return 0
        fi
        
        # If not ready, wait and try again
        sleep $RETRY_INTERVAL
        (( attempt++ ))
    done
    
    log "$LOG_LEVEL_ERROR" "Timed out waiting for node $node to become Ready"
    return 1
}
# Function to check if node is accessible via debug
check_node_debug_access() {
    local node=$1
    local dry_run=$2
    local max_attempts=$NODE_DEBUG_TIMEOUT
    local attempt=1
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would check if node $node is accessible via debug"
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would try to debug node up to $max_attempts times at $RETRY_INTERVAL second intervals"
        return 0
    fi
    
    log "$LOG_LEVEL_INFO" "Checking if node $node is accessible via debug..."
    while (( attempt <= max_attempts )); do
        log "$LOG_LEVEL_INFO" "Attempt $attempt/$max_attempts: Trying to debug node $node..."
        
        # Try to debug the node with a simple command with timeout
        if timeout $OC_COMMAND_TIMEOUT oc debug node/"$node" -- chroot /host ls / &> /dev/null; then
            log "$LOG_LEVEL_INFO" "Node $node is accessible via debug!"
            return 0
        fi
        
        # If not accessible, wait and try again
        log "$LOG_LEVEL_INFO" "Node $node not accessible yet, waiting..."
        sleep $RETRY_INTERVAL
        (( attempt++ ))
    done
    
    log "$LOG_LEVEL_ERROR" "Timed out waiting for node $node to be accessible via debug"
    return 1
}

# Function to drain a node
drain_node() {
    local node=$1
    local dry_run=$2
    local retry_count=1
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would drain node $node with command: oc adm drain node/$node --ignore-daemonsets --force --delete-emptydir-data --disable-eviction"
        return 0
    fi
    
    log "$LOG_LEVEL_INFO" "Draining node: $node"
    
    while (( retry_count <= DRAIN_RETRY_COUNT )); do
        log "$LOG_LEVEL_INFO" "Drain attempt $retry_count/$DRAIN_RETRY_COUNT..."
        
        if timeout $NODE_DRAIN_TIMEOUT oc adm drain node/$node --ignore-daemonsets --force --delete-emptydir-data --disable-eviction; then
            log "$LOG_LEVEL_INFO" "Successfully drained node $node"
            return 0
        else
            local exit_code=$?
            log "$LOG_LEVEL_WARNING" "Failed to drain node $node (attempt $retry_count/$DRAIN_RETRY_COUNT, exit code: $exit_code)"
            
            if (( retry_count == DRAIN_RETRY_COUNT )); then
                log "$LOG_LEVEL_ERROR" "Failed to drain node $node after $DRAIN_RETRY_COUNT attempts"
                return 1
            fi
            
            log "$LOG_LEVEL_INFO" "Waiting $RETRY_INTERVAL seconds before retrying..."
            sleep $RETRY_INTERVAL
            (( retry_count++ ))
        fi
    done
    
    return 1
}

# Function to uncordon a node (make schedulable again)
uncordon_node() {
    local node=$1
    local dry_run=$2
    local retry_count=1
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would uncordon node $node with command: oc adm uncordon node/$node"
        return 0
    fi
    
    log "$LOG_LEVEL_INFO" "Uncordoning node: $node (making schedulable again)"
    
    while (( retry_count <= DRAIN_RETRY_COUNT )); do
        log "$LOG_LEVEL_INFO" "Uncordon attempt $retry_count/$DRAIN_RETRY_COUNT..."
        
        if timeout $OC_COMMAND_TIMEOUT oc adm uncordon node/$node; then
            log "$LOG_LEVEL_INFO" "Successfully uncordoned node $node"
            return 0
        else
            local exit_code=$?
            log "$LOG_LEVEL_WARNING" "Failed to uncordon node $node (attempt $retry_count/$DRAIN_RETRY_COUNT, exit code: $exit_code)"
            
            if (( retry_count == DRAIN_RETRY_COUNT )); then
                log "$LOG_LEVEL_ERROR" "Failed to uncordon node $node after $DRAIN_RETRY_COUNT attempts"
                return 1
            fi
            
            log "$LOG_LEVEL_INFO" "Waiting $RETRY_INTERVAL seconds before retrying..."
            sleep $RETRY_INTERVAL
            (( retry_count++ ))
        fi
    done
    
    return 1
}

# Function to reboot a node
reboot_node() {
    local node=$1
    local dry_run=$2
    
    log "$LOG_LEVEL_INFO" "Starting graceful reboot process for node: $node"
    
    # Step 1: Drain the node
    if ! drain_node "$node" "$dry_run"; then
        log "$LOG_LEVEL_ERROR" "Failed to drain node $node before reboot"
        return 1
    fi
    
    # Step 2: Reboot the node
    log "$LOG_LEVEL_INFO" "Issuing reboot command to node: $node"
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would execute: oc debug node/$node -- chroot /host systemctl reboot"
        log "$LOG_LEVEL_INFO" "[DRY RUN] Debug pod would terminate after the reboot command"
    else
        # Execute the reboot command with timeout
        if ! timeout $OC_COMMAND_TIMEOUT oc debug node/"$node" -- chroot /host systemctl reboot; then
            log "$LOG_LEVEL_ERROR" "Failed to execute reboot command on node $node"
            
            # Try to uncordon the node even though reboot failed
            log "$LOG_LEVEL_WARNING" "Attempting to uncordon node $node after reboot failure"
            uncordon_node "$node" "$dry_run"
            
            return 1
        fi
        # The debug pod will terminate after the reboot command
        log "$LOG_LEVEL_INFO" "Reboot command sent to $node"
    fi
    
    return 0
}
get_default_parallel_count() {
    local role=$1
    
    case "$role" in
        master|infra)
            echo 1
            ;;
        worker)
            echo 2
            ;;
        *)
            echo 1
            ;;
    esac
}

# Function to generate status report
generate_status_report() {
    local total_nodes=$1
    local successful_nodes=$2
    local failed_nodes=$3
    local report_file="reboot-report-$(date +%Y%m%d-%H%M%S).txt"
    
    log "$LOG_LEVEL_INFO" "=========================================="
    log "$LOG_LEVEL_INFO" "Reboot Status Report"
    log "$LOG_LEVEL_INFO" "=========================================="
    log "$LOG_LEVEL_INFO" "Total nodes processed: $total_nodes"
    log "$LOG_LEVEL_INFO" "Successfully rebooted: $successful_nodes"
    log "$LOG_LEVEL_INFO" "Failed to reboot: $failed_nodes"
    log "$LOG_LEVEL_INFO" "Success rate: $(( (successful_nodes * 100) / total_nodes ))%"
    log "$LOG_LEVEL_INFO" "=========================================="
    # Save report to file
    {
        echo "=========================================="
        echo "Reboot Status Report - $(date)"
        echo "=========================================="
        echo "Total nodes processed: $total_nodes"
        echo "Successfully rebooted: $successful_nodes"
        echo "Failed to reboot: $failed_nodes"
        echo "Success rate: $(( (successful_nodes * 100) / total_nodes ))%"
        echo "=========================================="
    } > "$report_file"
    
    log "$LOG_LEVEL_INFO" "Report saved to: $report_file"
}

# Process nodes in parallel
process_nodes_parallel() {
    local parallel_count=$1
    local skip_prompts=$2
    local dry_run=$3
    local nodes=()
    local i=0
    local successful_nodes=0
    local failed_nodes=0
    
    # Read all nodes into an array
    while read -r node; do
        nodes+=("$node")
    done < "$NODE_LIST_FILE"
    
    total_nodes=${#nodes[@]}
    echo "Processing $total_nodes nodes with parallelism of $parallel_count"
    
    # Process nodes in batches
    while [ $i -lt $total_nodes ]; do
        local active_jobs=0
        local batch_start=$i
        local batch_end=$((i + parallel_count - 1))
        
        if [ $batch_end -ge $total_nodes ]; then
            batch_end=$((total_nodes - 1))
        fi
        
        log "$LOG_LEVEL_INFO" "=========================================="
        log "$LOG_LEVEL_INFO" "Processing batch of nodes: $((batch_start + 1)) to $((batch_end + 1)) of $total_nodes"
        log "$LOG_LEVEL_INFO" "=========================================="
        # Start a batch of nodes
        for j in $(seq $batch_start $batch_end); do
            local node=${nodes[$j]}
            
            echo "=========================================="
            echo "Processing node: $node ($(($j + 1))/$total_nodes)"
            
            # Ask for confirmation if not skipping prompts
            if ! $skip_prompts; then
                read -p "Reboot node $node? (y/n): " confirm
                if [[ "$confirm" != "y" ]]; then
                    log "$LOG_LEVEL_INFO" "Skipping node $node per user request"
                    # Count skipped nodes differently
                    echo "Node $node was skipped"
                    continue
                fi
            else
                log "$LOG_LEVEL_INFO" "Auto-confirming reboot of node $node (skip_prompts=true)"
            fi
            # Gracefully reboot the node (drain, reboot, and later uncordon)
            reboot_node "$node" "$dry_run"
            echo "Started reboot process for node $node"
            echo "=========================================="
            echo ""
            
            # Skip waiting in dry run mode
            if [ "$dry_run" = true ]; then
                successful_nodes=$((successful_nodes + 1))
                continue
            fi
        done
        
        # Wait for the batch to complete (only if not in dry run)
        if [ "$dry_run" = false ]; then
            echo "Waiting for batch to complete..."
            for j in $(seq $batch_start $batch_end); do
                local node=${nodes[$j]}
                local node_success=true
                
                log "$LOG_LEVEL_INFO" "Checking status of node: $node"
                local node_success=true
                
                # Wait for node to become Ready
                if ! wait_for_node_ready "$node" "$dry_run"; then
                    log "$LOG_LEVEL_WARNING" "Node $node did not become Ready within the timeout period."
                    node_success=false
                    if ! $skip_prompts; then
                        read -p "Continue with next batch? (y/n): " continue_confirm
                        if [[ "$continue_confirm" != "y" ]]; then
                            log "$LOG_LEVEL_ERROR" "Exiting script"
                            # Generate report before exiting
                            generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes"
                            return 1
                        fi
                    else
                        log "$LOG_LEVEL_INFO" "Auto-continuing to next batch (skip_prompts=true)"
                    fi
                    failed_nodes=$((failed_nodes + 1))
                    continue
                fi
                
                # Check if node is accessible via debug
                if ! check_node_debug_access "$node" "$dry_run"; then
                    log "$LOG_LEVEL_WARNING" "Node $node is not accessible via debug within the timeout period."
                    node_success=false
                    if ! $skip_prompts; then
                        read -p "Continue with next batch? (y/n): " continue_confirm
                        if [[ "$continue_confirm" != "y" ]]; then
                            log "$LOG_LEVEL_ERROR" "Exiting script"
                            # Generate report before exiting
                            generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes"
                            return 1
                        fi
                    else
                        log "$LOG_LEVEL_INFO" "Auto-continuing to next batch (skip_prompts=true)"
                    fi
                    failed_nodes=$((failed_nodes + 1))
                    continue
                fi
                
                # Only proceed with uncordoning if the node is ready and accessible
                if [ "$node_success" = true ]; then
                    # Step 3: Uncordon the node after it's back online
                    log "$LOG_LEVEL_INFO" "Node $node is accessible, uncordoning node..."
                    if ! uncordon_node "$node" "$dry_run"; then
                        log "$LOG_LEVEL_WARNING" "Failed to uncordon node $node after reboot"
                        node_success=false
                        failed_nodes=$((failed_nodes + 1))
                        continue
                    fi
                    
                    # If we got here, the node was successfully rebooted and uncordoned
                    successful_nodes=$((successful_nodes + 1))
                    log "$LOG_LEVEL_INFO" "Node $node has been successfully rebooted and is ready."
                fi
            done
        fi
        
        i=$((batch_end + 1))
    done
    
    # Generate final report
    generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes"
    
    return 0
}

# Main function
main() {
    local node_type=""
    local node_name=""
    local skip_prompts=false
    local dry_run=false
    local parallel_count=0 # 0 means use default based on node type
    
    # Parse command line arguments
    while getopts "t:n:ydp:h" opt; do
        case $opt in
            t) node_type="$OPTARG" ;;
            n) node_name="$OPTARG" ;;
            y) skip_prompts=true ;;
            d) dry_run=true ;;
            p) parallel_count="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
    
    # Check if either node type or node name is provided
    if [[ -z "$node_type" && -z "$node_name" ]]; then
        log "$LOG_LEVEL_ERROR" "Either node type (-t) or node name (-n) must be provided"
        usage
    fi
    
    # If both are provided, exit with error
    if [[ -n "$node_type" && -n "$node_name" ]]; then
        log "$LOG_LEVEL_ERROR" "Please provide either node type (-t) OR node name (-n), not both"
        usage
    fi
    # Validate parallel count if provided
    if [[ ! "$parallel_count" =~ ^[0-9]+$ ]]; then
        log "$LOG_LEVEL_ERROR" "Parallel count must be a number"
        usage
    fi
    
    if [[ $parallel_count -lt 0 ]]; then
        log "$LOG_LEVEL_ERROR" "Parallel count must be a positive integer"
        usage
    fi
    
    # Set a reasonable upper limit for parallel count to prevent accidental large values
    if [[ $parallel_count -gt 20 ]]; then
        log "$LOG_LEVEL_WARNING" "Parallel count of $parallel_count is unusually high"
        if ! $skip_prompts; then
            read -p "Are you sure you want to use a parallel count of $parallel_count? (y/n): " parallel_confirm
            if [[ "$parallel_confirm" != "y" ]]; then
                log "$LOG_LEVEL_INFO" "Operation cancelled by user"
                exit 0
            fi
        fi
    fi
    # Indicate if we're in dry run mode
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "============================================"
        log "$LOG_LEVEL_INFO" "DRY RUN MODE - No actual changes will be made"
        log "$LOG_LEVEL_INFO" "============================================"
    fi
    # Check if timeout command is available
    check_timeout_command
    
    # Check if oc client is available
    check_oc_client
    # Ensure debug namespace exists with empty node selector
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would ensure debug namespace exists with empty node selector"
    else
        ensure_debug_namespace
    fi
    # Get nodes by role or create a file for single node
    if [[ -n "$node_type" ]]; then
        if [ "$dry_run" = true ]; then
            log "$LOG_LEVEL_INFO" "[DRY RUN] Would find nodes with role: $node_type"
            # Still need to get the list of nodes for dry run display
            get_nodes_by_role "$node_type"
        else
            get_nodes_by_role "$node_type"
        fi
        # Set default parallel count if not specified
        if [[ $parallel_count -eq 0 ]]; then
            parallel_count=$(get_default_parallel_count "$node_type")
        fi
    else
        if [ "$dry_run" = true ]; then
            log "$LOG_LEVEL_INFO" "[DRY RUN] Would target node: $node_name"
            # Still need to create the node file for dry run display
            create_single_node_file "$node_name"
        else
            create_single_node_file "$node_name"
        fi
        # For single node, always use parallel count of 1
        parallel_count=1
    fi
    
    log "$LOG_LEVEL_INFO" "Using parallel count: $parallel_count"
    # Initial confirmation before starting any reboots
    if ! $skip_prompts; then
        local node_count=$(wc -l < "$NODE_LIST_FILE")
        log "$LOG_LEVEL_INFO" "=========================================="
        log "$LOG_LEVEL_INFO" "You are about to gracefully reboot $node_count node(s) with parallelism of $parallel_count."
        log "$LOG_LEVEL_INFO" "This process will:"
        log "$LOG_LEVEL_INFO" " 1. Drain each node (evacuate pods)"
        log "$LOG_LEVEL_INFO" " 2. Reboot the node"
        log "$LOG_LEVEL_INFO" " 3. Wait for node to become ready" 
        log "$LOG_LEVEL_INFO" " 4. Uncordon the node (make schedulable again)"
        if [ "$dry_run" = true ]; then
            log "$LOG_LEVEL_INFO" "[DRY RUN] No actual changes will be made."
        else
            log "$LOG_LEVEL_INFO" "This will cause service disruption if not handled properly."
        fi
        log "$LOG_LEVEL_INFO" "Make sure you understand the impact of this operation."
        log "$LOG_LEVEL_INFO" "=========================================="
        read -p "Do you want to proceed? (y/n): " initial_confirm
        if [[ "$initial_confirm" != "y" ]]; then
            log "$LOG_LEVEL_INFO" "Operation cancelled by user"
            rm "$NODE_LIST_FILE"
            exit 0
        fi
    fi
    
    # Process nodes in parallel
    process_nodes_parallel "$parallel_count" "$skip_prompts" "$dry_run"
    reboot_result=$?
    
    # Clean up
    rm -f "$NODE_LIST_FILE"
    
    if [ $reboot_result -eq 0 ]; then
        log "$LOG_LEVEL_INFO" "All nodes processed. Script complete."
    else
        log "$LOG_LEVEL_ERROR" "Script execution stopped early due to user input or errors."
        exit 1
    fi
}

# Run main function
main "$@"
