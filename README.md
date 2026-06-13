# HY2 UDP Forwarder

Reusable Linux menu installer for forwarding a Hysteria2/QUIC UDP node through another server.

The forwarder is a userspace UDP relay. This matters because it can accept both IPv4 and IPv6 clients on the Oracle server and relay them to an IPv4-only upstream Hysteria2 endpoint. The upstream TLS certificate and `pinSHA256` remain valid because the relay does not terminate Hysteria2; it only forwards UDP datagrams.

## One-line install

```bash
UPSTREAM_HOST=108.68.57.148 UPSTREAM_PORT=44445 LISTEN_PORT=44445 LISTEN_MODE=dual PROTOCOL=hy2 bash <(curl -fsSL https://raw.githubusercontent.com/InabaKumori/hy2-udp-forwarder/main/hy2-forwarder.sh) --install
```

If the server uses a VPN/WARP interface for outbound traffic, pin the public listener to the public NIC so replies to clients do not leave through the VPN interface:

```bash
UPSTREAM_HOST=108.68.57.148 UPSTREAM_PORT=44445 LISTEN_PORT=44445 LISTEN_MODE=dual LISTEN_INTERFACE=eth0 PROTOCOL=hy2 bash <(curl -fsSL https://raw.githubusercontent.com/InabaKumori/hy2-udp-forwarder/main/hy2-forwarder.sh) --install
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
- Set listen interface, optional; use the public NIC such as `eth0` when outbound VPN/WARP routing is enabled
- Set upstream host
- Set upstream UDP port

## Client usage

Keep the original Hysteria2 URI password, query parameters, and `pinSHA256`.

Change only the host/IP in the node to the forwarder server:

- IPv4: `138.2.238.48`
- IPv6: use the Oracle server IPv6 in brackets if your client requires URI bracket notation

The port remains `44445` unless you configure another listen port.

## Current deployment

Configured on 2026-06-13 for the Oracle forwarder server.

- GitHub project: `https://github.com/InabaKumori/hy2-udp-forwarder`
- Service: `hy2-udp-forwarder.service`
- Service state verified: `active` and `enabled`
- Install directory: `/opt/hy2-udp-forwarder`
- Config file: `/etc/hy2-udp-forwarder/config.env`
- Public listener: UDP `0.0.0.0:44445` and UDP `[::]:44445`
- Listener interface: `eth0`, to keep client-facing replies on the Oracle public NIC while upstream traffic can still use WARP
- Upstream endpoint: `108.68.57.148:44445`
- Inbound/client IPv4 target: `138.2.238.48`
- Inbound/client IPv6 target: `2603:c024:c01d:ac00:0:c96e:e41f:6daf`
- Outbound IPv4 observed from the VPS: `104.28.233.73`
- Outbound IPv6 observed from the VPS: `2603:c024:c01d:ac00:0:c96e:e41f:6daf`

Validation indicators recorded during deployment:

- `systemctl is-active hy2-udp-forwarder` returned `active`.
- `systemctl is-enabled hy2-udp-forwarder` returned `enabled`.
- `ss -lunp` showed the Python relay bound to UDP `44445` on both IPv4 and IPv6.
- A UDP probe sent to `138.2.238.48:44445` created an upstream relay socket to `108.68.57.148:44445`.
- Packet capture after the interface pin showed client replies leaving via `eth0`, while upstream packets still used `wgcf`/WARP.

Performance tuning recorded during testing:

- Relay sockets request 16 MiB receive/send buffers.
- Installer writes `/etc/sysctl.d/99-hy2-forwarder-performance.conf` with larger UDP/socket buffers and backlog.
- The relay treats transient UDP send pressure (`EAGAIN`, `EWOULDBLOCK`, `ENOBUFS`) as packet drop instead of closing the client session.
- Controlled IPv6-client-to-Oracle relay tests exceeded the 50 Mbps target: 60 Mbps target delivered about 58 Mbps upload to the upstream-side receiver and about 52 Mbps download to the client; 80 Mbps target still delivered about 59 Mbps download.

IPv6 cloud ingress requirement:

