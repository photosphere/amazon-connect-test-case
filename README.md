# Amazon Connect 报修流程测试工具

本目录包含针对 Amazon Connect 实例中"报修（request repair）"对话流程的测试工具。

被测对象：

- **实例**: `arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d`
- **Flow**: `arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d/contact-flow/b3075f06-622a-4b23-9846-bbcfd423fbbd`
- **渠道**: Chat
- **对话引擎**: 该 flow 通过 `ConnectParticipantWithLexBot` 接入 Lex V2 bot `NovaSonicSupport_2025_Bot`，由 **Amazon Q in Connect** 的生成式 AI 驱动对话。

---

## 背景：为什么需要两套测试

Amazon Connect 的原生测试框架（`CreateTestCase` / 测试与模拟）**只能观察到 flow 直接发出的消息**（如 welcome 文本、`MessageParticipant` 块），**无法观察经 `ConnectParticipantWithLexBot` 接入的生成式 bot 的流式回复**。

因此本目录提供两个互补的测试：

| 文件 | 类型 | 覆盖范围 | 稳定性 |
|------|------|----------|--------|
| `create-test-case.sh` + `test-case-content.json` | Connect 原生冒烟测试 | 验证 flow 正常把客户接入 bot | 稳定，~30 秒 |
| `e2e-repair-test.sh` | 端到端对话测试 | 走完整报修对话，验证工单是否真正生成 | 真实端到端 |

---

## 前置条件

