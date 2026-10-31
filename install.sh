#!/bin/bash
# Instala (ou atualiza) o MemMonitor. Uso:
#   curl -fsSL https://raw.githubusercontent.com/nandomontenegro88-spec/mac-memmonitor/main/install.sh | bash
set -euo pipefail

REPO="nandomontenegro88-spec/mac-memmonitor"
ZIP_URL="https://github.com/$REPO/releases/latest/download/MemMonitor.zip"
RAW="https://raw.githubusercontent.com/$REPO/main"

# requisitos: chip Apple + macOS 14 ou mais novo
[ "$(uname -m)" = "arm64" ] || { echo "O MemMonitor só funciona em Macs com chip Apple (M1 ou mais novo)."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "Precisa de macOS 14 ou mais novo."; exit 1; }

# onde instalar: /Applications se der, senão ~/Applications
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "A baixar o MemMonitor…"
curl -fsSL "$ZIP_URL" -o "$TMP/MemMonitor.zip"
ditto -x -k "$TMP/MemMonitor.zip" "$TMP/out"
APP="$(find "$TMP/out" -maxdepth 2 -name MemMonitor.app | head -1)"
[ -n "$APP" ] || { echo "Não encontrei o MemMonitor.app no download."; exit 1; }
codesign --verify "$APP" || { echo "A assinatura do app não confere. Abortei."; exit 1; }

# fecha a versão que estiver aberta e substitui
pkill -x MemMonitor 2>/dev/null || true
sleep 1
rm -rf "$DEST/MemMonitor.app"
ditto "$APP" "$DEST/MemMonitor.app"
xattr -cr "$DEST/MemMonitor.app" 2>/dev/null || true

echo "Instalado em $DEST/MemMonitor.app"
open "$DEST/MemMonitor.app"

# passo opcional: o botão "Liberar memória" sem pedir a senha (precisa do /dev/tty porque o script vem por pipe)
if [ -r /dev/tty ] && ! sudo -n /usr/sbin/purge >/dev/null 2>&1; then
  printf "Quer que o botão 'Liberar memória' pare de pedir a senha? (só libera o comando purge) [s/N] " > /dev/tty
  read -r ans < /dev/tty || ans=""
  if [ "$ans" = "s" ] || [ "$ans" = "S" ]; then
    curl -fsSL "$RAW/tirar-senha.sh" | bash
  fi
fi

echo "Pronto. Procura o ícone de chip com o uso de RAM na barra de menu."
