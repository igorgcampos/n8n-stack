#!/usr/bin/env bash
set -euo pipefail

# Cria diretório de dados com o UID correto (1000 = node user da imagem n8n)
mkdir -p n8n-data
chown -R 1000:1000 n8n-data

if [ ! -f n8n-worker.env ]; then
  cp n8n-worker.env.example n8n-worker.env
  echo ""
  echo "Arquivo n8n-worker.env criado a partir do exemplo."
  echo "Edite-o com os valores reais antes de subir o container:"
  echo "  nano n8n-worker.env"
  echo ""
else
  echo "n8n-worker.env já existe — nenhuma alteração feita."
fi
