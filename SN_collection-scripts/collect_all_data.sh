#!/bin/bash

# Color palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Centralized path configuration (override via environment variables)
PROJECT_ROOT="${PROJECT_ROOT:-{PROJECT_ROOT}}"
DATASET_STORAGE_DIR="${DATASET_STORAGE_DIR:-{DATA_OUTPUT_PATH}}"
DATASET_SCRIPT_DIR="${DATASET_SCRIPT_DIR:-${PROJECT_ROOT}/Dataset}"
SOCIAL_NETWORK_DIR="${SOCIAL_NETWORK_DIR:-${PROJECT_ROOT}/DeathStarBench/socialNetwork}"
CHAOSBLADE_DIR="${CHAOSBLADE_DIR:-${PROJECT_ROOT}/chaosblade/chaosblade-1.7.4}"
EVOMASTER_BASE_DIR="${EVOMASTER_BASE_DIR:-${PROJECT_ROOT}/BlackBox_tests}"
API_SPEC_PATH="${API_SPEC_PATH:-${PROJECT_ROOT}/social-network-api.yaml}"

# Logging helpers
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Validation helpers
ensure_path_var() {
    local name="$1"
    local value="${!name:-}"
    if [[ -z "$value" || "$value" =~ ^\{[A-Z_]+\}$ ]]; then
        log_error "Environment variable $name is not configured. Please export a valid absolute path."
        exit 1
    fi
}

validate_base_paths() {
    ensure_path_var PROJECT_ROOT
    ensure_path_var DATASET_STORAGE_DIR
    ensure_path_var DATASET_SCRIPT_DIR
    ensure_path_var SOCIAL_NETWORK_DIR
    ensure_path_var CHAOSBLADE_DIR
    ensure_path_var EVOMASTER_BASE_DIR
    ensure_path_var API_SPEC_PATH
}

# Error handling helper
check_command_success() {
    if [ $? -ne 0 ]; then
        log_error "Command failed: $1"
        # Evaluate whether to exit immediately or keep running for non-critical steps (e.g., coverage collection).
        # exit 1
    fi
}

# Wait until docker-compose services are up.
wait_for_services() {
    log_info "Waiting for services to start (usually takes 30-60 seconds)..."
    # Initial wait to give docker-compose enough time to spin up containers.
    sleep 30

    local max_attempts=30 # Total wait window: 30s initial + 30*5s = 180s
    local attempt=0
    local services_ready=false

    # The simplest check is to ensure at least one SocialNetwork container is alive.
    # Consider adding health checks or port probing if more accuracy is required.

    while [ $attempt -lt $max_attempts ]; do
        if docker ps --filter "name=socialnetwork" --format "{{.Names}}" | grep -q "socialnetwork"; then
            log_info "Detected SocialNetwork containers are running. Waiting another 10 seconds to ensure service initialization..."
            sleep 10 # Additional delay so internal components finish bootstrapping.
            services_ready=true
            break
        fi

        attempt=$((attempt + 1))
        log_info "Waiting for services to start... (${attempt}/${max_attempts})"
        sleep 5
    done

    if [ "$services_ready" = false ]; then
        log_error "Services startup timeout or key services not detected."
        log_info "Current socialnetwork-related containers:"
        docker ps --filter "name=socialnetwork"
        exit 1
    fi
    log_info "Services startup completed."
}


# Display available chaos experiments
show_chaos_options() {
    echo -e "${BLUE}Available chaos experiments:${NC}"
    echo "1. CPU contention"
    echo "   example: blade create cpu load --cpu-percent 100 --timeout 300"
    echo
    echo "2. Network drop between containers"
    echo "   example: blade create network loss --interface docker0 --percent 50 --timeout 300"
    echo
    echo "3. Disk I/O stress"
    echo "   example: blade create disk burn --read --write --path /var/log --size 1024 --timeout 300"
    echo
    echo "4. Kill container"
    echo "   example: blade create process kill --process UserTimelineService --signal 9"
    echo
    # echo "5. Packet-loss injection"
    # echo "   example: blade create network loss --interface docker0 --percent 10 --timeout 300"
    # echo
    # echo "6. Bandwidth throttling"
    # echo "   example: blade create network bandwidth --rate 1mbps --interface docker0 --timeout 300"
    # echo
    # echo "7. Custom command"
    # echo "   Provide any blade sub-command (without the 'blade' prefix, e.g., create cpu fullload)"
    # echo
}

