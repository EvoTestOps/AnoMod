#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

TIME_RANGE="${1:-}"
TIMESTAMP="${TIMESTAMP:-$(date +"%Y-%m-%d_%H-%M-%S")}"

if [ -n "${CUSTOM_DIR:-}" ]; then
  LOG_DIR_BASENAME="$CUSTOM_DIR"
else
  LOG_DIR_BASENAME="service_logs_${TIMESTAMP}"
fi

LOG_DIR="./$LOG_DIR_BASENAME"
mkdir -p "$LOG_DIR"
log_info "Logs will be stored in $(pwd)/$LOG_DIR_BASENAME"

SERVICES=(
  "compose-post-service"
  "post-storage-service"
  "user-service"
  "user-mention-service"
  "unique-id-service"
  "media-service"
  "social-graph-service"
  "user-timeline-service"
  "url-shorten-service"
  "home-timeline-service"
  "text-service"
  "nginx-thrift"
)

declare -A DISPLAY_NAMES=(
  ["compose-post-service"]="ComposePostService"
  ["post-storage-service"]="PostStorageService"
  ["user-service"]="UserService"
  ["user-mention-service"]="UserMentionService"
  ["unique-id-service"]="UniqueIdService"
  ["media-service"]="MediaService"
  ["social-graph-service"]="SocialGraphService"
  ["user-timeline-service"]="UserTimelineService"
  ["url-shorten-service"]="UrlShortenService"
  ["home-timeline-service"]="HomeTimelineService"
  ["text-service"]="TextService"
  ["nginx-thrift"]="NginxThrift"
)

if [ -z "$TIME_RANGE" ]; then
  log_info "Collecting full log history from ${#SERVICES[@]} SocialNetwork services."
else
  log_info "Collecting logs from the last $TIME_RANGE for ${#SERVICES[@]} SocialNetwork services."
fi

log_info "Enumerating running containers..."
CONTAINER_INFO=$(mktemp)
trap 'rm -f "$CONTAINER_INFO"' EXIT
docker ps --format "{{.ID}} {{.Names}}" > "$CONTAINER_INFO"

for SERVICE in "${SERVICES[@]}"; do
  CONTAINER_ID=$(grep -E "socialnetwork_${SERVICE}_[0-9]+" "$CONTAINER_INFO" | awk '{print $1}')

  if [ -z "$CONTAINER_ID" ]; then
    log_warn "Container for $SERVICE not found; skipping."
    continue
  fi

  DISPLAY_NAME=${DISPLAY_NAMES[$SERVICE]}
  LOG_FILE="$LOG_DIR/${DISPLAY_NAME}_${TIMESTAMP}.log"

  log_info "Collecting $DISPLAY_NAME logs from container $CONTAINER_ID..."
  if [ -z "$TIME_RANGE" ]; then
    docker logs "$CONTAINER_ID" > "$LOG_FILE" 2>&1
  else
    docker logs --since "$TIME_RANGE" "$CONTAINER_ID" > "$LOG_FILE" 2>&1
  fi
  sync

  if [ ! -s "$LOG_FILE" ]; then
    log_warn "  - Log file is empty. Retrying capture via tee..."
    if [ -z "$TIME_RANGE" ]; then
      docker logs "$CONTAINER_ID" | tee "$LOG_FILE" > /dev/null
    else
      docker logs --since "$TIME_RANGE" "$CONTAINER_ID" | tee "$LOG_FILE" > /dev/null
    fi
    sync
  fi

  if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(du -h "$LOG_FILE" | cut -f1)
    LOG_LINES=$(wc -l < "$LOG_FILE")
    NORMAL_LINES=$(grep -c -i "info" "$LOG_FILE" || echo "0")
    ERROR_LINES=$(grep -c -i "error" "$LOG_FILE" || echo "0")
    WARNING_LINES=$(grep -c -i "warn" "$LOG_FILE" || echo "0")
    log_info "  - Stored $LOG_SIZE (${LOG_LINES} lines, info=$NORMAL_LINES, warn=$WARNING_LINES, error=$ERROR_LINES)"
  else
    log_warn "  - Failed to capture logs for $DISPLAY_NAME."
  fi
done

{
  echo "Collection timestamp: $TIMESTAMP"
  if [ -z "$TIME_RANGE" ]; then
    echo "Time window: full history"
  else
    echo "Time window: last $TIME_RANGE"
  fi
  echo "Services captured: ${#SERVICES[@]}"
  echo ""
  echo "Log file summary:"
  for SERVICE in "${SERVICES[@]}"; do
    DISPLAY_NAME=${DISPLAY_NAMES[$SERVICE]}
    LOG_FILE="$LOG_DIR/${DISPLAY_NAME}_${TIMESTAMP}.log"
    if [ -f "$LOG_FILE" ]; then
      LOG_SIZE=$(du -h "$LOG_FILE" | cut -f1)
      LOG_LINES=$(wc -l < "$LOG_FILE")
      ERROR_LINES=$(grep -c -i "error" "$LOG_FILE" || echo "0")
      WARNING_LINES=$(grep -c -i "warn" "$LOG_FILE" || echo "0")
      STARTUP_LINES=$(grep -c "Starting" "$LOG_FILE" || echo "0")
      echo "- ${DISPLAY_NAME}: ${LOG_SIZE} (${LOG_LINES} lines) | errors=${ERROR_LINES}, warnings=${WARNING_LINES}, startup=${STARTUP_LINES}"
    else
      echo "- ${DISPLAY_NAME}: log file not generated"
    fi
  done
} > "$LOG_DIR/summary.txt"

TOTAL_LOGS=0
EMPTY_LOGS=0
VALID_LOGS=0

for SERVICE in "${SERVICES[@]}"; do
  DISPLAY_NAME=${DISPLAY_NAMES[$SERVICE]}
  LOG_FILE="$LOG_DIR/${DISPLAY_NAME}_${TIMESTAMP}.log"

  if [ ! -f "$LOG_FILE" ]; then
    log_warn "  - ${DISPLAY_NAME} log file is missing; container might have been stopped."
    continue
  fi

  TOTAL_LOGS=$((TOTAL_LOGS + 1))

  if [ ! -s "$LOG_FILE" ]; then
    log_warn "  - ${DISPLAY_NAME} log file is empty."
    EMPTY_LOGS=$((EMPTY_LOGS + 1))
  else
    VALID_LOGS=$((VALID_LOGS + 1))
    SPAN_LINES=$(grep -c "Reporting span" "$LOG_FILE" || echo "0")
    TOTAL_LINES=$(wc -l < "$LOG_FILE")
    if [ "$SPAN_LINES" -eq "$TOTAL_LINES" ] && [ "$TOTAL_LINES" -gt 0 ]; then
      log_warn "  - ${DISPLAY_NAME} log contains only tracing statements ($SPAN_LINES lines)."
    fi
  fi
done

log_info "Validation summary: total=$TOTAL_LOGS, empty=$EMPTY_LOGS, valid=$VALID_LOGS."
log_info "Review $(pwd)/$LOG_DIR_BASENAME for detailed log files and summary.txt."