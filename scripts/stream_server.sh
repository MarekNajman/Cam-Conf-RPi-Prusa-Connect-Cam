#!/bin/bash
#
# Camera Stream Server Script
# Lightweight Python-based MJPEG streaming server
# - Streams live video on port 8080
# - Saves snapshots to /tmp/stream_snapshot.jpg for Prusa Connect uploads
# - All temp files in RAM (tmpfs) to protect SD card
#

CONFIG_FILE="/etc/prusa_cam.conf"

# Check if config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run the installer first."
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

config_warning() {
    echo "WARNING: $*" >&2
}

config_get() {
    local variable_name="$1"
    local default_value="$2"
    local configured_value="${!variable_name}"

    if [[ -n "$configured_value" ]]; then
        printf '%s\n' "$configured_value"
    else
        printf '%s\n' "$default_value"
    fi
}

config_get_int() {
    local variable_name="$1"
    local default_value="$2"
    local configured_value="${!variable_name}"

    if [[ -z "$configured_value" ]]; then
        printf '%s\n' "$default_value"
        return
    fi

    if [[ "$configured_value" =~ ^-?[0-9]+$ ]]; then
        printf '%s\n' "$configured_value"
    else
        config_warning "$variable_name must be an integer; using default: $default_value"
        printf '%s\n' "$default_value"
    fi
}

validate_min_int() {
    local variable_name="$1"
    local value="$2"
    local default_value="$3"
    local min_value="$4"

    if (( value >= min_value )); then
        printf '%s\n' "$value"
    else
        config_warning "$variable_name must be >= $min_value; using default: $default_value"
        printf '%s\n' "$default_value"
    fi
}

validate_int_range() {
    local variable_name="$1"
    local value="$2"
    local default_value="$3"
    local min_value="$4"
    local max_value="$5"

    if (( value >= min_value && value <= max_value )); then
        printf '%s\n' "$value"
    else
        config_warning "$variable_name must be between $min_value and $max_value; using default: $default_value"
        printf '%s\n' "$default_value"
    fi
}

load_runtime_configuration() {
    # Runtime code must use only the normalized variables assigned here.
    # Add future configuration defaults and lightweight validation in this
    # function instead of adding fallback expressions to runtime logic.
    local stream_port_default=8080
    local stream_width_default=1280
    local stream_height_default=720
    local focus_mode_default="auto"
    local focus_value_default=0
    local focus_settle_time_default=0

    CAMERA_TYPE=$(config_get CAMERA_TYPE "")
    CAMERA_ID=$(config_get CAMERA_ID "")
    CAMERA_DEVICE=$(config_get CAMERA_DEVICE "")
    CAMERA_NAME=$(config_get CAMERA_NAME "")

    STREAM_PORT=$(config_get_int STREAM_PORT "$stream_port_default")
    STREAM_PORT=$(validate_int_range STREAM_PORT "$STREAM_PORT" "$stream_port_default" 1 65535)

    STREAM_WIDTH=$(config_get_int STREAM_WIDTH "$stream_width_default")
    STREAM_WIDTH=$(validate_min_int STREAM_WIDTH "$STREAM_WIDTH" "$stream_width_default" 1)

    STREAM_HEIGHT=$(config_get_int STREAM_HEIGHT "$stream_height_default")
    STREAM_HEIGHT=$(validate_min_int STREAM_HEIGHT "$STREAM_HEIGHT" "$stream_height_default" 1)

    FOCUS_MODE=$(config_get FOCUS_MODE "$focus_mode_default")

    FOCUS_VALUE=$(config_get_int FOCUS_VALUE "$focus_value_default")
    FOCUS_VALUE=$(validate_min_int FOCUS_VALUE "$FOCUS_VALUE" "$focus_value_default" 0)

    FOCUS_SETTLE_TIME=$(config_get_int FOCUS_SETTLE_TIME "$focus_settle_time_default")
    FOCUS_SETTLE_TIME=$(validate_min_int FOCUS_SETTLE_TIME "$FOCUS_SETTLE_TIME" "$focus_settle_time_default" 0)
}