# Display execution mode options
show_execution_modes() {
    echo -e "${BLUE}Please select execution mode:${NC}"
    echo "1. Complete workflow (restart services + chaos experiment + EvoMaster + data collection)"
    echo "2. Data collection only (collect logs, metrics, traces, and coverage)"
    echo
}

# Main entry point
main() {
    log_step "=== SocialNetwork multimodal data collection workflow ==="

    validate_base_paths

    # Show execution mode selector
    show_execution_modes

    local user_choice
    echo -n "Please enter your choice (1 or 2): "
    read user_choice

    # Step 1: collect experiment metadata
    log_step "Step 1: Configure experiment parameters"

    # Capture experiment folder name
    local experiment_base_name
    while true; do
        echo -n "Please enter the base name for this experiment (e.g., cpu_stress, disk_io_v1, network_delay_high): "
        read experiment_base_name
        if [[ -z "$experiment_base_name" ]]; then
            log_warn "Experiment base name cannot be empty, please re-enter."
        elif [[ "$experiment_base_name" =~ [/\\] ]]; then
            log_warn "Experiment base name cannot contain slashes ( / or \ ), please re-enter."
        else
            break
        fi
    done
    log_info "Experiment base name: $experiment_base_name"

    # Generate a global timestamp (YYYY-MM-DD_HH-MM-SS)
    GLOBAL_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    log_info "Global timestamp: $GLOBAL_TIMESTAMP"

    case $user_choice in
        1)
            # Full workflow
            log_step "=== Complete Workflow Mode ==="
            
            # Step 2: restart services
            log_step "Step 2: Restart SocialNetwork services"
            if [ -d "$SOCIAL_NETWORK_DIR" ]; then
                cd "$SOCIAL_NETWORK_DIR"
                check_command_success "Switch to SocialNetwork directory ($SOCIAL_NETWORK_DIR)"
            else
                log_error "SocialNetwork directory '$SOCIAL_NETWORK_DIR' not found."
                exit 1
            fi

            log_info "Stopping existing services (docker-compose -f docker-compose-gcov.yml down)..."
            docker-compose -f docker-compose-gcov.yml down

            log_info "Starting services (docker-compose -f docker-compose-gcov.yml up -d)..."
            docker-compose -f docker-compose-gcov.yml up -d
            check_command_success "Starting services"

            wait_for_services

            # Continue with the full workflow
            run_complete_workflow "$experiment_base_name" "$GLOBAL_TIMESTAMP"
            ;;
        2)
            # Data collection only
            log_step "=== Data Collection Only Mode ==="
            collect_multimodal_data "$experiment_base_name" "$GLOBAL_TIMESTAMP"
            
            # Summary
            log_step "=== Data Collection Completed ==="
            log_info "Experiment base name: $experiment_base_name"
            log_info "Global timestamp: $GLOBAL_TIMESTAMP"
            log_info "Data collection location:"
            log_info "  - Log data: ${DATASET_STORAGE_DIR}/log_data/${experiment_base_name}_logs_${GLOBAL_TIMESTAMP}"
            log_info "  - Metric data: ${DATASET_STORAGE_DIR}/metric_data/${experiment_base_name}_metrics_${GLOBAL_TIMESTAMP}"
            log_info "  - Trace data: ${DATASET_STORAGE_DIR}/trace_data/${experiment_base_name}_traces_${GLOBAL_TIMESTAMP}"
            log_info "  - API response data: ${DATASET_STORAGE_DIR}/api_responses/${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}"
            log_info "  - Coverage report: ${DATASET_STORAGE_DIR}/coverage_data/${experiment_base_name}_coverage_${GLOBAL_TIMESTAMP}"
            log_info "Script execution successful!"
            ;;
        *)
            log_error "Invalid choice. Please enter 1 or 2."
            exit 1
            ;;
    esac
}

