#!/bin/bash

# =============================================================================
# Automated Multimodal Data Collection Script
# Purpose: Automate system reset, anomaly injection, testing, and data collection
# =============================================================================

# Enable strict error handling
set -eE  # Exit on error and inherit ERR trap in functions
set -o pipefail  # Pipe failure causes script to fail

# Error trap function
error_trap() {
    local exit_code=$?
    local line_number=$1
    
    # Temporarily disable error handling to allow cleanup
    set +e
    
    log_error "Script failed at line $line_number with exit code $exit_code"
    log_error "Cleaning up before exit..."
    
    # Attempt to cleanup any active ChaosBlade experiments
    if [ -n "$CHAOSBLADE_UID" ]; then
        cd "$CHAOSBLADE_DIR" 2>/dev/null
        if [ $? -eq 0 ]; then
            if [ "$CHAOSBLADE_NEEDS_SUDO" = true ]; then
                sudo ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null
            else
                ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null
            fi
            log_info "Cleaned up ChaosBlade experiment: $CHAOSBLADE_UID"
        fi
    fi
    
    exit $exit_code
}

trap 'error_trap $LINENO' ERR

# Color definitions for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_section() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}\n"
}

# Error handling
check_command_success() {
    if [ $? -ne 0 ]; then
        log_error "$1 failed"
        return 1
    fi
    return 0
}

# Configuration variables (override via environment variables)
PROJECT_ROOT="${PROJECT_ROOT:-{PROJECT_ROOT}}"
DATA_ARCHIVE_ROOT="${DATA_ARCHIVE_ROOT:-{DATA_OUTPUT_PATH}}"
SOCIAL_NETWORK_DIR="${SOCIAL_NETWORK_DIR:-${PROJECT_ROOT}/DeathStarBench/socialNetwork}"
CHAOSBLADE_DIR="${CHAOSBLADE_DIR:-${PROJECT_ROOT}/chaosblade/chaosblade-1.7.4}"
VENV_PATH="${VENV_PATH:-${PROJECT_ROOT}/social/bin/activate}"
EVOMASTER_TEST_PATH="${EVOMASTER_TEST_PATH:-${PROJECT_ROOT}/BlackBox_tests/Final_version_2m/EvoMaster_successes_Test.py}"
COLLECT_DATA_SCRIPT="${COLLECT_DATA_SCRIPT:-${PROJECT_ROOT}/collect_all_data.sh}"

# EvoMaster test execution configuration
EVOMASTER_RUN_COUNT=200  # Can be increased to run the EvoMaster suite multiple times per experiment

# Workload (wrk2) execution configuration
WORKLOAD_RUN_COUNT=100
WORKLOAD_WRK_BINARY="${WORKLOAD_WRK_BINARY:-${PROJECT_ROOT}/DeathStarBench/wrk2/wrk}"
WORKLOAD_SCRIPT_PATH="${WORKLOAD_SCRIPT_PATH:-${SOCIAL_NETWORK_DIR}/wrk2/scripts/social-network/mixed-workload.lua}"
WORKLOAD_URL="http://localhost:8080/wrk2-api/post/compose"
WORKLOAD_THREADS=4
WORKLOAD_CONNECTIONS=30
WORKLOAD_DURATION=30
WORKLOAD_RATE=5
WORKLOAD_DISTRIBUTION="constant"

# Traffic trigger mode (evomaster | workload)
TRIGGER_MODE="evomaster"

# Wait time configurations
DOCKER_STARTUP_WAIT=60
ANOMALY_EFFECT_WAIT=10
POST_TEST_WAIT=5

# =============================================================================
# Helper functions: trigger mode management
# =============================================================================
describe_trigger_mode() {
    case "$TRIGGER_MODE" in
        workload)
            echo "wrk2 workload (mixed-workload.lua)"
            ;;
        *)
            echo "EvoMaster test suite"
            ;;
    esac
}

