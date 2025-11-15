#!/usr/bin/env python3

"""
Enhanced OpenAPI Response Monitor
This script provides comprehensive monitoring of OpenAPI responses for SocialNetwork microservices.
It captures status codes, headers, response body, and latency during test execution.
"""

import asyncio
import aiohttp
import json
import time
import logging
import sys
import signal
import threading
import os
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional
from collections import defaultdict
import argparse
import subprocess
import re

class EnhancedOpenAPIMonitor:
    def __init__(self, output_dir: str, duration: int = 60, sample_interval: int = 2):
        self.output_dir = Path(output_dir)
        self.duration = duration
        self.sample_interval = sample_interval
        self.responses = []
        self.start_time = None
        self.running = True
        
        # SocialNetwork API endpoints
        self.endpoints = [
            "http://localhost:8080/wrk2-api/user/register",
            "http://localhost:8080/wrk2-api/user/follow",
            "http://localhost:8080/wrk2-api/user/unfollow", 
            "http://localhost:8080/wrk2-api/user/login",
            "http://localhost:8080/wrk2-api/post/compose",
            "http://localhost:8080/wrk2-api/home-timeline/read",
            "http://localhost:8080/wrk2-api/user-timeline/read",
            "http://localhost:8080/wrk2-api/user/profile",
            "http://localhost:8080/wrk2-api/media/upload",
            "http://localhost:8080/wrk2-api/text/upload",
            "http://localhost:8080/wrk2-api/url/shorten",
            "http://localhost:8080/wrk2-api/user-mention/upload"
        ]
        
        # Setup logging (only to console by default to reduce files)
        log_to_file = os.getenv('OPENAPI_LOG_TO_FILE', 'false').lower() == 'true'
        handlers = [logging.StreamHandler()]
        if log_to_file:
            handlers.append(logging.FileHandler(self.output_dir / 'monitor.log'))
            
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=handlers
        )
        self.logger = logging.getLogger(__name__)
        
        # Setup signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # Statistics tracking
        self.stats = {
            'total_requests': 0,
            'successful_requests': 0,
            'failed_requests': 0,
            'status_codes': defaultdict(int),
            'response_times': [],
            'errors': []
        }
    
    def signal_handler(self, signum, frame):
        self.logger.info(f"Received signal {signum}, stopping collection...")
        self.running = False
    
    async def test_endpoint_connectivity(self) -> Dict[str, bool]:
        """Test connectivity to all endpoints before starting monitoring"""
        connectivity = {}
        
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as session:
            for endpoint in self.endpoints:
                try:
                    async with session.get(endpoint) as response:
                        connectivity[endpoint] = True
                        self.logger.info(f"[OK] {endpoint} - Status: {response.status}")
                except Exception as e:
                    connectivity[endpoint] = False
                    self.logger.warning(f"[ERR] {endpoint} - Error: {str(e)}")
        
        return connectivity
    
    async def make_sample_request(self, session: aiohttp.ClientSession, endpoint: str) -> Optional[Dict[str, Any]]:
        """Make a sample request to an endpoint and capture response details"""
        request_start = time.time()
        
        try:
            # Use different HTTP methods based on endpoint
            method = 'POST' if any(x in endpoint for x in ['register', 'login', 'compose', 'upload', 'follow', 'unfollow']) else 'GET'
            
            # Prepare request data for POST endpoints
            data = None
            headers = {'Content-Type': 'application/json'}
            
            if method == 'POST':
                if 'register' in endpoint:
                    data = json.dumps({
                        'first_name': 'Test',
                        'last_name': 'User',
                        'username': f'testuser_{int(time.time())}',
                        'password': 'testpass',
                        'user_id': int(time.time()) % 10000
                    })
                elif 'login' in endpoint:
                    data = json.dumps({
                        'username': 'testuser',
                        'password': 'testpass'
                    })
                elif 'compose' in endpoint:
                    data = json.dumps({
                        'username': 'testuser',
                        'user_id': 1,
                        'text': 'Test post',
                        'media_ids': [],
                        'media_types': [],
                        'post_type': 0
                    })
                else:
                    data = json.dumps({})
            
            # Make the request
            async with session.request(method, endpoint, data=data, headers=headers) as response:
                request_end = time.time()
                latency = (request_end - request_start) * 1000
                
                # Read response body
                try:
                    response_text = await response.text()
                    try:
                        response_json = json.loads(response_text)
                        body_type = "json"
                    except json.JSONDecodeError:
                        response_json = response_text
                        body_type = "text"
                except Exception as e:
                    response_json = f"Error reading response: {str(e)}"
                    body_type = "error"
                
                # Capture response details
                response_data = {
                    "timestamp": datetime.now().isoformat(),
                    "endpoint": endpoint,
                    "method": method,
                    "status_code": response.status,
                    "status_text": response.reason,
                    "headers": dict(response.headers),
                    "response_body": response_json,
                    "body_type": body_type,
                    "latency_ms": round(latency, 2),
                    "content_length": int(response.headers.get('Content-Length', 0)),
                    "content_type": response.headers.get('Content-Type', ''),
                    "request_start_time": request_start,
                    "request_end_time": request_end
                }
                
                # Update statistics
                self.stats['total_requests'] += 1
                self.stats['status_codes'][response.status] += 1
                self.stats['response_times'].append(latency)
                
                if 200 <= response.status < 400:
                    self.stats['successful_requests'] += 1
                else:
                    self.stats['failed_requests'] += 1
                
                return response_data
                
        except asyncio.TimeoutError:
            error_data = {
                "timestamp": datetime.now().isoformat(),
                "endpoint": endpoint,
                "method": method,
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
            
            self.stats['total_requests'] += 1
            self.stats['failed_requests'] += 1
            self.stats['errors'].append("timeout")
            
            return error_data
            
        except Exception as e:
            error_data = {
                "timestamp": datetime.now().isoformat(),
                "endpoint": endpoint,
                "method": method,
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
            
            self.stats['total_requests'] += 1
            self.stats['failed_requests'] += 1
            self.stats['errors'].append(str(e))
            
            return error_data
    
    def start_network_capture(self) -> Optional[subprocess.Popen]:
        """Start network packet capture using tcpdump (only if enabled)"""
        if os.getenv('ENABLE_NETWORK_CAPTURE', 'false').lower() != 'true':
            return None
            
        try:
            pcap_file = self.output_dir / "network_capture.pcap"
            cmd = ["sudo", "tcpdump", "-i", "any", "-w", str(pcap_file), "port", "8080"]
            
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
            
            self.logger.info(f"Started network capture: {pcap_file}")
            return process
            
        except Exception as e:
            self.logger.warning(f"Failed to start network capture: {e}")
            return None
    
    async def monitor_responses(self):
        """Main monitoring loop"""
        self.start_time = time.time()
        self.logger.info(f"Starting OpenAPI response monitoring for {self.duration} seconds...")
        
        # Test connectivity first
        connectivity = await self.test_endpoint_connectivity()
        active_endpoints = [ep for ep, connected in connectivity.items() if connected]
        
        if not active_endpoints:
            self.logger.error("No endpoints are reachable. Exiting.")
            return
        
        self.logger.info(f"Monitoring {len(active_endpoints)} active endpoints")
        
        # Start network capture
        capture_process = self.start_network_capture()
        
        # Create output files
        responses_file = self.output_dir / "openapi_responses.jsonl"
        
        async with aiohttp.ClientSession() as session:
            end_time = self.start_time + self.duration
            
            while time.time() < end_time and self.running:
                # Sample a subset of endpoints to avoid overwhelming the system
                sample_endpoints = active_endpoints[:min(5, len(active_endpoints))]
                
                tasks = []
                for endpoint in sample_endpoints:
                    if not self.running:
                        break
                    task = self.make_sample_request(session, endpoint)
                    tasks.append(task)
                
                # Execute requests concurrently but with limited concurrency
                if tasks:
                    responses = await asyncio.gather(*tasks, return_exceptions=True)
                    
                    for response_data in responses:
                        if isinstance(response_data, dict):
                            self.responses.append(response_data)
                            
                            # Write response to file immediately
                            with open(responses_file, 'a') as f:
                                f.write(json.dumps(response_data) + '\n')
                
                # Wait before next sampling cycle
                if self.running:
                    await asyncio.sleep(self.sample_interval)
        
        # Stop network capture
        if capture_process:
            try:
                capture_process.terminate()
                capture_process.wait(timeout=5)
                self.logger.info("Network capture stopped")
            except Exception as e:
                self.logger.warning(f"Error stopping network capture: {e}")
        
        # Generate final reports
        self.generate_reports()
        
        self.logger.info(f"Monitoring completed. Collected {len(self.responses)} responses.")
    
    def generate_reports(self):
        """Generate comprehensive analysis reports"""
        
        # Calculate latency statistics
        latency_stats = {}
        if self.stats['response_times']:
            times = sorted(self.stats['response_times'])
            latency_stats = {
                "min_ms": min(times),
                "max_ms": max(times),
                "mean_ms": sum(times) / len(times),
                "median_ms": times[len(times) // 2],
                "p95_ms": times[int(len(times) * 0.95)],
                "p99_ms": times[int(len(times) * 0.99)]
            }
        
        # Generate summary report
        summary = {
            "collection_info": {
                "start_time": datetime.fromtimestamp(self.start_time).isoformat(),
                "duration_seconds": self.duration,
                "total_responses": len(self.responses),
                "endpoints_monitored": self.endpoints,
                "sample_interval_seconds": self.sample_interval
            },
            "statistics": {
                "total_requests": self.stats['total_requests'],
                "successful_requests": self.stats['successful_requests'],
                "failed_requests": self.stats['failed_requests'],
                "success_rate_percent": (self.stats['successful_requests'] / max(1, self.stats['total_requests'])) * 100
            },
            "status_code_distribution": dict(self.stats['status_codes']),
            "latency_statistics": latency_stats,
            "error_summary": {
                "total_errors": len(self.stats['errors']),
                "unique_errors": len(set(self.stats['errors'])),
                "common_errors": list(set(self.stats['errors']))
            }
        }
        
        # Save summary report
        summary_file = self.output_dir / "response_summary.json"
        with open(summary_file, 'w') as f:
            json.dump(summary, f, indent=2)
        
        # Generate CSV for easy analysis
        csv_file = self.output_dir / "status_code_distribution.csv"
        with open(csv_file, 'w') as f:
            f.write('status_code,count,percentage\n')
            total = sum(self.stats['status_codes'].values())
            for status_code, count in sorted(self.stats['status_codes'].items()):
                percentage = (count / total * 100) if total > 0 else 0
                f.write(f'{status_code},{count},{percentage:.2f}\n')
        
        # Generate endpoint performance report
        endpoint_stats = defaultdict(lambda: {'count': 0, 'avg_latency': 0, 'status_codes': defaultdict(int)})
        
        for response in self.responses:
            endpoint = response.get('endpoint', 'unknown')
            latency = response.get('latency_ms', 0)
            status = response.get('status_code', 0)
            
            endpoint_stats[endpoint]['count'] += 1
            endpoint_stats[endpoint]['avg_latency'] += latency
            endpoint_stats[endpoint]['status_codes'][status] += 1
        
        # Calculate averages
        for endpoint, stats in endpoint_stats.items():
            if stats['count'] > 0:
                stats['avg_latency'] /= stats['count']
            stats['status_codes'] = dict(stats['status_codes'])
        
        endpoint_report_file = self.output_dir / "endpoint_performance.json"
        with open(endpoint_report_file, 'w') as f:
            json.dump(dict(endpoint_stats), f, indent=2)
        
        self.logger.info(f"Reports generated:")
        self.logger.info(f"  - Summary: {summary_file}")
        self.logger.info(f"  - CSV: {csv_file}")
        self.logger.info(f"  - Endpoint performance: {endpoint_report_file}")

def main():
    parser = argparse.ArgumentParser(description='Enhanced OpenAPI Response Monitor')
    parser.add_argument('--output-dir', required=True, help='Output directory for collected data')
    parser.add_argument('--duration', type=int, default=60, help='Monitoring duration in seconds')
    parser.add_argument('--sample-interval', type=int, default=2, help='Sampling interval in seconds')
    
    args = parser.parse_args()
    
    # Create output directory
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    monitor = EnhancedOpenAPIMonitor(
        output_dir=str(output_dir),
        duration=args.duration,
        sample_interval=args.sample_interval
    )
    
    try:
        asyncio.run(monitor.monitor_responses())
    except KeyboardInterrupt:
        monitor.logger.info("Monitoring interrupted by user")
    except Exception as e:
        monitor.logger.error(f"Error during monitoring: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
