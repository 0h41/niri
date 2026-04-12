#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
    echo "This script must be invoked via sudo by the target user." >&2
    exit 1
fi

SCRIPT_DIR=$(
    CDPATH= cd -- "$(dirname -- "$0")"
    pwd
)
BINARY_PATH="$SCRIPT_DIR/target/release/niri"

if [ ! -x "$BINARY_PATH" ]; then
    echo "Expected built binary at $BINARY_PATH" >&2
    echo "Build it first with: cargo build --release" >&2
    exit 1
fi

TARGET_USER=$SUDO_USER
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GROUP=$(id -gn "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not determine home directory for $TARGET_USER" >&2
    exit 1
fi

LOCAL_BIN_DIR="$TARGET_HOME/.local/bin"
SYSTEMD_USER_DIR="$TARGET_HOME/.config/systemd/user"

install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$LOCAL_BIN_DIR"
install -d -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SYSTEMD_USER_DIR"

install -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$BINARY_PATH" "$LOCAL_BIN_DIR/niri"

SESSION_SCRIPT=$(mktemp)
SERVICE_UNIT=$(mktemp)
SHUTDOWN_UNIT=$(mktemp)
cleanup() {
    rm -f "$SESSION_SCRIPT" "$SERVICE_UNIT" "$SHUTDOWN_UNIT"
}
trap cleanup EXIT INT TERM

cat >"$SESSION_SCRIPT" <<'EOF'
#!/bin/sh

if [ -n "${MANAGERPID:-}" ] && [ "${SYSTEMD_EXEC_PID:-}" = "$$" ]; then
    case "$(ps -p "$MANAGERPID" -o cmd=)" in
    *systemd*--user*)
        exec "$HOME/.local/bin/niri" --session
        ;;
    esac
fi

if ! command -v systemctl >/dev/null 2>&1; then
    exec "$HOME/.local/bin/niri" --session
fi

if systemctl --user -q is-active niri.service; then
    echo 'A niri session is already running.'
    exit 1
fi

systemctl --user reset-failed
systemctl --user import-environment

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --all
fi

systemctl --user --wait start niri.service
systemctl --user start --job-mode=replace-irreversibly niri-shutdown.target
systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET
EOF

cat >"$SERVICE_UNIT" <<'EOF'
[Unit]
Description=A scrollable-tiling Wayland compositor
BindsTo=graphical-session.target
Before=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
Wants=xdg-desktop-autostart.target
Before=xdg-desktop-autostart.target

[Service]
Slice=session.slice
Type=notify
ExecStart=%h/.local/bin/niri --session
EOF

cat >"$SHUTDOWN_UNIT" <<'EOF'
[Unit]
Description=Shutdown running niri session
DefaultDependencies=no
StopWhenUnneeded=true
Conflicts=graphical-session.target graphical-session-pre.target
After=graphical-session.target graphical-session-pre.target
EOF

install -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SESSION_SCRIPT" "$LOCAL_BIN_DIR/niri-session"
install -m 644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SERVICE_UNIT" "$SYSTEMD_USER_DIR/niri.service"
install -m 644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SHUTDOWN_UNIT" "$SYSTEMD_USER_DIR/niri-shutdown.target"

if command -v runuser >/dev/null 2>&1 && [ -d "/run/user/$TARGET_UID" ]; then
    XDG_RUNTIME_DIR="/run/user/$TARGET_UID"
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    runuser -u "$TARGET_USER" -- env \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        systemctl --user daemon-reload || true
fi

cat <<EOF
Installed source-built niri session for $TARGET_USER.

Files installed:
  $LOCAL_BIN_DIR/niri
  $LOCAL_BIN_DIR/niri-session
  $SYSTEMD_USER_DIR/niri.service
  $SYSTEMD_USER_DIR/niri-shutdown.target

Your ~/.zshrc already starts 'niri-session' on tty1, and ~/.local/bin is ahead of /usr/bin in PATH,
so the local session wrapper will be used automatically.

Before uninstalling the package, log out and log back into tty1 once to confirm the user-local session works.
EOF
