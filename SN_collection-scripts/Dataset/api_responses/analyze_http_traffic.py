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
