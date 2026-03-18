#!/bin/bash

set -euo pipefail

# -----------------------------
# CONFIG
# -----------------------------
SERVER_IP="10.105.201.99"
SERVER_USER="mongodb"
DEST_DIR="/home/mongodb/busqueda-de-imagenes"
ARCHIVE_NAME="deploy.tar.gz"

echo "🚀 Iniciando deploy desde Windows a $SERVER_IP..."

# -----------------------------
# CLEANUP LOCAL
# -----------------------------
cleanup() {
  echo "🧹 Limpiando archivos temporales locales..."
  rm -f "$ARCHIVE_NAME" || true
}
trap cleanup EXIT

# -----------------------------
# 1. Crear paquete optimizado
# -----------------------------
echo "📦 Creando paquete..."

# Usamos --exclude para limpiar y pasamos los nombres de las carpetas raíz.
# Esto incluye backend, frontend, nginx y el docker-compose.yml automáticamente.
tar -czf "$ARCHIVE_NAME" \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.next' \
  --exclude='__pycache__' \
  --exclude='.venv' \
  --exclude='uploaded_images' \
  --exclude='uploads' \
  --exclude='*.log' \
  --exclude='.env' \
  --exclude="$ARCHIVE_NAME" \
  --exclude='deploy.sh' \
  backend frontend nginx ssl docker-compose.yml README.md

# Verificamos si el paquete se creó correctamente
if [ -f "$ARCHIVE_NAME" ]; then
    echo "📊 Tamaño del paquete: $(du -sh "$ARCHIVE_NAME" | cut -f1)"
else
    echo "❌ Error: No se pudo crear el archivo comprimido."
    exit 1
fi

# -----------------------------
# 2. Preparar servidor y subir
# -----------------------------
echo "📁 Preparando directorio en servidor..."
ssh "$SERVER_USER@$SERVER_IP" "mkdir -p $DEST_DIR"

echo "⬆️ Subiendo paquete..."
scp "$ARCHIVE_NAME" "$SERVER_USER@$SERVER_IP:$DEST_DIR/"

# -----------------------------
# 3. Deploy remoto
# -----------------------------
echo "🏗️ Ejecutando comandos en el servidor..."

ssh "$SERVER_USER@$SERVER_IP" << EOF
set -euo pipefail

cd $DEST_DIR

# Detectar Docker Compose (v2 o v1)
if docker compose version > /dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

echo "📦 Extrayendo nueva versión..."
rm -rf new_release && mkdir new_release
tar -xzf $ARCHIVE_NAME -C new_release
rm $ARCHIVE_NAME

# Persistencia de archivos .env
if [ -d "current" ]; then
    echo "🔑 Manteniendo archivos .env actuales..."
    [ -f "current/backend/.env" ] && cp "current/backend/.env" "new_release/backend/.env"
    [ -f "current/frontend/.env" ] && cp "current/frontend/.env" "new_release/frontend/.env"
    
    echo "🛑 Bajando servicios anteriores..."
    # Bajamos los servicios desde la carpeta actual para evitar conflictos de red/nombres
    cd current && \$DC down && cd ..
fi

echo "🔁 Actualizando carpeta 'current'..."
# Eliminamos la versión vieja para que no ocupe espacio
rm -rf current_old
[ -d "current" ] && mv current current_old
mv new_release current

echo "🐳 Levantando servicios..."
cd current
\$DC up -d --build

echo "🧼 Limpiando imágenes y contenedores huérfanos..."
docker image prune -f

echo "✅ Proceso remoto terminado"
EOF

echo "---"
echo "✅ Deploy finalizado con éxito."
echo "🌐 Frontend: https://digitalizacion-de-imagenes-test.ater.gob.ar"
echo "🔌 Backend:  https://api-digitalizacion-de-imagenes-test.ater.gob.ar"

# -----------------------------
# 5. Smoke Test (Verificación rápida)
# -----------------------------
echo "🧪 Verificando servicios..."
sleep 5 # Damos unos segundos para que Nginx arranque bien
# -L sigue la redirección HTTP→HTTPS; -k acepta cert autofirmado en caso de ser necesario
STATUS_CODE=$(curl -L -k -o /dev/null -s -w "%{http_code}" https://digitalizacion-de-imagenes-test.ater.gob.ar || echo "000")

if [ "$STATUS_CODE" -eq 200 ] || [ "$STATUS_CODE" -eq 301 ] || [ "$STATUS_CODE" -eq 302 ]; then
    echo "✅ El sitio responde correctamente ($STATUS_CODE)"
else
    echo "⚠️ El sitio devolvió un código $STATUS_CODE. Revisar logs con 'docker compose logs -f'"
fi