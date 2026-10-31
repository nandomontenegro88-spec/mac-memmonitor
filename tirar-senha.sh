#!/bin/bash
# Deixa o MemMonitor funcionar sem pedir a senha do Mac no botão "Liberar memória" e no modo de pouca energia.
# Libera SÓ estes 3 comandos exatos para o seu usuário. Nada mais:
#   /usr/sbin/purge
#   /usr/bin/pmset -a lowpowermode 0
#   /usr/bin/pmset -a lowpowermode 1
#   bash tirar-senha.sh           -> instala a regra
#   bash tirar-senha.sh desfazer  -> remove a regra
set -e

REGRA=/etc/sudoers.d/memmonitor

if [ "$1" = "desfazer" ]; then
  sudo rm -f "$REGRA"
  echo "Regra removida. Os dois botões voltaram a pedir a senha."
  exit 0
fi

TMP="$(mktemp)"
echo "$(id -un) ALL=(root) NOPASSWD: /usr/sbin/purge, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1" > "$TMP"

# valida a sintaxe antes de instalar (um erro num arquivo sudoers pode bloquear o sudo)
sudo visudo -cf "$TMP"
sudo install -m 440 -o root -g wheel "$TMP" "$REGRA"
rm -f "$TMP"

# confirma que funciona: lê a lista de regras (`sudo -l` sobre um comando dá falso positivo para quem é administrador)
sudo -k
if sudo -n /usr/sbin/purge && sudo -n -l 2>/dev/null | grep -q "NOPASSWD:.*lowpowermode 0" && sudo -n -l 2>/dev/null | grep -q "NOPASSWD:.*lowpowermode 1"; then
  echo "Pronto: 'Liberar memória' e o modo de pouca energia já não pedem a senha."
else
  echo "A regra foi instalada, mas o teste falhou. Corre 'bash tirar-senha.sh desfazer' e tenta de novo."
  exit 1
fi