- The VM host firewall allows IPv6 UDP, but OCI security lists/NSGs must also allow inbound IPv6 UDP `44445` from the intended client source range, for example `::/0` if the node is public.
- Symptom when the OCI IPv6 UDP ingress rule is missing: IPv6 ping reaches the VM, `ss -lunp` shows `[::]:44445`, but `tcpdump -ni any 'ip6 and udp port 44445'` captures zero client UDP packets.

For this deployment, clients should keep the original Hysteria2 password, query parameters, and `pinSHA256`, then change only the node host/IP:

- IPv4 host: `138.2.238.48`
- IPv6 host: `[2603:c024:c01d:ac00:0:c96e:e41f:6daf]`
- Port: `44445`

## Oracle Hysteria2 server deployment

Configured on 2026-06-13 as the router-to-Oracle encrypted Hysteria2 path.

This is separate from the transparent UDP forwarder above. The transparent forwarder keeps the original upstream Hysteria2 session intact, while this service terminates Hysteria2 on the Oracle server so the router-to-Oracle leg is encrypted and congestion-controlled by Hysteria itself.

- Service: `hysteria-oracle-hy2.service`
- Service state verified: `active` and `enabled`
- Binary: `/usr/local/bin/hysteria`
- Config directory: `/etc/hysteria-oracle-hy2`
- Config file: `/etc/hysteria-oracle-hy2/config.yaml`
- Public listener: UDP `:44446`
- Oracle IPv4 endpoint: `138.2.238.48:44446`
- Oracle IPv6 endpoint: `[2603:c024:c01d:ac00:0:c96e:e41f:6daf]:44446`
- Server feature enabled for validation: Hysteria built-in `speedTest: true`

Router-side dae changes recorded during deployment:

- Added node label: `oracle_hy2`
- Forced the main `proxy` group to use `oracle_hy2` only.
- Disabled the previous active `aws12`, `aws13`, and `aws14` filters in the main `proxy` group without deleting them.
- Added anti-loop rules so the Hysteria client traffic to Oracle is not captured and re-proxied by dae:
  - `pname(hysteria) -> must_direct`
  - `dip(138.2.238.48) -> must_direct`
  - `dip('2603:c024:c01d:ac00:0:c96e:e41f:6daf') -> must_direct`
- Router config backups created before replacement:
  - `/etc/dae/config.dae.sisyphus-backup-20260613-091226`
  - `/etc/dae/config.dae.sisyphus-backup-force-oracle-20260613-092454`

Validation indicators recorded during deployment:

- Oracle `systemctl is-active hysteria-oracle-hy2.service` returned `active`.
- Oracle `ss -lunp` showed `hysteria` listening on UDP `44446`.
- Router `systemctl is-active dae.service` returned `active` after each reload.
- Router `dae validate -c /etc/dae/config.dae` returned success after each config replacement.
- Packet capture confirmed router-to-Oracle UDP `44446` reached Oracle directly after the anti-loop rules. IPv4 traffic arrived from the router WAN source, and IPv6 traffic arrived from the router IPv6 source.
- Hysteria built-in speed tests from the router connected successfully with UDP enabled.

Performance observations:

- Initial 80 Mbps Hysteria target over IPv4 delivered about `49.80 Mbps` download and `48.70 Mbps` upload on a 64 MiB test.
- Initial 80 Mbps Hysteria target over IPv6 delivered about `48.99 Mbps` download and `47.79 Mbps` upload on a 64 MiB test.
- A target sweep showed the best observed download slightly above 50 Mbps: `50.22 Mbps` download at an 80 Mbps target, with upload at `49.34 Mbps`.
- After forcing the main dae `proxy` group to `oracle_hy2`, a post-change 80 Mbps Hysteria test delivered about `46.71 Mbps` download and `47.28 Mbps` upload.
- Direct router-to-Oracle TCP iperf averaged about `45.6 Mbps` receiver-side during the same session, so the remaining sub-50 Mbps result appears path/capacity-bound rather than caused by the old transparent UDP relay.

Security notes for this mode:

- Do not commit the Hysteria2 auth password, full dae node URI, private key, or certificate fingerprint.
- The public README may document the endpoint, port, service paths, and sanitized routing rules only.
- Temporary router-side Hysteria speed-test configs must be stored under `/tmp` and removed after each run.

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