get_trigger_run_count() {
    case "$TRIGGER_MODE" in
        workload)
            echo "$WORKLOAD_RUN_COUNT"
            ;;
        *)
            echo "$EVOMASTER_RUN_COUNT"
            ;;
    esac
}

ensure_path_var() {
    local name="$1"
    local value="${!name:-}"
    if [[ -z "$value" || "$value" =~ ^\{[A-Z_]+\}$ ]]; then
        log_error "Environment variable $name is not configured. Please export a valid absolute path."
        exit 1
    fi
}

# Validate required base paths before running workflows
validate_required_paths() {
    ensure_path_var PROJECT_ROOT
    ensure_path_var DATA_ARCHIVE_ROOT
    ensure_path_var SOCIAL_NETWORK_DIR
    ensure_path_var CHAOSBLADE_DIR
    ensure_path_var VENV_PATH
    ensure_path_var EVOMASTER_TEST_PATH
    ensure_path_var COLLECT_DATA_SCRIPT
    ensure_path_var WORKLOAD_WRK_BINARY
    ensure_path_var WORKLOAD_SCRIPT_PATH
}

set_trigger_mode() {
    while true; do
        echo ""
        echo "Select a traffic trigger (current: $(describe_trigger_mode))"
        echo " 1. EvoMaster regression suite"
        echo " 2. wrk2 workload script"
        echo -n "Enter choice [1/2, default 1]: "
        read -r mode_choice
        mode_choice=${mode_choice:-1}

        case "$mode_choice" in
            1)
                TRIGGER_MODE="evomaster"
                log_info "EvoMaster selected (planned runs: $EVOMASTER_RUN_COUNT)"
                return 0
                ;;
            2)
                if [ ! -x "$WORKLOAD_WRK_BINARY" ]; then
                    log_error "wrk2 binary not found or not executable: $WORKLOAD_WRK_BINARY"
                    log_error "Ensure wrk2 follows the DeathStarBench directory layout"
                    continue
                fi
                if [ ! -f "$WORKLOAD_SCRIPT_PATH" ]; then
                    log_error "wrk2 Lua script not found: $WORKLOAD_SCRIPT_PATH"
                    continue
                fi
                TRIGGER_MODE="workload"
                log_info "wrk2 workload selected (planned runs: $WORKLOAD_RUN_COUNT)"
                return 0
                ;;
            *)
                log_warn "Invalid option, please try again."
                ;;
        esac
    done
}

# ChaosBlade experiment tracking
CHAOSBLADE_UID=""
CHAOSBLADE_NEEDS_SUDO=false

# =============================================================================
# Function: Check prerequisites
# =============================================================================
check_prerequisites() {
    log_section "Checking Prerequisites"
    
    local all_ok=true
    
    # Check directories
    if [ ! -d "$SOCIAL_NETWORK_DIR" ]; then
        log_error "SocialNetwork directory not found: $SOCIAL_NETWORK_DIR"
        all_ok=false
    else
        log_info "[OK] SocialNetwork directory found"
    fi
    
    if [ ! -d "$CHAOSBLADE_DIR" ]; then
        log_error "ChaosBlade directory not found: $CHAOSBLADE_DIR"
        all_ok=false
    else
        log_info "[OK] ChaosBlade directory found"
    fi
    
    # Check virtual environment
    if [ ! -f "$VENV_PATH" ]; then
        log_error "Virtual environment not found: $VENV_PATH"
        all_ok=false
    else
        log_info "[OK] Virtual environment found"
    fi
    
    # Check EvoMaster test file
    if [ ! -f "$EVOMASTER_TEST_PATH" ]; then
        log_error "EvoMaster test file not found: $EVOMASTER_TEST_PATH"
        all_ok=false
    else
        log_info "[OK] EvoMaster test file found"
    fi
    
    # Check data collection script
    if [ ! -f "$COLLECT_DATA_SCRIPT" ]; then
        log_error "Data collection script not found: $COLLECT_DATA_SCRIPT"
        all_ok=false
    else
        log_info "[OK] Data collection script found"
    fi
    
    # Check docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker command not found"
        all_ok=false
    else
        log_info "[OK] Docker command available"
    fi
    
    if [ "$all_ok" = false ]; then
        log_error "Prerequisites check failed. Please fix the above issues."
        exit 1
    fi
    
    log_info "All prerequisites satisfied!"
}

