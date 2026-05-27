# Server Setup

## Security
### Overview
Access to the server instance is locked down to the Tailscale VPN. A Cloud Firewall restricts all inbound traffic to only what Tailscale requires, preventing any direct public access to the server or its services. iptables running on the server instance additionally blocks inbound traffic, providing a layer of defense in depth in case of misconfiguration.

Note that all outbound ports are open, to facilitate cloudflared, tailscale, and updates. See (Further Security Enhancements)

Cloudflare Tunnels are used to access individual services, and must be protected with sufficent Cloudflare Access policies to control access. SSO and MFA is recommended.

NOTE: Open SSH is disabled, tailscale-ssh is only be available over Tailscale. Appropriate user Tailscale ACLs should be implemented there to prevent privelege escalation. Assuming the keys are kept confidential, this presents a very small attack surface to the wide web.

Emergency access is available via the Cloud's VNC to fix any tailscale misconfiguration.

#### Further Security Enhancements (Out of Scope)
To further secure this instance, a layer 7 traffic inspection firewall policy should be implemented to prevent data exfiltration in the event of a compromise on outbound ports. Due to the ability to tunnel outbound traffic over http/https and similar ports that need to be left open, this presents little additional protection, unless a layer 7 firewall is utilized.

### Administering the Server
All server administration is done over the Tailscale network. Install the Tailscale client on any device you want to administer the server from:

- **macOS:** https://tailscale.com/download/macos
- **Android/iOS:** Available in respective app stores (optional; but not recommended)

Services running on the server (e.g. Komodo) are accessed directly over the Tailscale network via MagicDNS hostname. No public ports are exposed for services. iptables restricts the necessary ports on the server instance to the `tailscale0` interface. If additional administrative applications are required, add rules scoped to `tailscale0` in `/etc/iptables/rules.v4` and run `netfilter-persistent save`. No additional ports should be opened on the cloud firewall.

---

## Setup

### 1. Tailscale 
#### 1. Account

