#!/bin/bash
#
# Prusa Connect Camera Upload Script
# Reads snapshots created by stream_server.sh and uploads them to Prusa Connect API
# every UPLOAD_INTERVAL seconds. Optional secondary camera settings are loaded from
# the same configuration file for backward-compatible dual-camera installs.
#

CONFIG_FILE="/etc/prusa_cam.conf"
HTTP_URL="https://connect.prusa3d.com/c/snapshot"
LONG_DELAY_SECONDS=60
SNAPSHOT_FILE="/tmp/stream_snapshot.jpg"
SECOND_SNAPSHOT_FILE="/tmp/stream_snapshot_second.jpg"

# Check if config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run the installer first."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

DELAY_SECONDS=${UPLOAD_INTERVAL:-10}
SECOND_CAMERA_ENABLED=${SECOND_CAMERA_ENABLED:-0}

upload_loop() {
    local label="$1"
    local camera_type="$2"
    local camera_name="$3"
    local fingerprint="$4"
    local token="$5"
    local snapshot_file="$6"
    local delay
    local file_age
    local http_response
    local wait_count=0

    echo "========================================"
    echo "  Prusa Connect $label Camera Upload Service"
    echo "========================================"
    echo ""
    echo "Camera Type: $camera_type"
    echo "Camera: $camera_name"
    echo "Upload Interval: ${DELAY_SECONDS}s"
    echo "Fingerprint: $fingerprint"
    echo "Snapshot File: $snapshot_file"
    echo ""
    echo "Waiting for $label stream server to start..."

    while [[ ! -f "$snapshot_file" ]] && [[ $wait_count -lt 30 ]]; do
        sleep 2
        ((wait_count++))
    done

    if [[ ! -f "$snapshot_file" ]]; then
        echo "WARNING: $label snapshot file not found after 60s, will keep trying..."
    fi

    echo "Starting $label upload loop..."
    echo ""

    while true; do
        if [[ -f "$snapshot_file" ]]; then
            file_age=$(($(date +%s) - $(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)))

            if [[ $file_age -lt 30 ]]; then
                http_response=$(curl -s -w "%{http_code}" -X PUT "$HTTP_URL" \
                    -H "accept: */*" \
                    -H "content-type: image/jpg" \
                    -H "fingerprint: $fingerprint" \
                    -H "token: $token" \
                    --data-binary "@$snapshot_file" \
                    --no-progress-meter \
                    --compressed \
                    -o /dev/null \
                    --max-time 30)

                case "$http_response" in
                    200|204)
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - $label upload successful"
                        delay=$DELAY_SECONDS
                        ;;
                    401)
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - $label upload failed: Invalid token (HTTP 401)"
                        delay=$LONG_DELAY_SECONDS
                        ;;
                    403)
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - $label upload failed: Access denied (HTTP 403)"
                        delay=$LONG_DELAY_SECONDS
                        ;;
                    *)
                        echo "$(date '+%Y-%m-%d %H:%M:%S') - $label upload failed (HTTP $http_response)"
                        delay=$LONG_DELAY_SECONDS
                        ;;
                esac
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - $label snapshot too old (${file_age}s), waiting for fresh frame..."
                delay=5
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Waiting for $label snapshot from stream server..."
            delay=5
        fi

        sleep "$delay"
    done
}

upload_loop "primary" "$CAMERA_TYPE" "$CAMERA_NAME" "$FINGERPRINT" "$TOKEN" "$SNAPSHOT_FILE" &

if [[ "$SECOND_CAMERA_ENABLED" == "1" ]]; then
    upload_loop "secondary" "$SECOND_CAMERA_TYPE" "$SECOND_CAMERA_NAME" "$SECOND_FINGERPRINT" "$SECOND_TOKEN" "$SECOND_SNAPSHOT_FILE" &
fi

wait
