# OpenCache installer

Installs and upgrades an [OpenCache](https://github.com/pfoundation/opencache) PoP.

```bash
curl -fsSL https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install.sh \
  | sudo bash -s -- --pop-id PAR1 --dus-token <token>
```

Upgrade an existing PoP (gap-free):

```bash
curl -fsSL https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install.sh \
  | sudo bash -s -- --upgrade
```

Run with `--dry-run` to see the plan without changing anything, or `--help` for all options.

## What it does

Installs Docker, nftables and openssl if missing, extracts the versioned OpenCache runtime
bundle into `/opt/opencache`, seeds `.env`, applies kernel tuning, caps Docker's log files,
installs the L4 blue/green nftables switch and its boot unit, opens the required firewall
ports, deploys the Swarm stack and runs a health check.

Re-running is safe: `.env`, `certs/`, `env/`, `cache*/`, `nginx/generated/` and
`docker-stack.override.yml` are never overwritten.

## Requirements

A root shell on an x86_64 Ubuntu/Debian or RHEL-family host, a Directus URL and token, and
a PoP identifier. Everything else is installed for you.

## Note

**This repository is a mirror.** `install.sh` is generated from `packaging/install.sh` in
the OpenCache repository and is overwritten by CI on every release — edits made here will
be lost. Open issues and pull requests against OpenCache instead.
