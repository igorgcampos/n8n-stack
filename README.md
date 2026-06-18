# n8n — Stack de produção (Docker Compose)

Self-hosted do **n8n** em modo fila (`queue`), com PostgreSQL, Redis e nginx
fazendo terminação TLS na frente. Pensado para rodar atrás da rede interna e,
opcionalmente, ter *workers* externos (ex.: GCP) consumindo a fila via VPN.

## Arquitetura

```
            ┌───────── nginx (TLS) ─────────┐
 cliente ──▶│ :80 → 301 → :443  →  n8n:5678 │
   HTTPS    └───────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                 ▼
   postgres:5432     redis:6379        n8n (main)
   (banco)           (fila Bull)       EXECUTIONS_MODE=queue
```

| Serviço  | Imagem                  | uid   | Exposição                  |
|----------|-------------------------|-------|----------------------------|
| postgres | `postgres:18.4`         | 999   | `5432` (host → worker GCP) |
| redis    | `redis:8.6.4`           | 999   | `6379` (host → worker GCP) |
| n8n      | `n8nio/n8n:2.26.7`      | 1000  | interno `5678` (via nginx) |
| nginx    | `nginx:trixie-perl`     | root* | `80`, `443` (host)         |

\* nginx sobe o master como root só para fazer *bind* nas portas 80/443; os
workers caem para usuário sem privilégio. Containers rodam com `read_only: true`,
`no-new-privileges` e diretórios temporários em `tmpfs`.

## Pré-requisitos

- Docker Engine + plugin `docker compose`
- `openssl` (geração de segredos e do certificado de teste)
- Acesso `sudo` (os segredos e os volumes são de propriedade dos uids dos containers)

## Subir do zero (clone novo)

Os segredos, certificados e dados **não** são versionados (ver `.gitignore`).
O script `setup.sh` provisiona tudo de forma idempotente:

```bash
sudo ./setup.sh
```

Ele:
1. cria `postgres-data/`, `redis-data/`, `n8n-data/` com o dono correto
   (`999:999` para postgres/redis, `1000:1000` para n8n);
2. gera segredos aleatórios e os grava de forma **consistente** em
   `.env`, `n8n.env` e `secrets/postgres_password.txt` (reaproveita os que já existirem);
3. gera um certificado **self-signed** em `nginx/certs/` (se ainda não houver);
4. valida o compose e sobe o stack.

Verifique:

```bash
docker compose ps          # todos healthy
curl -sk https://localhost/healthz -H "Host: n8n.editoraglobo.com.br"
```

## Provisionamento manual (equivalente ao script)

```bash
# 1) permissões dos volumes
mkdir -p postgres-data redis-data n8n-data
sudo chown 999:999  postgres-data redis-data
sudo chown 1000:1000 n8n-data

# 2) segredos (use os MESMOS valores onde indicado)
cp .env.example .env
cp n8n.env.example n8n.env
openssl rand -hex 24 | tr -d '\n' | sudo tee secrets/postgres_password.txt   # sem newline!
sudo chown 999:999 secrets/postgres_password.txt && sudo chmod 400 secrets/postgres_password.txt
#   -> edite .env e n8n.env preenchendo:
#      REDIS_PASSWORD  == QUEUE_BULL_REDIS_PASSWORD
#      DB_POSTGRESDB_PASSWORD == conteúdo de secrets/postgres_password.txt
#      N8N_ENCRYPTION_KEY = openssl rand -hex 16

# 3) certificado (self-signed de teste — troque pelo real depois)
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout nginx/certs/server.key -out nginx/certs/server.crt \
  -days 825 -subj "/CN=n8n.editoraglobo.com.br" \
  -addext "subjectAltName=DNS:n8n.editoraglobo.com.br"

# 4) subir
docker compose up -d
```

## Segredos e arquivos versionados

| Versionado ✓                         | Ignorado 🔒 (nunca commitar)          |
|--------------------------------------|---------------------------------------|
| `docker-compose.yml`, `nginx/nginx.conf` | `.env`, `n8n.env`                 |
| `start.sh`, `stop.sh`, `setup.sh`    | `secrets/postgres_password.txt`       |
| `*.example`, `README.md`             | `nginx/certs/server.{crt,key}`        |
| `.gitignore`                         | `postgres-data/`, `redis-data/`, `n8n-data/` |

> A chave `N8N_ENCRYPTION_KEY` cifra as credenciais salvas no n8n.
> **Faça backup dela** — sem ela, as credenciais existentes ficam ilegíveis.

## TLS / certificado

`setup.sh` cria um certificado **self-signed** só para o stack subir; o navegador
vai alertar "não confiável". Para usar o certificado real da CA:

```bash
sudo cp empresa.crt nginx/certs/server.crt
sudo cp empresa.key nginx/certs/server.key
sudo chmod 600 nginx/certs/server.key
docker compose exec nginx nginx -s reload
```

## Operação

```bash
./start.sh                              # docker compose up -d
./stop.sh                               # stop com timeout de 120s (preserva execuções)
docker compose ps                       # status / health
docker compose logs -f n8n              # logs
docker compose exec nginx nginx -t      # validar config do nginx
docker compose exec nginx nginx -s reload   # recarregar nginx (cert/config)
```

- **Alterou `n8n.env` ou `.env`?** recrie o container para reler as variáveis:
  `docker compose up -d --force-recreate n8n`
- **Alterou só `nginx/nginx.conf` ou o cert?** basta `nginx -s reload`.

## Acesso

- URL: **https://n8n.editoraglobo.com.br** (aponte o DNS para este host).
- Enquanto o DNS não resolver, acesse pelo IP do host (o cert self-signed já
  inclui o IP no SAN) — o aviso de certificado some quando o cert real for instalado.
- `http://` é redirecionado para `https://` automaticamente.

## Notas

- **Modo fila:** `EXECUTIONS_MODE=queue` usa o Redis como broker. As portas
  `5432`/`6379` estão publicadas no host para um *worker* externo (GCP) acessar
  via VPN/Interconnect — **restrinja esse acesso no firewall** à rede da VPN.
- **`N8N_PROXY_HOPS=1`:** o n8n confia no `X-Forwarded-Proto` enviado pelo nginx
  para montar URLs `https`. Não acrescente proxies sem ajustar esse valor.
- **Worker externo:** ao adicionar workers, considere
  `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` no `n8n.env`.