# =============================================================================
# Function: Reset system (docker-compose down/up + init social graph)
# =============================================================================
reset_system() {
    log_section "Step 1: Resetting System"
    
    log_step "Stopping existing services..."
    cd "$SOCIAL_NETWORK_DIR" || exit 1
    docker-compose -f docker-compose-gcov.yml down
    check_command_success "Docker compose down" || return 1
    
    log_step "Cleaning up unused Docker volumes to free disk space..."
    # Temporarily disable strict error handling
    set +e
    local volumes_freed=$(docker volume prune -f 2>&1 | grep "Total reclaimed space" || echo "No space reclaimed")
    set -e
    log_info "$volumes_freed"
    
    log_step "Starting services..."
    docker-compose -f docker-compose-gcov.yml up -d
    check_command_success "Docker compose up" || return 1
    
    log_step "Waiting for containers to start (${DOCKER_STARTUP_WAIT} seconds)..."
    sleep "$DOCKER_STARTUP_WAIT"
    
    log_step "Checking container status..."
    local max_retries=10
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if docker ps --filter "name=socialnetwork" --format "{{.Names}}" | grep -q "socialnetwork"; then
            log_info "Containers are running!"
            docker ps --filter "name=socialnetwork" --format "table {{.Names}}\t{{.Status}}"
            break
        fi
        retry=$((retry + 1))
        log_info "Waiting for containers... (attempt $retry/$max_retries)"
        sleep 5
    done
    
    if [ $retry -eq $max_retries ]; then
        log_error "Containers failed to start properly"
        return 1
    fi
    
    log_step "Activating virtual environment and initializing social graph..."
    source "$VENV_PATH"
    check_command_success "Activate virtual environment" || return 1
    
    cd "$SOCIAL_NETWORK_DIR" || exit 1
    python3 scripts/init_social_graph.py --graph=socfb-Reed98
    check_command_success "Initialize social graph" || return 1
    
    log_info "System reset completed successfully!"
    return 0
}

