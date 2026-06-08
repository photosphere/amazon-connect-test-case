#!/usr/bin/env bash
#
# 端到端测试（方案 3）：直接驱动 Amazon Q in Connect 生成式 bot 走完 "request repair" 报修对话，
# 读取 Lex session attributes / bot 回复 判定工单是否真正生成。
#
# 这是对 CreateTestCase 测试框架的补充——该框架无法观察生成式 bot 的流式回复，
# 因此用 lexv2-runtime recognize-text 直连 bot 验证端到端逻辑。
#
# 判定依据：
#   bot 回复文本中是否出现“工单已创建/已提交”或“处理失败、转人工”
#   Lex session attribute Tool (flow 用 $.Lex.SessionAttributes.Tool 分支): Complete / Escalate
#   x-amz-lex:q-in-connect:conversation-status: READY / CLOSED ...
#
set -uo pipefail

REGION="us-west-2"
BOT_ID="W0MUSVSUH1"
ALIAS_ID="TSTALIASID"
LOCALE="en_US"
SESSION_ID="e2e-repair-$(date +%s)-$RANDOM"
MAX_TURNS=30

# 预设客户资料（按 bot 实际收集的字段）
PHONE="18618383641"          # 完整手机号，尾号 3641
MODEL="BCD-500"
SERIAL="SN1234567890"
PURCHASE_DATE="January 15, 2024"
ISSUE="The device does not power on"
NAME="John Smith"
ADDRESS="100 Main Street, Nanshan, Shenzhen, Guangdong"
PREFERRED_TIME="June 15, 2026 in the morning"
WARRANTY="No, it is not under warranty"

command -v aws >/dev/null 2>&1 || { echo "错误: 未找到 aws CLI" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "错误: 未找到 python3" >&2; exit 1; }

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

# 已回答字段标志（用普通变量，避免关联数组的兼容性问题）
a_model=""; a_serial=""; a_purchase=""; a_issue=""; a_phone=""
a_name=""; a_address=""; a_time=""; a_warranty=""

send() {
  aws lexv2-runtime recognize-text \
    --region "$REGION" --bot-id "$BOT_ID" --bot-alias-id "$ALIAS_ID" \
    --locale-id "$LOCALE" --session-id "$SESSION_ID" \
    --text "$1" --output json > "$RESP_FILE" 2>&1
}

bot_text() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join(m.get('content','') for m in d.get('messages',[])))" "$RESP_FILE" 2>/dev/null
}

attr() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('sessionState',{}).get('sessionAttributes',{}).get(sys.argv[2],''))" "$RESP_FILE" "$1" 2>/dev/null
}

intent_state() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('sessionState',{}).get('intent',{}).get('state',''))" "$RESP_FILE" 2>/dev/null
}

# 根据 bot 的提问内容，选择合适的回答；通过全局变量记录已答字段
route_answer() {
  local q
  q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  # 确认/总结环节优先
  if printf '%s' "$q" | grep -qE "is everything correct|is that correct|confirm|shall i|should i (create|submit)|ready to (create|submit)|everything looks|all correct"; then
    REPLY_TEXT="Yes, everything is correct. Please create the work order."; return
  fi
  if printf '%s' "$q" | grep -q "serial" && [ -z "$a_serial" ]; then
    a_serial=1; REPLY_TEXT="The serial number is $SERIAL"; return
  fi
  if printf '%s' "$q" | grep -qE "model|product|appliance" && [ -z "$a_model" ]; then
    a_model=1; REPLY_TEXT="The product is a refrigerator, model $MODEL"; return
  fi
  if printf '%s' "$q" | grep -qE "purchase|buy|bought|when did you" && [ -z "$a_purchase" ]; then
    a_purchase=1; REPLY_TEXT="I purchased it on $PURCHASE_DATE"; return
  fi
  if printf '%s' "$q" | grep -qE "issue|problem|wrong|experiencing|symptom|not working" && [ -z "$a_issue" ]; then
    a_issue=1; REPLY_TEXT="$ISSUE"; return
  fi
  if printf '%s' "$q" | grep -qE "phone|number to reach|contact number|best number" && [ -z "$a_phone" ]; then
    a_phone=1; REPLY_TEXT="My phone number is $PHONE"; return
  fi
  if printf '%s' "$q" | grep -qE "(full |your )name|may i have your name|who am i" && [ -z "$a_name" ]; then
    a_name=1; REPLY_TEXT="My name is $NAME"; return
  fi
  if printf '%s' "$q" | grep -qE "address|location|where.*(repair|service|pick)" && [ -z "$a_address" ]; then
    a_address=1; REPLY_TEXT="My address is $ADDRESS"; return
  fi
  if printf '%s' "$q" | grep -qE "prefer|date and time|when would you|service visit|schedule|appointment" && [ -z "$a_time" ]; then
    a_time=1; REPLY_TEXT="I prefer $PREFERRED_TIME"; return
  fi
  if printf '%s' "$q" | grep -qE "warranty" && [ -z "$a_warranty" ]; then
    a_warranty=1; REPLY_TEXT="$WARRANTY"; return
  fi

  # 兜底：若所有字段都答过，则催促创建；否则补发尚未回答的字段
  if [ -z "$a_model" ];    then a_model=1;    REPLY_TEXT="The product is a refrigerator, model $MODEL"; return; fi
  if [ -z "$a_serial" ];   then a_serial=1;   REPLY_TEXT="The serial number is $SERIAL"; return; fi
  if [ -z "$a_purchase" ]; then a_purchase=1; REPLY_TEXT="I purchased it on $PURCHASE_DATE"; return; fi
  if [ -z "$a_issue" ];    then a_issue=1;    REPLY_TEXT="$ISSUE"; return; fi
  if [ -z "$a_phone" ];    then a_phone=1;    REPLY_TEXT="My phone number is $PHONE"; return; fi
  if [ -z "$a_name" ];     then a_name=1;     REPLY_TEXT="My name is $NAME"; return; fi
  if [ -z "$a_address" ];  then a_address=1;  REPLY_TEXT="My address is $ADDRESS"; return; fi
  if [ -z "$a_time" ];     then a_time=1;     REPLY_TEXT="I prefer $PREFERRED_TIME"; return; fi
  if [ -z "$a_warranty" ]; then a_warranty=1; REPLY_TEXT="$WARRANTY"; return; fi
  REPLY_TEXT="Yes, everything is correct. Please create the work order."
}

