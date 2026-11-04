# Persistent & Resilient k3s API Access

This document details the configuration, security trade-offs, and operational runbook for persistent, resilient access to the homelab k3s API server without relying on manual, fragile SSH tunnels (`ssh -L 6443:localhost:6443`).

---

## 1. Overview & Strategy Comparison

Running ad-hoc background SSH tunnels introduces operational failure modes:
- Tunnels collapse during laptop sleep, network switches (Wi-Fi to Ethernet/mobile), or SSH daemon timeouts.
- Local processes receive `connection refused` or `connection reset by peer` without automatic recovery.
- Multi-terminal workflows require redundant tunnels or brittle PID-file management.

Three resilient access patterns are supported:

| Access Method | Security Model | Client Requirements | Overhead / Resilience | Recommendation |
|---|---|---|---|---|
| **Tailscale Mesh VPN** | Zero-trust private overlay (WireGuard), port 6443 bound to VPN interface | Tailscale client installed on workstation | Auto-reconnect across sleep/roaming; no public port exposure | **Recommended for production & daily operations** |
| **Direct TLS SAN + Firewall** | mTLS client certificates, port 6443 exposed publicly or restricted by UFW | Native `kubectl` only | Direct TCP, minimal latency; requires strict firewalling | **Convenient alternative if VPN client cannot run** |
| **Cloudflare Zero Trust** | Authenticated reverse proxy via Cloudflare Access | `cloudflared access tcp` daemon on workstation | Identity-aware SSO login; adds local proxy hop | **Best for browser-based UI or remote teams** |

---

## 2. Server Configuration: k3s TLS SANs

By default, k3s signs its API server certificate with a self-signed CA and restricts Subject Alternative Names (SANs) to `localhost`, `127.0.0.1`, and internal Kubernetes Service CIDR addresses (`10.43.0.1`). Connecting via public IP, custom domain, or Tailscale IP results in:

```text
Unable to connect to the server: x509: certificate is valid for 127.0.0.1, 10.43.0.1, not <target-host>
```

### Configuring `/etc/rancher/k3s/config.yaml`

On the k3s server node (e.g. Hostinger VPS), configure all hostnames and IP addresses that will be used to access the API:

```yaml
# /etc/rancher/k3s/config.yaml
tls-san:
  - "187.77.241.62"        # Public VPS IPv4
  - "k8s.sputinik.tech"    # Public or internal DNS domain
  - "homelab-vps"          # Tailscale MagicDNS hostname
  - "100.64.0.1"           # Node Tailscale IPv4 address (replace with assigned IP)
```

Apply the configuration by restarting the k3s systemd service:

```bash
sudo systemctl restart k3s
```

> **Note on Certificate Regeneration:**
> When the k3s server starts, it inspects `/etc/rancher/k3s/config.yaml`. If entries in `tls-san` are not yet included in the serving certificate at `/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt`, k3s automatically regenerates the server certificate and dynamically reloads it without requiring cluster downtime.

### Verifying Certificate SANs

Run the following command from the host or any machine that can reach port 6443:

```bash
echo | openssl s_client -connect 127.0.0.1:6443 2>/dev/null | openssl x509 -noout -text | grep -A 2 "Subject Alternative Name"
```

Expected output:
```text
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:localhost, DNS:k8s.sputinik.tech, DNS:homelab-vps, IP Address:127.0.0.1, IP Address:10.43.0.1, IP Address:187.77.241.62, IP Address:100.64.0.1
```

---

## 3. Automated Tailscale Node Setup

To enable Zero-Trust private network access without opening port 6443 to the public internet:

### Setup on the VPS Node

Execute `scripts/setup-tailscale.sh`:

```bash
# Non-interactive with auth key:
sudo ./scripts/setup-tailscale.sh --auth-key tskey-auth-xxxx --configure-k3s-san --restart-k3s

# Interactive login:
sudo ./scripts/setup-tailscale.sh --hostname homelab-vps --configure-k3s-san --restart-k3s
```

The script performs the following actions:
1. Installs the official Tailscale package repository and binary if missing.
2. Starts and enables the `tailscaled` daemon.
3. Authenticates the node to your Tailnet under the specified hostname.
4. Appends the assigned Tailscale IP (`100.x.y.z`) to `/etc/rancher/k3s/config.yaml`.
5. Restarts `k3s` to issue certificates with the new SAN.

### Hardening the VPS Firewall (UFW)

Restrict port 6443 so it is accessible **only** through the encrypted Tailscale interface (`tailscale0`):

```bash
# Allow Tailscale interface traffic on 6443
sudo ufw allow in on tailscale0 to any port 6443 proto tcp

# Deny external access to 6443 from the public interface (if previously allowed)
sudo ufw delete allow 6443/tcp 2>/dev/null || true
sudo ufw reload
```

---

## 4. Local Workstation Setup

Once the server SANs and network route are configured, generate the local kubeconfig on your developer workstation using `scripts/setup-access.sh` or the `Makefile`.

### Method A: Via Makefile (Recommended)

```bash
# Retrieve credentials over SSH and point to the Tailscale IP:
SERVER=100.64.0.1 REMOTE_HOST=root@187.77.241.62 make access

# Or point to the public domain with TLS SAN:
SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 make access

# Safely merge into ~/.kube/config:
SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 MERGE=1 make access
```

### Method B: Using `scripts/setup-access.sh` Directly

The script isolates credentials to `~/.kube/config-k3s-homelab` with strict permissions (`0600`) and validates the connection immediately:

```bash
# Fetch from remote server and save to dedicated kubeconfig:
./scripts/setup-access.sh \
  --remote-host root@187.77.241.62 \
  --server 187.77.241.62

# Output:
# Wrote cluster kubeconfig to: ~/.kube/config-k3s-homelab
# Verifying cluster connectivity at https://187.77.241.62:6443...
# Connection verified successfully.
# NAME           STATUS   ROLES                  AGE    VERSION
# homelab-vps    Ready    control-plane,master   14d    v1.35.4+k3s1
```

To switch context in your current shell:

```bash
export KUBECONFIG=~/.kube/config-k3s-homelab
kubectl get nodes
```

---

## 5. Troubleshooting Runbook

### Symptom: `x509: certificate is valid for ..., not <HOST>`

**Root Cause:** The hostname or IP used in `server:` in kubeconfig is missing from `/etc/rancher/k3s/config.yaml`.

**Remediation:**
1. SSH into the server: `ssh user@<vps-ip>`.
2. Add the requested host/IP under `tls-san` in `/etc/rancher/k3s/config.yaml`.
3. Restart k3s: `sudo systemctl restart k3s`.
4. Re-run `./scripts/setup-access.sh --server <HOST>`.

### Symptom: `dial tcp <HOST>:6443: connect: connection refused`

**Root Cause:** k3s service is stopped or crashed.

**Remediation:**
1. Check k3s status: `sudo systemctl status k3s`.
2. Review recent k3s logs: `sudo journalctl -u k3s -n 50 --no-pager`.
3. Verify k3s is listening on port 6443: `sudo ss -tulpn | grep 6443`.

### Symptom: `i/o timeout` when running `kubectl`

**Root Cause:** Network firewall (UFW, cloud provider security groups, or ISP) is dropping SYN packets on port 6443.

**Remediation:**
1. Check VPS firewall: `sudo ufw status verbose`.
2. Ensure either:
   - Port 6443 is permitted from your public IP: `sudo ufw allow from <MY_IP> to any port 6443 proto tcp`.
   - OR Tailscale is connected on both client and host: `tailscale status`.
3. Test TCP reachability with `nc`: `nc -zv -w 5 <HOST> 6443`.
