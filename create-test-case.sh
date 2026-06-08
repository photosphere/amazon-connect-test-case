#!/usr/bin/env bash
#
# 使用 AWS CLI 为 Amazon Connect 创建一个 Test Case（测试用例）
# 参考: https://docs.aws.amazon.com/connect/latest/APIReference/API_CreateTestCase.html
#
# 测试场景（Chat 渠道）:
#   1. 发送 "request repair"
#   2. 验证手机尾号 3641
#   3. 依次收集 product / version / province / city / district / brand / issue description
#   4. 验证返回的 work order 是否有值
#
# 用法:
#   ./create-test-case.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 配置区 —— 按需修改
# ---------------------------------------------------------------------------

# 区域
REGION="us-west-2"

# Connect 实例 ARN（CreateTestCase 的 InstanceId 接受 ARN 或纯 ID）
INSTANCE_ID="arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d"

# 被测 Flow 的 ARN（用作 Chat 入口的 FlowId）
FLOW_ID="arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d/contact-flow/b3075f06-622a-4b23-9846-bbcfd423fbbd"

# 测试用例名称与描述
TEST_CASE_NAME="RequestRepair-Chat-Smoke-Test"
TEST_CASE_DESC="冒烟测试: Chat 渠道下发送 request repair，验证 flow 正常将客户接入 Amazon Q bot（匹配 flow 原生 welcome 消息）。注意: 该 flow 经 ConnectParticipantWithLexBot 接入生成式 bot，bot 的流式回复无法被测试框架观察，端到端报修/工单验证请使用 e2e-repair-test.sh。"

# 测试内容 JSON 文件（Testing language）
CONTENT_FILE="$(dirname "$0")/test-case-content.json"

# 创建后是否直接发布（PUBLISHED 会校验内容；SAVED 不校验）
STATUS="PUBLISHED"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "错误: 未找到 aws CLI，请先安装。" >&2; exit 1; }

if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "错误: 找不到测试内容文件: $CONTENT_FILE" >&2
  exit 1
fi

# 校验 JSON 合法性（如果有 python3）
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CONTENT_FILE" \
    || { echo "错误: $CONTENT_FILE 不是合法 JSON。" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 构造 entry-point（Chat 渠道）
# ---------------------------------------------------------------------------
ENTRY_POINT=$(cat <<EOF
{
  "Type": "CHAT",
  "ChatEntryPointParameters": {
    "FlowId": "${FLOW_ID}"
  }
}
EOF
)

# ---------------------------------------------------------------------------
# 幂等处理：先按名称查找是否已存在同名 Test Case
#   - 已存在 -> UpdateTestCase（更新 Content / EntryPoint / Status）
#   - 不存在 -> CreateTestCase
# ---------------------------------------------------------------------------
EXISTING_ID=$(aws connect list-test-cases \
  --region "${REGION}" \
  --instance-id "${INSTANCE_ID}" \
  --query "TestCaseSummaryList[?Name=='${TEST_CASE_NAME}'].Id | [0]" \
  --output text)

if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" != "None" ]]; then
  echo "已存在同名 Test Case (Id=${EXISTING_ID})，执行更新 ..."
  aws connect update-test-case \
    --region "${REGION}" \
    --instance-id "${INSTANCE_ID}" \
    --test-case-id "${EXISTING_ID}" \
    --name "${TEST_CASE_NAME}" \
    --description "${TEST_CASE_DESC}" \
    --content "file://${CONTENT_FILE}" \
    --entry-point "${ENTRY_POINT}" \
    --status "${STATUS}" \
    --output json
  echo "更新完成。TestCaseId=${EXISTING_ID}"
else
  echo "正在创建 Test Case: ${TEST_CASE_NAME} ..."
  aws connect create-test-case \
    --region "${REGION}" \
    --instance-id "${INSTANCE_ID}" \
    --name "${TEST_CASE_NAME}" \
    --description "${TEST_CASE_DESC}" \
    --content "file://${CONTENT_FILE}" \
    --entry-point "${ENTRY_POINT}" \
    --status "${STATUS}" \
    --output json
  echo "创建完成。"
fi
