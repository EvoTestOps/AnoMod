#!/bin/bash

# Metric collection window
HOURS=24
STEP="15s"
TIMESTAMP="${TIMESTAMP:-$(date +"%Y-%m-%d_%H-%M-%S")}"

# Honor CUSTOM_DIR from the parent script; fall back to a timestamped folder when executed standalone.
if [ -n "$CUSTOM_DIR" ]; then
    OUTPUT_DIR_BASENAME="$CUSTOM_DIR"
else
    OUTPUT_DIR_BASENAME="metrics_$TIMESTAMP"
fi

OUTPUT_DIR="./$OUTPUT_DIR_BASENAME"
mkdir -p "$OUTPUT_DIR"

echo "Metrics will be written to: $(pwd)/$OUTPUT_DIR_BASENAME"
echo "Collecting Prometheus metrics for the SocialNetwork workload..."

# ===== Microservice KPIs =====

echo "Collecting per-service HTTP request throughput..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(http_requests_total[5m])) by (service)" \
  --output "$OUTPUT_DIR/microservice_request_rate.csv" --hours $HOURS --step $STEP

echo "Collecting per-service HTTP request latency (p95)..."
python3 ./fetch_prometheus_metrics.py --query "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))" \
  --output "$OUTPUT_DIR/microservice_latency_p95.csv" --hours $HOURS --step $STEP

echo "Collecting per-service HTTP error rates..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(http_requests_total{status=~\"5..\"}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service)" \
  --output "$OUTPUT_DIR/microservice_error_rate.csv" --hours $HOURS --step $STEP

echo "Collecting post creation throughput..."
python3 ./fetch_prometheus_metrics.py --query "rate(post_compose_count[5m])" \
  --output "$OUTPUT_DIR/post_creation_rate.csv" --hours $HOURS --step $STEP

echo "Collecting timeline read throughput..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(timeline_read_count[5m])) by (type)" \
  --output "$OUTPUT_DIR/timeline_read_rate.csv" --hours $HOURS --step $STEP

# ===== Container resource usage =====

echo "Collecting container CPU utilization..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_project=\"socialnetwork\"}[5m])) by (container_label_com_docker_compose_service)" \
  --output "$OUTPUT_DIR/socialnet_container_cpu.csv" --hours $HOURS --step $STEP

echo "Collecting container memory usage..."
python3 ./fetch_prometheus_metrics.py --query "container_memory_usage_bytes{container_label_com_docker_compose_project=\"socialnetwork\"}" \
  --output "$OUTPUT_DIR/socialnet_container_memory.csv" --hours $HOURS --step $STEP

echo "Collecting container network receive throughput..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(container_network_receive_bytes_total{container_label_com_docker_compose_project=\"socialnetwork\"}[5m])) by (container_label_com_docker_compose_service)" \
  --output "$OUTPUT_DIR/socialnet_container_network_receive.csv" --hours $HOURS --step $STEP

echo "Collecting container network transmit throughput..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(container_network_transmit_bytes_total{container_label_com_docker_compose_project=\"socialnetwork\"}[5m])) by (container_label_com_docker_compose_service)" \
  --output "$OUTPUT_DIR/socialnet_container_network_transmit.csv" --hours $HOURS --step $STEP

# ===== Database and cache metrics =====

echo "Collecting MongoDB operation latency..."
python3 ./fetch_prometheus_metrics.py --query "histogram_quantile(0.95, sum(rate(mongodb_operation_latency_seconds_bucket[5m])) by (le, operation))" \
  --output "$OUTPUT_DIR/mongodb_latency_p95.csv" --hours $HOURS --step $STEP

echo "Collecting Redis memory usage..."
python3 ./fetch_prometheus_metrics.py --query "redis_memory_used_bytes" \
  --output "$OUTPUT_DIR/redis_memory_used.csv" --hours $HOURS --step $STEP

echo "Collecting Redis command throughput..."
python3 ./fetch_prometheus_metrics.py --query "rate(redis_commands_processed_total[5m])" \
  --output "$OUTPUT_DIR/redis_command_rate.csv" --hours $HOURS --step $STEP

# ===== Jaeger tracing metrics =====

echo "Collecting Jaeger span production rate..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(jaeger_tracer_reporter_spans_total[5m])) by (result)" \
  --output "$OUTPUT_DIR/jaeger_spans_rate.csv" --hours $HOURS --step $STEP

echo "Collecting Jaeger sampling ratio..."
python3 ./fetch_prometheus_metrics.py --query "jaeger_sampler_sampled_total / (jaeger_sampler_sampled_total + jaeger_sampler_not_sampled_total)" \
  --output "$OUTPUT_DIR/jaeger_sampling_rate.csv" --hours $HOURS --step $STEP

# ===== Host-level indicators =====

echo "Collecting system CPU utilization..."
python3 ./fetch_prometheus_metrics.py --query "100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)" \
  --output "$OUTPUT_DIR/system_cpu_usage.csv" --hours $HOURS --step $STEP

echo "Collecting system memory utilization..."
python3 ./fetch_prometheus_metrics.py --query "100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)" \
  --output "$OUTPUT_DIR/system_memory_usage_percent.csv" --hours $HOURS --step $STEP

echo "Collecting system load averages..."
python3 ./fetch_prometheus_metrics.py --query "node_load1" \
  --output "$OUTPUT_DIR/system_load1.csv" --hours $HOURS --step $STEP

echo "Collecting system network error rate..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(node_network_transmit_errs_total[5m]) + rate(node_network_receive_errs_total[5m]))" \
  --output "$OUTPUT_DIR/system_network_errors.csv" --hours $HOURS --step $STEP

# ===== Extended performance indicators =====

echo "Collecting disk I/O utilization..."
python3 ./fetch_prometheus_metrics.py --query "rate(node_disk_io_time_seconds_total[5m])" \
  --output "$OUTPUT_DIR/system_disk_io_time.csv" --hours $HOURS --step $STEP

echo "Collecting disk read/write throughput..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(node_disk_read_bytes_total[5m])) by (device)" \
  --output "$OUTPUT_DIR/system_disk_read_bytes.csv" --hours $HOURS --step $STEP

python3 ./fetch_prometheus_metrics.py --query "sum(rate(node_disk_written_bytes_total[5m])) by (device)" \
  --output "$OUTPUT_DIR/system_disk_write_bytes.csv" --hours $HOURS --step $STEP

echo "Collecting system network bandwidth..."
python3 ./fetch_prometheus_metrics.py --query "sum(rate(node_network_receive_bytes_total[5m])) by (device)" \
  --output "$OUTPUT_DIR/system_network_receive_bytes.csv" --hours $HOURS --step $STEP

python3 ./fetch_prometheus_metrics.py --query "sum(rate(node_network_transmit_bytes_total[5m])) by (device)" \
  --output "$OUTPUT_DIR/system_network_transmit_bytes.csv" --hours $HOURS --step $STEP

echo "Collecting disk usage percentage..."
python3 ./fetch_prometheus_metrics.py --query "100 * (1 - (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}))" \
  --output "$OUTPUT_DIR/system_disk_usage_percent.csv" --hours $HOURS --step $STEP

# ===== Metadata =====

{
  echo "Collection_Timestamp: $TIMESTAMP"
  echo "Collection_Duration_Hours: $HOURS"
  echo "Scrape_Step: $STEP"
} > "$OUTPUT_DIR/metadata.txt"

echo "Metric collection completed. Artifacts are stored in $OUTPUT_DIR"