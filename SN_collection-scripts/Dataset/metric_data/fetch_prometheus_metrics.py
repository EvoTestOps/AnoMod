 #!/usr/bin/env python3
import requests
import pandas as pd
import time
import sys
import argparse
from datetime import datetime, timedelta

def fetch_prometheus_metrics(query, start_time, end_time, step, prometheus_url):
    """
    Query Prometheus for the specified time range and return a DataFrame.

    Args:
        query (str): Prometheus expression.
        start_time (int): Start timestamp in seconds.
        end_time (int): End timestamp in seconds.
        step (str): Step size (e.g., '15s', '1m', '1h').
        prometheus_url (str): Base URL of the Prometheus server.

    Returns:
        pandas.DataFrame | None: Time-series data when available.
    """
    url = f"{prometheus_url}/api/v1/query_range"
    params = {
        'query': query,
        'start': start_time,
        'end': end_time,
        'step': step
    }
    
    try:
        response = requests.get(url, params=params)
        response.raise_for_status()
        data = response.json()
        
        if data['status'] != 'success':
            print(f"Error: {data.get('error', 'Unknown error')}")
            return None
        
        if not data['data']['result']:
            print(f"Warning: query '{query}' returned no data.")
            return None
        
        # Prepare a DataFrame payload
        all_data = []
        
        for result in data['data']['result']:
            metric_labels = result['metric']
            
            # Render label string
            labels_str = ','.join([f'{k}="{v}"' for k, v in metric_labels.items()])
            
            for value in result['values']:
                timestamp = datetime.fromtimestamp(value[0])
                metric_value = float(value[1])
                
                row = {
                    'timestamp': timestamp,
                    'value': metric_value,
                    'metric': labels_str
                }
                
                # Copy metric labels into individual columns
                for k, v in metric_labels.items():
                    row[k] = v
                
                all_data.append(row)
        
        if not all_data:
            return None
            
        df = pd.DataFrame(all_data)
        return df
    
    except requests.exceptions.RequestException as e:
        print(f"Request error: {e}")
        return None
    except Exception as e:
        print(f"Unexpected error: {e}")
        return None

def main():
    parser = argparse.ArgumentParser(description='Fetch metrics from Prometheus and persist as CSV.')
    parser.add_argument('--query', required=True, help='Prometheus query expression')
    parser.add_argument('--output', required=True, help='Output CSV path')
    parser.add_argument('--url', default='http://localhost:9090', help='Prometheus base URL')
    parser.add_argument('--hours', type=int, default=1, help='Number of hours to query backwards')
    parser.add_argument('--step', default='15s', help='Temporal step size')
    
    args = parser.parse_args()
    
    end_time = int(time.time())
    start_time = end_time - (args.hours * 3600)
    
    print(f"Fetching data for query '{args.query}'...")
    df = fetch_prometheus_metrics(args.query, start_time, end_time, args.step, args.url)
    
    if df is not None:
        df.to_csv(args.output, index=False)
        print(f"Wrote {len(df)} rows to {args.output}")
    else:
        print("No data returned; CSV file skipped.")

if __name__ == "__main__":
    main()