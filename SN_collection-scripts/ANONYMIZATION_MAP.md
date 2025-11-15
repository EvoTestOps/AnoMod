| Placeholder / Variable | Description | Example Value (replace in your environment) |
| --- | --- | --- |
| `PROJECT_ROOT` | Absolute path to the cloned SocialNetwork toolchain repository that houses DeathStarBench, ChaosBlade, EvoMaster suites, and dataset utilities. | `/srv/socialnetwork-tooling` |
| `DATA_ARCHIVE_ROOT` | Root directory where finalized multimodal datasets (logs, metrics, traces, API responses, coverage) are stored for release. Referenced by `automated_multimodal_collection.sh`. | `/data/sn_multimodal/archive` |
| `DATASET_STORAGE_DIR` | Working directory that receives freshly collected artifacts before archival; defaults to `${DATA_ARCHIVE_ROOT}` when not overridden. Used heavily by `collect_all_data.sh`. | `/data/sn_multimodal/raw` |
| `DATASET_SCRIPT_DIR` | Location of the modality-specific helper scripts under `Dataset/`. Typically `${PROJECT_ROOT}/Dataset`. | `/srv/socialnetwork-tooling/Dataset` |
| `SOCIAL_NETWORK_DIR` | SocialNetwork docker-compose project root from DeathStarBench. | `/srv/socialnetwork-tooling/DeathStarBench/socialNetwork` |
| `CHAOSBLADE_DIR` | Directory containing the ChaosBlade CLI (`blade`). | `/opt/chaosblade/chaosblade-1.7.4` |
| `EVOMASTER_BASE_DIR` | Directory that stores EvoMaster-generated regression suites and outputs. | `/srv/socialnetwork-tooling/BlackBox_tests` |
| `EVOMASTER_TEST_PATH` | Full path to the EvoMaster Python suite triggered by the automation script. | `/srv/socialnetwork-tooling/BlackBox_tests/Final_version_2m/EvoMaster_successes_Test.py` |
| `COLLECT_DATA_SCRIPT` | Path to `collect_all_data.sh`, invoked by the automation pipeline. | `/srv/socialnetwork-tooling/collect_all_data.sh` |
| `WORKLOAD_WRK_BINARY` | Compiled wrk2 binary used for workload-based triggering. | `/srv/socialnetwork-tooling/DeathStarBench/wrk2/wrk` |
| `WORKLOAD_SCRIPT_PATH` | Lua script executed by wrk2 for the mixed SocialNetwork workload. | `/srv/socialnetwork-tooling/DeathStarBench/socialNetwork/wrk2/scripts/social-network/mixed-workload.lua` |
| `API_SPEC_PATH` | Location of the OpenAPI/Swagger specification consumed by EvoMaster. | `/srv/socialnetwork-tooling/social-network-api.yaml` |

