# HY2 UDP Forwarder

Reusable Linux menu installer for forwarding a Hysteria2/QUIC UDP node through another server.

The forwarder is a userspace UDP relay. This matters because it can accept both IPv4 and IPv6 clients on the Oracle server and relay them to an IPv4-only upstream Hysteria2 endpoint. The upstream TLS certificate and `pinSHA256` remain valid because the relay does not terminate Hysteria2; it only forwards UDP datagrams.

## One-line install

```bash
UPSTREAM_HOST=108.68.57.148 UPSTREAM_PORT=44445 LISTEN_PORT=44445 LISTEN_MODE=dual PROTOCOL=hy2 bash <(curl -fsSL https://raw.githubusercontent.com/InabaKumori/hy2-udp-forwarder/main/hy2-forwarder.sh) --install
```

Interactive menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/InabaKumori/hy2-udp-forwarder/main/hy2-forwarder.sh)
```

## Menu options

- Install or update
- Configure
- Start
- Stop
- Status
- Show client IP replacement info
- Uninstall

The configure menu includes:

- Select protocol: currently `hy2`
- Select listen IP mode: dual, IPv4 only, IPv6 only, or custom IP
- Set listen UDP port
- Set upstream host
- Set upstream UDP port

## Client usage

Keep the original Hysteria2 URI password, query parameters, and `pinSHA256`.

Change only the host/IP in the node to the forwarder server:

- IPv4: `138.2.238.48`
- IPv6: use the Oracle server IPv6 in brackets if your client requires URI bracket notation

The port remains `44445` unless you configure another listen port.

## Service paths

- Service: `hy2-udp-forwarder.service`
- Install dir: `/opt/hy2-udp-forwarder`
- Config: `/etc/hy2-udp-forwarder/config.env`

## Commands

```bash
systemctl status hy2-udp-forwarder
systemctl restart hy2-udp-forwarder
systemctl stop hy2-udp-forwarder
```

Uninstall:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/InabaKumori/hy2-udp-forwarder/main/hy2-forwarder.sh) --uninstall
```

## Security notes

- Do not commit Hysteria2 passwords or private node URIs to this repository.
- The installer stores only upstream host and port by default.
- The relay does not decrypt or inspect Hysteria2 traffic.
