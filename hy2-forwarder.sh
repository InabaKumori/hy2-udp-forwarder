#!/usr/bin/env bash
set -uo pipefail

APP="hy2-udp-forwarder"
INSTALL_DIR="/opt/$APP"
CONFIG_DIR="/etc/$APP"
CONFIG_FILE="$CONFIG_DIR/config.env"
SERVICE_FILE="/etc/systemd/system/$APP.service"
DEFAULT_PROTOCOL="hy2"
DEFAULT_LISTEN_MODE="dual"
DEFAULT_LISTEN_INTERFACE=""
DEFAULT_LISTEN_PORT="44445"
DEFAULT_UPSTREAM_HOST="108.68.57.148"
DEFAULT_UPSTREAM_PORT="44445"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo env \
      PROTOCOL="${PROTOCOL:-}" \
      LISTEN_MODE="${LISTEN_MODE:-}" \
      LISTEN_INTERFACE="${LISTEN_INTERFACE:-}" \
      LISTEN_IP="${LISTEN_IP:-}" \
      LISTEN_PORT="${LISTEN_PORT:-}" \
      UPSTREAM_URI="${UPSTREAM_URI:-}" \
      UPSTREAM_HOST="${UPSTREAM_HOST:-}" \
      UPSTREAM_PORT="${UPSTREAM_PORT:-}" \
      bash "$0" "$@"
  fi
}

parse_upstream_uri() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

uri = sys.argv[1]
parsed = urlsplit(uri)
if parsed.scheme not in {"hysteria2", "hy2"}:
    raise SystemExit("unsupported URI scheme")
if not parsed.hostname or not parsed.port:
    raise SystemExit("URI must include host and port")
print(parsed.hostname)
print(parsed.port)
PY
}

load_config() {
  PROTOCOL="${PROTOCOL:-$DEFAULT_PROTOCOL}"
  LISTEN_MODE="${LISTEN_MODE:-$DEFAULT_LISTEN_MODE}"
  LISTEN_INTERFACE="${LISTEN_INTERFACE:-$DEFAULT_LISTEN_INTERFACE}"
  LISTEN_IP="${LISTEN_IP:-}"
  LISTEN_PORT="${LISTEN_PORT:-$DEFAULT_LISTEN_PORT}"
  UPSTREAM_HOST="${UPSTREAM_HOST:-$DEFAULT_UPSTREAM_HOST}"
  UPSTREAM_PORT="${UPSTREAM_PORT:-$DEFAULT_UPSTREAM_PORT}"

  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi

  if [ -n "${UPSTREAM_URI:-}" ]; then
    mapfile -t parsed < <(parse_upstream_uri "$UPSTREAM_URI") || die "failed to parse UPSTREAM_URI"
    UPSTREAM_HOST="${parsed[0]}"
    UPSTREAM_PORT="${parsed[1]}"
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF_CONFIG
PROTOCOL="$PROTOCOL"
LISTEN_MODE="$LISTEN_MODE"
LISTEN_INTERFACE="$LISTEN_INTERFACE"
LISTEN_IP="$LISTEN_IP"
LISTEN_PORT="$LISTEN_PORT"
UPSTREAM_HOST="$UPSTREAM_HOST"
UPSTREAM_PORT="$UPSTREAM_PORT"
EOF_CONFIG
  chmod 600 "$CONFIG_FILE"
}

