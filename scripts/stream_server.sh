#!/bin/bash
#
# Camera Stream Server Script
# Lightweight Python-based MJPEG streaming server
# - Streams live video on port 8080
# - Saves snapshots to /tmp/stream_snapshot.jpg for Prusa Connect uploads
# - All temp files in RAM (tmpfs) to protect SD card
#

CONFIG_FILE="/etc/prusa_cam.conf"
SNAPSHOT_FILE="/tmp/stream_snapshot.jpg"
SECOND_SNAPSHOT_FILE="/tmp/stream_snapshot_second.jpg"

log_info() {
    echo "$*"
}

log_warn() {
    echo "WARNING: $*"
}

log_error() {
    echo "ERROR: $*"
}

load_configuration() {
    # Keep existing installations compatible by loading the same config file first,
    # then applying defaults only for values that are not configured.
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Please run the installer first."
        exit 1
    fi

    # shellcheck source=/etc/prusa_cam.conf
    source "$CONFIG_FILE"

    # Current stream defaults.
    STREAM_PORT=${STREAM_PORT:-8080}
    STREAM_WIDTH=${STREAM_WIDTH:-1280}
    STREAM_HEIGHT=${STREAM_HEIGHT:-720}

    # Optional secondary camera defaults keep existing single-camera installs compatible.
    SECOND_CAMERA_ENABLED=${SECOND_CAMERA_ENABLED:-0}
    SECOND_STREAM_PORT=${SECOND_STREAM_PORT:-8081}
    SECOND_STREAM_WIDTH=${SECOND_STREAM_WIDTH:-1280}
    SECOND_STREAM_HEIGHT=${SECOND_STREAM_HEIGHT:-720}

    # Autofocus configuration. Empty values preserve existing camera behavior.
    FOCUS_MODE=${FOCUS_MODE:-}
    FOCUS_VALUE=${FOCUS_VALUE:-}
    FOCUS_SETTLE_TIME=${FOCUS_SETTLE_TIME:-2}
    SECOND_FOCUS_MODE=${SECOND_FOCUS_MODE:-}
    SECOND_FOCUS_VALUE=${SECOND_FOCUS_VALUE:-}
    SECOND_FOCUS_SETTLE_TIME=${SECOND_FOCUS_SETTLE_TIME:-2}

    # Camera control capability cache, populated once per USB camera at stream startup.
    CAMERA_CONTROLS_LOADED=0
    CAMERA_CONTROLS=""
}

print_startup_banner() {
    log_info "========================================"
    log_info "  Camera Stream Server"
    log_info "========================================"
    log_info ""
    log_info "Camera Type: $CAMERA_TYPE"
    log_info "Camera: $CAMERA_NAME"
    log_info "Stream Port: $STREAM_PORT"
    log_info "Resolution: ${STREAM_WIDTH}x${STREAM_HEIGHT}"
    if [[ "$SECOND_CAMERA_ENABLED" == "1" ]]; then
        log_info "Secondary Camera Type: $SECOND_CAMERA_TYPE"
        log_info "Secondary Camera: $SECOND_CAMERA_NAME"
        log_info "Secondary Stream Port: $SECOND_STREAM_PORT"
        log_info "Secondary Resolution: ${SECOND_STREAM_WIDTH}x${SECOND_STREAM_HEIGHT}"
    fi
    log_info ""
}

load_camera_controls() {
    local device="$1"

    CAMERA_CONTROLS_LOADED=1
    CAMERA_CONTROLS=""

    if ! command -v v4l2-ctl &> /dev/null; then
        log_warn "v4l2-ctl not found; camera controls will not be configured"
        return 0
    fi

    if ! CAMERA_CONTROLS=$(v4l2-ctl -d "$device" --list-ctrls 2>/dev/null); then
        CAMERA_CONTROLS=""
        log_warn "Unable to read camera controls for $device; continuing without control configuration"
    fi
}

has_v4l2_control() {
    local control="$1"

    [[ "$CAMERA_CONTROLS_LOADED" -eq 1 ]] && \
        printf '%s\n' "$CAMERA_CONTROLS" | grep -q "^[[:space:]]*$control[[:space:]]"
}

read_v4l2_control() {
    local device="$1"
    local control="$2"

    v4l2-ctl -d "$device" --get-ctrl="$control" 2>/dev/null | awk -F': ' '{print $2}'
}

write_v4l2_control() {
    local device="$1"
    local control="$2"
    local value="$3"

    v4l2-ctl -d "$device" --set-ctrl="${control}=${value}" 2>/dev/null
}

set_v4l2_control_or_warn() {
    local device="$1"
    local control="$2"
    local value="$3"
    local description="$4"

    if ! has_v4l2_control "$control"; then
        log_warn "Camera does not expose $control; cannot configure $description"
        return 1
    fi

    if ! write_v4l2_control "$device" "$control" "$value"; then
        log_warn "Failed to set $control=$value for $description"
        return 1
    fi

    return 0
}

