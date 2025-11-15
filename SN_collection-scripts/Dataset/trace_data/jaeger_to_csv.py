import json
import pandas as pd
import sys
from datetime import datetime

# Validate CLI arguments
if len(sys.argv) < 3:
    print("Usage: python jaeger_to_csv.py <input_json> <output_csv>")
    sys.exit(1)

# Load Jaeger JSON
with open(sys.argv[1], 'r') as f:
    try:
        jaeger_data = json.load(f)
    except json.JSONDecodeError:
        print("Error: invalid JSON payload.")
        sys.exit(1)

# Extract spans
traces = []
for trace in jaeger_data.get('data', []):
    trace_id = trace.get('traceID', '')
    
    # Map process identifiers to service names
    processes = trace.get('processes', {})
    process_to_service = {}
    for process_id, process_info in processes.items():
        service_name = process_info.get('serviceName', '')
        process_to_service[process_id] = service_name
    
    # Walk every span
    for span in trace.get('spans', []):
        # Resolve parent span
        parent_span_id = ''
        for ref in span.get('references', []):
            if ref.get('refType') == 'CHILD_OF':
                parent_span_id = ref.get('spanID', '')
                break
        
        # Convert timestamps
        start_time_ms = span.get('startTime', 0) / 1000
        end_time_ms = start_time_ms + span.get('duration', 0) / 1000
        start_time = datetime.fromtimestamp(start_time_ms / 1000).strftime('%Y-%m-%d %H:%M:%S.%f')
        
        process_id = span.get('processID', '')
        service_name = process_to_service.get(process_id, '')
        
        # Extract http metadata from tags
        tags = {}
        http_status_code = ''
        http_method = ''
        http_url = ''
        component = ''
        
        for tag in span.get('tags', []):
            tag_key = tag.get('key', '')
            tag_value = tag.get('value', '')
            tags[tag_key] = tag_value
            
            if tag_key == 'http.status_code':
                http_status_code = tag_value
            elif tag_key == 'http.method':
                http_method = tag_value
            elif tag_key == 'http.url':
                http_url = tag_value
            elif tag_key == 'component':
                component = tag_value
            
        # Collect span logs
        logs = []
        for log in span.get('logs', []):
            log_time = datetime.fromtimestamp(log.get('timestamp', 0) / 1000000).strftime('%Y-%m-%d %H:%M:%S.%f')
            log_fields = {field.get('key', ''): field.get('value', '') for field in log.get('fields', [])}
            logs.append(f"{log_time}: {json.dumps(log_fields)}")
            
        traces.append({
            'trace_id': trace_id,
            'span_id': span.get('spanID', ''),
            'parent_span_id': parent_span_id,
            'service': service_name,
            'operation': span.get('operationName', ''),
            'start_time': start_time,
            'duration_us': span.get('duration', 0),
            'http_status_code': http_status_code,
            'http_method': http_method,
            'http_url': http_url,
            'component': component,
            'tags': json.dumps(tags),
            'logs': '; '.join(logs)
        })

if not traces:
    print("Warning: no trace data detected.")
    pd.DataFrame(columns=['trace_id', 'span_id', 'parent_span_id', 'service', 
                         'operation', 'start_time', 'duration_us', 'http_status_code',
                         'http_method', 'http_url', 'component', 'tags', 'logs']).to_csv(sys.argv[2], index=False)
    sys.exit(0)

df = pd.DataFrame(traces)
df.to_csv(sys.argv[2], index=False)
print(f"Exported {len(traces)} spans to {sys.argv[2]}")
