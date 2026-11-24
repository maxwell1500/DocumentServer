#!/usr/bin/env bash
# Native macOS runner for Euro-Office DocumentServer:
#   - Embedded PostgreSQL (:5432)
#   - Local AMQP 1.0 broker via rhea (:5672)
#   - FileConverter (x2t / docbuilder)
#   - DocService (http://127.0.0.1:8000)
#   - Integration Example App (http://127.0.0.1:3000)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_DIR="${DS_ROOT}/server"
EXAMPLE_DIR="${DS_ROOT}/document-server-integration/web/documentserver-example/nodejs"

CORE_DIR="${EO_CORE_DIR:-/Users/max/Projects/Euro-Office/macos-stage/converter}"
EDITORS_DIR="${EO_EDITORS_DIR:-/Users/max/Projects/Euro-Office/macos-stage/editors}"
DICT_DIR="${EO_DICT_DIR:-/Users/max/Projects/Euro-Office/DesktopEditors/dictionaries}"

if [ ! -x "${CORE_DIR}/x2t" ]; then
    echo "error: ${CORE_DIR}/x2t not found. Set EO_CORE_DIR to your built macOS converter dir." >&2
    exit 1
fi
if [ ! -d "${EDITORS_DIR}/web-apps" ] || [ ! -d "${EDITORS_DIR}/sdkjs" ]; then
    echo "error: ${EDITORS_DIR}/{web-apps,sdkjs} not found. Set EO_EDITORS_DIR." >&2
    exit 1
fi

# Ensure DoctRenderer.config relative ../dictionaries resolves
STAGE_PARENT="$(cd "${CORE_DIR}/.." && pwd)"
if [ ! -e "${STAGE_PARENT}/dictionaries" ] && [ -d "${DICT_DIR}" ]; then
    ln -sfn "${DICT_DIR}" "${STAGE_PARENT}/dictionaries"
fi

# Generate web fonts once if missing and allfontsgen is available
if [ ! -f "${EDITORS_DIR}/fonts/000" ] && [ -x "${STAGE_PARENT}/stage-generators/allfontsgen" ] && [ -d "${STAGE_PARENT}/fonts" ]; then
    echo "==> Generating web fonts with allfontsgen"
    mkdir -p "${EDITORS_DIR}/fonts"
    DYLD_LIBRARY_PATH="${CORE_DIR}:${DYLD_LIBRARY_PATH:-}" \
        "${STAGE_PARENT}/stage-generators/allfontsgen" \
        --input="${STAGE_PARENT}/fonts" \
        --allfonts-web="${EDITORS_DIR}/sdkjs/common/AllFonts.js" \
        --allfonts="${CORE_DIR}/AllFonts.js" \
        --images="${EDITORS_DIR}/sdkjs/common/Images" \
        --selection="${CORE_DIR}/font_selection.bin" \
        --output-web="${EDITORS_DIR}/fonts" \
        --use-system="true"
fi

mkdir -p "${SERVER_DIR}/App_Data"