1. Sign up at [tailscale.com](https://tailscale.com) (Free tier is sufficient)
2. Install the client on your local machine
3. Enable the Tailscale network extension when prompted
4. Allow the VPN extension when prompted
5. Log in — your device should appear under **Devices** in the Tailscale admin console

#### 2. Tailnet hardening
https://login.tailscale.com/admin/settings/user-management
- Enable User Approval

https://login.tailscale.com/admin/settings/device-management
- Enable Device Approval

Further hardening of the tailnet should be done to prevent accidental access via ACLs to limit which machines/users on the tailnet can access the server; Out of scope.

#### 3. Tailscale Auth Key

The server authenticates to Tailscale automatically on first boot using an auth key.

https://login.tailscale.com/admin/settings/keys
1. Go to the Tailscale admin console → **Settings** → **Keys**
2. Generate an **Auth Key**
3. Copy the key — it goes into the cloud-config as `<tailscale-auth-key>`

##### Key Exiry
Recovery instructions if key expires:
https://tailscale.com/docs/features/access-control/key-expiry

By default, keys will expire after 90 days. 
For less security, but easier administration, this can be disabled.
https://tailscale.com/docs/features/access-control/key-expiry#disabling-key-expiry

This should allow for specifying a new key, and re-authenticating by generating a new `<tailscale-auth-key>`
`tailscale logout && tailscale up --authkey tskey-auth-XXXXXX`

### 2. SSH Key

> Not required — the server has no public SSH access. All access is via Tailscale SSH.
>
> If you want an emergency fallback, use the Hetzner/Oracle rescue console.

### 3. Cloud Config - Oracle (Alternatively, see Hetzner "Alternative Cloud - Hetzner")
https://www.oracle.com/ca-en/cloud/free


#### 1. Cloud Firewall

Create a firewall policy with the following inbound rules before provisioning the server.

| Rule Name | Protocol | Port | Notes |
|---|---|---|---|
| Tailscale | UDP | 41641 | Direct peer connections. Falls back to DERP relay if blocked. |

> **Note:** DERP relay (port 443) and STUN (port 3478) are outbound-only — Hetzner does not need inbound rules for them. There is no public SSH rule; all access is via Tailscale.

**Policy name:** `Tailscale Firewall`

#### 2. Cloud Instance

### 6. Cloud Config

Replace the placeholder values before pasting into the server instance cloud-config field.

| Placeholder | Value |
|---|---|
| `<tailscale-auth-key>` | Auth key from Tailscale admin console (Step 3) |
| `<mongo-password>` | Random strong password — `openssl rand -hex 32` |
| `<jwt-secret>` | Random string — `openssl rand -hex 32` |
| `<webhook-secret>` | Random string — `openssl rand -hex 32` |
| `<admin-password>` | Initial Komodo admin account password - `openssl rand -hex 32` |

> All placeholders can be filled before provisioning. After first boot, update `KOMODO_HOST` in `compose.env` to use the Tailscale MagicDNS hostname (Step 7). Periphery is configured separately in Step 8.

```yaml
#cloud-config
users:
  - name: cloud_user
    groups: users, admin, docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - iptables-persistent
  - curl
  - unattended-upgrades
  - apt-transport-https
  - ca-certificates
  - gnupg
package_update: true
package_upgrade: true

write_files:
  # Uncomment to enable this server as a Tailscale exit node.
  # Also requires approval in the Tailscale admin console after boot:
  # https://login.tailscale.com/admin/machines
  # - path: /etc/sysctl.d/99-tailscale.conf
  #   content: |
  #     net.ipv4.ip_forward=1
  #     net.ipv6.conf.all.forwarding=1

  - path: /etc/iptables/rules.v4
    content: |
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      # Allow established/related connections
      -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      # Allow loopback
      -A INPUT -i lo -j ACCEPT
      # Tailscale direct peer connections (falls back to DERP relay if blocked)
      -A INPUT -p udp --dport 41641 -j ACCEPT
      # SSH — Tailscale network only
      -A INPUT -i tailscale0 -p tcp --dport 22 -j ACCEPT
      # Komodo web UI — Tailscale network only
      -A INPUT -i tailscale0 -p tcp --dport 9120 -j ACCEPT
      COMMIT

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /opt/komodo/docker-compose.yml
    content: |
      services:
        mongo:
          image: mongo
          labels:
            komodo.skip:
          command: --quiet --wiredTigerCacheSizeGB 0.25
          restart: unless-stopped
          env_file: ./compose.env
          volumes:
            - mongo-data:/data/db
            - mongo-config:/data/configdb
          environment:
            MONGO_INITDB_ROOT_USERNAME: ${KOMODO_DATABASE_USERNAME}
            MONGO_INITDB_ROOT_PASSWORD: ${KOMODO_DATABASE_PASSWORD}

        core:
          image: ghcr.io/moghtech/komodo-core:${COMPOSE_KOMODO_IMAGE_TAG:-2}
          init: true
          restart: unless-stopped
          depends_on:
            - mongo
          ports:
            - 9120:9120
          env_file: ./compose.env
          environment:
            KOMODO_DATABASE_ADDRESS: mongo:27017
          volumes:
            - keys:/config/keys
            - /etc/komodo/backups:/backups

      volumes:
        mongo-data:
        mongo-config:
        keys:

  - path: /opt/komodo/compose.env
    content: |
      COMPOSE_KOMODO_IMAGE_TAG=2

      KOMODO_DATABASE_USERNAME=komodo
      KOMODO_DATABASE_PASSWORD=<mongo-password>

      TZ=Etc/UTC

      KOMODO_HOST=http://localhost:9120
      KOMODO_TITLE=Komodo

      KOMODO_LOCAL_AUTH=true
      KOMODO_INIT_ADMIN_USERNAME=admin
      KOMODO_INIT_ADMIN_PASSWORD=<admin-password>

      KOMODO_JWT_SECRET=<jwt-secret>
      KOMODO_WEBHOOK_SECRET=<webhook-secret>

      KOMODO_DISABLE_USER_REGISTRATION=true
      KOMODO_ENABLE_NEW_USERS=false

runcmd:
  # Disable openssh — emergency access via provider VNC console only
  - systemctl disable --now ssh || true
  - systemctl mask ssh

  # Install Tailscale
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

  # Install Docker CE
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -y
  - apt-get install -y tailscale docker-ce docker-ce-cli containerd.io docker-compose-plugin

  - systemctl enable --now tailscaled
  - systemctl enable --now docker

  # Start Komodo
  - docker compose -f /opt/komodo/docker-compose.yml --env-file /opt/komodo/compose.env up -d

  # Apply firewall rules and persist across reboots
  - iptables-restore < /etc/iptables/rules.v4
  - netfilter-persistent save

  # Authenticate Tailscale with SSH enabled
  # To also advertise as an exit node, uncomment the two lines below and comment out the one above:
  # - sysctl -p /etc/sysctl.d/99-tailscale.conf
  # - tailscale up --ssh --advertise-exit-node --authkey=<tailscale-auth-key>
  - tailscale up --ssh --authkey=<tailscale-auth-key>
  - reboot
```

### 7. Post-Provisioning

**Verify the node is online** (from your local machine):

```bash
tailscale status
```

The server should appear with a MagicDNS hostname (e.g. `hz-agents-0`).

**SSH into the server:**

```bash
ssh cloud_user@hz-agents-0
```

**Access Komodo:**

Open `http://hz-agents-0:9120` in a browser on any device connected to your Tailscale network. Register the first user — they get admin rights automatically.

### 8. Connect the Server to Komodo (Periphery)

Periphery is a small systemd-managed agent that lets Komodo manage this server. It connects outbound to Core — no inbound firewall rules needed.

**Step 1 — Create an Onboarding Key in Komodo:**

1. Log into Komodo
2. Go to **Settings → Onboarding Keys**
3. Create a new key — it will start with `O-...`
4. Copy it immediately (shown only once)

**Step 2 — Install Periphery via systemd on the server:**

```bash
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py \
  | python3 - \
  --core-address="http://localhost:9120" \
  --connect-as="agent-0" \
  --onboarding-key="O-..."
sudo systemctl enable periphery
```

The server will appear under **Servers** in the Komodo UI within seconds.

> The onboarding key is only needed for the initial connection. After Periphery registers, all subsequent auth uses automatically managed key pairs — no manual key rotation required.

## Alternative Cloud - Hetzner
In place of Oracle Cloud, create an instance with Hetzner. Ensure the Firewall is setup correctly 
### 5. Hetzner Server

Create the server with these settings:

| Setting | Value |
|---|---|
| Type | Regular Performance (CPX21) |
| Location | US-West |
| Image | Ubuntu 24.04 |
| Networking | IPv4 + IPv6 |
| SSH Key | Optional — emergency fallback only |
| Firewall | Tailscale Firewall |
| Backups | Enabled |