# =============================================================================
# Function: Inject anomaly
# Parameters: $1 = anomaly type, $2 = anomaly name
# =============================================================================
inject_anomaly() {
    local anomaly_type="$1"
    local anomaly_name="$2"
    
    log_section "Step 2: Injecting Anomaly - $anomaly_name"
    
    case "$anomaly_type" in
        "performance_cpu")
            log_step "Injecting CPU contention (100% load)..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(./blade create cpu load --cpu-percent 100 --timeout 300)
            check_command_success "CPU contention injection" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=false
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID"
            ;;
            
        "performance_network")
            log_step "Injecting network packet loss (50% on docker0)..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(sudo ./blade create network loss --interface docker0 --percent 50 --timeout 300)
            check_command_success "Network loss injection" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=true
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID (requires sudo)"
            ;;
            
        "performance_disk")
            log_step "Injecting disk I/O stress..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(./blade create disk burn --read --write --path /var/log --size 1024 --timeout 300)
            check_command_success "Disk I/O stress injection" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=false
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID"
            ;;
            
        "service_usertimeline")
            log_step "Killing UserTimelineService container..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(sudo ./blade create process kill --process UserTimelineService --signal 9)
            check_command_success "UserTimelineService kill" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=true
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID (requires sudo)"
            ;;
            
        "service_media")
            log_step "Killing MediaService container..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(sudo ./blade create process kill --process MediaService --signal 9)
            check_command_success "MediaService kill" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=true
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID (requires sudo)"
            ;;
            
        "service_socialgraph")
            log_step "Killing SocialGraphService container..."
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(sudo ./blade create process kill --process SocialGraphService --signal 9)
            check_command_success "SocialGraphService kill" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=true
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID (requires sudo)"
            ;;
            
        "database_hometimeline")
            log_step "Injecting Redis cache limit on home-timeline-redis..."
            local redis_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' socialnetwork_home-timeline-redis_1)
            log_info "Redis IP: $redis_ip"
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(./blade create redis cache-limit --addr "${redis_ip}:6379" --password "" --percent 50 --timeout 300)
            check_command_success "Redis cache-limit on home-timeline-redis" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=false
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID"
            ;;
            
        "database_usertimeline")
            log_step "Injecting Redis cache limit on user-timeline-redis..."
            local redis_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' socialnetwork_user-timeline-redis_1)
            log_info "Redis IP: $redis_ip"
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(./blade create redis cache-limit --addr "${redis_ip}:6379" --password "" --percent 50 --timeout 300)
            check_command_success "Redis cache-limit on user-timeline-redis" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=false
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID"
            ;;
            
        "database_socialgraph")
            log_step "Injecting Redis cache limit on social-graph-redis..."
            local redis_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' socialnetwork_social-graph-redis_1)
            log_info "Redis IP: $redis_ip"
            cd "$CHAOSBLADE_DIR" || return 1
            local result=$(./blade create redis cache-limit --addr "${redis_ip}:6379" --password "" --percent 50 --timeout 300)
            check_command_success "Redis cache-limit on social-graph-redis" || return 1
            CHAOSBLADE_UID=$(echo "$result" | grep -oP '"result":\s*"\K[^"]+' | head -1)
            CHAOSBLADE_NEEDS_SUDO=false
            if [ -z "$CHAOSBLADE_UID" ]; then
                log_error "Failed to extract ChaosBlade UID from result: $result"
                return 1
            fi
            log_info "ChaosBlade experiment UID: $CHAOSBLADE_UID"
            ;;
            
        "code_userservice")
            log_step "Stopping user-service container (code-level anomaly)..."
            docker stop socialnetwork_user-service_1
            check_command_success "Stop user-service" || return 1
            ;;
            
        "code_textservice")
            log_step "Stopping text-service container (code-level anomaly)..."
            docker stop socialnetwork_text-service_1
            check_command_success "Stop text-service" || return 1
            ;;
            
        "code_mediaservice")
            log_step "Stopping media-service container (code-level anomaly)..."
            docker stop socialnetwork_media-service_1
            check_command_success "Stop media-service" || return 1
            ;;
            
        "normal")
            log_step "No anomaly injection - collecting baseline/normal data..."
            log_info "System is running under normal conditions"
            # No anomaly to inject, just continue
            ;;
            
        *)
            log_error "Unknown anomaly type: $anomaly_type"
            return 1
            ;;
    esac
    
    log_step "Waiting for anomaly to take effect (${ANOMALY_EFFECT_WAIT} seconds)..."
    sleep "$ANOMALY_EFFECT_WAIT"
    
    log_info "Anomaly injection completed!"
    return 0
}

# =============================================================================
# Function: Run EvoMaster test to trigger the system
# =============================================================================
run_evomaster_test() {
    log_section "Step 3: Running EvoMaster Test"
    
    log_step "Activating virtual environment..."
    source "$VENV_PATH"
    
    log_step "Preparing to execute EvoMaster test ${EVOMASTER_RUN_COUNT} time(s)..."
    cd "$(dirname "$EVOMASTER_TEST_PATH")" || return 1

    local run=1
    while [ $run -le "$EVOMASTER_RUN_COUNT" ]; do
        log_step "Executing EvoMaster test (run $run/$EVOMASTER_RUN_COUNT)..."

        set +e
        python3 "$(basename "$EVOMASTER_TEST_PATH")"
        local exit_code=$?
        set -e

        # EvoMaster tests might have some failures which is expected
        if [ $exit_code -eq 0 ]; then
            log_info "EvoMaster test run $run completed successfully!"
        else
            log_warn "EvoMaster test run $run completed with exit code: $exit_code (some test failures are expected under anomalies)"
        fi

        if [ $run -lt "$EVOMASTER_RUN_COUNT" ]; then
            log_step "Waiting for system to stabilize before next run (${POST_TEST_WAIT} seconds)..."
            sleep "$POST_TEST_WAIT"
        fi

        run=$((run + 1))
    done

    log_step "Waiting for system to stabilize (${POST_TEST_WAIT} seconds)..."
    sleep "$POST_TEST_WAIT"
    
    return 0
}