- 已安装并配置 [AWS CLI](https://docs.aws.amazon.com/cli/)（具备访问该 Connect 实例和 Lex bot 的权限）
- `python3`（脚本用于解析 JSON）
- `bash`（`e2e-repair-test.sh` 使用 bash 特性，请用 `bash` 执行）

所需 IAM 权限（概要）：

- `connect:CreateTestCase`、`connect:UpdateTestCase`、`connect:ListTestCases`、`connect:StartTestCaseExecution`、`connect:ListTestCaseExecutions`、`connect:ListTestCaseExecutionRecords`
- `lex:RecognizeText`（针对 bot alias `TSTALIASID`）

---

## 1. `create-test-case.sh` + `test-case-content.json`（冒烟测试）

### 功能

在 Connect 实例中**幂等地创建或更新**一个名为 `RequestRepair-Chat-Smoke-Test` 的测试用例并发布（`PUBLISHED`）。

- 用例内容来自 `test-case-content.json`。
- 脚本先按名称查找是否已存在同名用例：
  - 已存在 → 调用 `update-test-case` 更新；
  - 不存在 → 调用 `create-test-case` 创建。
- 因此可以反复运行，不会报 `DuplicateResourceException`。

### `test-case-content.json` 的逻辑

采用 Amazon Connect 的 Testing Language（`Version 2019-10-30`），包含两个观察（Observation）：

1. **TestStart** — 测试开始时，以客户身份发送 "I want to request a repair...";
2. **VerifyFlowConnectsBot** — 用 `Inclusion`（包含匹配）监听 flow 接入 bot 前发出的 welcome 消息（包含 `"How can I help you today"`）；匹配到即 `EndTest`，测试通过。

> 这条 welcome 消息是 **flow 原生消息**（来自 `ConnectParticipantWithLexBot` 块的 `Text` 参数 `$.FlowAttributes.welcome_msg`），是测试框架可稳定观察的内容。因此该冒烟测试只验证"flow 是否正常把客户接入 bot"，不验证生成式对话本身。

### 使用方法

```bash
# 创建/更新并发布测试用例
./create-test-case.sh
```

成功后会输出 `TestCaseId` 与 `TestCaseArn`。

可调整的变量（位于脚本顶部）：

- `REGION` / `INSTANCE_ID` / `FLOW_ID` — 目标实例与 flow
- `TEST_CASE_NAME` / `TEST_CASE_DESC` — 用例名称与描述
- `CONTENT_FILE` — 测试内容文件路径（默认同目录的 `test-case-content.json`）
- `STATUS` — `PUBLISHED`（会校验内容）或 `SAVED`（不校验）

### 运行该测试用例

脚本只负责创建/更新用例。运行用例可在 Connect 控制台的"测试与模拟"界面操作，或用 CLI：

```bash
INSTANCE="arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d"

# 1) 取用例 Id
TC_ID=$(aws connect list-test-cases --region us-west-2 --instance-id "$INSTANCE" \
  --query "TestCaseSummaryList[?Name=='RequestRepair-Chat-Smoke-Test'].Id | [0]" --output text)

# 2) 启动执行（需要一个非空 client-token）
EID=$(aws connect start-test-case-execution --region us-west-2 --instance-id "$INSTANCE" \
  --test-case-id "$TC_ID" --client-token "smoke-$(date +%s)" \
  --query "TestCaseExecutionId" --output text)

# 3) 查看状态
aws connect list-test-case-executions --region us-west-2 --instance-id "$INSTANCE" \
  --test-case-id "$TC_ID" --max-results 1 \
  --query "TestCaseExecutions[0].[TestCaseExecutionId,TestCaseExecutionStatus]" --output text

# 4) 查看每步明细
aws connect list-test-case-execution-records --region us-west-2 --instance-id "$INSTANCE" \
  --test-case-id "$TC_ID" --test-case-execution-id "$EID" \
  --query "ExecutionRecords[].[ObservationId,Status]" --output text
```

预期结果：`TestStart` 与 `VerifyFlowConnectsBot` 均为 `PASSED`，整体 `PASSED`（约 30 秒）。

---

## 2. `e2e-repair-test.sh`（端到端报修对话测试）

### 功能

直接通过 `lexv2-runtime recognize-text` 驱动生成式 bot，**走完整段报修对话**，并判定工单（work order）是否真正生成。这是对原生测试框架无法观察生成式回复的补充。

脚本特点：

- **自适应应答**：读取 bot 每轮提问，根据关键词路由到对应字段的预设答案，自动把所需信息全部提供给 bot。
- 收集的字段（按 bot 实际需求）：型号 model、序列号 serial number、购买日期、问题描述、姓名、完整手机号（`18618383641`，尾号 3641）、地址、期望上门时间、是否在保。
- **结果判定**依据 bot 回复文本与 Lex session attribute `Tool`：
  - `WORK_ORDER_CREATED` / `TOOL_COMPLETE` → ✅ PASS（工单成功）
  - `ESCALATE_OR_FAIL`（bot 报处理失败/转人工，或 `Tool=Escalate`）→ ❌ FAIL
  - 超过最大轮数仍未收敛 → ❌ FAIL
- 退出码：成功 `0`，失败 `1`（可直接用于 CI）。

### 使用方法

```bash
bash e2e-repair-test.sh
```

> 请使用 `bash` 执行（脚本使用了 bash 特性，在 zsh 等其他 shell 下可能报错）。

脚本会逐轮打印客户输入、bot 回复及状态，最后输出 PASS/FAIL 结论。

可调整的变量（位于脚本顶部）：

- `REGION` / `BOT_ID` / `ALIAS_ID` / `LOCALE` — Lex bot 连接参数
- `MAX_TURNS` — 最大对话轮数（默认 30）
- 客户资料：`PHONE` / `MODEL` / `SERIAL` / `PURCHASE_DATE` / `ISSUE` / `NAME` / `ADDRESS` / `PREFERRED_TIME` / `WARRANTY`

### 已知现状

当前实测中：对话流程与字段收集**完全正常**，bot 收齐信息并复述确认后会说 *"Creating your repair work order now."*，但**后端建单失败**，随即转人工（`Tool=Escalate`）。

因此 `e2e-repair-test.sh` 当前会判定 **❌ FAIL**，这是对真实缺陷的准确反映——在工单创建后端修复之前，端到端测试会（也应该）失败。

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `create-test-case.sh` | 幂等创建/更新并发布 Connect 冒烟测试用例 |
| `test-case-content.json` | 冒烟测试用例内容（Connect Testing Language） |
| `e2e-repair-test.sh` | 端到端报修对话测试（直连生成式 bot） |
| `flow-content.json` | 被测 flow 的导出内容（参考） |
| `existing-tc-chinese-pretty.json` | 实例中已有测试用例的格式参考 |
