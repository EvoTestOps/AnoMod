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
