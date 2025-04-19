#!/bin/bash

# ocp-graceful-reboot-nodes
# Script to gracefully reboot OpenShift nodes of a specific type/role or a specific node
# Usage: ./ocp-graceful-reboot-nodes -t <node_type> | -n <node_name> [-p <parallel_count>] [-y] [-d] [-c] [-l <log_file>]
# Example: ./ocp-graceful-reboot-nodes -t infra
# Example: ./ocp-graceful-reboot-nodes -n worker-01.money-prod-ewd.k8s.ephico2real.com
# Example: ./ocp-graceful-reboot-nodes -t worker -p 4
# Example: ./ocp-graceful-reboot-nodes -t worker -c -l reboot.log

set -e

# Version information
SCRIPT_VERSION="1.2.0"
SCRIPT_DATE="2025-04-18"

# Configuration variables - can be overridden with environment variables
NODE_READY_TIMEOUT=${NODE_READY_TIMEOUT:-30}      # Number of attempts to check if node is Ready (~ 5 minutes with 10s interval)
NODE_DEBUG_TIMEOUT=${NODE_DEBUG_TIMEOUT:-12}      # Number of attempts to check if node is accessible via debug (~ 2 minutes with 10s interval)
RETRY_INTERVAL=${RETRY_INTERVAL:-10}              # Seconds to wait between retry attempts
OC_COMMAND_TIMEOUT=${OC_COMMAND_TIMEOUT:-60}      # Timeout in seconds for oc commands
NODE_DRAIN_TIMEOUT=${NODE_DRAIN_TIMEOUT:-300}     # Timeout in seconds for node drain operations (5 minutes)
DRAIN_RETRY_COUNT=${DRAIN_RETRY_COUNT:-3}         # Number of attempts to drain a node before giving up

# Default parallel counts by node type
MASTER_PARALLEL_DEFAULT=${MASTER_PARALLEL_DEFAULT:-1}
INFRA_PARALLEL_DEFAULT=${INFRA_PARALLEL_DEFAULT:-1}
WORKER_PARALLEL_DEFAULT=${WORKER_PARALLEL_DEFAULT:-2}
OTHER_PARALLEL_DEFAULT=${OTHER_PARALLEL_DEFAULT:-1}

# Log levels
LOG_LEVEL_DEBUG="DEBUG"
LOG_LEVEL_INFO="INFO"
LOG_LEVEL_WARNING="WARNING"
LOG_LEVEL_ERROR="ERROR"

# Global variables
CURRENT_LOG_LEVEL=${LOG_LEVEL_INFO}  # Default log level
NODE_LIST_FILE=""
USE_COLORS=true
LOG_FILE=""
SPINNER_PID=""
ENABLE_SPINNER=true
START_TIME=$(date +%s)

# Colors for terminal output
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_PURPLE="\033[0;35m"
COLOR_CYAN="\033[0;36m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"

# Function to check terminal support for colors
check_color_support() {
    # Check if stdout is a terminal
    if [[ -t 1 ]] && [[ -n "$TERM" && "$TERM" != "dumb" ]]; then
        # Check if tput is available
        if command -v tput &> /dev/null; then
            # Check if terminal supports colors
            if [[ $(tput colors) -ge 8 ]]; then
                USE_COLORS=true
                return 0
            fi
        fi
    fi
    
    # Default to no colors if checks fail
    USE_COLORS=false
    return 1
}

# Spinner function for long-running operations
start_spinner() {
    local message=$1
    
    if ! $ENABLE_SPINNER || ! $USE_COLORS; then
        return 0
    fi
    
    # Don't start spinner if one is already running
    if [[ -n "$SPINNER_PID" ]] && kill -0 "$SPINNER_PID" 2>/dev/null; then
        return 0
    fi
    
    # Define spinner function
    _spin() {
        local delay=0.2
        local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local temp
        
        printf "\r%s " "$message"
        
        while true; do
            temp=${spinstr#?}
            printf " %c " "${spinstr}"
            spinstr=${temp}${spinstr%"$temp"}
            sleep $delay
            printf "\b\b\b"
        done
    }
    
    # Start spinner in background
    _spin &
    SPINNER_PID=$!
    disown
}

# Stop spinner function
stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill $SPINNER_PID 2>/dev/null || true
        SPINNER_PID=""
        printf "\r%-60s\r" " " # Clear the spinner line
    fi
}

# Trap to ensure spinner is stopped
stop_spinner_trap() {
    stop_spinner
}