# =============================================================================
# Function: Run workload (wrk2) to trigger the system
# =============================================================================
run_workload_test() {
    log_section "Step 3: Running wrk2 Workload"

    local wrk_bin="$WORKLOAD_WRK_BINARY"
    local workload_script="$WORKLOAD_SCRIPT_PATH"

    if [ ! -x "$wrk_bin" ]; then
        log_error "wrk2 binary is missing or not executable: $wrk_bin"
        return 1
    fi

    if [ ! -f "$workload_script" ]; then
        log_error "wrk2 Lua workload script not found: $workload_script"
        return 1
    fi

    log_step "Preparing to execute wrk2 workload ${WORKLOAD_RUN_COUNT} time(s)..."

    local run=1
    while [ $run -le "$WORKLOAD_RUN_COUNT" ]; do
        log_step "Running wrk2 workload ($run/$WORKLOAD_RUN_COUNT)..."

        set +e
        (
            cd "$SOCIAL_NETWORK_DIR" || exit 1
            "$wrk_bin" -D "$WORKLOAD_DISTRIBUTION" \
                -t "$WORKLOAD_THREADS" \
                -c "$WORKLOAD_CONNECTIONS" \
                -d "$WORKLOAD_DURATION" \
                -L \
                -s "$workload_script" \
                "$WORKLOAD_URL" \
                -R "$WORKLOAD_RATE"
        )
        local exit_code=$?
        set -e

        if [ $exit_code -eq 0 ]; then
            log_info "wrk2 workload run $run completed successfully!"
        else
            log_warn "wrk2 workload run $run exited with code: $exit_code"
            return $exit_code
        fi

        if [ $run -lt "$WORKLOAD_RUN_COUNT" ]; then
            log_step "Waiting for the system to stabilize (${POST_TEST_WAIT} seconds) before the next workload run..."
            sleep "$POST_TEST_WAIT"
        fi

        run=$((run + 1))
    done

    log_step "Waiting for the system to stabilize (${POST_TEST_WAIT} seconds)..."
    sleep "$POST_TEST_WAIT"

    return 0
}

# =============================================================================
# Function: Dispatch trigger according to current mode
# =============================================================================
trigger_system() {
    case "$TRIGGER_MODE" in
        workload)
            run_workload_test
            ;;
        *)
            run_evomaster_test
            ;;
    esac
}

# =============================================================================
# Function: Collect multimodal data
# Parameters: $1 = experiment name
# =============================================================================
collect_data() {
    local experiment_name="$1"
    
    log_section "Step 4: Collecting Multimodal Data"
    
    log_step "Preparing to collect data for experiment: $experiment_name"
    
    local collection_script_dir
    collection_script_dir="$(cd "$(dirname "$COLLECT_DATA_SCRIPT")" && pwd)"
    cd "$collection_script_dir" || return 1
    
    # The collect_all_data.sh script is interactive, so we'll provide the experiment name via input
    log_info "Executing data collection script..."
    log_info "Note: The script will prompt for experiment name and execution mode"
    
    # Temporarily disable strict error handling for data collection
    # because the collect scripts may have non-critical failures
    set +e
    
    # Execute the data collection script
    # Mode 2 = Data collection only (we don't need to restart services again)
    echo -e "2\n${experiment_name}" | "$COLLECT_DATA_SCRIPT"
    local collection_exit_code=$?
    
    # Re-enable strict error handling
    set -e
    
    if [ $collection_exit_code -ne 0 ]; then
        log_error "Data collection script exited with code: $collection_exit_code"
        return 1
    fi
    
    log_info "Data collection completed successfully!"
    return 0
}