# Complete workflow driver
run_complete_workflow() {
    local experiment_base_name="$1"
    local GLOBAL_TIMESTAMP="$2"

    # Derive modal-specific directory basenames
    # EvoMaster output uses only the experiment name
    EVOMASTER_OUTPUT_FOLDER_NAME="$experiment_base_name"
    # Other modalities include the global timestamp
    LOG_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_logs_${GLOBAL_TIMESTAMP}"
    METRIC_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_metrics_${GLOBAL_TIMESTAMP}"
    TRACE_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_traces_${GLOBAL_TIMESTAMP}"
    OPENAPI_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}"
    # Coverage folders include the timestamp suffix
    COVERAGE_FINAL_TARGET_FOLDER_BASENAME="${experiment_base_name}_coverage_${GLOBAL_TIMESTAMP}"

    log_info "EvoMaster output subdirectory name: $EVOMASTER_OUTPUT_FOLDER_NAME"
    log_info "Log data output subdirectory name: $LOG_OUTPUT_FOLDER_BASENAME"
    log_info "Metric data output subdirectory name: $METRIC_OUTPUT_FOLDER_BASENAME"
    log_info "Trace data output subdirectory name: $TRACE_OUTPUT_FOLDER_BASENAME"
    log_info "OpenAPI response data output subdirectory name: $OPENAPI_OUTPUT_FOLDER_BASENAME"
    log_info "Coverage report output subdirectory name: $COVERAGE_FINAL_TARGET_FOLDER_BASENAME"

    show_chaos_options

    local chaos_command_args
    echo -n "Please enter the parameters for the ChaosBlade command (e.g., create cpu load --cpu-percent 80 --timeout 300): "
    read chaos_command_args

    if [ -z "$chaos_command_args" ]; then
        log_error "ChaosBlade command parameters cannot be empty"
        exit 1
    fi
    local full_chaos_command="blade $chaos_command_args"
    log_info "Full ChaosBlade command: $full_chaos_command"

    local need_sudo=false
    if [[ "$chaos_command_args" == *"network"* || "$chaos_command_args" == *"disk"* || "$chaos_command_args" == *"process"* ]]; then
        need_sudo=true
        log_warn "Detected network, disk, or process related commands, will use sudo to execute ChaosBlade"
    fi

    log_step "Step 3: Execute ChaosBlade experiment"
    local chaosblade_dir="$CHAOSBLADE_DIR"

    if [ "$need_sudo" = true ]; then
        if [ ! -d "$chaosblade_dir" ]; then
            log_error "ChaosBlade directory '$chaosblade_dir' not found, cannot execute sudo command."
            exit 1
        fi
        cd "$chaosblade_dir"
        check_command_success "Switch to ChaosBlade directory ($chaosblade_dir)"

        log_info "Executing command: sudo ./$full_chaos_command"
        sudo ./$full_chaos_command
        check_command_success "Execute ChaosBlade experiment (sudo)"
    else
        if ! command -v blade &> /dev/null; then
            log_warn "'blade' command not found in PATH. Trying to execute from '$chaosblade_dir'."
            if [ -f "$chaosblade_dir/blade" ]; then
                full_chaos_command="$chaosblade_dir/blade $chaos_command_args"
                log_info "Executing command: $full_chaos_command"
                $full_chaos_command
                check_command_success "Execute ChaosBlade experiment (direct path)"
            else
                log_error "'blade' command not found, and can't find in '$chaosblade_dir/blade' ."
                log_info "Ensure ChaosBlade is correctly installed and configured in PATH, or modify the chaosblade_dir variable in the script."
                exit 1
            fi
        else
            log_info "Executing command: $full_chaos_command"
            $full_chaos_command
            check_command_success "Execute ChaosBlade experiment (PATH)"
        fi
    fi

    log_info "Waiting for ChaosBlade experiment to take effect (default 10 seconds)..."
    sleep 10

    log_step "Step 4: Run EvoMaster black box test"
    local evomaster_base_dir="$EVOMASTER_BASE_DIR"
    local evomaster_output_path="${evomaster_base_dir}/${EVOMASTER_OUTPUT_FOLDER_NAME}"
    local social_network_api_yaml="$API_SPEC_PATH"

    if [ ! -f "$social_network_api_yaml" ]; then
        log_error "EvoMaster dependent API file '$social_network_api_yaml' not found."
        exit 1
    fi

    mkdir -p "$evomaster_output_path"
    check_command_success "Create or confirm EvoMaster output directory: $evomaster_output_path"

    log_info "Starting OpenAPI response collection in background during EvoMaster test..."
    local openapi_script_dir="${DATASET_SCRIPT_DIR}/api_responses"
    local openapi_storage_dir="${DATASET_STORAGE_DIR}/api_responses"
    mkdir -p "$openapi_script_dir"
    mkdir -p "$openapi_storage_dir"
    
    (
        cd "$openapi_script_dir" || exit 1
        export CUSTOM_DIR="${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}"
        export OPENAPI_MONITOR_DURATION=70
        export ENABLE_NETWORK_CAPTURE=true  # Capture on-wire traffic for richer payloads
        ./collect_openapi_response.sh > /dev/null 2>&1
    ) &
    local openapi_monitor_pid=$!
    log_info "OpenAPI monitor started with PID: $openapi_monitor_pid"
    
    sleep 3
    
    log_info "Starting EvoMaster test, output to: $evomaster_output_path"
    docker run --network=host \
        -v "$evomaster_base_dir:/BlackBox_tests" \
        -v "$social_network_api_yaml:/social-network-api.yaml" \
        webfuzzing/evomaster \
        --blackBox true \
        --bbSwaggerUrl file:///social-network-api.yaml \
        --outputFormat PYTHON_UNITTEST \
        --outputFolder "/BlackBox_tests/$EVOMASTER_OUTPUT_FOLDER_NAME" \
        --maxTime 60s \
        --ratePerMinute 60

    check_command_success "EvoMaster test"
    
    log_info "Waiting for OpenAPI response collection to complete..."
    wait $openapi_monitor_pid
    log_info "OpenAPI response collection completed"

    local openapi_source_path="${openapi_script_dir}/${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}"
    if [ -d "$openapi_source_path" ]; then
        mkdir -p "$openapi_storage_dir"
        mv "$openapi_source_path" "$openapi_storage_dir/" && \
            log_info "Moved OpenAPI data to ${openapi_storage_dir}/${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}" || \
            log_warn "Failed to move OpenAPI data from $openapi_source_path to $openapi_storage_dir"
    else
        log_warn "Expected OpenAPI data directory not found at $openapi_source_path"
    fi

    export SKIP_OPENAPI_COLLECTION=true
    collect_multimodal_data "$experiment_base_name" "$GLOBAL_TIMESTAMP"
    unset SKIP_OPENAPI_COLLECTION

    log_step "=== Data collection completed ==="
    log_info "Experiment base name: $experiment_base_name"
    log_info "Global timestamp: $GLOBAL_TIMESTAMP"
    log_info "Chaos experiment command: $full_chaos_command"
    log_info "Data collection location:"
    log_info "  - EvoMaster output: $evomaster_output_path"
    log_info "  - Log data: ${DATASET_STORAGE_DIR}/log_data/${experiment_base_name}_logs_${GLOBAL_TIMESTAMP}"
    log_info "  - Metric data: ${DATASET_STORAGE_DIR}/metric_data/${experiment_base_name}_metrics_${GLOBAL_TIMESTAMP}"
    log_info "  - Trace data: ${DATASET_STORAGE_DIR}/trace_data/${experiment_base_name}_traces_${GLOBAL_TIMESTAMP}"
    log_info "  - API response data: ${DATASET_STORAGE_DIR}/api_responses/${experiment_base_name}_openapi_${GLOBAL_TIMESTAMP}"
    log_info "  - Coverage report: ${DATASET_STORAGE_DIR}/coverage_data/${experiment_base_name}_coverage_${GLOBAL_TIMESTAMP}"

    log_info "Script execution successful!"
}