# Logging function with colors and levels
log() {
    local level=$1
    shift
    local message=$*
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted_message=""
    local level_value=0
    
    # Assign numeric values to log levels for comparison
    case "$level" in
        "$LOG_LEVEL_DEBUG") level_value=10 ;;
        "$LOG_LEVEL_INFO") level_value=20 ;;
        "$LOG_LEVEL_WARNING") level_value=30 ;;
        "$LOG_LEVEL_ERROR") level_value=40 ;;
        *) level_value=0 ;;
    esac
    
    # Assign numeric values to current log level
    local current_level_value=0
    case "$CURRENT_LOG_LEVEL" in
        "$LOG_LEVEL_DEBUG") current_level_value=10 ;;
        "$LOG_LEVEL_INFO") current_level_value=20 ;;
        "$LOG_LEVEL_WARNING") current_level_value=30 ;;
        "$LOG_LEVEL_ERROR") current_level_value=40 ;;
        *) current_level_value=0 ;;
    esac
    
    # Only log if level is high enough
    if [[ $level_value -lt $current_level_value ]]; then
        return 0
    fi
    
    # Format message with colors if enabled
    if $USE_COLORS; then
        case "$level" in
            "$LOG_LEVEL_DEBUG")
                formatted_message="[${COLOR_DIM}$timestamp${COLOR_RESET}] ${COLOR_DIM}$level${COLOR_RESET}: $message"
                ;;
            "$LOG_LEVEL_INFO")
                formatted_message="[${COLOR_CYAN}$timestamp${COLOR_RESET}] ${COLOR_GREEN}$level${COLOR_RESET}: $message"
                ;;
            "$LOG_LEVEL_WARNING")
                formatted_message="[${COLOR_CYAN}$timestamp${COLOR_RESET}] ${COLOR_YELLOW}$level${COLOR_RESET}: $message"
                ;;
            "$LOG_LEVEL_ERROR")
                formatted_message="[${COLOR_CYAN}$timestamp${COLOR_RESET}] ${COLOR_RED}$level${COLOR_RESET}: $message"
                ;;
            *)
                formatted_message="[$timestamp] $level: $message"
                ;;
        esac
    else
        formatted_message="[$timestamp] $level: $message"
    fi
    
    # Temporarily stop spinner if active
    stop_spinner
    
    # Output to terminal
    case "$level" in
        "$LOG_LEVEL_WARNING"|"$LOG_LEVEL_ERROR")
            echo -e "$formatted_message" >&2
            ;;
        *)
            echo -e "$formatted_message"
            ;;
    esac
    
    # Output to log file if specified
    if [[ -n "$LOG_FILE" ]]; then
        # Strip colors for log file
        echo -e "$formatted_message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' >> "$LOG_FILE"
    fi
}

# Function to print a horizontal rule
print_hr() {
    local char=${1:-"-"}
    local width
    
    # Try to get terminal width
    if command -v tput &> /dev/null; then
        width=$(tput cols)
    else
        width=80  # Default width
    fi
    
    local line
    line=$(printf "%${width}s" | tr " " "$char")
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "${COLOR_DIM}${line}${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "$line"
    fi
}

# Cleanup function
cleanup() {
    stop_spinner
    
    if [[ -f "$NODE_LIST_FILE" ]]; then
        log "$LOG_LEVEL_DEBUG" "Cleaning up temporary files..."
        rm -f "$NODE_LIST_FILE"
    fi
    
    # Calculate script runtime
    local end_time=$(date +%s)
    local runtime=$((end_time - START_TIME))
    local hours=$((runtime / 3600))
    local minutes=$(( (runtime % 3600) / 60 ))
    local seconds=$((runtime % 60))
    
    if [[ $hours -gt 0 ]]; then
        log "$LOG_LEVEL_INFO" "Script execution time: ${hours}h ${minutes}m ${seconds}s"
    else
        log "$LOG_LEVEL_INFO" "Script execution time: ${minutes}m ${seconds}s"
    fi
}

# Set trap handlers
trap cleanup EXIT
trap 'stop_spinner_trap; log "$LOG_LEVEL_ERROR" "Script interrupted by user"; exit 1' INT TERM

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
        log "$LOG_LEVEL_DEBUG" "Timeout command is available."
    fi
}

# Function to display usage
usage() {
    echo "OpenShift Node Graceful Reboot Utility v${SCRIPT_VERSION}"
    echo "Usage: $0 [-t <node_type> | -n <node_name>] [options]"
    echo
    echo "Node Selection Options:"
    echo "  -t <node_type>        Node type/role to reboot (e.g., infra, master, worker)"
    echo "  -n <node_name>        Specific node name to reboot"
    echo
    echo "Execution Options:"
    echo "  -p <count>            Number of nodes to reboot in parallel"
    echo "                        (default: 1 for master/infra, 2 for worker)"
    echo "  -y                    Skip all confirmation prompts (use with caution)"
    echo "  -d                    Dry run - show what would happen without making changes"
    echo
    echo "Output Options:"
    echo "  -c                    Disable colored output"
    echo "  -l <file>             Log output to specified file"
    echo "  -v                    Enable verbose output (debug messages)"
    echo
    echo "Other Options:"
    echo "  -h                    Display this help message"
    echo "  --timeout <seconds>   Custom timeout for node readiness checks"
    echo "  --no-spinner          Disable progress spinner"
    echo
    echo "Environment Variables:"
    echo "  NODE_READY_TIMEOUT    Number of attempts for node ready checks (default: 30)"
    echo "  NODE_DEBUG_TIMEOUT    Number of attempts for debug access checks (default: 12)"
    echo "  RETRY_INTERVAL        Seconds between retry attempts (default: 10)"
    echo "  OC_COMMAND_TIMEOUT    Timeout for OpenShift commands (default: 60s)"
    echo "  NODE_DRAIN_TIMEOUT    Timeout for node drain operations (default: 300s)"
    echo
    echo "Examples:"
    echo "  $0 -t infra                     # Reboot all infra nodes one at a time"
    echo "  $0 -t worker -p 3               # Reboot worker nodes 3 at a time"
    echo "  $0 -n worker-01.example.com -d  # Dry run for a specific node"
    echo "  $0 -t master -y -c -l reboot.log # Reboot all masters with auto-confirm, no colors"
    exit 1
}

