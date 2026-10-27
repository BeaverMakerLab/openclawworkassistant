# TOOLS.md - Work Agent 本地工具说明

本文件只记录工具能力和调用接口；会议业务规则见 `skills/meeting/SKILL.md`。

---

## 调用硬门槛

`meeting_transcribe.sh` 是耗时工具。**Agent 不得因为仅收到音频/视频附件就调用它。**
只有用户明确提出转写、总结、会议纪要、记录工作或待办提取要求后才可调用。
附件本身、文件名和媒体类型均不构成调用授权。

## 会议转写工具

入口：

```bash
bash tools/meeting_transcribe.sh "<attachment>" [speaker_count]
```

### 支持的输入

#### 1. 飞书 / OpenClaw 媒体引用

```text
media://inbound/<filename>
```

在当前环境中对应 OpenClaw 容器真实文件：

```text
/home/node/.openclaw/media/inbound/<filename>
```

工具会自动完成映射。Agent 应把完整 `media://inbound/...` 原样传给工具，不需要自己转换路径。

#### 2. OpenClaw 容器内普通绝对路径

```text
/home/node/.../meeting.m4a
```

### 已知说话人数

用户明确说明会议有 4 人时：

```bash
bash tools/meeting_transcribe.sh "media://inbound/example.m4a" 4
```

不知道人数时不要猜，省略第二个参数，由 pyannote 自动判断。

### 底层环境

- FFmpeg：`audio-ffmpeg`
- FunASR：`fun-asr`
- pyannote：`pyannote-diarization`
- OpenClaw 容器具有 Docker CLI 和 `/var/run/docker.sock`

### 成功输出

stdout 最终输出机器可读字段：

```text
STATUS=OK
CACHE=HIT|MISS
ARCHIVE=<workspace中的原始音频归档路径>
TRANSCRIPT=<workspace中的完整转写路径>
SPEAKER_JSON=<workspace中的说话人时间轴路径>
META=<workspace中的元数据路径>
SEGMENTS=<有效转写段数>
```

### 长期保存位置

原始音频：

```text
meetings/_audio/YYYY/MM/
```

完整转写及程序元数据：

```text
meetings/_transcripts/
```

正式会议纪要由 work Agent 保存到：

```text
meetings/YYYY-MM-DD_会议主题.md
```

### 缓存

工具使用“原文件 SHA-256 + speaker_count 模式”生成任务 ID。

同一份录音、相同人数设置再次处理时，如果完整缓存存在则直接复用。若自动判断后用户又明确给出 4 人，则传入 `4` 会生成另一套 diarization/transcript，不会误用自动模式缓存。

### 职责边界

工具只负责：
- 解析 `media://inbound/...`
- 归档原始音频
- FFmpeg 标准化
- pyannote 说话人分离
- FunASR 转写
- 生成 Speaker TXT / JSON / meta

工具不负责：会议总结、meeting.md、daily、tasks、projects。这些由 work Agent 按 `skills/meeting/SKILL.md` 完成。

### 失败原则

不得在未调用工具验证前，仅凭 `media://` URI 判断文件不可读取。

只有工具明确返回 `STATUS=ERROR` 或真实文件检查失败时，才向用户报告附件读取失败。