install_files() {
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/udp_forwarder.py" <<'PY'
#!/usr/bin/env python3
import argparse
import errno
import selectors
import socket
import time


BUFFER_SIZE = 65535
SOCKET_BUFFER_SIZE = 16 * 1024 * 1024
TRANSIENT_SEND_ERRORS = {errno.EAGAIN, errno.EWOULDBLOCK, errno.ENOBUFS}


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def tune_udp_socket(sock):
    for opt in (socket.SO_RCVBUF, socket.SO_SNDBUF):
        try:
            sock.setsockopt(socket.SOL_SOCKET, opt, SOCKET_BUFFER_SIZE)
        except OSError:
            pass


def bind_to_interface(sock, interface):
    if not interface:
        return
    opt = getattr(socket, "SO_BINDTODEVICE", 25)
    try:
        sock.setsockopt(socket.SOL_SOCKET, opt, interface.encode() + b"\0")
    except OSError as exc:
        raise SystemExit(f"failed to bind listener to interface {interface}: {exc}")


def same_endpoint(left, right):
    return left[0] == right[0] and left[1] == right[1]


def close_session(selector, sessions, upstream_by_fd, session_key, reason=None):
    session = sessions.pop(session_key, None)
    if session is None:
        return
    upstream = session["upstream"]
    upstream_by_fd.pop(upstream.fileno(), None)
    try:
        selector.unregister(upstream)
    except Exception:
        pass
    upstream.close()
    if reason:
        log(f"closed session {session['client']}: {reason}")


def build_listeners(mode, listen_ip, listen_interface, port):
    binds = []
    if mode == "dual":
        binds = [(socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")]
    elif mode == "ipv4":
        binds = [(socket.AF_INET, "0.0.0.0")]
    elif mode == "ipv6":
        binds = [(socket.AF_INET6, "::")]
    elif mode == "custom":
        family = socket.AF_INET6 if ":" in listen_ip else socket.AF_INET
        binds = [(family, listen_ip)]
    else:
        raise SystemExit(f"unsupported listen mode: {mode}")

    sockets = []
    for family, host in binds:
        sock = socket.socket(family, socket.SOCK_DGRAM)
        tune_udp_socket(sock)
        bind_to_interface(sock, listen_interface)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((host, port))
        sock.setblocking(False)
        sockets.append(sock)
    return sockets


def main():
    parser = argparse.ArgumentParser(description="UDP relay for Hysteria2/QUIC nodes")
    parser.add_argument("--protocol", default="hy2", choices=["hy2"])
    parser.add_argument("--listen-mode", default="dual", choices=["dual", "ipv4", "ipv6", "custom"])
    parser.add_argument("--listen-ip", default="")
    parser.add_argument("--listen-interface", default="")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--session-timeout", type=int, default=180)
    args = parser.parse_args()

    upstream_infos = socket.getaddrinfo(args.upstream_host, args.upstream_port, socket.AF_UNSPEC, socket.SOCK_DGRAM)
    if not upstream_infos:
        raise SystemExit("could not resolve upstream")
    upstream_family, _, _, _, upstream_addr = upstream_infos[0]

    selector = selectors.DefaultSelector()
    listeners = build_listeners(args.listen_mode, args.listen_ip, args.listen_interface, args.listen_port)
    listener_by_fd = {}
    sessions = {}
    upstream_by_fd = {}

    for listener in listeners:
        selector.register(listener, selectors.EVENT_READ, "listener")
        listener_by_fd[listener.fileno()] = listener
        log(f"listening on {listener.getsockname()} -> {upstream_addr}")

    while True:
        now = time.time()
        for key, _ in selector.select(timeout=1):
            sock = key.fileobj
            role = key.data
            if role == "listener":
                try:
                    data, client_addr = sock.recvfrom(BUFFER_SIZE)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    log(f"listener receive failed on {sock.getsockname()}: {exc}")
                    continue
                session_key = (sock.fileno(), client_addr)
                session = sessions.get(session_key)
                if session is None:
                    upstream = socket.socket(upstream_family, socket.SOCK_DGRAM)
                    tune_udp_socket(upstream)
                    upstream.setblocking(False)
                    selector.register(upstream, selectors.EVENT_READ, "upstream")
                    session = {"listener": sock, "client": client_addr, "upstream": upstream, "last": now}
                    sessions[session_key] = session
                    upstream_by_fd[upstream.fileno()] = session_key
                session["last"] = now
                try:
                    session["upstream"].sendto(data, upstream_addr)
                except OSError as exc:
                    if exc.errno not in TRANSIENT_SEND_ERRORS:
                        close_session(selector, sessions, upstream_by_fd, session_key, f"upstream send failed: {exc}")
            else:
                session_key = upstream_by_fd.get(sock.fileno())
                if session_key is None:
                    continue
                session = sessions.get(session_key)
                if session is None:
                    continue
                try:
                    data, source_addr = sock.recvfrom(BUFFER_SIZE)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    close_session(selector, sessions, upstream_by_fd, session_key, f"upstream receive failed: {exc}")
                    continue
                if not same_endpoint(source_addr, upstream_addr):
                    log(f"ignored packet from unexpected upstream {source_addr}")
                    continue
                session["last"] = now
                try:
                    session["listener"].sendto(data, session["client"])
                except OSError as exc:
                    if exc.errno not in TRANSIENT_SEND_ERRORS:
                        close_session(selector, sessions, upstream_by_fd, session_key, f"client send failed: {exc}")

        expired = [k for k, v in sessions.items() if now - v["last"] > args.session_timeout]
        for session_key in expired:
            close_session(selector, sessions, upstream_by_fd, session_key)


if __name__ == "__main__":
    main()
PY

  cat > "$INSTALL_DIR/run.sh" <<'RUN'
#!/usr/bin/env bash
set -uo pipefail
. /etc/hy2-udp-forwarder/config.env
LISTEN_INTERFACE="${LISTEN_INTERFACE:-}"
exec /usr/bin/python3 /opt/hy2-udp-forwarder/udp_forwarder.py \
  --protocol "$PROTOCOL" \
  --listen-mode "$LISTEN_MODE" \
  --listen-ip "$LISTEN_IP" \
  --listen-interface "$LISTEN_INTERFACE" \
  --listen-port "$LISTEN_PORT" \
  --upstream-host "$UPSTREAM_HOST" \
  --upstream-port "$UPSTREAM_PORT"
RUN

  chmod 755 "$INSTALL_DIR/udp_forwarder.py" "$INSTALL_DIR/run.sh"
}

install_service() {
  cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=HY2 UDP Forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/run.sh
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable "$APP" >/dev/null
}

install_performance_tuning() {
  cat > /etc/sysctl.d/99-hy2-forwarder-performance.conf <<'EOF_SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 250000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF_SYSCTL
  sysctl --system >/dev/null 2>&1 || true
}

open_local_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$LISTEN_PORT/udp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$LISTEN_PORT/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

install_or_update() {
  load_config
  write_config
  install_files
  install_service
  install_performance_tuning
  open_local_firewall
  systemctl restart "$APP"
  say "Installed and started $APP."
  show_status
}

start_service() {
  systemctl start "$APP"
  show_status
}

stop_service() {
  systemctl stop "$APP" || true
  say "Stopped $APP."
}

uninstall_service() {
  systemctl disable --now "$APP" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
  say "Uninstalled $APP."
}

show_status() {
  systemctl --no-pager --full status "$APP" || true
  ss -lunp | grep -E ":$LISTEN_PORT\b" || true
}

show_nodes() {
  load_config
  ipv4=$(curl -4 -fsS https://api.ipify.org 2>/dev/null || true)
  ipv6=$(curl -6 -fsS https://api64.ipify.org 2>/dev/null || true)
  say "Forwarder listens on UDP port $LISTEN_PORT."
  [ -n "$ipv4" ] && say "Use IPv4 host: $ipv4"
  [ -n "$ipv6" ] && say "Use IPv6 host: [$ipv6]"
  say "Keep the original HY2 password/query/pin. Replace only the host with the address above."
}

select_protocol() {
  say "Available protocols:"
  say "1) hy2"
  read -r -p "Select protocol [1]: " choice
  case "${choice:-1}" in
    1) PROTOCOL="hy2" ;;
    *) warn "Unsupported protocol; keeping $PROTOCOL" ;;
  esac
}

select_listen_ip() {
  say "Listen IP mode:"
  say "1) dual - all IPv4 and all IPv6"
  say "2) ipv4 - all IPv4 only"
  say "3) ipv6 - all IPv6 only"
  say "4) custom - one specific IP"
  read -r -p "Select listen IP mode [1]: " choice
  case "${choice:-1}" in
    1) LISTEN_MODE="dual"; LISTEN_IP="" ;;
    2) LISTEN_MODE="ipv4"; LISTEN_IP="" ;;
    3) LISTEN_MODE="ipv6"; LISTEN_IP="" ;;
    4) LISTEN_MODE="custom"; read -r -p "Custom listen IP: " LISTEN_IP ;;
    *) warn "Invalid choice; keeping $LISTEN_MODE" ;;
  esac
}

