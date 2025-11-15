#!/bin/bash

# OpenAPI Response Data Collection Script
# This script collects OpenAPI responses including status codes, headers, response body, and latency
# Supports both Mixed-workload test and EvoMaster test scenarios

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
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

# Error handling function
check_command_success() {
    if [ $? -ne 0 ]; then
        log_error "Command execution failed: $1"
        return 1
    fi
}

# Function to set up output directory
setup_output_directory() {
    local base_dir="$1"
    
    if [ -z "$CUSTOM_DIR" ]; then
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
        OUTPUT_DIR="${base_dir}/openapi_responses_${TIMESTAMP}"
    else
        OUTPUT_DIR="${base_dir}/${CUSTOM_DIR}"
    fi
    
    mkdir -p "$OUTPUT_DIR"
    if [ $? -eq 0 ]; then
        log_info "Created output directory: $OUTPUT_DIR"
    else
        log_error "Failed to create output directory: $OUTPUT_DIR"
        exit 1
    fi
}

# Function to capture OpenAPI responses during test execution
capture_openapi_responses() {
    local test_type="$1"
    local duration="$2"
    
    log_step "Starting OpenAPI response capture for $test_type test"
    
    # Define the main API endpoints for SocialNetwork
    declare -a ENDPOINTS=(
        "http://localhost:8080/wrk2-api/user/register"
        "http://localhost:8080/wrk2-api/user/follow"
        "http://localhost:8080/wrk2-api/user/unfollow"
        "http://localhost:8080/wrk2-api/user/login"
        "http://localhost:8080/wrk2-api/post/compose"
        "http://localhost:8080/wrk2-api/home-timeline/read"
        "http://localhost:8080/wrk2-api/user-timeline/read"
        "http://localhost:8080/wrk2-api/user/profile"
        "http://localhost:8080/wrk2-api/media/upload"
        "http://localhost:8080/wrk2-api/text/upload"
        "http://localhost:8080/wrk2-api/url/shorten"
        "http://localhost:8080/wrk2-api/user-mention/upload"
    )
    
    # Optional: Start monitoring network traffic using tcpdump (disabled by default to save space)
    local tcpdump_pid=""
    if [ "$ENABLE_NETWORK_CAPTURE" = "true" ]; then
        log_info "Starting network traffic capture..."
        local pcap_file="${OUTPUT_DIR}/network_traffic.pcap"
        sudo tcpdump -i any -w "$pcap_file" port 8080 &
        tcpdump_pid=$!
    fi
    
    # Start HTTP response monitoring using the enhanced Python script
    log_info "Starting enhanced HTTP response monitoring..."
    python3 "${SCRIPT_DIR}/enhanced_openapi_monitor.py" \
        --output-dir "$OUTPUT_DIR" \
        --duration "$duration" \
        --sample-interval 2 &
    local monitor_pid=$!
    
    # Wait for the specified duration
    log_info "Monitoring OpenAPI responses for ${duration} seconds..."
    sleep "$duration"
    
    # Stop monitoring processes
    log_info "Stopping monitoring processes..."
    kill $monitor_pid 2>/dev/null
    if [ -n "$tcpdump_pid" ]; then
        sudo kill $tcpdump_pid 2>/dev/null
    fi
    
    # Wait a moment for cleanup
    sleep 2
    
    log_info "OpenAPI response capture completed"
}

# Function to analyze captured network traffic
analyze_network_traffic() {
    local pcap_file="${OUTPUT_DIR}/network_traffic.pcap"
    
    if [ ! -f "$pcap_file" ]; then
        log_warn "Network traffic capture file not found: $pcap_file"
        return 1
    fi
    
    log_info "Analyzing network traffic..."
    
    # Use tshark to extract HTTP request/response information
    local http_analysis="${OUTPUT_DIR}/http_analysis.json"
    
    tshark -r "$pcap_file" -Y "http" -T json > "$http_analysis" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "$http_analysis" ]; then
        log_info "HTTP traffic analysis saved to: $http_analysis"
        
        # Generate summary statistics
        python3 "${SCRIPT_DIR}/analyze_http_traffic.py" \
            --input-file "$http_analysis" \
            --output-dir "$OUTPUT_DIR"
    else
        log_warn "No HTTP traffic captured or tshark analysis failed"
    fi
}

