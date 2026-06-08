# Amazon Connect 报修流程测试工具

本目录包含针对 Amazon Connect 实例中"报修（request repair）"对话流程的测试工具。

被测对象：

- **实例**: `arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d`
- **Flow**: `arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d/contact-flow/b3075f06-622a-4b23-9846-bbcfd423fbbd`
- **渠道**: Chat
- **对话引擎**: 该 flow 通过 `ConnectParticipantWithLexBot` 接入 Lex V2 bot `NovaSonicSupport_2025_Bot`，由 **Amazon Q in Connect** 的生成式 AI 驱动对话。

---

##  `e2e-repair-test.sh`（端到端报修对话测试）

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