configure_menu() {
  load_config
  while true; do
    say ""
    say "Configure $APP"
    say "1) Select protocol          [$PROTOCOL]"
    say "2) Select listen IP mode    [$LISTEN_MODE ${LISTEN_IP}]"
    say "3) Set listen port          [$LISTEN_PORT]"
    say "4) Set upstream host        [$UPSTREAM_HOST]"
    say "5) Set upstream port        [$UPSTREAM_PORT]"
    say "6) Set listen interface    [$LISTEN_INTERFACE]"
    say "7) Save and restart"
    say "0) Back"
    read -r -p "Choice: " choice
    case "$choice" in
      1) select_protocol ;;
      2) select_listen_ip ;;
      3) read -r -p "Listen UDP port: " LISTEN_PORT ;;
      4) read -r -p "Upstream host: " UPSTREAM_HOST ;;
      5) read -r -p "Upstream UDP port: " UPSTREAM_PORT ;;
      6) read -r -p "Listen interface, blank for kernel default: " LISTEN_INTERFACE ;;
      7) write_config; install_or_update; return ;;
      0) return ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

main_menu() {
  need_root "$@"
  load_config
  while true; do
    say ""
    say "$APP menu"
    say "1) Install or update"
    say "2) Configure"
    say "3) Start"
    say "4) Stop"
    say "5) Status"
    say "6) Show client IP replacement info"
    say "7) Uninstall"
    say "0) Exit"
    read -r -p "Choice: " choice
    case "$choice" in
      1) install_or_update ;;
      2) configure_menu ;;
      3) start_service ;;
      4) stop_service ;;
      5) show_status ;;
      6) show_nodes ;;
      7) read -r -p "Uninstall $APP? [y/N] " yn; [ "$yn" = "y" ] || [ "$yn" = "Y" ] && uninstall_service ;;
      0) exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

noninteractive() {
  need_root "$@"
  case "${1:-}" in
    --install) install_or_update ;;
    --start) load_config; start_service ;;
    --stop) load_config; stop_service ;;
    --status) load_config; show_status ;;
    --uninstall) uninstall_service ;;
    --show-nodes) show_nodes ;;
    *) main_menu "$@" ;;
  esac
}

case "${1:-}" in
  --install|--start|--stop|--status|--uninstall|--show-nodes) noninteractive "$@" ;;
  *) main_menu "$@" ;;
esac
