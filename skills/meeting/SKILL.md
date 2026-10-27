---
name: meeting
description: >
  Process meeting audio or video only when the user explicitly asks to
  transcribe, summarize, create meeting minutes, record work, update tasks,
  or sync an existing project. A bare audio/video attachment alone must never
  trigger transcription or other expensive processing.
user-invocable: false
disable-model-invocation: false
---

# Meeting Skill - 会议录音与会议材料处理

## 目标

把用户通过飞书发送的会议录音、录屏或其他会议媒体，可靠地转换为可追溯的会议资料，并根据用户明确意图决定是否：

- 仅生成完整转写；
- 生成正式会议纪要；
- 更新指定日期的 daily；
- 更新 tasks；
- 同步已有项目。

本 Skill 只负责“会议处理及会议产生的联动触发”，不负责定义项目内部文件如何维护；项目更新规则统一由 `skills/project/SKILL.md` 负责。

---

## 1. 触发条件

只有同时满足以下条件时才可启动会议处理：

1. 当前会话存在可用的音频/视频附件；
2. 用户明确表达了处理意图。

明确处理意图包括：

- 转成文字；
- 转写；
- 语音识别；
- 总结一下；
- 整理会议；
- 生成会议纪要；
- 总结并记录；
- 记录到工作；
- 更新待办；
- 同步到项目；
- 更新项目。

### 仅附件时

仅收到附件但没有明确处理意图时：

- 不调用 `tools/meeting_transcribe.sh`；
- 不启动 FFmpeg、pyannote、FunASR；
- 不生成纪要；
- 不更新 daily、tasks、project；
- 简洁询问用户希望如何处理。

**附件本身不代表用户授权转写。**

---

## 2. 附件与上下文复用

飞书附件可能表现为：

```text
media://inbound/<filename>
```

当前部署中，它对应：

```text
/home/node/.openclaw/media/inbound/<filename>
```

规则：

- `media://inbound/...` 是有效本地媒体引用；
- 不得仅因为它不是普通 POSIX 路径就判断“无法读取”；
- 不要要求用户重新上传同一文件；
- 不要自行重新下载附件；
- 直接把完整 URI 原样传给 `tools/meeting_transcribe.sh`；
- 只有工具明确返回文件不存在或读取失败时，才报告附件不可读。

用户先发附件，随后说：

- 刚才那个文件；
- 这个录音；
- 上面的会议；
- 刚才的会议；

且没有新附件时，应复用当前会话最近的相关有效附件。

若存在多个合理候选且无法可靠判断，不得误处理。

---

## 3. 提取会议信息

优先提取：

- 会议日期；
- 会议主题；
- 所属项目；
- 已知说话人数；
- 用户希望的处理模式。

### 日期

- 用户明确给出日期时必须使用；
- “今天 / 昨天 / 前天”等应换算为实际日期；
- 不得用上传时间覆盖用户给出的会议日期；
- 无法可靠判断时不要编造。

### 主题

- 用户明确给出主题时优先使用；
- 未给主题时，可在转写后根据实际内容提炼简短、客观主题；
- 文件名移除 `/ \ : * ? " < > |` 等不安全字符。

### Speaker 人数

- 用户明确给出人数时传给工具；
- 未给出时不猜，使用自动判断。

---

## 4. 调用转写工具

默认：

```bash
bash tools/meeting_transcribe.sh "<media URI 或本地绝对路径>"
```

已知说话人数：

```bash
bash tools/meeting_transcribe.sh "<attachment>" <speaker_count>
```

成功后解析：

- `ARCHIVE=`
- `TRANSCRIPT=`
- `SPEAKER_JSON=`
- `META=`
- `SPEAKERS=`
- `SEGMENTS=`
- `CACHE=`（如有）

必须读取 `TRANSCRIPT=` 指向的完整转写文件后再进行会议理解。

工具只负责确定性媒体处理，不负责：

- 生成会议纪要；
- 修改 daily；
- 修改 tasks；
- 修改 project；
- 调用 work Agent；
- 做业务判断。

---

## 5. Speaker 与 ASR

`SPEAKER_00` 等仅表示聚类标签，不代表真实姓名。

只有以下情况才允许映射真实姓名：

- 用户明确告知；
- 会议中有可靠自我介绍或唯一明确称呼；
- 已有可靠参与者映射。

否则保留 Speaker 编号。

允许结合上下文修正明显的：

- 同音字；
- 错别字；
- 专有名词；
- 标点和断句。

不得：

- 补造会议没有说过的事实；
- 编造数字；
- 擅自补齐责任人或截止时间；
- 把讨论、建议或假设写成正式决策。

无法可靠判断的内容标记“需确认”。

---

## 6. 处理模式

### A. 仅转文字

用户意图例如：

