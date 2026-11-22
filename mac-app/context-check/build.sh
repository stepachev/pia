#!/bin/zsh
# Сборка проверки из тех же файлов, что и в приложении (Swift 6, строгая проверка потоков).
cd "${0:A:h}"
mode=${1:-6}
timeout 300 swiftc -swift-version $mode -O -o context-check \
  ../Sources/PiaChat/Context/*.swift main.swift 2>&1