# =============================================================================
# Function: Clean up anomaly
# Parameters: $1 = anomaly type
# =============================================================================
cleanup_anomaly() {
    local anomaly_type="$1"
    
    (
        # Run in subshell with all error handling disabled
        set +e
        set +o pipefail
        
        log_step "Cleaning up anomaly: $anomaly_type"
        
        case "$anomaly_type" in
            "performance_cpu"|"performance_network"|"performance_disk"|"database_"*)
                # Destroy ChaosBlade experiment using captured UID
                if [ -n "$CHAOSBLADE_UID" ]; then
                    cd "$CHAOSBLADE_DIR" || return 0
                    log_info "Destroying ChaosBlade experiment UID: $CHAOSBLADE_UID"
                    if [ "$CHAOSBLADE_NEEDS_SUDO" = true ]; then
                        sudo ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null || true
                    else
                        ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null || true
                    fi
                    sleep 3
                    log_info "ChaosBlade experiment destroyed"
                else
                    log_warn "No ChaosBlade UID recorded, skipping cleanup"
                fi
                ;;
                
            "service_"*)
                # Destroy ChaosBlade process kill experiment using captured UID
                if [ -n "$CHAOSBLADE_UID" ]; then
                    cd "$CHAOSBLADE_DIR" || return 0
                    log_info "Destroying ChaosBlade experiment UID: $CHAOSBLADE_UID"
                    if [ "$CHAOSBLADE_NEEDS_SUDO" = true ]; then
                        sudo ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null || true
                    else
                        ./blade destroy "$CHAOSBLADE_UID" 2>/dev/null || true
                    fi
                fi
                # Docker will auto-restart killed containers
                log_info "Waiting for Docker to auto-restart killed services..."
                sleep 15
                ;;
                
            "code_"*)
                # Need to manually restart stopped containers
                log_info "Restarting stopped containers..."
                docker start socialnetwork_user-service_1 2>/dev/null || true
                docker start socialnetwork_text-service_1 2>/dev/null || true
                docker start socialnetwork_media-service_1 2>/dev/null || true
                sleep 5
                log_info "Containers restarted"
                ;;
                
            "normal")
                # No cleanup needed for normal data collection
                log_info "No anomaly to clean up (normal data collection)"
                ;;
        esac
        
        return 0
    )
    
    # Reset UID outside subshell
    CHAOSBLADE_UID=""
    
    return 0
}

# =============================================================================
# Function: Clean up all previous anomalies before starting new experiment
# =============================================================================
cleanup_all_previous_anomalies() {
    (
        # Run in subshell with all error handling disabled
        set +e
        set +o pipefail
        
        log_step "Cleaning up all previous anomalies before starting new experiment..."
        
        # Destroy all ChaosBlade experiments by UID
        cd "$CHAOSBLADE_DIR" || return 0
        
        # Get all active ChaosBlade experiments (Status: "Success")
        local active_uids=$(./blade status --type create 2>/dev/null | grep -B 5 '"Status": "Success"' | grep '"Uid"' | grep -oP '"Uid":\s*"\K[^"]+' || true)
        
        if [ -n "$active_uids" ]; then
            log_warn "Found active ChaosBlade experiments, destroying them..."
            echo "$active_uids" | while IFS= read -r uid; do
                if [ -n "$uid" ]; then
                    log_info "Destroying ChaosBlade experiment: $uid"
                    # Try without sudo first
                    ./blade destroy "$uid" 2>/dev/null || {
                        # If that fails, try with sudo
                        sudo ./blade destroy "$uid" 2>/dev/null || true
                    }
                fi
            done
            sleep 3
            log_info "Previous ChaosBlade experiments destroyed"
        else
            log_info "No active ChaosBlade experiments found"
        fi
        
        # Restart any stopped containers
        log_info "Ensuring all containers are running..."
        docker start socialnetwork_user-service_1 2>/dev/null || true
        docker start socialnetwork_text-service_1 2>/dev/null || true
        docker start socialnetwork_media-service_1 2>/dev/null || true
        
        sleep 3
        log_info "Previous anomalies cleanup completed"
        
        return 0
    )
    
    # Reset ChaosBlade tracking variables (outside subshell)
    CHAOSBLADE_UID=""
    CHAOSBLADE_NEEDS_SUDO=false
    
    return 0
}

