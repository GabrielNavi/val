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

Daemon de distribución de inventario. Observa cambios de versión en VAS (o VAC) y ejecuta scripts hook configurables con el inventario resultante. No modifica ni requiere cambios en VAS ni en VAC.

Casos de uso habituales: sincronización de Veyon, configuración de CUPS, exportación de CSVs, notificaciones a sistemas de monitorización.

---

## Tabla de contenidos

- [Ecosistema](#ecosistema)
- [Instalación rápida](#instalación-rápida)
- [Archivos instalados](#archivos-instalados)
- [Configuración](#configuración)
- [Ciclo de operación](#ciclo-de-operación)
- [Hooks](#hooks)
- [VAL-Aware (push)](#val-aware-push)
- [Paralelización](#paralelización)
- [Servicio](#servicio)
- [Wiki](#wiki)
- [Licencia](#licencia)

---

## Ecosistema

```
VAS  ──bump de versión──►  VAL  ──hooks.d/──►  Veyon / CUPS / Prometheus / ...
VAC  ──fichero versión──►  VAL  (SOURCE=vac)
VAS  ──push UDP────────►  VAL-Aware  (latencia en milisegundos)
```

| Paquete | Repositorio | Descripción |
|---------|-------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Servidor de inventario |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) | Cliente de autoregistro |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) ← *este* | Consumidor genérico con hooks |
| `versatile-autoreg-vaf` | vaf | Federación de servidores (experimental) |

---

## Instalación rápida

```bash
# Instalar
sudo dpkg -i versatile-autoreg-val_*.deb
sudo apt-get -f install

# Configurar — mínimo necesario
sudo nano /etc/val/val.conf
# VAS_HOST=10.0.0.1

# Añadir un hook
sudo cp mi-hook.sh /etc/val/hooks.d/10-mi-hook.sh
sudo chmod +x /etc/val/hooks.d/10-mi-hook.sh

# Arrancar
sudo systemctl enable --now val

# Verificar
journalctl -u val -f
```

> **Dependencias:** `bash`, `curl`, `jq` · `netcat-openbsd` (recomendado, para VAL-Aware)  
> Ver [Instalación](https://github.com/GabrielNavi/val/wiki/ES_Instalacion) en la wiki para instrucciones completas.

---

## Archivos instalados

| Ruta | Descripción |
|------|-------------|
| `/usr/bin/val` | Daemon principal (polling + push VAL-Aware) |
| `/usr/bin/val-sub` | Bucle VAL completo para sub-instancias |
| `/usr/bin/val-sub-manager` | Supervisor de sub-instancias con fail counter |
| `/usr/bin/val-sub-instance` | CLI para crear, listar y eliminar sub-instancias |
| `/usr/lib/val/val-common.sh` | Librería compartida: config, logging, fetch, materialización, hooks |
| `/etc/val/val.conf` | Configuración principal |
| `/etc/val/val.conf.d/` | Overlays en orden lexical |
| `/etc/val/hooks.d/` | Scripts hook ejecutables (orden lexical) |
| `/usr/share/val/val.conf.defaults` | Referencia exhaustiva de variables (solo lectura) |
| `/lib/systemd/system/val.service` | Unidad systemd |

**Estado en tiempo de ejecución:**

| Ruta | Descripción |
|------|-------------|
| `/var/lib/val/version` | Última versión procesada |
| `/var/lib/val/clients.json` | Último inventario descargado |
| `/var/lib/val/KEY_clients.json` | Vistas materializadas por clave (`LOCAL_KEY_LIST`) |

---

## Configuración

```ini
# /etc/val/val.conf  (referencia completa en /usr/share/val/val.conf.defaults)

SOURCE=vas               # vas | vac
VAS_HOST=10.0.0.1        # IP/hostname; sin scheme, puerto 8000 implícito
# VAS_SCHEME=http        # http (defecto) | https
FILTER=active            # active | inactive | archived | all
CHECK_SECONDS=300
HOOKS_DIR=/etc/val/hooks.d
HOOK_TIMEOUT_SECONDS=30  # 0 = sin límite (no recomendado)
BUMP_LISTEN_PORT=9876    # activado automáticamente en instalación fresca
PARALLEL_MODE=both       # both | only_parallel | only_main
LOG_LEVEL=normal         # no | normal | debug
```

Guía completa: [Configuración](https://github.com/GabrielNavi/val/wiki/ES_Configuracion)

---

## Ciclo de operación

```
1. GET /version  (o leer VAC_STATE_DIR/version)
   ├─ Sin cambio → interruptible_sleep(CHECK_SECONDS)
   │               UDP bump recibido → ciclo inmediato
   └─ Con cambio →
       2. fetch_clients()          [opcional: VAT --direction upstream]
       3. materialize_keys()       [opcional: VAT --direction downstream]
       4. dispatch_hooks()         con timeout por hook
       5. Actualizar VERSION_FILE
```

VAT (Transformador de Autoregistro Versátil) puede opcionalmente normalizar clientes al llegar (upstream) y filtrarlos antes de despachar hooks (downstream). Véase la [documentación VAT](https://github.com/GabrielNavi/vat) para la configuración.

Más información: [Flujo de operación](https://github.com/GabrielNavi/val/wiki/ES_Flujo)

---

## Hooks

Scripts en `/etc/val/hooks.d/`, ejecutados en orden lexical. Reciben variables de entorno y opcionalmente el inventario por stdin (`DISPATCH_STDIN=true`):

```bash
#!/bin/bash
# /etc/val/hooks.d/10-cups.sh
# Requiere: LOCAL_KEY_LIST="cups"
jq -r '.clients[] | "\(.ip)\t\(.extra_imperative.cups.server // "-")"' \
    "${VAL_STATE_DIR}/cups_clients.json"
```

**Variables disponibles:** `VAL_VERSION`, `VAL_FILTER`, `VAL_SOURCE`, `VAL_EXTRA_KEY`, `VAL_STATE_DIR`

Un hook que supera `HOOK_TIMEOUT_SECONDS` recibe SIGTERM (exit 124 en log). Los demás hooks continúan.

Más información: [Hooks](https://github.com/GabrielNavi/val/wiki/ES_Hooks)

---

## VAL-Aware (push)

Con `BUMP_LISTEN_PORT=9876` y el hook `val-local` activo en VAS, la latencia de reacción cae de `CHECK_SECONDS` a milisegundos. En instalación fresca, ambos lados se activan automáticamente.

Más información: [VAL-Aware](https://github.com/GabrielNavi/val/wiki/ES_VAL-Aware)

---

## Paralelización

```bash
val-sub-instance --create samba --vas 10.0.2.1
# crea /etc/val/val.sub/samba/ con .enabled, val.conf y hooks.d/
systemctl restart val   # con PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` · `only_parallel` · `only_main`. Sub-instancias sin `.enabled` son ignoradas. El supervisor deja de reiniciar tras 5 fallos duros consecutivos.

Más información: [Sub-instancias](https://github.com/GabrielNavi/val/wiki/ES_Sub-instancias)

---

## Servicio

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

[Instalación](https://github.com/GabrielNavi/val/wiki/ES_Instalacion) · [Configuración](https://github.com/GabrielNavi/val/wiki/ES_Configuracion) · [Flujo de operación](https://github.com/GabrielNavi/val/wiki/ES_Flujo) · [Hooks](https://github.com/GabrielNavi/val/wiki/ES_Hooks) · [VAL-Aware](https://github.com/GabrielNavi/val/wiki/ES_VAL-Aware) · [Sub-instancias](https://github.com/GabrielNavi/val/wiki/ES_Sub-instancias) · [Logging](https://github.com/GabrielNavi/val/wiki/ES_Logging)

---

## Licencia

[Apache License 2.0](LICENSE)