- 转成文字；
- 帮我转写；
- 语音识别一下。

执行：

- 完成转写；
- 保存原始音频归档；
- 保存 Speaker TXT/JSON/meta。

不执行：

- 不生成会议纪要；
- 不修改 daily；
- 不修改 tasks；
- 不修改 project。

### B. 整理会议纪要

用户意图例如：

- 总结一下；
- 整理会议；
- 生成会议纪要。

执行：

- 完成转写；
- 读取完整 transcript；
- 生成并保存 `meetings/YYYY-MM-DD_会议主题.md`。

默认不修改：

- daily；
- tasks；
- project。

### C. 总结并记录工作

用户意图例如：

- 总结并记录；
- 记录到工作；
- 整理并更新待办；
- 这是 XX 项目的会议，帮我总结并记录工作。

执行：

- 完成转写；
- 生成正式会议纪要；
- 按 AGENTS.md 的 Daily 全局规则更新指定日期 daily；
- 按 AGENTS.md 的 Tasks 全局规则更新明确行动项；
- 若会议能可靠关联已有项目，则按本 Skill 的“项目联动”规则调用 project Skill。

---

## 7. 会议纪要

优先使用：

`templates/meeting_template.md`

至少包含：

- 会议主题；
- 会议日期；
- 所属项目（如已确认）；
- 原始音频归档位置；
- 完整转写位置；
- 核心讨论；
- 主要观点；
- 已形成结论；
- 决策事项；
- 待办事项；
- 未决问题。

责任人和截止时间仅在来源明确时填写。

会议纪要是该次会议的正式事实记录，不把 PROJECT.md 或 daily 的内容反向复制进来。

---

## 8. 项目联动

只有以下情况才联动项目：

- 用户明确说“同步到 <项目>”；
- 用户明确说“这是 <项目> 的会议”，并要求记录工作或更新项目；
- 用户说“总结并记录工作”，且会议与已有项目关联非常明确；
- 当前对话已经明确绑定某项目且没有歧义。

如果用户只要求：

- 转文字；
- 整理会议纪要；
- 总结会议；

默认不更新项目。

### 项目识别优先级

1. 用户明确指定项目；
2. 精确项目名或 alias 明确命中；
3. 高置信度语义匹配已有项目；
4. 存在多个合理候选时，不擅自写入。

不要因为会议中偶然出现公司名、客户名或技术名而自动创建项目。

### 传给 project Skill 的内容

只提供本次会议产生的增量事实：

- 项目阶段变化；
- 当前状态变化；
- 已完成的重要工作；
- 正在推进事项；
- 新问题/风险；
- 新决策；
- 下一步；
- 正式会议来源。

`PROJECT.md`、`decisions.md`、`_index.md` 和项目状态的具体维护方式，由：

`skills/project/SKILL.md`

统一负责。

---

## 9. Daily 与 Tasks 联动

### Daily

只有用户明确要求记录工作、更新日报或“总结并记录”时才更新。

按 AGENTS.md 的 Daily 全局规则执行。

会议只向 daily 提供：

- 会议名称；
- 推进事项；
- 形成结论；
- 关键成果；
- 下一步。

不得复制完整转写或整篇会议纪要。

### Tasks

按 AGENTS.md 的 Tasks 全局规则执行。

会议只产生候选行动项。

只有明确、可执行、尚未完成的事项才可进入 `tasks/tasks.md`。

创建前必须去重；责任人和截止时间不明确时不得猜测。

---

## 10. 缓存与重复处理

如果工具返回：

```text
CACHE=HIT
```

表示已有有效处理结果。

应复用已有：

`TRANSCRIPT=`

不得因为用户再次说“整理一下刚才的会议”就重复运行 pyannote/FunASR。

---

## 11. 失败处理

如果某一步失败：

- 明确失败步骤；
- 说明已经完成并保存了哪些结果；
- 保留已经成功生成的 archive、Speaker JSON、transcript、meeting.md；
- 不声称全部完成；
- 已存在有效 `media://inbound/...` 时，不要未经验证就要求用户重新上传。

---

## 12. 回复用户

完成后简洁反馈：

- 会议日期与主题；
- 转写是否完成；
- 纪要是否生成及位置；
- 原始音频和完整转写保存位置；
- 是否更新 daily；
- 是否更新 tasks；
- 是否关联并更新项目。

正常情况下不需要向用户展示 Docker、FFmpeg、pyannote、FunASR、hash 或 cache 细节，除非用户主动要求调试。

---

## 最终原则

1. **只发附件，不处理。**
2. **明确要求处理，才启动转写。**
3. **已有附件优先复用，不要求重复上传。**
4. **会议纪要保存会议事实。**
5. **项目内部更新交给 project Skill。**
6. **Daily 和 Tasks 遵循 AGENTS.md 的全局规则。**