# Function to check cluster health before proceeding
check_cluster_health() {
    local dry_run=$1
    
    if [ "$dry_run" = true ]; then
        log "$LOG_LEVEL_INFO" "[DRY RUN] Would check cluster health status..."
        return 0
    fi
    
    log "$LOG_LEVEL_INFO" "Checking cluster health status..."
    
    # Check for degraded operators
    start_spinner "Checking operator status..."
    local degraded_operators
    degraded_operators=$(timeout $OC_COMMAND_TIMEOUT oc get clusteroperators -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Degraded")].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    stop_spinner
    
    if [[ -n "$degraded_operators" ]]; then
        log "$LOG_LEVEL_WARNING" "The following operators are currently degraded:"
        echo "$degraded_operators" | while read -r operator; do
            log "$LOG_LEVEL_WARNING" "  - $operator"
        done
        
        if ! $SKIP_PROMPTS; then
            read -p "Continue despite degraded operators? (y/n): " continue_confirm
            if [[ "$continue_confirm" != "y" ]]; then
                log "$LOG_LEVEL_ERROR" "Operation cancelled due to degraded operators"
                exit 1
            fi
        else
            log "$LOG_LEVEL_WARNING" "Continuing despite degraded operators (skip_prompts=true)"
        fi
    else
        log "$LOG_LEVEL_INFO" "No degraded operators found."
    fi
    
    # Check for unhealthy nodes
    start_spinner "Checking node health..."
    local not_ready_nodes
    not_ready_nodes=$(timeout $OC_COMMAND_TIMEOUT oc get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    stop_spinner
    
    if [[ -n "$not_ready_nodes" ]]; then
        log "$LOG_LEVEL_WARNING" "The following nodes are currently not Ready:"
        echo "$not_ready_nodes" | while read -r node; do
            log "$LOG_LEVEL_WARNING" "  - $node"
        done
        
        if ! $SKIP_PROMPTS; then
            read -p "Continue despite unhealthy nodes? (y/n): " continue_confirm
            if [[ "$continue_confirm" != "y" ]]; then
                log "$LOG_LEVEL_ERROR" "Operation cancelled due to unhealthy nodes"
                exit 1
            fi
        else
            log "$LOG_LEVEL_WARNING" "Continuing despite unhealthy nodes (skip_prompts=true)"
        fi
    else
        log "$LOG_LEVEL_INFO" "All nodes appear to be healthy."
    fi
    
    # Check for pending CSRs
    start_spinner "Checking certificate signing requests..."
    local pending_csrs
    pending_csrs=$(timeout $OC_COMMAND_TIMEOUT oc get csr -o jsonpath='{range .items[?(@.status.conditions[0].type!="Approved")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    stop_spinner
    
    if [[ -n "$pending_csrs" ]]; then
        log "$LOG_LEVEL_WARNING" "There are pending certificate signing requests:"
        echo "$pending_csrs" | while read -r csr; do
            log "$LOG_LEVEL_WARNING" "  - $csr"
        done
        
        log "$LOG_LEVEL_INFO" "Pending CSRs won't be automatically approved during this operation."
    else
        log "$LOG_LEVEL_INFO" "No pending certificate signing requests found."
    fi
    
    log "$LOG_LEVEL_INFO" "Cluster health check completed."
    return 0
}

# Function to verify OpenShift CLI and login status
check_oc_client() {
    if ! command -v oc &> /dev/null; then
        log "$LOG_LEVEL_ERROR" "OpenShift CLI (oc) is not installed or not in PATH."
        exit 1
    fi

    # Get oc version for diagnosis
    local oc_version
    oc_version=$(oc version 2>&1 | head -n 1)
    log "$LOG_LEVEL_INFO" "OpenShift CLI version: $oc_version"

    # Debug output before checking login
    log "$LOG_LEVEL_DEBUG" "Checking OpenShift login status..."
    
    start_spinner "Verifying OpenShift login status..."
    
    # Run oc whoami with explicit output capture
    local login_check
    login_check=$(oc whoami 2>&1)
    local login_status=$?
    
    stop_spinner
    
    if [ $login_status -ne 0 ]; then
        log "$LOG_LEVEL_ERROR" "Not logged into OpenShift. Error was: $login_check"
        exit 1
    fi
    
    log "$LOG_LEVEL_INFO" "OpenShift CLI check passed. Logged in as: $login_check"
    
    # Check if user has cluster-admin or equivalent privileges
    local can_create_namespace
    start_spinner "Checking permissions..."
    can_create_namespace=$(timeout $OC_COMMAND_TIMEOUT oc auth can-i create namespace 2>/dev/null)
    stop_spinner
    
    if [[ "$can_create_namespace" != "yes" ]]; then
        log "$LOG_LEVEL_ERROR" "Insufficient permissions. The current user cannot create namespaces."
        log "$LOG_LEVEL_ERROR" "This script requires cluster-admin privileges."
        exit 1
    fi
    
    log "$LOG_LEVEL_DEBUG" "User has sufficient privileges."
}

# Function to ensure debug namespace exists with empty node selector
ensure_debug_namespace() {
    log "$LOG_LEVEL_INFO" "Ensuring debug namespace exists with empty node selector..."
    
    # Check if debug namespace already exists
    start_spinner "Checking for debug namespace..."
    local namespace_exists
    namespace_exists=$(timeout $OC_COMMAND_TIMEOUT oc get namespace debug &> /dev/null; echo $?)
    stop_spinner
    
    if [[ $namespace_exists -eq 0 ]]; then
        log "$LOG_LEVEL_INFO" "Debug namespace already exists. Ensuring it has an empty node selector..."
        start_spinner "Updating namespace node selector..."
        if ! timeout $OC_COMMAND_TIMEOUT oc patch namespace debug -p '{"metadata":{"annotations":{"openshift.io/node-selector":""}}}' --type=merge; then
            stop_spinner
            log "$LOG_LEVEL_ERROR" "Failed to patch debug namespace with empty node selector"
            exit 1
        fi
        stop_spinner
    else
        log "$LOG_LEVEL_INFO" "Creating debug namespace with empty node selector..."
        start_spinner "Creating debug namespace..."
        if ! timeout $OC_COMMAND_TIMEOUT oc adm new-project --node-selector="" debug; then
            stop_spinner
            log "$LOG_LEVEL_ERROR" "Failed to create debug namespace"
            exit 1
        fi
        stop_spinner
    fi
    
    # Switch to debug namespace
    start_spinner "Switching to debug namespace..."
    if ! timeout $OC_COMMAND_TIMEOUT oc project debug; then
        stop_spinner
        log "$LOG_LEVEL_ERROR" "Failed to switch to debug namespace"
        exit 1
    fi
    stop_spinner
    
    log "$LOG_LEVEL_INFO" "Now using project debug"
}

# Function to get nodes by role
get_nodes_by_role() {
    local role=$1
    local selector="node-role.kubernetes.io/$role="
    
    log "$LOG_LEVEL_INFO" "Finding nodes with role: $role"
    
    # Create temporary file to store node names with role as prefix
    NODE_LIST_FILE=$(mktemp -t "${role}-nodes-XXXXXX")
    
    # Get nodes with the specified role
    start_spinner "Retrieving nodes with role '$role'..."
    if ! timeout $OC_COMMAND_TIMEOUT oc get nodes -l "$selector" -o name | cut -d'/' -f2 > "$NODE_LIST_FILE"; then
        stop_spinner
        log "$LOG_LEVEL_ERROR" "Failed to get nodes with role '$role' or command timed out"
        rm -f "$NODE_LIST_FILE"
        exit 1
    fi
    stop_spinner
    
    # Check if any nodes were found
    if [[ ! -s "$NODE_LIST_FILE" ]]; then
        log "$LOG_LEVEL_ERROR" "No nodes found with role '$role'"
        rm -f "$NODE_LIST_FILE"
        exit 1
    fi
    
    # Count and display found nodes
    local node_count
    node_count=$(wc -l < "$NODE_LIST_FILE")
    
    log "$LOG_LEVEL_INFO" "Found ${node_count} node(s) with role '$role':"
    if $USE_COLORS; then
        cat "$NODE_LIST_FILE" | while read -r node; do
            log "$LOG_LEVEL_INFO" "  - ${COLOR_CYAN}$node${COLOR_RESET}"
        done
    else
        cat "$NODE_LIST_FILE" | while read -r node; do
            log "$LOG_LEVEL_INFO" "  - $node"
        done
    fi
    
    log "$LOG_LEVEL_DEBUG" "Node list saved to temporary file: $NODE_LIST_FILE"
}

# Function to create a node list file with a single node
create_single_node_file() {
    local node=$1
    
    log "$LOG_LEVEL_INFO" "Targeting specific node: $node"
    
    # Extract role from node name if possible
    local role="custom"
    if [[ "$node" =~ ^(infra|master|worker) ]]; then
        role=$(echo "$node" | sed 's/\([^-]*\).*/\1/')
    fi
    
    # Create temporary file to store node name with role as prefix
    NODE_LIST_FILE=$(mktemp -t "${role}-node-XXXXXX")
    
    # Check if node exists
    start_spinner "Verifying node exists..."
    if ! timeout $OC_COMMAND_TIMEOUT oc get node "$node" &> /dev/null; then
        stop_spinner
        log "$LOG_LEVEL_ERROR" "Node '$node' not found or command timed out"
        rm -f "$NODE_LIST_FILE"
        exit 1
    fi
    stop_spinner
    
    # Get node role(s) for informational purposes
    start_spinner "Getting node role information..."
    local node_roles
    node_roles=$(timeout $OC_COMMAND_TIMEOUT oc get node "$node" -o jsonpath='{.metadata.labels}' | grep -o 'node-role.kubernetes.io/[^:]*' | sed 's/node-role.kubernetes.io\///')
    stop_spinner
    
    if [[ -n "$node_roles" ]]; then
        log "$LOG_LEVEL_INFO" "Node roles: $node_roles"
    fi
    
    # Write the node name to the file
    echo "$node" > "$NODE_LIST_FILE"
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "Targeting node: ${COLOR_CYAN}$node${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "Targeting node: $node"
    fi
    
    log "$LOG_LEVEL_DEBUG" "Node saved to temporary file: $NODE_LIST_FILE"
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
    
    start_spinner "Waiting for node to report Ready status..."
    
    while (( attempt <= max_attempts )); do
        log "$LOG_LEVEL_DEBUG" "Attempt $attempt/$max_attempts: Checking if node $node is Ready..."
        
        # Check node status with timeout
        if timeout $OC_COMMAND_TIMEOUT oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
            stop_spinner
            log "$LOG_LEVEL_INFO" "Node $node is Ready!"
            return 0
        fi
        
        # If not ready, wait and try again
        sleep $RETRY_INTERVAL
        (( attempt++ ))
    done
    
    stop_spinner
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
    start_spinner "Waiting for debug access to node..."
    
    while (( attempt <= max_attempts )); do
        log "$LOG_LEVEL_DEBUG" "Attempt $attempt/$max_attempts: Trying to debug node $node..."
        
        # Try to debug the node with a simple command with timeout
        if timeout $OC_COMMAND_TIMEOUT oc debug node/"$node" -- chroot /host ls / &> /dev/null; then
            stop_spinner
            log "$LOG_LEVEL_INFO" "Node $node is accessible via debug!"
            return 0
        fi
        
        # If not accessible, wait and try again
        log "$LOG_LEVEL_DEBUG" "Node $node not accessible yet, waiting..."
        sleep $RETRY_INTERVAL
        (( attempt++ ))
    done
    
    stop_spinner
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
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "Draining node: ${COLOR_CYAN}$node${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "Draining node: $node"
    fi
    
    # Check for pods on the node
    start_spinner "Checking pods on node..."
    local pod_count
    pod_count=$(timeout $OC_COMMAND_TIMEOUT oc get pods --all-namespaces -o wide --field-selector spec.nodeName="$node" --no-headers 2>/dev/null | wc -l)
    stop_spinner
    
    if [ "$pod_count" -eq 0 ]; then
        log "$LOG_LEVEL_INFO" "No pods found on node $node, skipping drain operation."
        return 0
    else
        log "$LOG_LEVEL_INFO" "Found $pod_count pods running on node $node."
    fi
    
    while (( retry_count <= DRAIN_RETRY_COUNT )); do
        log "$LOG_LEVEL_INFO" "Drain attempt $retry_count/$DRAIN_RETRY_COUNT..."
        
        start_spinner "Draining node ${node}..."
        local drain_output
        drain_output=$(timeout $NODE_DRAIN_TIMEOUT oc adm drain node/$node --ignore-daemonsets --force --delete-emptydir-data --disable-eviction 2>&1)
        local exit_code=$?
        stop_spinner
        
        if [ $exit_code -eq 0 ]; then
            log "$LOG_LEVEL_INFO" "Successfully drained node $node"
            
            # Log important drain output at debug level
            log "$LOG_LEVEL_DEBUG" "Drain output summary:"
            echo "$drain_output" | grep -E 'evicted|pods' | while read -r line; do
                log "$LOG_LEVEL_DEBUG" "  $line"
            done
            
            return 0
        else
            log "$LOG_LEVEL_WARNING" "Failed to drain node $node (attempt $retry_count/$DRAIN_RETRY_COUNT, exit code: $exit_code)"
            
            # Log error output
            echo "$drain_output" | grep -E 'error|warning|unable' | while read -r line; do
                log "$LOG_LEVEL_WARNING" "  $line"
            done
            
            if (( retry_count == DRAIN_RETRY_COUNT )); then
                log "$LOG_LEVEL_ERROR" "Failed to drain node $node after $DRAIN_RETRY_COUNT attempts"
                
                # Check for common issues
                if echo "$drain_output" | grep -q "cannot delete Pods not managed by ReplicationController, ReplicaSet, Job, DaemonSet or StatefulSet"; then
                    log "$LOG_LEVEL_WARNING" "There appear to be static pods or pods not managed by controllers on this node."
                    log "$LOG_LEVEL_WARNING" "Consider using --force-delete-pods if you want to proceed anyway."
                fi
                
                if echo "$drain_output" | grep -q "PodDisruptionBudget"; then
                    log "$LOG_LEVEL_WARNING" "PodDisruptionBudget is preventing eviction of some pods."
                    log "$LOG_LEVEL_WARNING" "Consider checking PDB configurations or using --disable-eviction flag."
                fi
                
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
        log "$LOG_LEVEL_DEBUG" "Uncordon attempt $retry_count/$DRAIN_RETRY_COUNT..."
        
        start_spinner "Uncordoning node..."
        if timeout $OC_COMMAND_TIMEOUT oc adm uncordon node/$node; then
            stop_spinner
            log "$LOG_LEVEL_INFO" "Successfully uncordoned node $node"
            return 0
        else
            stop_spinner
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
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "Starting graceful reboot process for node: ${COLOR_CYAN}$node${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "Starting graceful reboot process for node: $node"
    fi
    
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
        start_spinner "Rebooting node..."
        if ! timeout $OC_COMMAND_TIMEOUT oc debug node/"$node" -- chroot /host systemctl reboot; then
            stop_spinner
            log "$LOG_LEVEL_ERROR" "Failed to execute reboot command on node $node"
            
            # Try to uncordon the node even though reboot failed
            log "$LOG_LEVEL_WARNING" "Attempting to uncordon node $node after reboot failure"
            uncordon_node "$node" "$dry_run"
            
            return 1
        fi
        stop_spinner
        
        # The debug pod will terminate after the reboot command
        log "$LOG_LEVEL_INFO" "Reboot command sent to $node"
    fi
    
    return 0
}

# Function to determine default parallel count based on node type
get_default_parallel_count() {
    local role=$1
    
    case "$role" in
        master)
            echo "$MASTER_PARALLEL_DEFAULT"
            ;;
        infra)
            echo "$INFRA_PARALLEL_DEFAULT"
            ;;
        worker)
            echo "$WORKER_PARALLEL_DEFAULT"
            ;;
        *)
            echo "$OTHER_PARALLEL_DEFAULT"
            ;;
    esac
}

