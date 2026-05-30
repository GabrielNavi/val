# vx-dga-l-val — Versatile Autoregistration Listener

Daemon de distribución de inventario. Observa cambios de versión en VAS o VAC y ejecuta scripts hook configurables con el inventario resultante. No modifica ni requiere cambios en VAS ni en VAC.

Casos de uso habituales: sincronización de Veyon, configuración de CUPS, exportación de CSVs, notificaciones a sistemas de monitorización.

## Ecosistema

```
vx-dga-l-vas          → servidor de inventario
vx-dga-l-vac          → cliente de autoregistro
vx-dga-l-val          → consumidor genérico con hooks (este paquete)
vx-dga-l-veyon-sync   → integración Veyon (consumidor especializado)
```

## Requisitos

- `bash`, `curl`, `jq`
- `netcat-openbsd` (para `BUMP_LISTEN_PORT != 0`, declarado como `Recommends`)

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `/usr/bin/val` | Daemon principal (polling + push) |
| `/usr/bin/val-sub` | Bucle VAL completo para sub-instancias |
| `/usr/bin/val-sub-manager` | Supervisor de sub-instancias con fail counter |
| `/usr/bin/val-sub-instance` | CLI para crear, listar y eliminar sub-instancias |
| `/usr/lib/val/val-common.sh` | Librería compartida: config, logging, fetch, materialización, hooks |
| `/etc/val/val.conf` | Configuración principal |
| `/etc/val/hooks.d/` | Scripts hook ejecutables (orden lexical) |
| `/usr/share/val/val.conf.defaults` | Referencia exhaustiva de todas las variables (solo lectura) |
| `/usr/share/val/instance-template/val.conf` | Plantilla para nuevas sub-instancias |

## Estado local

| Ruta | Descripción |
|---|---|
| `/var/lib/val/version` | Última versión procesada |
| `/var/lib/val/clients.json` | Último inventario descargado |
| `/var/lib/val/KEY_clients.json` | Vistas materializadas por clave (`LOCAL_KEY_LIST`) |
| `/var/lib/val/sub/<name>/` | Estado de cada sub-instancia |

## Configuración

```ini
# /etc/val/val.conf  (referencia completa en val.conf.defaults)
SOURCE=vas
VAS_HOST=10.0.0.1        # IP/hostname; sin scheme, :8000 implícito
# VAS_SCHEME=http        # http (defecto) | https
FILTER=active
CHECK_SECONDS=300
HOOKS_DIR=/etc/val/hooks.d
HOOK_TIMEOUT_SECONDS=30  # 0 = sin límite (no recomendado)
BUMP_LISTEN_PORT=9876    # activado automáticamente en instalación fresca
PARALLEL_MODE=both
LOG_LEVEL=normal
```

## Ciclo de operación

```
1. GET /version (o leer VAC_STATE_DIR/version)
   ├─ Sin cambio → interruptible_sleep(CHECK_SECONDS)
   │                 UDP bump recibido → ciclo inmediato
   └─ Con cambio →
       2. fetch_clients()  [VAT upstream opcional]
       3. materialize_keys() por LOCAL_KEY_LIST  [VAT downstream opcional]
       4. dispatch_hooks()  con timeout por hook
       5. Actualizar VERSION_FILE
```

## Hooks

Scripts en `/etc/val/hooks.d/`, ejecutados en orden lexical. Reciben variables de entorno y opcionalmente el inventario por stdin (`DISPATCH_STDIN=true`):

```bash
#!/bin/bash
# /etc/val/hooks.d/10-cups.sh
# Requiere: LOCAL_KEY_LIST="cups"  DISPATCH_STDIN=false
jq -r '.clients[] | "\(.ip)\t\(.extra_imperative.cups.server // "-")"' \
    "${VAL_STATE_DIR}/cups_clients.json"
```

Variables disponibles: `VAL_VERSION`, `VAL_FILTER`, `VAL_SOURCE`, `VAL_EXTRA_KEY`, `VAL_STATE_DIR`.

Un hook que supera `HOOK_TIMEOUT_SECONDS` recibe SIGTERM (exit 124 en log). Los demás hooks continúan.

## VAL-Aware (push)

Con `BUMP_LISTEN_PORT=9876` y el hook `val-local` activo en VAS, la latencia de reacción cae de `CHECK_SECONDS` a milisegundos. En instalación fresca, ambos lados se activan automáticamente (postinst de VAS instala `val-local`; postinst de VAL activa el puerto).

## Paralelización

```bash
val-sub-instance --create samba --vas 10.0.2.1
# crea /etc/val/val.sub/samba/ con .enabled, val.conf y hooks.d/
systemctl restart val   # con PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` · `only_parallel` · `only_main`. Sub-instancias sin `.enabled` son ignoradas. El supervisor distingue fallos duros de transitorios y deja de reiniciar tras 5 fallos duros.

## Servicio

```bash
systemctl status val
systemctl restart val
journalctl -u val -f
journalctl -u val | grep '\[VAL-ERROR\]'
journalctl -u val | grep '\[PARALLEL\]'
```

## Wiki

[Instalación](../../wiki/Instalacion) · [Configuración](../../wiki/Configuracion) · [Flujo de operación](../../wiki/Flujo-de-operacion) · [Hooks](../../wiki/Hooks) · [VAL-Aware](../../wiki/VAL-Aware) · [Paralelización](../../wiki/Paralelizacion) · [Logging](../../wiki/Logging)