# =============================================================================
# Function: Run single experiment
# Parameters: $1 = anomaly type, $2 = anomaly display name
# =============================================================================
run_single_experiment() {
    local anomaly_type="$1"
    local anomaly_display_name="$2"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local experiment_name="${anomaly_display_name}_${timestamp}"
    
    log_section "Starting Experiment: $anomaly_display_name"
    log_info "Experiment ID: $experiment_name"
    log_info "Timestamp: $timestamp"
    
    # Step 0: Clean up any previous anomalies
    cleanup_all_previous_anomalies
    
    # Step 1: Reset system
    if ! reset_system; then
        log_error "System reset failed for experiment: $experiment_name"
        cleanup_anomaly "$anomaly_type"
        return 1
    fi
    
    # Step 2: Inject anomaly
    if ! inject_anomaly "$anomaly_type" "$anomaly_display_name"; then
        log_error "Anomaly injection failed for experiment: $experiment_name"
        log_error "Stopping experiment due to injection failure"
        cleanup_anomaly "$anomaly_type"
        return 1
    fi
    
    # Step 3: Trigger system via selected mode
    log_info "Trigger strategy: $(describe_trigger_mode); planned iterations: $(get_trigger_run_count)"
    if ! trigger_system; then
        log_error "Traffic trigger execution issue for experiment: $experiment_name"
        log_error "Stopping experiment due to trigger failure"
        cleanup_anomaly "$anomaly_type"
        return 1
    fi
    
    # Step 4: Collect data  
    if ! collect_data "$experiment_name"; then
        log_error "Data collection failed for experiment: $experiment_name"
        log_error "Stopping experiment due to data collection failure"
        cleanup_anomaly "$anomaly_type"
        return 1
    fi
    
    # Step 5: Cleanup
    cleanup_anomaly "$anomaly_type"
    
    log_section "Experiment Completed: $anomaly_display_name"
    log_info "Experiment ID: $experiment_name"
    log_info "Data saved under ${DATA_ARCHIVE_ROOT}/* directories with prefix: $experiment_name"
    
    return 0
}

# =============================================================================
# Function: Display menu and get user selection
# =============================================================================
show_menu() {
    log_section "Automated Multimodal Data Collection Script"
    
    echo "Current trigger strategy: $(describe_trigger_mode) (planned runs: $(get_trigger_run_count))"
    echo ""
    echo "Available anomalies to inject:"
    echo ""
    echo "Performance Level (3 anomalies):"
    echo "  1. CPU Contention (100% load)"
    echo "  2. Network Packet Loss (50% on docker0)"
    echo "  3. Disk I/O Stress"
    echo ""
    echo "Service Level (3 anomalies):"
    echo "  4. Kill UserTimelineService"
    echo "  5. Kill MediaService"
    echo "  6. Kill SocialGraphService"
    echo ""
    echo "Database Level (3 anomalies):"
    echo "  7. Redis Cache Limit - home-timeline-redis"
    echo "  8. Redis Cache Limit - user-timeline-redis"
    echo "  9. Redis Cache Limit - social-graph-redis"
    echo ""
    echo "Code Level (3 anomalies):"
    echo " 10. Stop user-service container"
    echo " 11. Stop text-service container"
    echo " 12. Stop media-service container"
    echo ""
    echo "Baseline Collection:"
    echo " 18. Collect Normal/Baseline data (no anomaly injection)"
    echo ""
    echo "Batch Operations:"
    echo " 13. Run ALL anomalies sequentially (12 experiments)"
    echo " 14. Run all Performance Level anomalies"
    echo " 15. Run all Service Level anomalies"
    echo " 16. Run all Database Level anomalies"
    echo " 17. Run all Code Level anomalies"
    echo " 19. Run ALL + Normal (13 experiments total)"
    echo ""
    echo "Other actions:"
    echo " 20. Switch traffic trigger mode"
    echo ""
    echo "  0. Exit"
    echo ""
}

