# MemMonitor

Medidor de **memória, bateria e saúde** do Mac na barra de menu. Clica no ícone da RAM e abre um painel com três abas:
**Memória** (apps que mais pesam, botão Fechar, Liberar memória), **Bateria** (percentual, potência do carregador, saúde, ciclos)
e **Saúde** (selo geral, disco, rede, CPU e itens de início).

Requisitos: Mac com **chip Apple** (M1 ou mais novo) e **macOS 14+**.

## Instalar ou atualizar (uma linha)

Cola no Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nandomontenegro88-spec/mac-memmonitor/main/install.sh | bash
```

Roda de novo a mesma linha para atualizar. O script baixa o app, confere a assinatura, instala em Aplicativos e abre.
Como o download é feito pelo Terminal, o macOS **não** mostra o aviso de "desenvolvedor não verificado".
No fim ele pergunta se queres tirar o pedido de senha do botão **Liberar memória**.

> Antes de rodar qualquer `curl | bash`, vale ler o script: [`install.sh`](install.sh).

## Sem pedir senha no "Liberar memória" (opcional)

O `purge` só roda como administrador. O `tirar-senha.sh` cria uma regra que libera **só esse comando**:

```bash
curl -fsSL https://raw.githubusercontent.com/nandomontenegro88-spec/mac-memmonitor/main/tirar-senha.sh | bash
```

Para desfazer: `sudo rm /etc/sudoers.d/memmonitor`.
O **modo de pouca energia** continua pedindo a senha sempre, de propósito.

## Bom saber

- *Liberar memória* esvazia só o cache de arquivos; o macOS volta a enchê-lo. O que baixa o uso de verdade é fechar apps pesados.
- Os gráficos guardam ~2 h e começam vazios sempre que o app abre.
- Na aba Saúde, o macOS pode perguntar se o app pode controlar o *System Events* (para listar os itens de início).
- O app não envia nada para a internet.

## Desinstalar

Sai pelo ícone da barra de menu, apaga `MemMonitor.app` de Aplicativos e, se usaste o passo sem-senha, `sudo rm /etc/sudoers.d/memmonitor`.

## Compilar

```bash
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 src/MemMonitor.swift -o MemMonitor
```
(precisa do Xcode ou das Command Line Tools). O código está em [`src/MemMonitor.swift`](src/MemMonitor.swift).
