# MemMonitor

Medidor de **memória, bateria e saúde** do Mac na barra de menu. Clica no ícone da RAM e abre um painel com três abas:
**Memória** (anel, quatro cards clicáveis — Apps, Sistema, Comprimida e CPU — com os detalhes de cada um embaixo, botão Fechar e Liberar memória), **Bateria** (percentual, potência do carregador, saúde, ciclos)
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

## Atualizações dentro do app

A partir da **versão 1.1** o app confere sozinho se há versão nova (ao abrir e a cada 12 h). Quando houver, aparece uma faixa verde no painel
com o botão **Atualizar**: ele baixa a release, confere o identificador, a versão e a assinatura, troca o app e reabre.
Se algo não confere, o app atual fica como está. Quem ainda estiver na 1.0 precisa rodar a linha de instalação acima **uma vez**.

## Sem pedir senha (opcional)

O botão **Liberar memória** (`purge`) e o interruptor do **modo de pouca energia** (`pmset`) só rodam como administrador. O `tirar-senha.sh` cria uma regra que libera **só estes 3 comandos exatos**: `purge`, `pmset -a lowpowermode 0` e `pmset -a lowpowermode 1`:

```bash
curl -fsSL https://raw.githubusercontent.com/nandomontenegro88-spec/mac-memmonitor/main/tirar-senha.sh | bash
```

Para desfazer: `sudo rm /etc/sudoers.d/memmonitor`.
Quem já tinha rodado o script na 1.0 precisa rodar **de novo** uma vez, para incluir o modo de pouca energia.

## Bom saber

- *Liberar memória* esvazia só o cache de arquivos; o macOS volta a enchê-lo. O que baixa o uso de verdade é fechar apps pesados.
- Os gráficos guardam ~2 h e começam vazios sempre que o app abre.
- Na aba Saúde, o macOS pode perguntar se o app pode controlar o *System Events* (para listar os itens de início).
- A única conexão do app é perguntar ao GitHub qual é a última versão (no máximo a cada 12 h); não envia nada do seu Mac.

## Desinstalar

Sai pelo ícone da barra de menu, apaga `MemMonitor.app` de Aplicativos e, se usaste o passo sem-senha, `sudo rm /etc/sudoers.d/memmonitor`.

## Testes

```bash
bash tests/run.sh
```

Compila com `-DDEBUG` e roda os testes embutidos (comparação de versões, leitura do `pmset`, formatação, leitura de CPU e memória).

## Compilar

```bash
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 src/MemMonitor.swift -o MemMonitor
```
(precisa do Xcode ou das Command Line Tools). O código está em [`src/MemMonitor.swift`](src/MemMonitor.swift).