# Generic multimodal collection routine
collect_multimodal_data() {
    local experiment_base_name="$1"
    local global_timestamp="$2"
    
    log_step "Step: Collect multi-modal data"
    
    # Derive modality folder basenames
    local LOG_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_logs_${global_timestamp}"
    local METRIC_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_metrics_${global_timestamp}"
    local TRACE_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_traces_${global_timestamp}"
    local COVERAGE_FINAL_TARGET_FOLDER_BASENAME="${experiment_base_name}_coverage_${global_timestamp}"
    local OPENAPI_OUTPUT_FOLDER_BASENAME="${experiment_base_name}_openapi_${global_timestamp}"

    # Log data
    log_info "Collecting log data..."
    local log_script_dir="${DATASET_SCRIPT_DIR}/log_data"
    local log_storage_dir="${DATASET_STORAGE_DIR}/log_data"
    mkdir -p "$log_script_dir"
    mkdir -p "$log_storage_dir"
    cd "$log_script_dir"
    check_command_success "Switch to log_data directory ($log_script_dir)"
    export CUSTOM_DIR="$LOG_OUTPUT_FOLDER_BASENAME"
    log_info "Log data will be saved to: $log_storage_dir/$LOG_OUTPUT_FOLDER_BASENAME"
    ./collect_log.sh
    check_command_success "Collect log data"
    unset CUSTOM_DIR

    local log_source_path="${log_script_dir}/${LOG_OUTPUT_FOLDER_BASENAME}"
    if [ -d "$log_source_path" ]; then
        mv "$log_source_path" "$log_storage_dir/" && \
            log_info "Moved log data to $log_storage_dir/$LOG_OUTPUT_FOLDER_BASENAME" || \
            log_warn "Failed to move log data from $log_source_path to $log_storage_dir"
    else
        log_warn "Expected log data directory not found at $log_source_path"
    fi

    # Metric data
    log_info "Collecting metric data..."
    local metric_script_dir="${DATASET_SCRIPT_DIR}/metric_data"
    local metric_storage_dir="${DATASET_STORAGE_DIR}/metric_data"
    mkdir -p "$metric_script_dir"
    mkdir -p "$metric_storage_dir"
    cd "$metric_script_dir"
    check_command_success "Switch to metric_data directory ($metric_script_dir)"
    export CUSTOM_DIR="$METRIC_OUTPUT_FOLDER_BASENAME"
    log_info "Metric data will be saved to: $metric_storage_dir/$METRIC_OUTPUT_FOLDER_BASENAME"
    ./collect_metric.sh
    check_command_success "Collect metric data"
    unset CUSTOM_DIR

    local metric_source_path="${metric_script_dir}/${METRIC_OUTPUT_FOLDER_BASENAME}"
    if [ -d "$metric_source_path" ]; then
        mv "$metric_source_path" "$metric_storage_dir/" && \
            log_info "Moved metric data to $metric_storage_dir/$METRIC_OUTPUT_FOLDER_BASENAME" || \
            log_warn "Failed to move metric data from $metric_source_path to $metric_storage_dir"
    else
        log_warn "Expected metric data directory not found at $metric_source_path"
    fi

    # Trace data
    log_info "Collecting trace data..."
    local trace_script_dir="${DATASET_SCRIPT_DIR}/trace_data"
    local trace_storage_dir="${DATASET_STORAGE_DIR}/trace_data"
    mkdir -p "$trace_script_dir"
    mkdir -p "$trace_storage_dir"
    cd "$trace_script_dir"
    check_command_success "Switch to trace_data directory ($trace_script_dir)"
    export CUSTOM_DIR="$TRACE_OUTPUT_FOLDER_BASENAME"
    log_info "Trace data will be saved to: $trace_storage_dir/$TRACE_OUTPUT_FOLDER_BASENAME"
    ./collect_trace.sh
    check_command_success "Collect trace data"
    unset CUSTOM_DIR

    local trace_source_path="${trace_script_dir}/${TRACE_OUTPUT_FOLDER_BASENAME}"
    if [ -d "$trace_source_path" ]; then
        mv "$trace_source_path" "$trace_storage_dir/" && \
            log_info "Moved trace data to $trace_storage_dir/$TRACE_OUTPUT_FOLDER_BASENAME" || \
            log_warn "Failed to move trace data from $trace_source_path to $trace_storage_dir"
    else
        log_warn "Expected trace data directory not found at $trace_source_path"
    fi

    # Collect OpenAPI responses (skipped when full workflow already captured them)
    if [ "$SKIP_OPENAPI_COLLECTION" != "true" ]; then
        log_info "Collecting OpenAPI response data..."
        local openapi_script_dir="${DATASET_SCRIPT_DIR}/api_responses"
        local openapi_storage_dir="${DATASET_STORAGE_DIR}/api_responses"
        mkdir -p "$openapi_script_dir"
        mkdir -p "$openapi_storage_dir"
        cd "$openapi_script_dir"
        check_command_success "Switch to api_responses directory ($openapi_script_dir)"
        export CUSTOM_DIR="$OPENAPI_OUTPUT_FOLDER_BASENAME"
        export OPENAPI_MONITOR_DURATION=60  # Monitor duration in seconds
        log_info "OpenAPI response data will be saved to: $openapi_storage_dir/$OPENAPI_OUTPUT_FOLDER_BASENAME"
        ./collect_openapi_response.sh
        check_command_success "Collect OpenAPI response data"
        unset CUSTOM_DIR
        unset OPENAPI_MONITOR_DURATION

        local openapi_source_path="${openapi_script_dir}/${OPENAPI_OUTPUT_FOLDER_BASENAME}"
        if [ -d "$openapi_source_path" ]; then
            mv "$openapi_source_path" "$openapi_storage_dir/" && \
                log_info "Moved OpenAPI data to $openapi_storage_dir/$OPENAPI_OUTPUT_FOLDER_BASENAME" || \
                log_warn "Failed to move OpenAPI data from $openapi_source_path to $openapi_storage_dir"
        else
            log_warn "Expected OpenAPI data directory not found at $openapi_source_path"
        fi
    else
        log_info "Skipping OpenAPI response collection (already collected during test execution)"
    fi

    # Coverage reports
    log_step "Collect code coverage report (experiment name: $experiment_base_name, timestamp: $global_timestamp)"
    local social_network_dir_compose_root="$SOCIAL_NETWORK_DIR"
    
    if [ ! -d "$social_network_dir_compose_root" ]; then
        log_error "SocialNetwork docker-compose root directory '$social_network_dir_compose_root' not found, cannot trigger coverage collection."
        return 1
    fi

    log_info "Triggering coverage data writing (kill -USR1)..."
    for service in $(docker ps --filter "name=socialnetwork_.*service" --format "{{.Names}}"); do
        log_info "Sending SIGUSR1 to $service"
        docker exec "$service" kill -USR1 1
    done

    log_info "Waiting for coverage data writing to complete (5 seconds)..."
    sleep 5

    log_info "Executing coverage collection scripts in each service container..."
    for svc in compose-post-service home-timeline-service media-service post-storage-service social-graph-service text-service unique-id-service url-shorten-service user-mention-service user-service user-timeline-service; do
        local cname="socialnetwork_${svc}_1"
        if docker ps --filter "name=${cname}" --format "{{.Names}}" | grep -q "$cname"; then
            log_info "Executing coverage collection script for service '$svc' (container '$cname')..."
            log_info "  Forwarding EXPERIMENT_BASE_NAME='$experiment_base_name', SERVICE_NAME='$svc', TIMESTAMP='$global_timestamp'"
            
            docker exec \
                -e EXPERIMENT_BASE_NAME="$experiment_base_name" \
                -e SERVICE_NAME="$svc" \
                -e TIMESTAMP="$global_timestamp" \
                "$cname" /usr/local/bin/collect_coverage.sh

            if [ $? -ne 0 ]; then
                log_warn "Execution of coverage collection script for service '$svc' container may have failed."
            else
                log_info "Execution of coverage collection script for service '$svc' container has been triggered."
            fi
        else
            log_warn "Container '$cname' is not running, skipping coverage collection for '$svc'."
        fi
    done

    log_info "Waiting for coverage files to be visible on host (10 seconds)..."
    sleep 10

    # Move host-mounted coverage reports into the dataset folder
    local host_mounted_coverage_root="$social_network_dir_compose_root/coverage-reports"
    local source_coverage_dir_on_host="${host_mounted_coverage_root}/${experiment_base_name}_${global_timestamp}"
    
    local final_coverage_dataset_dir="${DATASET_STORAGE_DIR}/coverage_data"
    local final_target_coverage_path="${final_coverage_dataset_dir}/${COVERAGE_FINAL_TARGET_FOLDER_BASENAME}"

    if [ -d "$source_coverage_dir_on_host" ]; then
        log_info "Found generated coverage report source directory: $source_coverage_dir_on_host"
        mkdir -p "$final_coverage_dataset_dir"
        check_command_success "Create/confirm final coverage data set directory: $final_coverage_dataset_dir"

        log_info "Moving coverage report from '$source_coverage_dir_on_host' to '$final_target_coverage_path'..."
        sudo mv "$source_coverage_dir_on_host" "$final_target_coverage_path"
        if [ $? -eq 0 ]; then
            log_info "Coverage report has been successfully moved to: $final_target_coverage_path"
        else
            log_error "Failed to move coverage report. Source: '$source_coverage_dir_on_host', Target: '$final_target_coverage_path'"
            log_info "Please manually check the source directory content."
        fi
    else
        log_warn "Coverage report source directory not found on host: '$source_coverage_dir_on_host'"
        log_warn "Please check if the container's collect_coverage.sh script correctly uses EXPERIMENT_BASE_NAME ('$experiment_base_name') and TIMESTAMP ('$global_timestamp') to create the directory."
        log_warn "The expected container path should be /coverage-reports/${experiment_base_name}_${global_timestamp}/<SERVICE_NAME>"
    fi
}

