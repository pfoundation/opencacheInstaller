# OpenCache installer

Installs an OpenCache edge PoP on FreeBSD.

```sh
fetch -qo - https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh \
  | sh -s -- --pop-id PAR1 --baas-host https://baas.example.com --baas-token <token>
```

Upgrade an existing node:

```sh
fetch -qo - https://raw.githubusercontent.com/pfoundation/opencacheInstaller/master/install-freebsd.sh \
  | sh -s -- --upgrade
```

Once a node is installed the same script is on disk, so an upgrade also works
without outbound access to GitHub:

```sh
/opt/opencache/packaging/install-freebsd.sh --upgrade
```

> **Once, on a node still running v26.10.13 or older, do not run the installed
> copy in place.** Those releases overwrite their own file during the upgrade
> and then run part of the new one. Upgrade such a node with the one-liner
> above, or run a copy:
>
> ```sh
> cp /opt/opencache/packaging/install-freebsd.sh /tmp/ && sh /tmp/install-freebsd.sh --upgrade
> ```
>
> Every later release is safe to run in place.

## What it does

Turns a bare FreeBSD server into a serving PoP. It installs packages, builds
nginx from source with the module set OpenCache needs (brotli, cache_purge,
headers-more, geoip2, njs, oc_cache_min_uses), extracts the versioned runtime bundle into
`/opt/opencache`, seeds `.env`, mounts RAM-backed tmpfs for the certificate
store and the memory cache tier, applies kernel tuning, configures GeoIP
updates, hardens SSH, discovers cache disks under `/mnt/nvme-<i>` and
`/mnt/hdd-<i>`, installs the `rc.d` services and starts them.

Every component runs natively under `rc.d` — there are no containers. A single
nginx binds public 80/443.

Node-local state is never overwritten on upgrade: `.env`, `certs/`, `env/`,
`cache*/` and `nginx/generated/`.

Run `install-freebsd.sh --help` for the full flag list, or `--dry-run` to see
what a run would change without changing it.

## Releases

Each release here carries the runtime bundle the installer consumes:

- `opencache-<version>.tar.gz` — the bundle
- `opencache-<version>.tar.gz.sha256` — its checksum

Without `--version` the installer resolves the newest published release. To
install from a local or mirrored copy instead:

```sh
install-freebsd.sh --bundle-tarball ./opencache-v26.08.12.tar.gz
```

## About this repository

**This repository is a mirror.** `install-freebsd.sh` and this README are
generated from `packaging/` in the private `pfoundation/opencache` repo and
overwritten on every release — do not edit them here, the change will be lost.

It exists because the source repository is private: `raw.githubusercontent.com`
and its release assets both return 404 to an anonymous PoP, so a public mirror
is what makes a fetchable installer possible at all.

> **Linux/Swarm PoPs are no longer supported.** `install.sh` was removed — the
> stack runs on FreeBSD only. Existing Linux nodes must be rebuilt; pin a
> release from before the removal if you need to keep one running while you
> migrate.
