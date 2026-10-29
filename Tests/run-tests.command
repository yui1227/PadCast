#!/bin/bash
cd "$(dirname "$0")/.."
mkdir -p build && chmod +x Tests/run-tests.sh
./Tests/run-tests.sh 2>&1 | tee build/test-log.txt
echo
read -n 1 -p "按任意鍵關閉"
