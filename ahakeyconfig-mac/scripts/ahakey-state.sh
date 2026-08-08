#!/bin/sh
# AhaKey LED 상태 동기화 hook 스크립트
# 사용법: ahakey-state.sh <state_number>
# Unix 소켓을 통해 ahakeyconfig-agent에 알려 LED 상태를 키보드로 전송합니다
#
# Claude Hook 이벤트 → state 매핑:
#   Notification=0  PermissionRequest=1  PostToolUse=2
#   PreToolUse=3    SessionStart=4       Stop=5
#   TaskCompleted=6 UserPromptSubmit=7   SessionEnd=8

SOCKET="/tmp/ahakey.sock"
STATE="${1:-0}"

[ -S "$SOCKET" ] && echo "$STATE" | nc -U "$SOCKET" -w 1 2>/dev/null || true
