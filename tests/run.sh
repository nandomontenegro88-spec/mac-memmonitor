#!/bin/bash
# Compila com -DDEBUG e roda os testes embutidos (versões, pmset, formatação, leitura de CPU/memória).
set -e
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/memmonitor-test"
swiftc -O -swift-version 5 -DDEBUG src/MemMonitor.swift -o "$BIN"
"$BIN" --selftest
