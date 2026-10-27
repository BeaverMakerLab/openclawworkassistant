# OpenClaw 工作管理助手 (Work Agent)

> 基于 OpenClaw 智能体框架的专业级个人工作秘书。帮助用户建立**会议纪要整理 $\to$ 待办任务提取 $\to$ 长期项目跟踪 $\to$ 日报沉淀 $\to$ 周报复盘**的高保真工作闭环。

---

## 🌟 核心特性

- **严格的事实驱动，拒绝模型幻觉**
  - “先记录，再回复；纯查询，不造记录；无事实，不编造”。
  - 严格区分“声纹聚类标签”与“真实身份”，无可靠凭据绝不强行猜测参会人姓名。
- **高耗时/高风险操作保护门槛 (Action Gating)**
  - 收到音视频或文件附件时，**默认不自动触发转写**，必须在用户明确指示（如“整理纪要”、“转成文字”）后才启动算力容器，避免群晖/服务器 GPU 资源被意外打满。
- **飞书/Lark 深度协同与原生物流**
  - 支持飞书媒体引用（`media://inbound/...`）自动映射，无需重复上传文件。
  - 输出格式精炼、结构化、排版优美，专为飞书聊天与工作汇报场景调优。
- **本地高精度语音转写与声纹分离 (Diarization)**
  - 依托 FFmpeg + Pyannote Diarization + 阿里 FunASR 本地容器微服务，支持带说话人区分（Speaker 1/2）的长录音自动解析与哈希防重缓存。
- **分层上下文治理与单事实源**
  - 任务唯一事实源：`tasks/tasks.md`（标准 Markdown Checklist 状态机）。
  - 项目知识库：各项目独立目录维护 `PROJECT.md`（当前状态）与 `decisions.md`（架构与决策依据）。
  - 日报/周报：从每日事实自动提炼周报，向领导汇报告别流水账。

---

## 📁 目录结构

```text
├── AGENTS.md                   # Agent 顶层调度规则、规则优先级与 Skill 路由器
├── IDENTITY.md                 # Agent 身份与人设定义
├── SOUL.md                     # Agent 行为准则、信任原则与交互风格
├── USER.md                     # 用户习惯、偏好与时区设置（用户需配置）
├── MEMORY.md                   # 长期记忆维护（长期方向、工作流偏好）
├── TOOLS.md                    # 本地工具接口规范与输入输出契约
├── HEARTBEAT.md                # 心跳与定时调度配置
├── DEPLOY.md                   # 部署与环境集成说明
│
├── deploy/                     # Docker Compose 编排配置文件
│   ├── openclaw.yaml           # OpenClaw 主服务、权限修复与 DoH DNS 编排
│   └── funasr.yaml             # 本地语音转写三合一编排（FunASR+Pyannote+FFmpeg）
│
├── skills/                     # 领域能力技能库
│   ├── meeting/SKILL.md        # 会议音频/视频处理业务逻辑
│   └── project/SKILL.md        # 长期项目跟踪与决策维护业务逻辑
│
├── templates/                  # 标准化 Markdown 模板库
│   ├── daily_template.md       # 日报模板
│   ├── weekly_template.md      # 周报模板
│   ├── meeting_template.md     # 会议纪要模板
│   ├── project_template.md     # 项目主卡片模板
│   ├── project_decisions_template.md # 架构决策记录 (ADR) 模板
│   ├── project_notes_template.md     # 项目备忘模板
│   └── project_index_template.md     # 项目全局总览模板
│
├── tools/                      # 本地底层自动化脚本
│   └── meeting_transcribe.sh   # 多容器协同转写脚本（FFmpeg+FunASR+pyannote）
│
├── daily/                      # 日常工作记录（例：2026-01-15.md）
├── weekly/                     # 周度复盘汇报（例：2026-W03.md）
├── tasks/
│   └── tasks.md                # 任务看板（待处理 / 进行中 / 等待跟进 / 已完成）
├── projects/                   # 各独立研发项目工作区
│   ├── _index.md               # 项目总览索引
│   └── 示例项目-AI智能知识库系统/ # 样例项目
│       ├── PROJECT.md          # 项目当前状态
│       ├── decisions.md        # 架构决策记录
│       ├── NOTES.md            # 背景备忘
│       └── docs/               # 技术文档目录
├── meetings/                   # 会议纪要与转写沉淀
│   ├── _audio/                 # 会议原始音频自动归档目录（已 .gitignore）
│   └── _transcripts/           # 逐字稿与声纹时间轴缓存目录（已 .gitignore）
└── media/
    └── inbound/                # 飞书等即时通讯工具传入的媒体中转区
```

---

## 🚀 快速上手

### 1. 个性化配置

在首次启用前，建议按个人实际情况修改以下配置文件：

1. **`USER.md`**：填写您的称呼、时区以及常用交互偏好。
2. **`MEMORY.md`**：在“长期工作方向”章节中填写您日常关注的业务领域或技术栈。
3. **`projects/_index.md`**：清理或添加您当下的实际项目列表。

### 2. 部署到 OpenClaw

如果使用 Docker 或群晖部署 OpenClaw：

1. 将本仓库内容克隆或复制到 OpenClaw 的 workspace 挂载目录（如 `/home/node/.openclaw/workspace/work`）。
2. 确保工具脚本具有可执行权限：
   ```bash
   chmod +x tools/meeting_transcribe.sh
   ```

### 3. 本地语音转写容器依赖（可选）

如需使用自动化会议转写能力，需确保运行宿主机具备 Docker 环境并启动以下容器服务：

- **FFmpeg 容器**：`audio-ffmpeg`（用于音频格式标准化与抽取）
- **FunASR 容器**：`fun-asr`（阿里开源中文语音识别引擎 WebSocket 服务，默认端口 `10095`）
- **Pyannote 容器**：`pyannote-diarization`（用于说话人聚类与声纹切分）

详细运行测试可参考 [`DEPLOY.md`](DEPLOY.md)。

---

## 💡 典型使用场景指令（飞书）

- **会议整理**：
  > “整理一下刚才发给你的会议录音，日期是今天，主题是《技术架构方案评审》，有 3 个人参会，提取结论和待办并同步到项目。”
- **任务管理**：
  > “查看一下我当前所有进行中和待处理的任务。”
- **日报沉淀**：
  > “今天完成了微服务网关鉴权对接，压测延迟降低了 40%，帮我记录到今天的日报，并把关联任务标记完成。”
- **周报生成**：
  > “汇总本周日报，帮我生成一份面向领导汇报的本周工作周报。”
- **项目状态查询**：
  > “目前【AI智能知识库系统】进展到什么阶段了？还有哪些待解决的卡点？”

---

## 📄 开源协议

本项目基于 [MIT License](LICENSE) 开源。
