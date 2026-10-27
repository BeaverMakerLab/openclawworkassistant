# Work Agent 会议能力部署说明

本目录可覆盖到现有 `work` workspace。

## 新增/修改

- `AGENTS.md`：高层工作规则，会议流程委托给 Skill。
- `skills/meeting/SKILL.md`：完整会议业务流程。
- `TOOLS.md`：会议工具接口及 `media://inbound` 映射说明。
- `tools/meeting_transcribe.sh`：支持飞书 media URI、原始音频归档、pyannote + FunASR 转写。
- `templates/meeting_template.md`：会议纪要模板。
- `MEMORY.md`：记录长期会议处理偏好。

现有 daily / weekly / tasks / projects 文件均保留。

## 目录

- 原始会议音频：`meetings/_audio/YYYY/MM/`
- 完整转写：`meetings/_transcripts/*.speakers.txt`
- Speaker 时间轴：`meetings/_transcripts/*.speakers.json`
- 元数据：`meetings/_transcripts/*.meta.json`
- 正式纪要：`meetings/YYYY-MM-DD_会议主题.md`

## 部署

建议先备份：

```bash
cd /volume1/docker/openclaw/workspace
cp -a work work_backup_$(date +%Y%m%d_%H%M%S)
```

然后将本包中的 `work/` 内容覆盖到当前 workspace。

确保脚本可执行：

```bash
chmod +x /volume1/docker/openclaw/workspace/work/tools/meeting_transcribe.sh
```

语法检查：

```bash
bash -n /volume1/docker/openclaw/workspace/work/tools/meeting_transcribe.sh
```

## 手动验证现有飞书附件

在 OpenClaw 容器内：

```bash
cd /home/node/.openclaw/workspace/work
bash tools/meeting_transcribe.sh \
  "media://inbound/example_meeting.m4a"
```

成功时应输出 `STATUS=OK`、`ARCHIVE=`、`TRANSCRIPT=` 等字段。
