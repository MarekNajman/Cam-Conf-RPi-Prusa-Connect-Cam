#!/bin/bash
#
# Prusa Connect Camera Setup Script for Raspberry Pi
# https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
#
# This script will:
# 1. Install required dependencies (curl, v4l-utils, python3, ffmpeg)
# 2. Download and install scripts
# 3. Detect and let you select a camera (RPi Camera or USB webcam)
# 4. Configure Prusa Connect integration (token + fingerprint)
# 5. Install systemd services for auto-start on boot
# 6. Start the camera stream and upload services
#

set -e

INSTALL_DIR="/opt/prusa-cam"
REPO_URL="https://github.com/MarekNajman/Cam-Conf-RPi-Prusa-Connect-Cam"
REPO_BRANCH="camera-configuration-v2"
CONFIG_FILE="/etc/prusa_cam.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

TOTAL_STEPS=6

print_header() {
    echo ""
    echo -e "${ORANGE}========================================${NC}"
    echo -e "${ORANGE}  Prusa Connect Camera Setup${NC}"
    echo -e "${ORANGE}========================================${NC}"
    echo ""
}

print_section_header() {
    echo ""
    echo -e "${ORANGE}--- $1 ---${NC}"
}

print_step() {
    echo -e "${GREEN}[$1/$TOTAL_STEPS]${NC} $2"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

read_with_default() {
    local prompt="$1"
    local default_value="$2"
    local answer

    if [[ -n "$default_value" ]]; then
        read -p "$prompt [$default_value]: " answer < /dev/tty
        echo "${answer:-$default_value}"
    else
        read -p "$prompt: " answer < /dev/tty
        echo "$answer"
    fi
}

read_required() {
    local prompt="$1"
    local answer

    while true; do
        answer=$(read_with_default "$prompt" "")
        if [[ -n "$answer" ]]; then
            echo "$answer"
            return
        fi
        print_error "This value cannot be empty"
    done
}

read_number_with_default() {
    local prompt="$1"
    local default_value="$2"
    local answer

    while true; do
        answer=$(read_with_default "$prompt" "$default_value")
        if [[ "$answer" =~ ^[0-9]+$ ]]; then
            echo "$answer"
            return
        fi
        print_error "Please enter a numeric value"
    done
}

preflight_checks() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo bash install.sh"
        exit 1
    fi

    # Check for Raspberry Pi
    if ! grep -q "Raspberry Pi\|BCM" /proc/cpuinfo 2>/dev/null; then
        print_warning "This doesn't appear to be a Raspberry Pi"
        read -p "Continue anyway? [y/N]: " confirm < /dev/tty
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 1
        fi
    fi

    echo "This script will install and configure the Prusa Connect camera service."
    echo ""
}

# ============================================
# Install dependencies
# ============================================
install_dependencies() {
    print_step 1 "Installing dependencies..."

    apt-get update -qq

    # Core dependencies
    apt-get install -y -qq \
        curl \
        v4l-utils \
        python3 \
        ffmpeg

    echo "  Dependencies installed."
}

