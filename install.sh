#!/bin/bash
# Instala (ou atualiza) o MemMonitor. Uso:
#   curl -fsSL https://raw.githubusercontent.com/nandomontenegro88-spec/mac-memmonitor/main/install.sh | bash
set -euo pipefail

REPO="nandomontenegro88-spec/mac-memmonitor"
ZIP_URL="https://github.com/$REPO/releases/latest/download/MemMonitor.zip"

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
if [ -r /dev/tty ] && ! sudo -n -l /usr/bin/pmset -a lowpowermode 0 >/dev/null 2>&1; then
  printf "Quer que 'Liberar memória' e o modo de pouca energia parem de pedir a senha? (só libera 3 comandos exatos) [s/N] " > /dev/tty
  read -r ans < /dev/tty || ans=""
  if [ "$ans" = "s" ] || [ "$ans" = "S" ]; then
    # o script vem da versão que acabou de ser instalada (a tag), não da branch main: o que corre com sudo não muda por baixo
    TAG="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's|.*/||')"
    if [ -n "$TAG" ] && [ "$TAG" != "latest" ]; then
      curl -fsSL "https://raw.githubusercontent.com/$REPO/$TAG/tirar-senha.sh" | bash
    else
      echo "Não consegui descobrir a versão; pulei esse passo. Dá para fazer depois: bash tirar-senha.sh"
    fi
  fi
fi

echo "Pronto. Procura o ícone de chip com o uso de RAM na barra de menu."
