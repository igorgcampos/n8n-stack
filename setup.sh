#!/usr/bin/env bash
#
# Provisionamento do stack n8n (Postgres + Redis + n8n + nginx).
#
#   Uso:  sudo ./setup.sh
#
# Idempotente: cria diretórios/segredos/cert apenas se ainda não existirem e
# NUNCA sobrescreve segredos já presentes. Pode ser rodado novamente com
# segurança (ele apenas corrige permissões e sobe o stack).
#
set -euo pipefail

DOMAIN="n8n.edglobo.com.br"

cd "$(dirname "$(readlink -f "$0")")"

# Precisa de root: faz chown para os uids usados dentro dos containers
# (postgres/redis = 999, n8n = 1000) e grava arquivos de segredo restritos.
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERRO: rode como root  ->  sudo ./setup.sh" >&2
  exit 1
fi

echo "==> 1/5  Diretórios de dados (bind-mounts) + permissões"
mkdir -p postgres-data redis-data n8n-data secrets nginx/certs
chown 999:999   postgres-data redis-data   # postgres e redis rodam como uid 999
chown 1000:1000 n8n-data                    # n8n roda como uid 1000

echo "==> 2/5  Segredos (gera se ausente; reaproveita o existente p/ manter consistência)"
PGPW=$(   [[ -f secrets/postgres_password.txt ]] && cat secrets/postgres_password.txt || openssl rand -hex 24 )
REDISPW=$( [[ -f .env     ]] && grep -oP '^REDIS_PASSWORD=\K.*'     .env     || openssl rand -hex 24 )
ENCKEY=$(  [[ -f n8n.env  ]] && grep -oP '^N8N_ENCRYPTION_KEY=\K.*' n8n.env  || openssl rand -hex 16 )

# secrets/postgres_password.txt — sem newline final; legível só pelo uid 999
if [[ ! -f secrets/postgres_password.txt ]]; then
  printf '%s' "$PGPW" > secrets/postgres_password.txt
  echo "   - secrets/postgres_password.txt criado"
fi
chown 999:999 secrets/postgres_password.txt
chmod 400     secrets/postgres_password.txt

# .env (interpolado pelo docker compose: senha do redis)
if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDISPW}|" .env
  chmod 600 .env
  echo "   - .env criado"
fi

# n8n.env (env_file do container n8n)
if [[ ! -f n8n.env ]]; then
  cp n8n.env.example n8n.env
  sed -i "s|^DB_POSTGRESDB_PASSWORD=.*|DB_POSTGRESDB_PASSWORD=${PGPW}|"          n8n.env
  sed -i "s|^QUEUE_BULL_REDIS_PASSWORD=.*|QUEUE_BULL_REDIS_PASSWORD=${REDISPW}|" n8n.env
  sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${ENCKEY}|"               n8n.env
  chmod 600 n8n.env
  echo "   - n8n.env criado"
fi

echo "==> 3/5  Certificado TLS (self-signed se ausente)"
if [[ ! -f nginx/certs/server.crt || ! -f nginx/certs/server.key ]]; then
  IP=$(hostname -I | awk '{print $1}')
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout nginx/certs/server.key -out nginx/certs/server.crt \
    -days 825 -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},IP:${IP}" 2>/dev/null
  echo "   - self-signed gerado (CN=${DOMAIN}, IP=${IP})"
  echo "   - ATENÇÃO: troque por um certificado real da CA quando disponível."
fi
chmod 600 nginx/certs/server.key
chmod 644 nginx/certs/server.crt

echo "==> 4/5  Validando docker-compose"
docker compose config -q && echo "   - compose OK"

echo "==> 5/5  Subindo o stack"
docker compose up -d

echo
echo "Concluído. Status:  docker compose ps"
echo "Acesso:  https://${DOMAIN}   (ou https://$(hostname -I | awk '{print $1}') enquanto o DNS não resolver)"