configure_focus() {
    local device="$1"
    local captured_focus

    case "$FOCUS_MODE" in
        "")
            return 0
            ;;
        "auto")
            set_v4l2_control_or_warn "$device" "focus_auto" "1" "autofocus" || true
            ;;
        "continuous")
            if has_v4l2_control "focus_automatic_continuous"; then
                set_v4l2_control_or_warn "$device" "focus_automatic_continuous" "1" "continuous autofocus" || true
            else
                log_warn "Camera does not expose focus_automatic_continuous; cannot configure continuous autofocus"
            fi
            ;;
        "lock")
            if ! has_v4l2_control "focus_auto"; then
                log_warn "Camera does not expose focus_auto; cannot configure locked autofocus"
                return 0
            fi
            if ! has_v4l2_control "focus_absolute"; then
                log_warn "Camera does not expose focus_absolute; cannot lock current focus value"
                return 0
            fi

            if write_v4l2_control "$device" "focus_auto" "1"; then
                sleep "$FOCUS_SETTLE_TIME"
                captured_focus=$(read_v4l2_control "$device" "focus_absolute")
                if [[ -n "$captured_focus" ]]; then
                    write_v4l2_control "$device" "focus_auto" "0" || \
                        log_warn "Failed to disable autofocus after focus lock"
                    write_v4l2_control "$device" "focus_absolute" "$captured_focus" || \
                        log_warn "Failed to restore locked focus value $captured_focus"
                else
                    log_warn "Unable to read focus_absolute after autofocus settle; leaving autofocus enabled"
                fi
            else
                log_warn "Failed to enable autofocus for focus lock"
            fi
            ;;
        "manual")
            if [[ -z "$FOCUS_VALUE" ]]; then
                log_warn "FOCUS_MODE=manual but FOCUS_VALUE is empty; skipping manual focus configuration"
                return 0
            fi
            set_v4l2_control_or_warn "$device" "focus_auto" "0" "manual focus" || true
            set_v4l2_control_or_warn "$device" "focus_absolute" "$FOCUS_VALUE" "manual focus" || true
            ;;
        *)
            log_warn "Unknown FOCUS_MODE '$FOCUS_MODE'; continuing without focus configuration"
            ;;
    esac
}

run_mjpeg_server() {
    local stream_port="$1"
    local snapshot_file="$2"

    STREAM_SERVER_PORT="$stream_port" \
    STREAM_SERVER_SNAPSHOT_FILE="$snapshot_file" \
    python3 -c "$(generate_mjpeg_server_python)"
}

generate_mjpeg_server_python() {
    cat <<'PYTHON'
import os
import socket
import sys
import threading
import time

HOST = '0.0.0.0'
PORT = int(os.environ['STREAM_SERVER_PORT'])
SNAPSHOT_FILE = os.environ.get('STREAM_SERVER_SNAPSHOT_FILE', '/tmp/stream_snapshot.jpg')
SNAPSHOT_INTERVAL = 2  # Save snapshot every 2 seconds

BOUNDARY = b'--FRAME'
HEADERS = (
    b'HTTP/1.1 200 OK\r\n'
    b'Content-Type: multipart/x-mixed-replace; boundary=FRAME\r\n'
    b'Cache-Control: no-cache\r\n'
    b'Connection: close\r\n'
    b'\r\n'
)

clients = []
clients_lock = threading.Lock()
current_frame = None
frame_lock = threading.Lock()


def handle_client(conn, addr):
    try:
        conn.recv(4096)
        conn.sendall(HEADERS)

        with clients_lock:
            clients.append(conn)

        while True:
            try:
                conn.setblocking(False)
                try:
                    data = conn.recv(1, socket.MSG_PEEK)
                    if not data:
                        break
                except BlockingIOError:
                    pass
                conn.setblocking(True)

                with frame_lock:
                    frame = current_frame

                if frame:
                    try:
                        conn.sendall(BOUNDARY + b'\r\nContent-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')
                    except:
                        break

                time.sleep(0.066)
            except:
                break
    except:
        pass
    finally:
        with clients_lock:
            if conn in clients:
                clients.remove(conn)
        try:
            conn.close()
        except:
            pass


def server_thread():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f'Stream server listening on http://{HOST}:{PORT}/')

    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr))
            t.daemon = True
            t.start()
        except:
            pass


def snapshot_saver_thread():
    """Periodically save current frame to file for upload service."""
    while True:
        time.sleep(SNAPSHOT_INTERVAL)
        with frame_lock:
            frame = current_frame
        if frame:
            try:
                tmp_file = SNAPSHOT_FILE + '.tmp'
                with open(tmp_file, 'wb') as f:
                    f.write(frame)
                os.rename(tmp_file, SNAPSHOT_FILE)
            except Exception:
                pass