# ============================================
# Install application files
# ============================================
install_files() {
    print_step 2 "Setting up installation directory..."

    mkdir -p "$INSTALL_DIR"/{scripts,config,web}

    # Check if we're running from the repo directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$SCRIPT_DIR/scripts/detect_cameras.sh" ]]; then
        # Running from local repo
        echo "  Installing from local repository..."
        cp "$SCRIPT_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/"
        cp "$SCRIPT_DIR/web/"* "$INSTALL_DIR/web/" 2>/dev/null || true
        cp "$SCRIPT_DIR/config/"* "$INSTALL_DIR/config/" 2>/dev/null || true
    else
        # Download from GitHub
        echo "  Downloading from GitHub..."
        cd /tmp
        rm -rf RPi-Prusa-Connect-Cam-* 2>/dev/null || true
        curl -sL "$REPO_URL/archive/$REPO_BRANCH.tar.gz" | tar -xz
        cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/scripts/*.sh "$INSTALL_DIR/scripts/"
        cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/web/* "$INSTALL_DIR/web/" 2>/dev/null || true
        cp RPi-Prusa-Connect-Cam-$REPO_BRANCH/config/* "$INSTALL_DIR/config/" 2>/dev/null || true
        rm -rf /tmp/RPi-Prusa-Connect-Cam-*
    fi

    chmod +x "$INSTALL_DIR/scripts/"*.sh

    echo "  Scripts installed to $INSTALL_DIR"
}

# ============================================
# Camera selection wizard page
# Future pages can use the global camera values set here.
# ============================================
configure_camera() {
    print_step 3 "Detecting cameras..."
    print_section_header "Camera"

    # Source the detection script
    source "$INSTALL_DIR/scripts/detect_cameras.sh"

    # Run camera selection
    SELECTED_CAMERA=$(select_camera)

    if [[ -z "$SELECTED_CAMERA" ]]; then
        print_error "No camera selected"
        exit 1
    fi

    CAMERA_TYPE=$(echo "$SELECTED_CAMERA" | cut -d: -f1)
    CAMERA_ID=$(echo "$SELECTED_CAMERA" | cut -d: -f2)
    CAMERA_NAME=$(echo "$SELECTED_CAMERA" | cut -d: -f3-)

    # Determine camera device for USB cameras
    if [[ "$CAMERA_TYPE" == "USB" ]]; then
        CAMERA_DEVICE="$CAMERA_ID"
    else
        CAMERA_DEVICE=""
    fi

    echo ""
    echo -e "  Selected: ${GREEN}$CAMERA_NAME${NC}"
}

# ============================================
# Prusa Connect wizard page
# Collects credentials and creates a new fingerprint before writing config.
# ============================================
configure_prusa_connect() {
    print_step 4 "Configuring Prusa Connect..."
    print_section_header "Prusa Connect"

    echo "To get your camera token:"
    echo "  1. Go to https://connect.prusa3d.com"
    echo "  2. Select your printer"
    echo "  3. Go to the Camera tab"
    echo "  4. Click 'Add new other camera'"
    echo "  5. Copy the Token shown"
    echo ""

    TOKEN=$(read_required "Enter your Prusa Connect Token")

    # Generate unique fingerprint
    FINGERPRINT=$(cat /proc/sys/kernel/random/uuid)

    echo ""
    echo -e "  Generated Fingerprint: ${YELLOW}$FINGERPRINT${NC}"
    echo ""
    echo "  IMPORTANT: Save this fingerprint! You may need it to re-register"
    echo "  the camera in Prusa Connect if you reinstall."
    echo ""
}

# ============================================
# Focus wizard page
# USB cameras can opt into focus modes; Raspberry Pi cameras skip this page.
# Future image-control pages can be inserted after this function.
# ============================================
configure_focus() {
    FOCUS_MODE="auto"
    FOCUS_VALUE="0"
    FOCUS_SETTLE_TIME="2"

    if [[ "$CAMERA_TYPE" != "USB" ]]; then
        return
    fi

    print_section_header "Focus"
    echo "Select focus mode:"
    echo "  1) Automatic (recommended)"
    echo "  2) Continuous autofocus"
    echo "  3) Focus lock"
    echo "  4) Manual focus"
    echo ""

    while true; do
        focus_choice=$(read_with_default "Focus mode" "1")
        case "$focus_choice" in
            1)
                FOCUS_MODE="auto"
                break
                ;;
            2)
                FOCUS_MODE="continuous"
                break
                ;;
            3)
                FOCUS_MODE="lock"
                break
                ;;
            4)
                FOCUS_MODE="manual"
                FOCUS_VALUE=$(read_number_with_default "Manual focus value" "0")
                break
                ;;
            *)
                print_error "Please choose 1, 2, 3, or 4"
                ;;
        esac
    done

    FOCUS_SETTLE_TIME=$(read_number_with_default "Focus settle time in seconds" "$FOCUS_SETTLE_TIME")
}

# ============================================
# Stream wizard page
# Collects stream resolution and port before the single config write.
# ============================================
configure_stream() {
    STREAM_WIDTH="1280"
    STREAM_HEIGHT="720"
    STREAM_PORT="8080"

    print_section_header "Stream"
    echo "Select stream resolution:"
    echo "  1) 1920x1080"
    echo "  2) 1280x720 (recommended)"
    echo "  3) 640x480"
    echo "  4) Custom"
    echo ""

    while true; do
        resolution_choice=$(read_with_default "Stream resolution" "2")
        case "$resolution_choice" in
            1)
                STREAM_WIDTH="1920"
                STREAM_HEIGHT="1080"
                break
                ;;
            2)
                STREAM_WIDTH="1280"
                STREAM_HEIGHT="720"
                break
                ;;
            3)
                STREAM_WIDTH="640"
                STREAM_HEIGHT="480"
                break
                ;;
            4)
                STREAM_WIDTH=$(read_number_with_default "Custom stream width" "$STREAM_WIDTH")
                STREAM_HEIGHT=$(read_number_with_default "Custom stream height" "$STREAM_HEIGHT")
                break
                ;;
            *)
                print_error "Please choose 1, 2, 3, or 4"
                ;;
        esac
    done

    STREAM_PORT=$(read_number_with_default "HTTP stream port" "$STREAM_PORT")
}

# ============================================
# Write collected wizard values once
# ============================================
write_configuration() {
    cat > "$CONFIG_FILE" << EOF_CONF
# Prusa Connect Camera Configuration
# Generated on $(date)
# https://github.com/Houzvicka/RPi-Prusa-Connect-Cam

# Camera Settings
CAMERA_TYPE="$CAMERA_TYPE"
CAMERA_ID="$CAMERA_ID"
CAMERA_DEVICE="$CAMERA_DEVICE"
CAMERA_NAME="$CAMERA_NAME"

# Prusa Connect API
FINGERPRINT="$FINGERPRINT"
TOKEN="$TOKEN"

# Capture Settings
CAPTURE_WIDTH=1920
CAPTURE_HEIGHT=1080
UPLOAD_INTERVAL=10

# Focus Settings
FOCUS_MODE="$FOCUS_MODE"
FOCUS_VALUE=$FOCUS_VALUE
FOCUS_SETTLE_TIME=$FOCUS_SETTLE_TIME

# Stream Settings
STREAM_PORT=$STREAM_PORT
STREAM_WIDTH=$STREAM_WIDTH
STREAM_HEIGHT=$STREAM_HEIGHT
EOF_CONF

    chmod 600 "$CONFIG_FILE"

    echo "  Configuration saved to $CONFIG_FILE"
}

# ============================================
# Install systemd services
# ============================================
install_services() {
    print_step 5 "Installing systemd services..."

    # Prusa Connect Upload Service
    cat > /etc/systemd/system/prusa-connect-upload.service << 'EOF_SERVICE'
[Unit]
Description=Prusa Connect Camera Upload Service
Documentation=https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/prusa-cam/scripts/prusa_connect_upload.sh
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusa-connect-upload

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    # Camera Stream Service
    cat > /etc/systemd/system/camera-stream.service << 'EOF_SERVICE'
[Unit]
Description=Camera MJPEG Stream Server
Documentation=https://github.com/Houzvicka/RPi-Prusa-Connect-Cam
After=network.target

[Service]
Type=simple
ExecStart=/opt/prusa-cam/scripts/stream_server.sh
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=camera-stream

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    # Reload systemd and enable services
    systemctl daemon-reload
    systemctl enable prusa-connect-upload.service
    systemctl enable camera-stream.service

    echo "  Services installed and enabled."
}

# ============================================
# Start services
# ============================================
start_services() {
    print_step 6 "Starting services..."

    systemctl start camera-stream.service
    sleep 2
    systemctl start prusa-connect-upload.service

    echo "  Services started."
}

# ============================================
# Installation summary
# ============================================
print_summary() {
    # Get IP address
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$IP_ADDR" ]]; then
        IP_ADDR="<your-pi-ip>"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Camera Stream:"
    echo -e "  ${YELLOW}http://$IP_ADDR:$STREAM_PORT${NC}"
    echo ""
    echo "Prusa Connect:"
    echo "  Snapshots are being uploaded every 10 seconds"
    echo "  Check your printer's Camera tab in Prusa Connect"
    echo ""
    echo "Your camera fingerprint:"
    echo -e "  ${YELLOW}$FINGERPRINT${NC}"
    echo ""
    echo "Useful commands:"
    echo "  View upload logs:   journalctl -u prusa-connect-upload -f"
    echo "  View stream logs:   journalctl -u camera-stream -f"
    echo "  Restart upload:     sudo systemctl restart prusa-connect-upload"
    echo "  Restart stream:     sudo systemctl restart camera-stream"
    echo "  Edit config:        sudo nano $CONFIG_FILE"
    echo "  Uninstall:          sudo /opt/prusa-cam/uninstall.sh"
    echo ""
    echo -e "${GREEN}Enjoy your Prusa Connect camera!${NC}"
    echo ""
}

main() {
    print_header
    preflight_checks
    install_dependencies
    install_files
    configure_camera
    configure_prusa_connect
    configure_focus
    configure_stream
    write_configuration
    install_services
    start_services
    print_summary
}

main "$@"