# =============================================================================
# Main script execution
# =============================================================================
main() {
    log_section "Automated Multimodal Data Collection Script Starting"
    
    validate_required_paths

    # Check prerequisites first
    check_prerequisites
    set_trigger_mode
    
    # Define all anomaly configurations
    declare -A ANOMALIES
    ANOMALIES[1]="performance_cpu:Perf_CPU_Contention"
    ANOMALIES[2]="performance_network:Perf_Network_Loss"
    ANOMALIES[3]="performance_disk:Perf_Disk_IO_Stress"
    ANOMALIES[4]="service_usertimeline:Svc_Kill_UserTimeline"
    ANOMALIES[5]="service_media:Svc_Kill_Media"
    ANOMALIES[6]="service_socialgraph:Svc_Kill_SocialGraph"
    ANOMALIES[7]="database_hometimeline:DB_Redis_CacheLimit_HomeTimeline"
    ANOMALIES[8]="database_usertimeline:DB_Redis_CacheLimit_UserTimeline"
    ANOMALIES[9]="database_socialgraph:DB_Redis_CacheLimit_SocialGraph"
    ANOMALIES[10]="code_userservice:Code_Stop_UserService"
    ANOMALIES[11]="code_textservice:Code_Stop_TextService"
    ANOMALIES[12]="code_mediaservice:Code_Stop_MediaService"
    ANOMALIES[18]="normal:Normal_Baseline"
    
    while true; do
        show_menu
        
        echo -n "Please select an option [0-19]: "
        read choice
        
        case $choice in
            0)
                log_info "Exiting script. Goodbye!"
                exit 0
                ;;
            1|2|3|4|5|6|7|8|9|10|11|12|18)
                IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$choice]}"
                run_single_experiment "$anomaly_type" "$anomaly_name"
                ;;
            13)
                log_info "Running ALL 12 anomaly experiments sequentially..."
                for i in {1..12}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    
                    if [ $i -lt 12 ]; then
                        log_info "Waiting 30 seconds before next experiment..."
                        sleep 30
                    fi
                done
                log_section "All 12 experiments completed!"
                ;;
            14)
                log_info "Running all Performance Level anomalies..."
                for i in {1..3}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    if [ $i -lt 3 ]; then sleep 30; fi
                done
                ;;
            15)
                log_info "Running all Service Level anomalies..."
                for i in {4..6}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    if [ $i -lt 6 ]; then sleep 30; fi
                done
                ;;
            16)
                log_info "Running all Database Level anomalies..."
                for i in {7..9}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    if [ $i -lt 9 ]; then sleep 30; fi
                done
                ;;
            17)
                log_info "Running all Code Level anomalies..."
                for i in {10..12}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    if [ $i -lt 12 ]; then sleep 30; fi
                done
                ;;
            19)
                log_info "Running ALL 12 anomalies + Normal baseline (13 experiments total)..."
                # First run normal baseline
                log_info "Starting with normal baseline data collection..."
                IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[18]}"
                run_single_experiment "$anomaly_type" "$anomaly_name"
                log_info "Waiting 30 seconds before next experiment..."
                sleep 30
                
                # Then run all 12 anomalies
                for i in {1..12}; do
                    IFS=':' read -r anomaly_type anomaly_name <<< "${ANOMALIES[$i]}"
                    run_single_experiment "$anomaly_type" "$anomaly_name"
                    
                    if [ $i -lt 12 ]; then
                        log_info "Waiting 30 seconds before next experiment..."
                        sleep 30
                    fi
                done
                log_section "All 13 experiments (Normal + 12 Anomalies) completed!"
                ;;
            20)
                set_trigger_mode
                ;;
            *)
                log_error "Invalid option. Please try again."
                sleep 2
                ;;
        esac
        
        echo ""
        echo "Press Enter to continue..."
        read
    done
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

