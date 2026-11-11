#!/bin/zsh
cd "$(dirname "$0")"
echo "=== build started $(date)" > build.log
swift build >> build.log 2>&1
echo "EXIT=$?" >> build.log