# Function to generate status report
generate_status_report() {
    local total_nodes=$1
    local successful_nodes=$2
    local failed_nodes=$3
    local skipped_nodes=$4
    local report_file="reboot-report-$(date +%Y%m%d-%H%M%S).txt"
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_BLUE}===========================================${COLOR_RESET}"
        log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_BLUE}Reboot Status Report${COLOR_RESET}"
        log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_BLUE}===========================================${COLOR_RESET}"
        log "$LOG_LEVEL_INFO" "Total nodes processed:  $total_nodes"
        log "$LOG_LEVEL_INFO" "Successfully rebooted: ${COLOR_GREEN}$successful_nodes${COLOR_RESET}"
        if [[ $failed_nodes -gt 0 ]]; then
            log "$LOG_LEVEL_INFO" "Failed to reboot:     ${COLOR_RED}$failed_nodes${COLOR_RESET}"
        else
            log "$LOG_LEVEL_INFO" "Failed to reboot:     $failed_nodes"
        fi
        if [[ $skipped_nodes -gt 0 ]]; then
            log "$LOG_LEVEL_INFO" "Skipped nodes:        ${COLOR_YELLOW}$skipped_nodes${COLOR_RESET}"
        else
            log "$LOG_LEVEL_INFO" "Skipped nodes:        $skipped_nodes"
        fi
        
        # Calculate success rate only if at least one node was attempted (not skipped)
        if [[ $((total_nodes - skipped_nodes)) -gt 0 ]]; then
            local success_rate=$(( (successful_nodes * 100) / (total_nodes - skipped_nodes) ))
            log "$LOG_LEVEL_INFO" "Success rate:         ${COLOR_BOLD}${success_rate}%${COLOR_RESET}"
        fi
        log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_BLUE}===========================================${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "=========================================="
        log "$LOG_LEVEL_INFO" "Reboot Status Report"
        log "$LOG_LEVEL_INFO" "=========================================="
        log "$LOG_LEVEL_INFO" "Total nodes processed:  $total_nodes"
        log "$LOG_LEVEL_INFO" "Successfully rebooted: $successful_nodes"
        log "$LOG_LEVEL_INFO" "Failed to reboot:     $failed_nodes"
        log "$LOG_LEVEL_INFO" "Skipped nodes:        $skipped_nodes"
        
        # Calculate success rate only if at least one node was attempted (not skipped)
        if [[ $((total_nodes - skipped_nodes)) -gt 0 ]]; then
            local success_rate=$(( (successful_nodes * 100) / (total_nodes - skipped_nodes) ))
            log "$LOG_LEVEL_INFO" "Success rate:         $success_rate%"
        fi
        log "$LOG_LEVEL_INFO" "=========================================="
    fi
    
    # Save report to file
    {
        echo "=========================================="
        echo "Reboot Status Report - $(date)"
        echo "=========================================="
        echo "Total nodes processed:  $total_nodes"
        echo "Successfully rebooted: $successful_nodes"
        echo "Failed to reboot:     $failed_nodes"
        echo "Skipped nodes:        $skipped_nodes"
        
        # Calculate success rate only if at least one node was attempted (not skipped)
        if [[ $((total_nodes - skipped_nodes)) -gt 0 ]]; then
            local success_rate=$(( (successful_nodes * 100) / (total_nodes - skipped_nodes) ))
            echo "Success rate:         $success_rate%"
        fi
        echo "=========================================="
        echo "Script version: $SCRIPT_VERSION"
        echo "Report generated: $(date)"
        echo "User: $(whoami)@$(hostname)"
        echo "Command used: $0 $ORIGINAL_ARGS"
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
    local skipped_nodes=0
    local skipped_node_list=()
    # Read all nodes into an array
    while read -r node; do
        nodes+=("$node")
    done < "$NODE_LIST_FILE"
    
    total_nodes=${#nodes[@]}
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "Processing ${COLOR_BOLD}$total_nodes${COLOR_RESET} nodes with parallelism of ${COLOR_BOLD}$parallel_count${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "Processing $total_nodes nodes with parallelism of $parallel_count"
    fi
    
    # Process nodes in batches
    while [ $i -lt $total_nodes ]; do
        local batch_start=$i
        local batch_end=$((i + parallel_count - 1))
        
        if [ $batch_end -ge $total_nodes ]; then
            batch_end=$((total_nodes - 1))
        fi
        
        if $USE_COLORS; then
            print_hr "="
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}Processing batch of nodes: $((batch_start + 1)) to $((batch_end + 1)) of $total_nodes${COLOR_RESET}"
            print_hr "="
        else
            print_hr "="
            log "$LOG_LEVEL_INFO" "Processing batch of nodes: $((batch_start + 1)) to $((batch_end + 1)) of $total_nodes"
            print_hr "="
        fi
        
        # Start a batch of nodes
        for j in $(seq $batch_start $batch_end); do
            local node=${nodes[$j]}
            
            if $USE_COLORS; then
                print_hr "-"
                log "$LOG_LEVEL_INFO" "${COLOR_BOLD}Processing node: ${COLOR_CYAN}$node${COLOR_RESET}${COLOR_BOLD} ($(($j + 1))/$total_nodes)${COLOR_RESET}"
            else
                print_hr "-"
                log "$LOG_LEVEL_INFO" "Processing node: $node ($(($j + 1))/$total_nodes)"
            fi
            
            # Ask for confirmation if not skipping prompts
            # Ask for confirmation if not skipping prompts
            if ! $skip_prompts; then
                read -p "Reboot node $node? (y/n): " confirm
                if [[ "$confirm" != "y" ]]; then
                    log "$LOG_LEVEL_INFO" "Skipping node $node per user request"
                    skipped_nodes=$((skipped_nodes + 1))
                    skipped_node_list+=("$node")
                    log "$LOG_LEVEL_INFO" "Node $node was skipped"
                    continue
                fi
            else
                log "$LOG_LEVEL_DEBUG" "Auto-confirming reboot of node $node (skip_prompts=true)"
            fi
            # Gracefully reboot the node (drain, reboot, and later uncordon)
            if ! reboot_node "$node" "$dry_run"; then
                log "$LOG_LEVEL_ERROR" "Failed to initiate reboot process for node $node"
                failed_nodes=$((failed_nodes + 1))
                continue
            fi
            
            log "$LOG_LEVEL_INFO" "Started reboot process for node $node"
            
            # Skip waiting in dry run mode
            if [ "$dry_run" = true ]; then
                successful_nodes=$((successful_nodes + 1))
                continue
            fi
        done
        
        # Wait for the batch to complete (only if not in dry run)
        if [ "$dry_run" = false ]; then
            log "$LOG_LEVEL_INFO" "Waiting for batch to complete..."
            
            for j in $(seq $batch_start $batch_end); do
                local node=${nodes[$j]}
                local was_skipped=false
                
                # Check if this node was skipped
                local was_skipped=false
                for skipped_node in "${skipped_node_list[@]}"; do
                    if [[ "$node" == "$skipped_node" ]]; then
                        was_skipped=true
                        break
                    fi
                done
                if $was_skipped; then
                    log "$LOG_LEVEL_DEBUG" "Skipping wait for node $node as it was not rebooted"
                    continue
                fi
                
                local node_success=true
                
                if $USE_COLORS; then
                    log "$LOG_LEVEL_INFO" "Checking status of node: ${COLOR_CYAN}$node${COLOR_RESET}"
                else
                    log "$LOG_LEVEL_INFO" "Checking status of node: $node"
                fi
                
                # Wait for node to become Ready
                if ! wait_for_node_ready "$node" "$dry_run"; then
                    log "$LOG_LEVEL_WARNING" "Node $node did not become Ready within the timeout period."
                    node_success=false
                    if ! $skip_prompts; then
                        read -p "Continue with next batch? (y/n): " continue_confirm
                        if [[ "$continue_confirm" != "y" ]]; then
                            log "$LOG_LEVEL_ERROR" "Exiting script"
                            # Generate report before exiting
                            generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes" "$skipped_nodes"
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
                            generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes" "$skipped_nodes"
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
                    if $USE_COLORS; then
                        log "$LOG_LEVEL_INFO" "Node ${COLOR_CYAN}$node${COLOR_RESET} has been ${COLOR_GREEN}successfully${COLOR_RESET} rebooted and is ready."
                    else
                        log "$LOG_LEVEL_INFO" "Node $node has been successfully rebooted and is ready."
                    fi
                fi
            done
        fi
        
        i=$((batch_end + 1))
    done
    
    # Generate final report
    generate_status_report "$total_nodes" "$successful_nodes" "$failed_nodes" "$skipped_nodes"
    
    return 0
}

# Main function
main() {
    ORIGINAL_ARGS="$*"
    local node_type=""
    local node_name=""
    local SKIP_PROMPTS=false
    local dry_run=false
    local parallel_count=0 # 0 means use default based on node type
    local custom_timeout=0
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type)
                node_type="$2"
                shift 2
                ;;
            -n|--node)
                node_name="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_PROMPTS=true
                shift
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -p|--parallel)
                parallel_count="$2"
                shift 2
                ;;
            -c|--no-color)
                USE_COLORS=false
                shift
                ;;
            -l|--log)
                LOG_FILE="$2"
                shift 2
                ;;
            -v|--verbose)
                CURRENT_LOG_LEVEL="$LOG_LEVEL_DEBUG"
                shift
                ;;
            --timeout)
                custom_timeout="$2"
                shift 2
                ;;
            --no-spinner)
                ENABLE_SPINNER=false
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log "$LOG_LEVEL_ERROR" "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Banner with version info
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_BLUE}OpenShift Node Graceful Reboot Utility v${SCRIPT_VERSION}${COLOR_RESET}"
        log "$LOG_LEVEL_INFO" "${COLOR_DIM}Running on $(date)${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "OpenShift Node Graceful Reboot Utility v${SCRIPT_VERSION}"
        log "$LOG_LEVEL_INFO" "Running on $(date)"
    fi
    
    # Check if terminal supports colors
    check_color_support
    log "$LOG_LEVEL_DEBUG" "Color support detected: $USE_COLORS"
    
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
    
    # Apply custom timeout if provided
    if [[ $custom_timeout -gt 0 ]]; then
        NODE_READY_TIMEOUT=$((custom_timeout / RETRY_INTERVAL))
        log "$LOG_LEVEL_INFO" "Using custom timeout: $custom_timeout seconds ($NODE_READY_TIMEOUT attempts)"
    fi
    
    # Set a reasonable upper limit for parallel count to prevent accidental large values
    if [[ $parallel_count -gt 20 ]]; then
        log "$LOG_LEVEL_WARNING" "Parallel count of $parallel_count is unusually high"
        if ! $SKIP_PROMPTS; then
            read -p "Are you sure you want to use a parallel count of $parallel_count? (y/n): " parallel_confirm
            if [[ "$parallel_confirm" != "y" ]]; then
                log "$LOG_LEVEL_INFO" "Operation cancelled by user"
                exit 0
            fi
        fi
    fi
    
    # Indicate if we're in dry run mode
    if [ "$dry_run" = true ]; then
        if $USE_COLORS; then
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_PURPLE}============================================${COLOR_RESET}"
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_PURPLE}DRY RUN MODE - No actual changes will be made${COLOR_RESET}"
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_PURPLE}============================================${COLOR_RESET}"
        else
            log "$LOG_LEVEL_INFO" "============================================"
            log "$LOG_LEVEL_INFO" "DRY RUN MODE - No actual changes will be made"
            log "$LOG_LEVEL_INFO" "============================================"
        fi
    fi
    
    # Check if timeout command is available
    check_timeout_command
    
    # Check if oc client is available
    check_oc_client
    
    # Check cluster health before proceeding
    check_cluster_health "$dry_run"
    
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
    
    if $USE_COLORS; then
        log "$LOG_LEVEL_INFO" "Using parallel count: ${COLOR_BOLD}$parallel_count${COLOR_RESET}"
    else
        log "$LOG_LEVEL_INFO" "Using parallel count: $parallel_count"
    fi
    
    # Initial confirmation before starting any reboots
    if ! $SKIP_PROMPTS; then
        local node_count=$(wc -l < "$NODE_LIST_FILE")
        
        if $USE_COLORS; then
            print_hr "="
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_YELLOW}You are about to gracefully reboot $node_count node(s) with parallelism of $parallel_count.${COLOR_RESET}"
            log "$LOG_LEVEL_INFO" "This process will:"
            log "$LOG_LEVEL_INFO" " 1. ${COLOR_CYAN}Drain${COLOR_RESET} each node (evacuate pods)"
            log "$LOG_LEVEL_INFO" " 2. ${COLOR_CYAN}Reboot${COLOR_RESET} the node"
            log "$LOG_LEVEL_INFO" " 3. ${COLOR_CYAN}Wait${COLOR_RESET} for node to become ready" 
            log "$LOG_LEVEL_INFO" " 4. ${COLOR_CYAN}Uncordon${COLOR_RESET} the node (make schedulable again)"
            
            if [ "$dry_run" = true ]; then
                log "$LOG_LEVEL_INFO" "${COLOR_PURPLE}[DRY RUN] No actual changes will be made.${COLOR_RESET}"
            else
                log "$LOG_LEVEL_INFO" "${COLOR_YELLOW}This will cause service disruption if not handled properly.${COLOR_RESET}"
            fi
            
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_YELLOW}Make sure you understand the impact of this operation.${COLOR_RESET}"
            print_hr "="
        else
            print_hr "="
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
            print_hr "="
        fi
        
        read -p "Do you want to proceed? (y/n): " initial_confirm
        if [[ "$initial_confirm" != "y" ]]; then
            log "$LOG_LEVEL_INFO" "Operation cancelled by user"
            rm -f "$NODE_LIST_FILE"
            exit 0
        fi
    fi
    
    # Process nodes in parallel
    process_nodes_parallel "$parallel_count" "$SKIP_PROMPTS" "$dry_run"
    reboot_result=$?
    
    # Clean up
    rm -f "$NODE_LIST_FILE"
    
    if [ $reboot_result -eq 0 ]; then
        if $USE_COLORS; then
            log "$LOG_LEVEL_INFO" "${COLOR_BOLD}${COLOR_GREEN}All nodes processed. Script complete.${COLOR_RESET}"
        else
            log "$LOG_LEVEL_INFO" "All nodes processed. Script complete."
        fi
    else
        if $USE_COLORS; then
            log "$LOG_LEVEL_ERROR" "${COLOR_BOLD}${COLOR_RED}Script execution stopped early due to user input or errors.${COLOR_RESET}"
        else
            log "$LOG_LEVEL_ERROR" "Script execution stopped early due to user input or errors."
        fi
        exit 1
    fi
}

# Run main function
main "$@"
