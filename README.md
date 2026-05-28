# vx-dga-l-val — Versatile Autoregistration Listener

Daemon genérico que observa cambios de versión en el inventario de **VAS** o **VAC** y distribuye el resultado a hooks configurables.

No modifica ni requiere cambios en VAS ni en VAC.

## ¿Qué hace?

1. Compara la versión remota del inventario con la última conocida (polling o push).
2. Si detecta un cambio, descarga el inventario (opcionalmente filtrado por `GLOBAL_KEY`).
3. Materializa vistas locales por clave (`LOCAL_KEY_LIST`) en `STATE_DIR/KEY_clients.json`.
4. Ejecuta en orden lexical todos los scripts ejecutables de `hooks.d/`.

## Modos de fuente

| `SOURCE` | Fuente | Requisito |
|---|---|---|
| `vas` | `GET /clients` desde VAS via HTTP | `VAS_HOST` configurado |
| `vac` | `/var/lib/vac/clients.json` local | VAC instalado y activo |

## Filtro de clientes

| `FILTER` | Clientes incluidos | Compatible con |
|---|---|---|
| `active` | Solo activos | `vas` y `vac` |
| `inactive` | Solo inactivos | Solo `vas` |
| `archived` | Solo archivados | Solo `vas` |
| `all` | Todos | Solo `vas` |

> Con `SOURCE=vac`, VAC descarga únicamente clientes activos. `FILTER=inactive`, `FILTER=archived` o `FILTER=all` pueden dar resultados incompletos.

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `/usr/bin/val` | Daemon principal |
| `/usr/bin/val-sub` | Daemon para sub-instancias (standalone) |
| `/usr/bin/val-sub-manager` | Supervisor de sub-instancias |
| `/usr/bin/val-sub-instance` | Gestión del ciclo de vida de sub-instancias |
| `/usr/share/val/val.conf.defaults` | Referencia de valores por defecto (solo lectura) |
| `/etc/val/val.conf` | Configuración principal |
| `/etc/val/val.conf.d/` | Overlays de configuración (orden lexical) |
| `/etc/val/hooks.d/` | Scripts hook ejecutables |
| `/etc/val/val.sub/` | Directorio raíz de sub-instancias |
| `/etc/val/val.sub/<name>/val.conf` | Configuración de sub-instancia |
| `/etc/val/val.sub/<name>/hooks.d/` | Hooks propios de la sub-instancia |
| `/var/lib/val/version` | Última versión procesada |
| `/var/lib/val/clients.json` | Último inventario descargado |
| `/var/lib/val/KEY_clients.json` | Vista por clave (una por entrada en `LOCAL_KEY_LIST`) |
| `/var/lib/val/sub/<name>/` | Estado de la sub-instancia |

## Configuración

Edita `/etc/val/val.conf` o añade un fichero en `/etc/val/val.conf.d/`. Los overlays tienen prioridad sobre el conf principal.

Tras cualquier cambio, reinicia el servicio:

```sh
sudo systemctl restart val
```

### Variables disponibles

