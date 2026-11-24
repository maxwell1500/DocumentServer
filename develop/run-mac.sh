#!/usr/bin/env bash
# Native macOS runner for Euro-Office DocumentServer (DocService + FileConverter).
# Requires PostgreSQL (or MySQL), Redis, and RabbitMQ running locally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_DIR="${DS_ROOT}/server"

CORE_DIR="${EO_CORE_DIR:-/Users/max/Projects/Euro-Office/macos-stage/converter}"
EDITORS_DIR="${EO_EDITORS_DIR:-/Users/max/Projects/Euro-Office/DesktopEditors/build/deploy/common/editors}"
DICT_DIR="${EO_DICT_DIR:-/Users/max/Projects/Euro-Office/DesktopEditors/dictionaries}"

if [ ! -x "${CORE_DIR}/x2t" ]; then
    echo "error: ${CORE_DIR}/x2t not found. Set EO_CORE_DIR to your built macOS converter dir." >&2
    exit 1
fi
if [ ! -d "${EDITORS_DIR}/web-apps" ] || [ ! -d "${EDITORS_DIR}/sdkjs" ]; then
    echo "error: ${EDITORS_DIR}/{web-apps,sdkjs} not found. Set EO_EDITORS_DIR." >&2
    exit 1
fi

CONFIG_DIR="${SERVER_DIR}/Common/config"
cat > "${CONFIG_DIR}/local-mac.json" <<EOF
{
  "services": {
    "CoAuthoring": {
      "server": {
        "port": 8000,
        "static_content": {
          "/fonts": { "path": "${CORE_DIR}" },
          "/sdkjs": { "path": "${EDITORS_DIR}/sdkjs" },
          "/web-apps": { "path": "${EDITORS_DIR}/web-apps" },
          "/sdkjs-plugins": { "path": "${EDITORS_DIR}/sdkjs-plugins" },
          "/dictionaries": { "path": "${DICT_DIR}" }
        }
      },
      "sql": {
        "type": "${EO_SQL_TYPE:-postgres}",
        "dbHost": "${EO_DB_HOST:-localhost}",
        "dbPort": ${EO_DB_PORT:-5432},
        "dbName": "${EO_DB_NAME:-onlyoffice}",
        "dbUser": "${EO_DB_USER:-onlyoffice}",
        "dbPass": "${EO_DB_PASS:-onlyoffice}"
      },
      "redis": {
        "host": "${EO_REDIS_HOST:-127.0.0.1}",
        "port": ${EO_REDIS_PORT:-6379}
      }
    }
  },
  "rabbitmq": {
    "url": "${EO_AMQP_URL:-amqp://localhost:5672}"
  },
  "FileConverter": {
    "converter": {
      "x2tPath": "${CORE_DIR}/x2t",
      "docbuilderPath": "${CORE_DIR}/docbuilder",
      "presentationThemesDir": "${EDITORS_DIR}/sdkjs/slide/themes",
      "fontDir": "${CORE_DIR}"
    }
  }
}
EOF

export NODE_ENV="mac"
export NODE_CONFIG_ENV="local-mac"
export NODE_CONFIG_DIR="${CONFIG_DIR}"
export DYLD_LIBRARY_PATH="${CORE_DIR}:${DYLD_LIBRARY_PATH:-}"

echo "==> Starting FileConverter and DocService (http://localhost:8000)"
trap 'kill 0' EXIT INT TERM
(cd "${SERVER_DIR}/FileConverter" && node sources/convertermaster.js) &
(cd "${SERVER_DIR}/DocService" && node sources/server.js) &
wait