load_runtime_configuration

echo "========================================"
echo "  Camera Stream Server"
echo "========================================"
echo ""
echo "Camera Type: $CAMERA_TYPE"
echo "Camera: $CAMERA_NAME"
echo "Stream Port: $STREAM_PORT"
echo "Resolution: ${STREAM_WIDTH}x${STREAM_HEIGHT}"
echo ""

case "$CAMERA_TYPE" in
    "RPI")
        echo "Starting RPi camera stream..."

        # Determine which command to use
        if command -v rpicam-vid &> /dev/null; then
            VID_CMD="rpicam-vid"
        elif command -v libcamera-vid &> /dev/null; then
            VID_CMD="libcamera-vid"
        else
            echo "ERROR: No video capture tool found (rpicam-vid/libcamera-vid)"
            exit 1
        fi

        # Use rpicam-vid with inline MJPEG and pipe to Python HTTP server
        $VID_CMD --camera "$CAMERA_ID" \
            --width "$STREAM_WIDTH" \
            --height "$STREAM_HEIGHT" \
            --framerate 15 \
            --codec mjpeg \
            --quality 80 \
            --nopreview \
            -t 0 \
            --inline \
            -o - 2>/dev/null | python3 -c "
import sys
import socket
import threading
import time
import os

HOST = '0.0.0.0'
PORT = $STREAM_PORT
SNAPSHOT_FILE = '/tmp/stream_snapshot.jpg'
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
    \"\"\"Periodically save current frame to file for upload service\"\"\"
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
            except Exception as e:
                pass

# Start server thread
t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

# Start snapshot saver thread
ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

# Read MJPEG frames from stdin
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
"
        ;;

    "USB")
        echo "Starting USB webcam stream..."

        if ! command -v ffmpeg &> /dev/null; then
            echo "ERROR: ffmpeg not found"
            exit 1
        fi

        # Use ffmpeg + python server for USB cameras
        ffmpeg -f v4l2 -input_format mjpeg \
            -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" \
            -framerate 15 \
            -i "$CAMERA_DEVICE" \
            -c:v mjpeg -q:v 5 \
            -f mjpeg - 2>/dev/null | python3 -c "
import sys
import socket
import threading
import time
import os

HOST = '0.0.0.0'
PORT = $STREAM_PORT
SNAPSHOT_FILE = '/tmp/stream_snapshot.jpg'
SNAPSHOT_INTERVAL = 2

BOUNDARY = b'--FRAME'
HEADERS = (
    b'HTTP/1.1 200 OK\r\n'
    b'Content-Type: multipart/x-mixed-replace; boundary=FRAME\r\n'
    b'Cache-Control: no-cache\r\n'
    b'Connection: close\r\n'
    b'\r\n'
)

current_frame = None
frame_lock = threading.Lock()

def handle_client(conn, addr):
    global current_frame
    try:
        conn.recv(4096)
        conn.sendall(HEADERS)
        while True:
            with frame_lock:
                frame = current_frame
            if frame:
                try:
                    conn.sendall(BOUNDARY + b'\r\nContent-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')
                except:
                    break
            time.sleep(0.066)
    except:
        pass
    finally:
        conn.close()

def server_thread():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f'Stream server listening on http://{HOST}:{PORT}/')
    while True:
        conn, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(conn, addr))
        t.daemon = True
        t.start()

def snapshot_saver_thread():
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
            except:
                pass

t = threading.Thread(target=server_thread)
t.daemon = True
t.start()

ss = threading.Thread(target=snapshot_saver_thread)
ss.daemon = True
ss.start()

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
"
        ;;

    *)
        echo "ERROR: Unknown camera type: $CAMERA_TYPE"
        exit 1
        ;;
esac