| Variable | Por defecto | Descripción |
|---|---|---|
| `SOURCE` | `vas` | Fuente de datos: `vas` o `vac` |
| `VAS_HOST` | `http://127.0.0.1:8000` | URL del servidor VAS (solo `SOURCE=vas`) |
| `FILTER` | `active` | Filtro de clientes: `active`, `inactive`, `archived`, `all` |
| `CHECK_SECONDS` | `300` | Intervalo entre comprobaciones de versión |
| `RETRY_SECONDS` | `60` | Espera ante errores de conexión o hooks fallidos |
| `HOOKS_DIR` | `/etc/val/hooks.d` | Directorio con los scripts hook |
| `VAC_STATE_DIR` | `/var/lib/vac` | Directorio de estado de VAC (solo `SOURCE=vac`) |
| `GLOBAL_KEY` | _(vacío)_ | Clave enviada a VAS como `?extra_key=KEY`; reduce tráfico descargando solo clientes que tengan esa clave. Solo `SOURCE=vas`. |
| `LOCAL_KEY_LIST` | _(vacío)_ | Claves separadas por espacios. VAL escribe `STATE_DIR/KEY_clients.json` por cada una tras cada descarga. |
| `DISPATCH_STDIN` | `true` | `true`: hooks reciben el inventario por stdin (compat). `false`: stdin vacío; hooks leen `VAL_STATE_DIR/KEY_clients.json`. |
| `BUMP_LISTEN_PORT` | `0` | Puerto UDP de escucha para notificaciones push de VAS. `0` = desactivado (solo polling). Con valor distinto de 0, cualquier datagrama UDP recibido interrumpe el `sleep` del ciclo e inicia una comprobación inmediata. |
| `PARALLELIZATION` | `false` | `true`: arranca `val-sub-manager` en background al iniciar el daemon principal. Gestiona sub-instancias independientes. |

## Hooks

Los scripts de `hooks.d/` se ejecutan en **orden lexical**. Un hook que falla no interrumpe la cadena.

### Contrato de un hook

- **Stdin**: inventario JSON (`{ "clients": [...] }`) si `DISPATCH_STDIN=true`; vacío si `false`.
- **Variables de entorno**:
  - `VAL_VERSION` → versión que disparó la ejecución
  - `VAL_FILTER` → filtro activo (`active`/`inactive`/`archived`/`all`)
  - `VAL_SOURCE` → fuente usada (`vas`/`vac`)
  - `VAL_EXTRA_KEY` → valor de `GLOBAL_KEY` aplicado al stdin (vacío si sin filtro)
  - `VAL_STATE_DIR` → directorio de estado con los ficheros `KEY_clients.json`
- **Retorno**: `0` = éxito, cualquier otro = warning en log, continúa

> **Práctica recomendada para hooks nuevos**: ignorar stdin y leer
> `$VAL_STATE_DIR/KEY_clients.json` directamente. Configurar `DISPATCH_STDIN=false`.

### Ejemplo de hook (patrón clásico — stdin)

```sh
#!/bin/bash
# /etc/val/hooks.d/10-log.sh
echo "=== $VAL_VERSION ($VAL_FILTER via $VAL_SOURCE) ===" >> /var/log/val-inventory.log
jq '.clients | length' >> /var/log/val-inventory.log
```

### Ejemplo de hook (patrón recomendado — fichero por clave)

```sh
#!/bin/bash
# /etc/val/hooks.d/20-cups.sh
# Requiere LOCAL_KEY_LIST="cups" y DISPATCH_STDIN=false en val.conf.
# Configura CUPS en cada equipo que tenga la clave 'cups' en sus extras.
cups_file="${VAL_STATE_DIR}/cups_clients.json"
[[ -f "$cups_file" ]] || exit 0

jq -r '.clients[] | "\(.ip) \(.extra_imperative.cups.server // "")"' "$cups_file" \
| while read -r ip server; do
    [[ -z "$server" ]] && continue
    echo "Configurando $ip → cups://$server"
    # lpadmin -H "$ip" ...
done
```

```sh
chmod +x /etc/val/hooks.d/20-cups.sh
```

### Reconstruir veyon-sync como hook

Un hook equivalente a `vx-dga-l-veyon-sync` en ~15 líneas:

```sh
#!/bin/bash
# /etc/val/hooks.d/20-veyon.sh
LOCATION="Autoregistrados"
CSV=$(mktemp)
jq -r --arg loc "$LOCATION" \
  '.clients[]? | "computer;\((.hostname//""|gsub(";";"")));\((.ip//""|gsub(";";"")));\((.mac//""|gsub(";";"")));\($loc)"' \
  > "$CSV"
veyon-cli networkobjects remove "$LOCATION" >/dev/null 2>&1 || true
veyon-cli networkobjects import "$CSV" format "%type%;%name%;%host%;%mac%;%location%" >/dev/null
rm -f "$CSV"
```

