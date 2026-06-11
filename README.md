<div align="center">
  <img src="assets/logo.svg" alt="VAL logo" width="100"/>
  <h1>VAL — Versatile Autoregistration Listener</h1>
</div>

[![en](https://img.shields.io/badge/lang-en-blue.svg)](README.md)
[![es](https://img.shields.io/badge/lang-es-green.svg)](README.es.md)

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Debian package](https://img.shields.io/badge/package-versatile--autoreg--val-brightgreen)](https://github.com/GabrielNavi/val/releases)
[![Bash](https://img.shields.io/badge/shell-bash-89e051.svg)](https://www.gnu.org/software/bash/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

Inventory distribution daemon. Watches for version changes in VAS (or VAC) and executes configurable hook scripts with the resulting inventory. Requires no changes to VAS or VAC.

Common use cases: Veyon synchronization, CUPS configuration, CSV export, monitoring system notifications.

---

## Table of Contents

- [Ecosystem](#ecosystem)
- [Quick Start](#quick-start)
- [Installed Files](#installed-files)
- [Configuration](#configuration)
- [Operation Cycle](#operation-cycle)
- [Hooks](#hooks)
- [VAL-Aware (Push)](#val-aware-push)
- [Parallelization](#parallelization)
- [Service Management](#service-management)
- [Wiki](#wiki)
- [License](#license)

---

## Ecosystem

```
VAS  ──version bump──►  VAL  ──hooks.d/──►  Veyon / CUPS / Prometheus / ...
VAC  ──version file──►  VAL  (SOURCE=vac)
VAS  ──UDP push─────►  VAL-Aware  (millisecond latency)
```

| Package | Repository | Description |
|---------|------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Inventory server |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) | Autoregistration client |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) ← *this* | Generic consumer with hooks |
| `versatile-autoreg-vaf` | [vaf](https://github.com/GabrielNavi/vaf) | Server federation (beta) |
| `versatile-autoreg-vat` | [vat](https://github.com/GabrielNavi/vat) | Inventory Transformer (experimental) |

---

## Quick Start

```bash
# Install
sudo dpkg -i versatile-autoreg-val_*.deb
sudo apt-get -f install

# Configure — minimum required
sudo nano /etc/val/val.conf
# VAS_HOST=10.0.0.1

# Add a hook
sudo cp my-hook.sh /etc/val/hooks.d/10-my-hook.sh
sudo chmod +x /etc/val/hooks.d/10-my-hook.sh

# Start
sudo systemctl enable --now val

# Verify
journalctl -u val -f
```

> **Dependencies:** `bash`, `curl`, `jq` · `netcat-openbsd` (recommended, for VAL-Aware)  
> See [Installation](https://github.com/GabrielNavi/val/wiki/EN_Install) in the wiki for full instructions.

---

## Installed Files

| Path | Description |
|------|-------------|
| `/usr/bin/val` | Main daemon (polling + VAL-Aware push) |
| `/usr/bin/val-sub` | Full VAL loop for sub-instances |
| `/usr/bin/val-sub-manager` | Sub-instance supervisor with fail counter |
| `/usr/bin/val-sub-instance` | CLI to create, list and delete sub-instances |
| `/usr/lib/val/val-common.sh` | Shared library: config, logging, fetch, materialization, hooks |
| `/etc/val/val.conf` | Main configuration file |
| `/etc/val/val.conf.d/` | Config overlays in lexical order |
| `/etc/val/hooks.d/` | Executable hook scripts (lexical order) |
| `/usr/share/val/val.conf.defaults` | Exhaustive variable reference (read-only) |
| `/lib/systemd/system/val.service` | systemd unit |

**Runtime state:**

| Path | Description |
|------|-------------|
| `/var/lib/val/version` | Last processed version |
| `/var/lib/val/clients.json` | Last downloaded inventory |
| `/var/lib/val/KEY_clients.json` | Materialized views by key (`LOCAL_KEY_LIST`) |

---

## Configuration

```ini
# /etc/val/val.conf  (full reference at /usr/share/val/val.conf.defaults)

SOURCE=vas               # vas | vac
VAS_HOST=10.0.0.1        # IP/hostname — no scheme, port 8000 implicit
# VAS_SCHEME=http        # http (default) | https
FILTER=active            # active | inactive | archived | all
CHECK_SECONDS=300
HOOKS_DIR=/etc/val/hooks.d
HOOK_TIMEOUT_SECONDS=30  # 0 = no limit (not recommended)
BUMP_LISTEN_PORT=9876    # enabled automatically on fresh install
PARALLEL_MODE=both       # both | only_parallel | only_main
LOG_LEVEL=normal         # no | normal | debug
```

Full guide: [Configuration](https://github.com/GabrielNavi/val/wiki/EN_Config)

---

## Operation Cycle

```
1. GET /version  (or read VAC_STATE_DIR/version)
   ├─ No change → interruptible_sleep(CHECK_SECONDS)
   │               UDP bump received → immediate cycle
   └─ Changed →
       2. fetch_clients()          [optional: VAT --direction upstream]
       3. materialize_keys()       [optional: VAT --direction downstream]
       4. dispatch_hooks()         with timeout per hook
       5. Update VERSION_FILE
```

VAT (Versatile Autoregistration Transformer) can optionally normalize clients on arrival (upstream) and filter them before hook dispatch (downstream). See [VAT documentation](https://github.com/GabrielNavi/vat) for configuration.

More details: [Operation Flow](https://github.com/GabrielNavi/val/wiki/EN_Operation)

---

## Hooks

Scripts in `/etc/val/hooks.d/`, executed in lexical order. Receive environment variables and optionally the inventory via stdin (`DISPATCH_STDIN=true`):

```bash
#!/bin/bash
# /etc/val/hooks.d/10-cups.sh
# Requires: LOCAL_KEY_LIST="cups"
jq -r '.clients[] | "\(.ip)\t\(.extra_imperative.cups.server // "-")"' \
    "${VAL_STATE_DIR}/cups_clients.json"
```

**Available variables:** `VAL_VERSION`, `VAL_FILTER`, `VAL_SOURCE`, `VAL_EXTRA_KEY`, `VAL_STATE_DIR`

A hook exceeding `HOOK_TIMEOUT_SECONDS` receives SIGTERM (exit 124 in log). The remaining hooks continue normally.

More details: [Hooks](https://github.com/GabrielNavi/val/wiki/EN_Hooks)

---

## VAL-Aware (Push)

With `BUMP_LISTEN_PORT=9876` and the `val-local` hook active in VAS, reaction latency drops from `CHECK_SECONDS` to milliseconds. On a fresh install, both sides are activated automatically (VAS postinst installs `val-local`; VAL postinst enables the port).

More details: [VAL-Aware](https://github.com/GabrielNavi/val/wiki/EN_VAL-Aware)

---

## Parallelization

```bash
val-sub-instance --create samba --vas 10.0.2.1
# creates /etc/val/val.sub/samba/ with .enabled, val.conf and hooks.d/
systemctl restart val   # with PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` · `only_parallel` · `only_main`. Sub-instances without `.enabled` are ignored. The supervisor stops restarting an instance after 5 consecutive hard failures.

More details: [Sub-instances](https://github.com/GabrielNavi/val/wiki/EN_Sub-instances)

---

## Service Management

```bash
sudo systemctl status val
sudo systemctl restart val
journalctl -u val -f
journalctl -u val | grep '\[VAL-ERROR\]'
journalctl -u val | grep '\[PARALLEL\]'
journalctl -u val | grep '\[HOOKS\]'
```

---

## Wiki

[Installation](https://github.com/GabrielNavi/val/wiki/EN_Install) · [Configuration](https://github.com/GabrielNavi/val/wiki/EN_Config) · [Operation](https://github.com/GabrielNavi/val/wiki/EN_Operation) · [Hooks](https://github.com/GabrielNavi/val/wiki/EN_Hooks) · [VAL-Aware](https://github.com/GabrielNavi/val/wiki/EN_VAL-Aware) · [Sub-instances](https://github.com/GabrielNavi/val/wiki/EN_Sub-instances) · [Logging](https://github.com/GabrielNavi/val/wiki/EN_Logging)

---

## License

[Apache License 2.0](LICENSE)
