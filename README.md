# vx-dga-l-vcd — Vitalinux Consumer Daemon

Daemon genérico que observa cambios de versión en el inventario de **VAS** o **VAC** y distribuye el resultado filtrado a hooks configurables mediante tuberías.

No modifica ni requiere cambios en VAS ni en VAC.

## ¿Qué hace?

1. Compara periódicamente la versión remota del inventario con la última conocida.
2. Si detecta un cambio, descarga el inventario filtrado.
3. Ejecuta en orden lexical todos los scripts ejecutables de `hooks.d/`, pasando el JSON por stdin.

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
| `all` | Todos | Solo `vas` |

> Con `SOURCE=vac`, VAC descarga únicamente clientes activos. `FILTER=inactive` o `FILTER=all` pueden dar resultados incompletos.

## Archivos instalados

| Ruta | Descripción |
|---|---|
| `/usr/bin/vcd` | Daemon principal |
| `/usr/share/vcd/vcd.conf.defaults` | Referencia de valores por defecto (solo lectura) |
| `/etc/vcd/vcd.conf` | Configuración principal |
| `/etc/vcd/vcd.conf.d/` | Overlays de configuración (orden lexical) |
| `/etc/vcd/hooks.d/` | Scripts hook ejecutables |
| `/var/lib/vcd/version` | Última versión procesada |
| `/var/lib/vcd/clients.json` | Último inventario descargado |

## Configuración

Edita `/etc/vcd/vcd.conf` o añade un fichero en `/etc/vcd/vcd.conf.d/`. Los overlays tienen prioridad sobre el conf principal.

Tras cualquier cambio, reinicia el servicio:

```sh
sudo systemctl restart vcd
```

### Variables disponibles

| Variable | Por defecto | Descripción |
|---|---|---|
| `SOURCE` | `vas` | Fuente de datos: `vas` o `vac` |
| `VAS_HOST` | `http://127.0.0.1:8000` | URL del servidor VAS (solo `SOURCE=vas`) |
| `FILTER` | `active` | Filtro de clientes: `active`, `inactive`, `all` |
| `CHECK_SECONDS` | `300` | Intervalo entre comprobaciones de versión |
| `RETRY_SECONDS` | `60` | Espera ante errores de conexión o hooks fallidos |
| `HOOKS_DIR` | `/etc/vcd/hooks.d` | Directorio con los scripts hook |
| `VAC_STATE_DIR` | `/var/lib/vac` | Directorio de estado de VAC (solo `SOURCE=vac`) |

## Hooks

Los scripts de `hooks.d/` se ejecutan en **orden lexical**. Un hook que falla no interrumpe la cadena.

### Contrato de un hook

- **Stdin**: inventario JSON completo (`{ "clients": [...] }`)
- **Variables de entorno**:
  - `VCD_VERSION` → versión que disparó la ejecución
  - `VCD_FILTER` → filtro activo (`active`/`inactive`/`all`)
  - `VCD_SOURCE` → fuente usada (`vas`/`vac`)
- **Retorno**: `0` = éxito, cualquier otro = warning en log, continúa

### Ejemplo de hook

```sh
#!/bin/bash
# /etc/vcd/hooks.d/10-log.sh
# Guarda el inventario en un fichero de log con timestamp.

echo "=== $VCD_VERSION ($VCD_FILTER via $VCD_SOURCE) ===" >> /var/log/vcd-inventory.log
jq '.clients | length' >> /var/log/vcd-inventory.log
```

```sh
chmod +x /etc/vcd/hooks.d/10-log.sh
```

### Reconstruir veyon-sync como hook

Un hook equivalente a `vx-dga-l-veyon-sync` en ~15 líneas:

```sh
#!/bin/bash
# /etc/vcd/hooks.d/20-veyon.sh
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
sudo systemctl status vcd
sudo systemctl restart vcd
journalctl -u vcd -f
journalctl -u vcd -f | grep "\[VCD-ERROR\]"
```

## Notas

- El daemon es **idempotente**: puede reiniciarse sin perder estado.
- Si no hay hooks ejecutables en `hooks.d/`, el ciclo se ejecuta igualmente (sin errores).
- `vx-dga-l-veyon-sync` sigue siendo el componente recomendado para integración con Veyon. VCD está diseñado para casos de uso adicionales o complementarios.
