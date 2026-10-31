#!/bin/bash
# Deixa o botão "Liberar memória" do MemMonitor funcionar sem pedir a senha do Mac.
# Libera SÓ o comando /usr/sbin/purge para o seu usuário. Nada mais.
#   bash tirar-senha.sh           -> instala a regra
#   bash tirar-senha.sh desfazer  -> remove a regra
set -e

REGRA=/etc/sudoers.d/memmonitor

if [ "$1" = "desfazer" ]; then
  sudo rm -f "$REGRA"
  echo "Regra removida. O botão voltou a pedir a senha."
  exit 0
fi

TMP="$(mktemp)"
echo "$(id -un) ALL=(root) NOPASSWD: /usr/sbin/purge" > "$TMP"

# valida a sintaxe antes de instalar (um erro num arquivo sudoers pode bloquear o sudo)
sudo visudo -cf "$TMP"
sudo install -m 440 -o root -g wheel "$TMP" "$REGRA"
rm -f "$TMP"

# confirma que funciona
if sudo -n /usr/sbin/purge; then
  echo "Pronto: o 'Liberar memória' já não pede a senha."
else
  echo "A regra foi instalada, mas o teste falhou. Corre 'bash tirar-senha.sh desfazer' e tenta de novo."
  exit 1
fi
