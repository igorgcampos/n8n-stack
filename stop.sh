#!/bin/bash
# [CORRIGIDO] "stop" com timeout em vez de "down": preserva os containers
# (start mais rápido) e dá até 120s para o n8n concluir execuções em andamento
cd /opt/n8n && docker compose stop -t 120
