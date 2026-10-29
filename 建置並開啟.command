#!/bin/bash
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "尚未安裝 Command Line Tools，正在開啟安裝視窗…裝完後請再雙擊一次這個檔案。"
  xcode-select --install
  read -n 1 -p "按任意鍵關閉"; exit 1
fi
./build.sh 2>&1 | tee build.log
if [ ${PIPESTATUS[0]} -eq 0 ]; then open PadCast.app; else echo "建置失敗，錯誤已存到 build.log"; read -n 1 -p "按任意鍵關閉"; fi