## Servicio

```sh
sudo systemctl status val
sudo systemctl restart val
journalctl -u val -f
journalctl -u val -f | grep "\[VAL-ERROR\]"
```

## Modo VAL-Aware (notificación push)

Con `BUMP_LISTEN_PORT` distinto de 0, VAL abre un socket UDP y escucha notificaciones push de VAS. Cuando VAS ejecuta `bump_version`, el hook `val-local` envía un datagrama UDP; VAL interrumpe su `sleep` y consulta `/version` inmediatamente, reduciendo la latencia de reacción a milisegundos.

```ini
# /etc/val/val.conf
BUMP_LISTEN_PORT=9876
```

Requiere:
1. El paquete `netcat-openbsd` instalado en el sistema VAL (se instala como `Recommends`).
2. El hook `val-local` activo en VAS (`/etc/vas/hooks.d/val-local`).
3. Que el equipo cliente haya publicado `inform.url` en VAC:
   ```bash
   echo '{"url":"IP_VAL:9876"}' | vac-register --imperative --key inform -
   ```

Los sleeps de error (`RETRY_SECONDS`) no son interrumpibles; solo lo son los del ciclo normal (`CHECK_SECONDS`).

## Paralelización (sub-instancias)

VAL puede gestionar múltiples instancias paralelas, cada una con su propio `SOURCE`/`VAS_HOST`, hooks y estado. Útil para consumir simultáneamente inventarios de varios servidores VAS.

### Crear y activar una sub-instancia

```bash
# Crear sub-instancia apuntando a un segundo VAS
val-sub-instance --create samba --vas http://10.0.2.1:8000

# Activar paralelización en val.conf
echo 'PARALLELIZATION=true' >> /etc/val/val.conf
systemctl restart val
```

### Estructura de directorios

```
/etc/val/val.sub/
└── samba/
    ├── val.conf          # Solo VAS_HOST; hereda /etc/val/val.conf
    ├── val.conf.d/
    └── hooks.d/

/var/lib/val/sub/
└── samba/
    ├── version
    ├── clients.json
    └── KEY_clients.json
```

### Modos de activación

| Modo | Comando |
|---|---|
| Junto a la instancia principal (`PARALLELIZATION=true`) | `systemctl restart val` |
| Standalone (sin instancia principal) | `systemctl start val-sub` |

### Gestión de sub-instancias

```bash
val-sub-instance --list                        # listar sub-instancias y estado
val-sub-instance --create nombre --vas http://IP:PORT
val-sub-instance --create nombre --source vac  # desde VAC local
val-sub-instance --delete nombre               # elimina config y estado
```

### Logging

| Proceso | Journal | Prefijo filtrable |
|---|---|---|
| `val` (instancia principal) | `val.service` | `[VAL]` |
| `val-sub-manager` (hijo de val) | `val.service` | `[VAL] [PARALLEL]` |
| `val-sub samba` | `val.service` | `[SAMBA-VAL]` |
| `val-sub-manager` (standalone) | `val-sub.service` | `[VAL] [PARALLEL]` |
| `val-sub samba` (standalone) | `val-sub.service` | `[SAMBA-VAL]` |

```bash
journalctl -u val     | grep '\[PARALLEL\]'
journalctl -u val     | grep '\[SAMBA-VAL\]'
journalctl -u val-sub | grep '\[SAMBA-VAL\]'
```

## Notas

- El daemon es **idempotente**: puede reiniciarse sin perder estado.
- Si no hay hooks ejecutables en `hooks.d/`, el ciclo se ejecuta igualmente (sin errores).
- `vx-dga-l-veyon-sync` sigue siendo el componente recomendado para integración con Veyon. VAL está diseñado para casos de uso adicionales o complementarios.