echo "==================================================================="
echo " 端到端报修对话测试"
echo " Session: $SESSION_ID"
echo "==================================================================="
echo

CUSTOMER="I want to request a repair"
RESULT="UNKNOWN"

for ((turn=1; turn<=MAX_TURNS; turn++)); do
  echo "------------------------------------------------------------------"
  echo "[Turn $turn] >>> CUSTOMER: $CUSTOMER"
  send "$CUSTOMER"

  BOT="$(bot_text)"
  STATUS="$(attr 'x-amz-lex:q-in-connect:conversation-status')"
  REASON="$(attr 'x-amz-lex:q-in-connect:conversation-status-reason')"
  TOOL="$(attr 'Tool')"
  ISTATE="$(intent_state)"

  echo "    <<< BOT: $BOT"
  echo "    [status=$STATUS reason=$REASON Tool=$TOOL intentState=$ISTATE]"

  BOT_LC="$(printf '%s' "$BOT" | tr '[:upper:]' '[:lower:]')"

  # 1) 明确的失败/升级信号（优先级最高）
  if printf '%s' "$BOT_LC" | grep -qE "having (trouble|difficulty) processing|connect you with a (human|live)? ?agent|transfer you to (a|an) agent|unable to (help|process)|i'll need to end this"; then
    RESULT="ESCALATE_OR_FAIL"; break
  fi
  # 2) 明确的成功信号
  if printf '%s' "$BOT_LC" | grep -qE "work order.*(created|submitted|placed|generated)|repair (request|ticket|order).*(created|submitted|placed|generated)|your (work order|ticket|reference) (number|id|is)|successfully (created|submitted)"; then
    RESULT="WORK_ORDER_CREATED"; break
  fi
  # 3) flow 层 Tool 信号（仅在 bot 未表达放弃时才视为有效）
  if [ "$TOOL" = "Escalate" ]; then RESULT="ESCALATE_OR_FAIL"; break; fi
  if [ "$TOOL" = "Complete" ] && printf '%s' "$BOT_LC" | grep -qvE "unable|can't|cannot|end this"; then
    RESULT="TOOL_COMPLETE"; break
  fi

  CUSTOMER=""
  route_answer "$BOT"
  CUSTOMER="$REPLY_TEXT"
done

echo
echo "==================================================================="
case "$RESULT" in
  WORK_ORDER_CREATED) echo " 结果: ✅ PASS —— bot 确认工单已生成（返回了工单号/创建成功）"; CODE=0 ;;
  TOOL_COMPLETE)      echo " 结果: ✅ PASS —— flow 收到 Tool=Complete（工单流程正常完成）"; CODE=0 ;;
  ESCALATE_OR_FAIL)   echo " 结果: ❌ FAIL —— bot 后端处理失败或升级转人工，工单未成功生成"; CODE=1 ;;
  *)                  echo " 结果: ⏱  FAIL —— 达到最大轮数仍未生成工单，对话未收敛"; CODE=1 ;;
esac
echo "==================================================================="
exit "${CODE:-1}"