# Script entrypoint
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Validate critical directories
    if [ ! -d "$SOCIAL_NETWORK_DIR" ]; then
        log_error "Critical directory '$SOCIAL_NETWORK_DIR' not found. Please ensure the path is correct or has been cloned/created."
        exit 1
    fi
    if [ ! -d "$DATASET_SCRIPT_DIR" ]; then
        log_error "Data collection scripts directory '${DATASET_SCRIPT_DIR}' not found. Please ensure the original Dataset directory is available."
        exit 1
    fi
    if [ ! -d "$DATASET_STORAGE_DIR" ]; then
        log_warn "Data storage base directory '${DATASET_STORAGE_DIR}' not found. The script will attempt to create its subdirectories."
        mkdir -p "${DATASET_STORAGE_DIR}/log_data" "${DATASET_STORAGE_DIR}/metric_data" "${DATASET_STORAGE_DIR}/trace_data" "${DATASET_STORAGE_DIR}/api_responses" "${DATASET_STORAGE_DIR}/coverage_data"
    fi
    if [ ! -d "$CHAOSBLADE_DIR" ] && ! command -v blade &> /dev/null; then
        log_warn "ChaosBlade tool may not be properly configured. If experiments are required, please check '$CHAOSBLADE_DIR' or ensure 'blade' is in PATH."
    fi
    if [ ! -f "$API_SPEC_PATH" ]; then
        log_warn "EvoMaster dependent API file '$API_SPEC_PATH' not found. Running EvoMaster will fail."
    fi


    # Execute main routine
    main "$@"
fi