CONFIG_DIR="${SERVER_DIR}/Common/config"
cat > "${CONFIG_DIR}/local-mac.json" <<EOF
{
  "log": {
    "filePath": "../Common/config/log4js/development.json"
  },
  "storage": {
    "fs": {
      "folderPath": "../App_Data"
    }
  },
  "queue": {
    "type": "activemq"
  },
  "activemq": {
    "connectOptions": {
      "host": "127.0.0.1",
      "port": 5672,
      "reconnect": false
    }
  },
  "wopi": {
    "enable": true
  },
  "services": {
    "CoAuthoring": {
      "server": {
        "port": 8000,
        "static_content": {
          "/fonts": { "path": "${EDITORS_DIR}/fonts" },
          "/sdkjs": { "path": "${EDITORS_DIR}/sdkjs" },
          "/web-apps": { "path": "${EDITORS_DIR}/web-apps" },
          "/sdkjs-plugins": { "path": "${EDITORS_DIR}/sdkjs-plugins" },
          "/dictionaries": { "path": "${DICT_DIR}" },
          "/welcome": { "path": "${SERVER_DIR}/branding/welcome" },
          "/info": { "path": "${SERVER_DIR}/branding/info" }
        }
      },
      "utils": {
        "utils_common_fontdir": "/Library/Fonts"
      },
      "request-filtering-agent": {
        "allowPrivateIPAddress": true,
        "allowMetaIPAddress": true
      },
      "sql": {
        "type": "${EO_SQL_TYPE:-postgres}",
        "dbHost": "${EO_DB_HOST:-127.0.0.1}",
        "dbPort": ${EO_DB_PORT:-5432},
        "dbName": "${EO_DB_NAME:-onlyoffice}",
        "dbUser": "${EO_DB_USER:-onlyoffice}",
        "dbPass": "${EO_DB_PASS:-onlyoffice}"
      },
      "token": {
        "enable": {
          "browser": false,
          "request": {
            "inbox": false,
            "outbox": false
          }
        }
      }
    }
  },
  "FileConverter": {
    "converter": {
      "workercount": ${EO_CONVERTER_WORKERS:-2},
      "x2tPath": "${CORE_DIR}/x2t",
      "docbuilderPath": "${CORE_DIR}/docbuilder",
      "presentationThemesDir": "${EDITORS_DIR}/sdkjs/slide/themes",
      "fontDir": "${CORE_DIR}"
    }
  }
}
EOF

wait_port() {
    local host="$1" port="$2" name="$3"
    for _ in $(seq 1 60); do
        if nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "error: timed out waiting for ${name} on ${host}:${port}" >&2
    return 1
}

PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do
        kill "$p" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

echo "==> Starting local PostgreSQL"
PG_READY_FILE="${SERVER_DIR}/App_Data/.pg-ready"
rm -f "${PG_READY_FILE}"
EO_PG_READY_FILE="${PG_READY_FILE}" node "${SCRIPT_DIR}/pg-local.js" &
PIDS+=($!)
for _ in $(seq 1 120); do
    if [ -f "${PG_READY_FILE}" ]; then
        break
    fi
    if ! kill -0 "${PIDS[0]}" 2>/dev/null; then
        echo "error: pg-local.js exited early" >&2
        exit 1
    fi
    sleep 0.5
done
if [ ! -f "${PG_READY_FILE}" ]; then
    echo "error: timed out waiting for PostgreSQL schema setup" >&2
    exit 1
fi

echo "==> Starting local AMQP 1.0 broker"
node "${SCRIPT_DIR}/amqp-broker.js" &
PIDS+=($!)
wait_port 127.0.0.1 "${EO_AMQP_PORT:-5672}" "AMQP broker"

export NODE_ENV="local-mac"
export NODE_CONFIG_DIR="${CONFIG_DIR}"
export DYLD_LIBRARY_PATH="${CORE_DIR}:${DYLD_LIBRARY_PATH:-}"

echo "==> Starting FileConverter"
(cd "${SERVER_DIR}/FileConverter" && node sources/convertermaster.js) &
PIDS+=($!)

echo "==> Starting DocService (http://127.0.0.1:8000)"
(cd "${SERVER_DIR}/DocService" && node sources/server.js) &
PIDS+=($!)
wait_port 127.0.0.1 8000 "DocService"

if [ -d "${EXAMPLE_DIR}" ]; then
    echo "==> Starting DocumentServer Example App (http://127.0.0.1:3000)"
    (cd "${EXAMPLE_DIR}" && NODE_ENV=development-mac NODE_CONFIG_DIR="${EXAMPLE_DIR}/config" node bin/www) &
    PIDS+=($!)
    wait_port 127.0.0.1 3000 "Example App"
fi

echo ""
echo "=========================================================="
echo "Euro-Office DocumentServer is running!"
echo "  Example App (open in Firefox): http://127.0.0.1:3000/"
echo "  DocumentServer API / Health:   http://127.0.0.1:8000/healthcheck"
echo "=========================================================="
wait
