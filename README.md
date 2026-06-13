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

## Corrected live architecture

After validation on 2026-06-13, the live path is the transparent UDP forwarder on Oracle, not an Oracle-terminating Hysteria2 server.

The client/router must keep using the original Hysteria2 auth, query parameters, and `pinSHA256` for the provided upstream node. Oracle only replaces the host/IP and relays UDP datagrams; it does not decrypt, terminate, or re-originate Hysteria2 traffic.

Live path:

- Router dae node labels: `aws12` and `aws14`
- Router-facing Oracle IPv4 node host: `138.2.238.48:44445`
- Router-facing Oracle IPv6 node host: `[2603:c024:c01d:ac00:0:c96e:e41f:6daf]:44445`
- Oracle transparent forwarder service: `hy2-udp-forwarder.service`
- Oracle listener: UDP `0.0.0.0%eth0:44445` and UDP `[::]%eth0:44445`
- Oracle upstream endpoint: `108.68.57.148:44445`
- Router dae bandwidth hints restored after correction: `bandwidth_max_tx: '60 mbps'` and `bandwidth_max_rx: '60 mbps'`

Superseded experiment:

- `hysteria-oracle-hy2.service` was tested on UDP `:44446` as an Oracle-terminating Hysteria2 server.
- That mode was disabled because it makes Oracle the Hysteria2 endpoint, which is not the intended architecture when the provided upstream HY2 node must remain the endpoint.
- Verified corrected state: `hysteria-oracle-hy2.service` is `inactive` and `disabled`; no UDP `44446` listener is required for the live path.

Router-side correction recorded during restoration:

- Removed the mistaken `oracle_hy2` node and proxy-group filter.
- Reactivated the forwarded-node filters `aws12`, `aws13`, and `aws14` in the main `proxy` group.
- Kept direct anti-loop rules for Oracle forwarder reachability checks:
  - `pname(hysteria) -> must_direct`
  - `dip(138.2.238.48) -> must_direct`
  - `dip('2603:c024:c01d:ac00:0:c96e:e41f:6daf') -> must_direct`
- Router restore backup: `/etc/dae/config.dae.sisyphus-backup-restore-forwarder-20260613-094655`

Validation indicators recorded after correction:

- Oracle `hy2-udp-forwarder.service` returned `active` and `enabled`.
- Oracle `hysteria-oracle-hy2.service` returned `inactive` and `disabled`.
- Oracle `/etc/hy2-udp-forwarder/config.env` showed `UPSTREAM_HOST="108.68.57.148"`, `UPSTREAM_PORT="44445"`, `LISTEN_PORT="44445"`, and `LISTEN_INTERFACE=eth0`.
- Router `dae.service` returned `active` and `dae validate -c /etc/dae/config.dae` succeeded.
- Sanitized router config showed active `aws12`/`aws14` Hysteria2 nodes pointing at Oracle `:44445`, while preserving the original HY2 auth and certificate pin end-to-end.

Security notes for this mode:

- Do not commit Hysteria2 passwords, full dae node URIs, private keys, or certificate fingerprints.
- The public README may document endpoint IPs, ports, service paths, and sanitized routing rules only.
- Temporary router-side test configs must be stored under `/tmp` and removed after each run.

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
