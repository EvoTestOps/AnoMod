#!/bin/bash

# Honor CUSTOM_DIR from the parent script; default to a timestamped folder when running standalone.
if [ -n "$CUSTOM_DIR" ]; then
    OUTPUT_DIR_BASENAME="$CUSTOM_DIR"
else
    # Match the YYYY-MM-DD_HH-MM-SS format when executed independently.
    TIMESTAMP_INTERNAL=$(date +"%Y-%m-%d_%H-%M-%S")
    OUTPUT_DIR_BASENAME="traces_$TIMESTAMP_INTERNAL"
fi

OUTPUT_DIR="./$OUTPUT_DIR_BASENAME"
mkdir -p "$OUTPUT_DIR"
echo "Trace data will be stored in: $(pwd)/$OUTPUT_DIR_BASENAME"

# Set time period parameters
LOOKBACK=${1:-3600000}  # Default to 1 hour (in milliseconds)
LIMIT=${2:-50}          # Default to 50 traces per service
OUTPUT_NAME=${3:-"all_traces"}  # Default output filename

echo "Collecting traces for the last $LOOKBACK ms with limit $LIMIT per service..."

# Get all available services
SERVICES_FILE="$OUTPUT_DIR/available_services.json"
curl -s -X GET "http://localhost:16686/api/services" -o "$SERVICES_FILE"

# Create a temporary directory for individual service trace files
TEMP_DIR="$OUTPUT_DIR/temp_traces"
mkdir -p "$TEMP_DIR"

# Parse services from the JSON file using jq (install if not available: apt-get install jq)
if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y jq
fi

SERVICES=$(jq -r '.data[]' "$SERVICES_FILE")

# Initialize a JSON file with empty data array
echo '{"data":[]}' > "$OUTPUT_DIR/${OUTPUT_NAME}.json"

# Loop through each service and collect traces
for SERVICE in $SERVICES
do
    echo "Collecting traces for service: $SERVICE"
    SERVICE_FILE="$TEMP_DIR/${SERVICE}.json"
    
    # Get traces for this service
    curl -s -X GET "http://localhost:16686/api/traces?service=$SERVICE&limit=$LIMIT&lookback=$LOOKBACK" -o "$SERVICE_FILE"
    
    # Check if we got valid data
    if [[ $(jq -r '.data | length' "$SERVICE_FILE") -gt 0 ]]; then
        # Merge this service's traces into the main file (avoiding duplicates by traceID)
        COMBINED=$(jq -s '
            .[0].data + .[1].data | 
            unique_by(.traceID) | 
            {data: .}
        ' "$OUTPUT_DIR/${OUTPUT_NAME}.json" "$SERVICE_FILE")
        
        echo "$COMBINED" > "$OUTPUT_DIR/${OUTPUT_NAME}.json"
    fi
done

# Count the number of unique traces collected
TOTAL_TRACES=$(jq -r '.data | length' "$OUTPUT_DIR/${OUTPUT_NAME}.json")
echo "Collected $TOTAL_TRACES unique traces across all services"

# Convert to CSV
echo "Converting to CSV..."
python jaeger_to_csv.py "$OUTPUT_DIR/${OUTPUT_NAME}.json" "$OUTPUT_DIR/${OUTPUT_NAME}.csv"

# Clean up temporary files
echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

echo "Done! Trace data saved to $OUTPUT_DIR/${OUTPUT_NAME}.csv"