# Function to create monitoring Python script
create_monitor_script() {
    local script_path="${SCRIPT_DIR}/monitor_http_responses.py"
    
    cat > "$script_path" << 'EOF'
#!/usr/bin/env python3

import argparse
import asyncio
import aiohttp
import json
import time
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any
import signal

class OpenAPIResponseCollector:
    def __init__(self, output_dir: str, endpoints: List[str], duration: int):
        self.output_dir = Path(output_dir)
        self.endpoints = endpoints
        self.duration = duration
        self.responses = []
        self.start_time = None
        self.running = True
        
        # Setup logging
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s'
        )
        self.logger = logging.getLogger(__name__)
        
        # Setup signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
    
    def signal_handler(self, signum, frame):
        self.logger.info(f"Received signal {signum}, stopping collection...")
        self.running = False
    
    async def make_request(self, session: aiohttp.ClientSession, endpoint: str) -> Dict[str, Any]:
        """Make a single HTTP request and capture response details"""
        request_start = time.time()
        
        try:
            async with session.get(endpoint, timeout=aiohttp.ClientTimeout(total=10)) as response:
                request_end = time.time()
                latency = (request_end - request_start) * 1000  # Convert to milliseconds
                
                # Read response body
                try:
                    response_body = await response.text()
                    # Try to parse as JSON if possible
                    try:
                        response_json = json.loads(response_body)
                        body_type = "json"
                    except json.JSONDecodeError:
                        response_json = response_body
                        body_type = "text"
                except Exception as e:
                    response_json = f"Error reading response body: {str(e)}"
                    body_type = "error"
                
                # Capture response details
                response_data = {
                    "timestamp": datetime.now().isoformat(),
                    "endpoint": endpoint,
                    "status_code": response.status,
                    "status_text": response.reason,
                    "headers": dict(response.headers),
                    "response_body": response_json,
                    "body_type": body_type,
                    "latency_ms": round(latency, 2),
                    "content_length": response.headers.get('Content-Length', 0),
                    "content_type": response.headers.get('Content-Type', ''),
                    "request_start_time": request_start,
                    "request_end_time": request_end
                }
                
                return response_data
                
        except asyncio.TimeoutError:
            return {
                "timestamp": datetime.now().isoformat(),
                "endpoint": endpoint,
                "status_code": 408,
                "status_text": "Request Timeout",
                "headers": {},
                "response_body": "Request timed out",
                "body_type": "error",
                "latency_ms": (time.time() - request_start) * 1000,
                "content_length": 0,
                "content_type": "",
                "request_start_time": request_start,
                "request_end_time": time.time(),
                "error": "timeout"
            }
        except Exception as e:
            return {
                "timestamp": datetime.now().isoformat(),
                "endpoint": endpoint,
                "status_code": 0,
                "status_text": "Connection Error",
                "headers": {},
                "response_body": f"Connection error: {str(e)}",
                "body_type": "error",
                "latency_ms": (time.time() - request_start) * 1000,
                "content_length": 0,
                "content_type": "",
                "request_start_time": request_start,
                "request_end_time": time.time(),
                "error": str(e)
            }
    
    async def passive_monitor(self):
        """Passively monitor HTTP responses during test execution"""
        self.start_time = time.time()
        self.logger.info(f"Starting passive monitoring for {self.duration} seconds...")
        
        # Create output files
        responses_file = self.output_dir / "openapi_responses.jsonl"
        summary_file = self.output_dir / "response_summary.json"
        
        async with aiohttp.ClientSession() as session:
            end_time = self.start_time + self.duration
            
            while time.time() < end_time and self.running:
                # Sample a few endpoints periodically
                for endpoint in self.endpoints[:3]:  # Limit to avoid overwhelming
                    if not self.running:
                        break
                    
                    response_data = await self.make_request(session, endpoint)
                    self.responses.append(response_data)
                    
                    # Write response to file immediately
                    with open(responses_file, 'a') as f:
                        f.write(json.dumps(response_data) + '\n')
                    
                    # Small delay between requests
                    await asyncio.sleep(1)
                
                # Wait before next sampling cycle
                if self.running:
                    await asyncio.sleep(5)
        
        # Generate summary
        self.generate_summary(summary_file)
        
        self.logger.info(f"Monitoring completed. Collected {len(self.responses)} responses.")
    
    def generate_summary(self, summary_file: Path):
        """Generate summary statistics from collected responses"""
        if not self.responses:
            return
        
        # Calculate statistics
        status_codes = {}
        latencies = []
        content_types = {}
        errors = 0
        
        for response in self.responses:
            # Status code distribution
            status_code = response.get('status_code', 0)
            status_codes[status_code] = status_codes.get(status_code, 0) + 1
            
            # Latency statistics
            latency = response.get('latency_ms', 0)
            if latency > 0:
                latencies.append(latency)
            
            # Content type distribution
            content_type = response.get('content_type', 'unknown').split(';')[0]
            content_types[content_type] = content_types.get(content_type, 0) + 1
            
            # Error count
            if 'error' in response:
                errors += 1
        
        # Calculate latency statistics
        latency_stats = {}
        if latencies:
            latencies.sort()
            latency_stats = {
                "min": min(latencies),
                "max": max(latencies),
                "mean": sum(latencies) / len(latencies),
                "median": latencies[len(latencies) // 2],
                "p95": latencies[int(len(latencies) * 0.95)],
                "p99": latencies[int(len(latencies) * 0.99)]
            }
        
        summary = {
            "collection_info": {
                "start_time": datetime.fromtimestamp(self.start_time).isoformat(),
                "duration_seconds": self.duration,
                "total_responses": len(self.responses),
                "endpoints_monitored": self.endpoints
            },
            "status_code_distribution": status_codes,
            "latency_statistics": latency_stats,
            "content_type_distribution": content_types,
            "error_count": errors,
            "success_rate": (len(self.responses) - errors) / len(self.responses) * 100 if self.responses else 0
        }
        
        with open(summary_file, 'w') as f:
            json.dump(summary, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='Monitor OpenAPI responses')
    parser.add_argument('--output-dir', required=True, help='Output directory for collected data')
    parser.add_argument('--endpoints', nargs='+', required=True, help='List of endpoints to monitor')
    parser.add_argument('--duration', type=int, default=60, help='Monitoring duration in seconds')
    
    args = parser.parse_args()
    
    collector = OpenAPIResponseCollector(args.output_dir, args.endpoints, args.duration)
    
    try:
        asyncio.run(collector.passive_monitor())
    except KeyboardInterrupt:
        collector.logger.info("Collection interrupted by user")
    except Exception as e:
        collector.logger.error(f"Error during collection: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF
    
    chmod +x "$script_path"
    log_info "Created HTTP response monitoring script: $script_path"
}

# Function to create HTTP traffic analysis script
create_analysis_script() {
    local script_path="${SCRIPT_DIR}/analyze_http_traffic.py"
    
    cat > "$script_path" << 'EOF'
#!/usr/bin/env python3

import argparse
import json
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime

def analyze_http_traffic(input_file: str, output_dir: str):
    """Analyze captured HTTP traffic and generate reports"""
    
    try:
        with open(input_file, 'r') as f:
            traffic_data = json.load(f)
    except Exception as e:
        print(f"Error reading input file: {e}")
        return
    
    output_path = Path(output_dir)
    
    # Initialize statistics
    http_requests = []
    http_responses = []
    status_codes = defaultdict(int)
    methods = defaultdict(int)
    endpoints = defaultdict(int)
    
    # Process traffic data
    for packet in traffic_data:
        try:
            layers = packet.get('_source', {}).get('layers', {})
            http_layer = layers.get('http', {})
            
            if not http_layer:
                continue
            
            # Extract HTTP information
            http_info = {}
            
            # Check if this is a request or response
            if 'http.request.method' in http_layer:
                # This is a request
                method = http_layer.get('http.request.method', 'UNKNOWN')
                uri = http_layer.get('http.request.uri', '')
                host = http_layer.get('http.host', '')
                
                methods[method] += 1
                endpoints[f"{method} {uri}"] += 1
                
                http_info = {
                    'type': 'request',
                    'method': method,
                    'uri': uri,
                    'host': host,
                    'timestamp': packet.get('_source', {}).get('layers', {}).get('frame', {}).get('frame.time_epoch', ''),
                    'headers': extract_headers(http_layer, 'request')
                }
                
                http_requests.append(http_info)
                
            elif 'http.response.code' in http_layer:
                # This is a response
                status_code = int(http_layer.get('http.response.code', 0))
                status_phrase = http_layer.get('http.response.phrase', '')
                
                status_codes[status_code] += 1
                
                http_info = {
                    'type': 'response',
                    'status_code': status_code,
                    'status_phrase': status_phrase,
                    'timestamp': packet.get('_source', {}).get('layers', {}).get('frame', {}).get('frame.time_epoch', ''),
                    'headers': extract_headers(http_layer, 'response'),
                    'content_length': http_layer.get('http.content_length', 0)
                }
                
                http_responses.append(http_info)
                
        except Exception as e:
            print(f"Error processing packet: {e}")
            continue
    
    # Generate analysis report
    analysis_report = {
        'summary': {
            'total_requests': len(http_requests),
            'total_responses': len(http_responses),
            'unique_endpoints': len(endpoints),
            'analysis_timestamp': datetime.now().isoformat()
        },
        'status_code_distribution': dict(status_codes),
        'method_distribution': dict(methods),
        'endpoint_usage': dict(endpoints),
        'detailed_requests': http_requests[:100],  # Limit to first 100 for file size
        'detailed_responses': http_responses[:100]  # Limit to first 100 for file size
    }
    
    # Save analysis report
    analysis_file = output_path / 'traffic_analysis.json'
    with open(analysis_file, 'w') as f:
        json.dump(analysis_report, f, indent=2)
    
    # Generate CSV summary for easier analysis
    csv_file = output_path / 'response_summary.csv'
    with open(csv_file, 'w') as f:
        f.write('status_code,count,percentage\n')
        total_responses = sum(status_codes.values())
        for status_code, count in sorted(status_codes.items()):
            percentage = (count / total_responses * 100) if total_responses > 0 else 0
            f.write(f'{status_code},{count},{percentage:.2f}\n')
    
    print(f"Analysis completed:")
    print(f"  - Detailed analysis: {analysis_file}")
    print(f"  - CSV summary: {csv_file}")
    print(f"  - Total requests: {len(http_requests)}")
    print(f"  - Total responses: {len(http_responses)}")

def extract_headers(http_layer, request_type):
    """Extract HTTP headers from the packet data"""
    headers = {}
    
    for key, value in http_layer.items():
        if key.startswith('http.'):
            # Clean up the key name
            header_name = key.replace('http.', '').replace('_', '-')
            if isinstance(value, list):
                headers[header_name] = value[0] if value else ''
            else:
                headers[header_name] = str(value)
    
    return headers

def main():
    parser = argparse.ArgumentParser(description='Analyze captured HTTP traffic')
    parser.add_argument('--input-file', required=True, help='Input JSON file from tshark')
    parser.add_argument('--output-dir', required=True, help='Output directory for analysis results')
    
    args = parser.parse_args()
    
    analyze_http_traffic(args.input_file, args.output_dir)

if __name__ == "__main__":
    main()
EOF
    
    chmod +x "$script_path"
    log_info "Created HTTP traffic analysis script: $script_path"
}

# Main function
main() {
    log_step "=== OpenAPI Response Data Collection ==="
    
    # Get script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Setup output directory
    setup_output_directory "$(pwd)"
    
    # Create monitoring and analysis scripts
    create_monitor_script
    create_analysis_script
    
    # Check if we're running in test mode or collection mode
    if [ "$1" = "test" ]; then
        # Test mode - run for a short duration
        log_info "Running in test mode..."
        capture_openapi_responses "test" 30
    else
        # Determine test duration based on environment or default
        local duration=${OPENAPI_MONITOR_DURATION:-60}
        log_info "Running OpenAPI response collection for ${duration} seconds..."
        capture_openapi_responses "production" "$duration"
    fi
    
    # Analyze captured traffic
    analyze_network_traffic
    
    # Optional: Generate final report (disabled by default to reduce file count)
    if [ "$GENERATE_COLLECTION_REPORT" = "true" ]; then
        log_info "Generating final collection report..."
        echo "OpenAPI Response Collection Report" > "${OUTPUT_DIR}/collection_report.txt"
        echo "=================================" >> "${OUTPUT_DIR}/collection_report.txt"
        echo "Collection Time: $(date)" >> "${OUTPUT_DIR}/collection_report.txt"
        echo "Output Directory: ${OUTPUT_DIR}" >> "${OUTPUT_DIR}/collection_report.txt"
        echo "" >> "${OUTPUT_DIR}/collection_report.txt"
        
        # List collected files
        echo "Collected Files:" >> "${OUTPUT_DIR}/collection_report.txt"
        ls -la "${OUTPUT_DIR}" >> "${OUTPUT_DIR}/collection_report.txt"
    fi
    
    log_info "OpenAPI response data collection completed successfully!"
    log_info "Results saved to: ${OUTPUT_DIR}"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check dependencies
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 is required but not installed."
        exit 1
    fi
    
    if ! command -v tcpdump &> /dev/null; then
        log_error "tcpdump is required but not installed. Please install with: sudo apt-get install tcpdump"
        exit 1
    fi
    
    if ! command -v tshark &> /dev/null; then
        log_warn "tshark not found. Install with: sudo apt-get install tshark"
        log_warn "Network traffic analysis will be limited without tshark."
    fi
    
    # Install required Python packages if needed
    python3 -c "import aiohttp" 2>/dev/null || {
        log_info "Installing required Python package: aiohttp"
        pip3 install aiohttp
    }
    
    # Run main function
    main "$@"
fi
