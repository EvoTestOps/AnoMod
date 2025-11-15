| Path | Type | Purpose | Key Dependencies |
| --- | --- | --- | --- |
| `automated_multimodal_collection.sh` | Shell | Orchestrates SocialNetwork resets, anomaly injection, traffic triggering, and multimodal data capture. | Docker Compose, ChaosBlade CLI, Python 3, EvoMaster image, `collect_all_data.sh`. |
| `collect_all_data.sh` | Shell | Drives log/metric/trace/API/coverage collectors and optional chaos workflows. | Docker, ChaosBlade, Python 3, scripts under `Dataset/*`. |
| `DeathStarBench/socialNetwork/scripts/init_social_graph.py` | Python | Seeds the SocialGraph dataset for the SocialNetwork benchmark. | Python 3, NetworkX, SocialNetwork data files. |
| `DeathStarBench/socialNetwork/docker-compose-gcov.yml` | YAML | Coverage-enabled Docker Compose topology for SocialNetwork microservices. | Docker Compose, SocialNetwork images. |
| `DeathStarBench/socialNetwork/wrk2/scripts/social-network/mixed-workload.lua` | Lua | wrk2 workload definition combining read/write API calls. | wrk2 binary, Lua 5.1 runtime embedded in wrk2. |
| `BlackBox_tests/Final_version_2m/EvoMaster_successes_Test.py` | Python (unittest) | EvoMaster-generated regression suite replaying 256 HTTP scenarios. | Python 3, `requests`, `timeout_decorator`, `em_test_utils.py`. |
| `BlackBox_tests/Final_version_2m/em_test_utils.py` | Python | Shared helpers for EvoMaster suites (header builders, assertions). | Python 3. |
| `Dataset/api_responses/collect_openapi_response.sh` | Shell | Launches enhanced OpenAPI capture, optional tcpdump, and summary generation. | bash, `python3`, `tcpdump`, `jq`, scripts in the same folder. |
| `Dataset/api_responses/enhanced_openapi_monitor.py` | Python (asyncio) | Polls SocialNetwork endpoints, records responses, and computes latency stats. | Python 3.9+, `aiohttp`, `numpy`, `pandas`. |
| `Dataset/api_responses/analyze_http_traffic.py` | Python | Parses tshark JSON to derive HTTP statistics for API responses. | Python 3, `pandas`, `numpy`. |
| `Dataset/api_responses/monitor_http_responses.py` | Python | Lightweight async monitor used when tcpdump/tshark is unavailable. | Python 3, `aiohttp`. |
| `Dataset/log_data/collect_log.sh` | Shell | Extracts container logs, validates contents, and summarizes counts per service. | Docker CLI, `grep`, `du`, `wc`, `mktemp`. |
| `Dataset/metric_data/collect_metric.sh` | Shell | Queries Prometheus for microservice, system, and storage metrics. | Python 3, Prometheus HTTP API, `fetch_prometheus_metrics.py`. |
| `Dataset/metric_data/fetch_prometheus_metrics.py` | Python | Helper to fetch Prometheus time series and output CSV files. | Python 3, `requests`, `pandas`. |
| `Dataset/trace_data/collect_trace.sh` | Shell | Retrieves Jaeger traces for each service and converts them to CSV. | `curl`, `jq`, Python 3, Jaeger query API, `jaeger_to_csv.py`. |
| `Dataset/trace_data/jaeger_to_csv.py` | Python | Converts Jaeger JSON trace dumps into flat CSV rows. | Python 3, `pandas`. |