# Start HTTP server and snapshot saver threads.
t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

# Read MJPEG frames from stdin and publish complete JPEG frames.
buffer = b''
SOI = b'\xff\xd8'
EOI = b'\xff\xd9'

while True:
    chunk = sys.stdin.buffer.read(4096)
    if not chunk:
        break
    buffer += chunk

    while True:
        start = buffer.find(SOI)
        if start == -1:
            buffer = b''
            break

        end = buffer.find(EOI, start)
        if end == -1:
            buffer = buffer[start:]
            break

        frame = buffer[start:end+2]
        buffer = buffer[end+2:]

        with frame_lock:
            current_frame = frame
PYTHON
}

find_rpi_video_command() {
    if command -v rpicam-vid &> /dev/null; then
        echo "rpicam-vid"
    elif command -v libcamera-vid &> /dev/null; then
        echo "libcamera-vid"
    else
        return 1
    fi
}

start_rpi_stream() {
    local camera_id="$1"
    local width="$2"
    local height="$3"
    local port="$4"
    local snapshot_file="$5"
    local label="$6"
    local vid_cmd

    log_info "Starting $label RPi camera stream on port $port..."

    if ! vid_cmd=$(find_rpi_video_command); then
        log_error "No video capture tool found (rpicam-vid/libcamera-vid)"
        exit 1
    fi

    "$vid_cmd" --camera "$camera_id" \
        --width "$width" \
        --height "$height" \
        --framerate 20 \
        --codec mjpeg \
        --quality 90 \
        --nopreview \
        -t 0 \
        --inline \
        -o - 2>/dev/null | run_mjpeg_server "$port" "$snapshot_file"
}

start_usb_stream() {
    local device="$1"
    local width="$2"
    local height="$3"
    local port="$4"
    local snapshot_file="$5"
    local label="$6"

    log_info "Starting $label USB webcam stream on port $port..."

    if ! command -v ffmpeg &> /dev/null; then
        log_error "ffmpeg not found"
        exit 1
    fi

    load_camera_controls "$device"
    configure_focus "$device"

    ffmpeg -f v4l2 -input_format mjpeg \
        -video_size "${width}x${height}" \
        -framerate 20 \
        -i "$device" \
        -c:v mjpeg -q:v 5 \
        -f mjpeg - 2>/dev/null | run_mjpeg_server "$port" "$snapshot_file"
}

start_camera_stream() {
    local camera_type="$1"
    local camera_id="$2"
    local camera_device="$3"
    local width="$4"
    local height="$5"
    local port="$6"
    local snapshot_file="$7"
    local label="$8"
    local focus_mode="$9"
    local focus_value="${10}"
    local focus_settle_time="${11}"

    FOCUS_MODE="$focus_mode"
    FOCUS_VALUE="$focus_value"
    FOCUS_SETTLE_TIME="$focus_settle_time"

    case "$camera_type" in
        "RPI")
            start_rpi_stream "$camera_id" "$width" "$height" "$port" "$snapshot_file" "$label"
            ;;
        "USB")
            start_usb_stream "$camera_device" "$width" "$height" "$port" "$snapshot_file" "$label"
            ;;
        *)
            log_error "Unknown $label camera type: $camera_type"
            exit 1
            ;;
    esac
}

main() {
    load_configuration
    print_startup_banner

    if [[ "$SECOND_CAMERA_ENABLED" == "1" ]] && [[ "$STREAM_PORT" == "$SECOND_STREAM_PORT" ]]; then
        log_error "Primary and secondary stream ports must be different (both are $STREAM_PORT)"
        exit 1
    fi

    start_camera_stream "$CAMERA_TYPE" "$CAMERA_ID" "$CAMERA_DEVICE" \
        "$STREAM_WIDTH" "$STREAM_HEIGHT" "$STREAM_PORT" "$SNAPSHOT_FILE" \
        "primary" "$FOCUS_MODE" "$FOCUS_VALUE" "$FOCUS_SETTLE_TIME" &

    if [[ "$SECOND_CAMERA_ENABLED" == "1" ]]; then
        start_camera_stream "$SECOND_CAMERA_TYPE" "$SECOND_CAMERA_ID" "$SECOND_CAMERA_DEVICE" \
            "$SECOND_STREAM_WIDTH" "$SECOND_STREAM_HEIGHT" "$SECOND_STREAM_PORT" "$SECOND_SNAPSHOT_FILE" \
            "secondary" "$SECOND_FOCUS_MODE" "$SECOND_FOCUS_VALUE" "$SECOND_FOCUS_SETTLE_TIME" &
    fi

    wait
}

main "$@"
