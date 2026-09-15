# Dual-Stack Certificate Design

## Goal

Allow each managed domain to use an explicit IPv4, IPv6, or dual-stack HTTP-01 validation mode, retain that mode for manual and scheduled renewals, and store certificates below `/etc/letsencrypt/live/<domain>/`.

## Constraints

- Continue using acme.sh standalone HTTP-01 validation and TCP port 80.
- Do not treat an outbound WARP IPv4 address as proof that the server owns that IPv4 address.
- Do not stop port listeners until the full port-safety preflight succeeds.
- Keep legacy certificates in `/root/cert/<domain>/` usable by migrating them without overwriting files already present in the new destination.
- Preserve existing acme.sh records, logs, and cron jobs during updates.
- Maintain Debian, Ubuntu, and Alpine compatibility with Bash and their available core networking tools.

## Data Model

`/etc/letsencrypt/ssl-certbot/<domain>.conf` is a root-readable configuration file containing the required setting below after issuance:

```bash
SSL_CERTBOT_NETWORK_MODE=ipv4
```

Allowed values are `ipv4`, `ipv6`, and `dual`. A missing or invalid file falls back to `dual` for legacy certificates, preserving the previous standalone listener behavior.

## Network Selection

Interactive issuance prompts for one of three modes. Command-line issuance accepts `w ssl <domain> [ipv4|ipv6|dual]`; without a mode it prompts on a TTY and otherwise selects `dual`.

DNS preflight independently collects A and AAAA records and compares them only against addresses assigned to the server's non-loopback interfaces:

- IPv4 mode requires a matching A record and uses acme.sh `--listen-v4`.
- IPv6 mode requires a matching AAAA record and uses acme.sh `--listen-v6`.
- Dual mode requires matching A and AAAA records and uses acme.sh's normal dual-stack standalone listener.

Outbound address-discovery services are not used for validation. This avoids false IPv4 failures created by WARP or other egress tunnels. The tool reports DNS records and matching local addresses before it pauses services.

HTTP-01 is controlled by the CA's DNS resolution. In dual mode, both records must be publicly reachable over TCP 80. A deliberately single-stack deployment must select its matching mode and publish only the corresponding DNS record.

## Renewal Flow

Every renewal reads the domain's saved mode and passes the corresponding acme.sh listener flag. Batch renewal pauses services once for all certificates that need renewal, then renews each domain using its independent persisted mode.

## Certificate Storage Migration

The canonical base directory becomes `/etc/letsencrypt/live`. At startup, the tool scans legacy `/root/cert/*/` directories. For each domain with a legacy `fullchain.pem` and `privkey.pem`, it creates the new target directory only when neither target file exists and moves both files. It preserves `644` on the full chain, `600` on the private key, and `700` on each certificate directory.

All certificate operations use the new base after migration: issuance, renew, list, status, delete, help output, and README paths. Removing a certificate also removes its saved network-mode configuration.

## Error Handling

Invalid mode values are rejected with a Chinese error. Missing DNS records, missing local addresses, or non-matching records fail before any port listener is stopped. A missing saved mode during renewal uses dual mode and emits a warning. A failed configuration write after installation reports the issuance as failed because future automatic renewal would otherwise use an unknown validation mode.

## Tests

The shell suite covers mode validation and persistence, listener flags for issuance and renewal, IPv6 validation without public IPv4 lookup, dual-stack requirements, legacy migration, configuration deletion, and documentation updates.
