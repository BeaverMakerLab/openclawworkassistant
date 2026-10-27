#!/usr/bin/env bash

set -u
set -o pipefail

# ==========================================================
# work Agent 会议转写底层工具
#
# 用法：
#   bash tools/meeting_transcribe.sh "media://inbound/xxx.m4a"
#   bash tools/meeting_transcribe.sh "/absolute/path/xxx.m4a" 4
#
# 职责：
#   media URI/本地文件 -> 原始音频归档 -> FFmpeg -> pyannote
#   -> FunASR -> Speaker TXT/JSON/meta
#
# 不负责：会议总结 / daily / tasks / projects
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRANSCRIPT_DIR="${WORKSPACE_DIR}/meetings/_transcripts"
AUDIO_ARCHIVE_DIR="${WORKSPACE_DIR}/meetings/_audio"

FFMPEG_CONTAINER="audio-ffmpeg"
FUNASR_CONTAINER="fun-asr"
PYANNOTE_CONTAINER="pyannote-diarization"

FUNASR_CLIENT="/workspace/FunASR/runtime/python/websocket/funasr_wss_client.py"
FUNASR_HOST="127.0.0.1"
FUNASR_PORT="10095"

mkdir -p "$TRANSCRIPT_DIR" "$AUDIO_ARCHIVE_DIR"

fail() {
    echo "STATUS=ERROR"
    echo "ERROR=$1"
    exit "${2:-1}"
}

if [ $# -lt 1 ]; then
    fail "用法: $0 <media://inbound/... 或本地绝对路径> [speaker_count]" 1
fi

SOURCE_INPUT="$1"
NUM_SPEAKERS="${2:-}"

# ----------------------------------------------------------
# 解析 OpenClaw/飞书 media URI
# ----------------------------------------------------------
case "$SOURCE_INPUT" in
    media://inbound/*)
        MEDIA_NAME="${SOURCE_INPUT#media://inbound/}"
        # 拒绝目录穿越，只允许 inbound 下的单个文件名。
        case "$MEDIA_NAME" in
            */*|..*) fail "非法 media://inbound 文件名" 1 ;;
        esac
        SOURCE_FILE="/home/node/.openclaw/media/inbound/${MEDIA_NAME}"
        ;;
    /*)
        SOURCE_FILE="$SOURCE_INPUT"
        ;;
    *)
        fail "不支持的输入引用: $SOURCE_INPUT" 1
        ;;
esac

[ -f "$SOURCE_FILE" ] || fail "附件实际文件不存在或当前容器不可读取: $SOURCE_FILE" 1

if [ -n "$NUM_SPEAKERS" ]; then
    case "$NUM_SPEAKERS" in
        ''|*[!0-9]*) fail "speaker_count 必须是正整数" 1 ;;
    esac
    [ "$NUM_SPEAKERS" -gt 0 ] || fail "speaker_count 必须大于 0" 1
fi

check_container() {
    local name="$1"
    local running
    running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
    [ "$running" = "true" ] || fail "Docker 容器未运行: $name" 2
}

check_container "$FFMPEG_CONTAINER"
check_container "$FUNASR_CONTAINER"
check_container "$PYANNOTE_CONTAINER"

SOURCE_NAME="$(basename "$SOURCE_FILE")"
SOURCE_STEM="${SOURCE_NAME%.*}"
EXT="${SOURCE_NAME##*.}"
[ "$EXT" != "$SOURCE_NAME" ] || EXT="bin"

# 去掉 OpenClaw 为防重名添加的 ---UUID 后缀，归档名更易读。
DISPLAY_STEM="$(printf '%s' "$SOURCE_STEM" | sed -E 's/---[0-9a-fA-F-]{20,}$//')"
SAFE_STEM="$(printf '%s' "$DISPLAY_STEM" | sed 's/[^A-Za-z0-9._-]/_/g; s/^_*//; s/_*$//')"
[ -n "$SAFE_STEM" ] || SAFE_STEM="meeting"
SAFE_STEM="$(printf '%s' "$SAFE_STEM" | cut -c1-64)"

if command -v sha256sum >/dev/null 2>&1; then
    SOURCE_HASH="$(sha256sum "$SOURCE_FILE" | awk '{print $1}')"
else
    SOURCE_HASH="$(cksum "$SOURCE_FILE" | awk '{print $1"-"$2}')"
fi
HASH12="$(printf '%s' "$SOURCE_HASH" | cut -c1-12)"

if [ -n "$NUM_SPEAKERS" ]; then
    SPEAKER_TAG="spk${NUM_SPEAKERS}"
else
    SPEAKER_TAG="auto"
fi

JOB_ID="${SAFE_STEM}_${HASH12}_${SPEAKER_TAG}"

# 原始音频按处理日期归档；会议纪要的业务日期由 Agent 根据用户描述决定。
ARCHIVE_YEAR="$(date +%Y)"
ARCHIVE_MONTH="$(date +%m)"
ARCHIVE_MONTH_DIR="${AUDIO_ARCHIVE_DIR}/${ARCHIVE_YEAR}/${ARCHIVE_MONTH}"
mkdir -p "$ARCHIVE_MONTH_DIR"
ARCHIVE_FILE="${ARCHIVE_MONTH_DIR}/${SAFE_STEM}_${HASH12}.${EXT}"

LOCAL_JSON="${TRANSCRIPT_DIR}/${JOB_ID}.speakers.json"
LOCAL_TXT="${TRANSCRIPT_DIR}/${JOB_ID}.speakers.txt"
LOCAL_META="${TRANSCRIPT_DIR}/${JOB_ID}.meta.json"
SEGMENT_LIST="${TRANSCRIPT_DIR}/.${JOB_ID}.segments.tsv"

REMOTE_SOURCE="/audio/input/${JOB_ID}.${EXT}"
REMOTE_WAV="/audio/input/${JOB_ID}.wav"
REMOTE_JSON="/audio/output/${JOB_ID}.speakers.json"
REMOTE_SEG_DIR_FFMPEG="/audio/input/.${JOB_ID}_segments"
REMOTE_SEG_DIR_FUNASR="/workspace/input/.${JOB_ID}_segments"

cleanup_remote() {
    docker exec "$FFMPEG_CONTAINER" sh -c \
        "rm -f '$REMOTE_SOURCE' '$REMOTE_WAV'; rm -rf '$REMOTE_SEG_DIR_FFMPEG'" \
        >/dev/null 2>&1 || true
    docker exec "$PYANNOTE_CONTAINER" sh -c \
        "rm -f '$REMOTE_JSON'" \
        >/dev/null 2>&1 || true
    rm -f "$SEGMENT_LIST"
}
trap cleanup_remote EXIT

# 原始音频归档：使用 hash 防止重复保存。
if [ ! -s "$ARCHIVE_FILE" ]; then
    cp -p "$SOURCE_FILE" "$ARCHIVE_FILE" || fail "无法归档原始音频到 workspace" 3
fi

# 完整缓存命中。
if [ -s "$LOCAL_TXT" ] && [ -s "$LOCAL_JSON" ] && [ -s "$LOCAL_META" ]; then
    LINES="$(wc -l < "$LOCAL_TXT" | tr -d ' ')"
    echo "STATUS=OK"
    echo "CACHE=HIT"
    echo "ARCHIVE=$ARCHIVE_FILE"
    echo "TRANSCRIPT=$LOCAL_TXT"
    echo "SPEAKER_JSON=$LOCAL_JSON"
    echo "META=$LOCAL_META"
    echo "SEGMENTS=$LINES"
    exit 0
fi

echo "[1/5] 导入附件并标准化音频..." >&2

docker cp "$SOURCE_FILE" "${FFMPEG_CONTAINER}:${REMOTE_SOURCE}" \
    >/dev/null || fail "无法把附件复制到 audio-ffmpeg 容器" 3

docker exec "$FFMPEG_CONTAINER" \
    ffmpeg -hide_banner -loglevel error -y \
    -i "$REMOTE_SOURCE" -vn -ar 16000 -ac 1 -c:a pcm_s16le \
    "$REMOTE_WAV" \
    || fail "FFmpeg 音频转换失败" 3

echo "[2/5] pyannote 说话人分离..." >&2

if [ -n "$NUM_SPEAKERS" ]; then
    docker exec "$PYANNOTE_CONTAINER" \
        python -u /app/diarize.py "$REMOTE_WAV" \
        --output "$REMOTE_JSON" --num-speakers "$NUM_SPEAKERS" \
        || fail "pyannote 说话人分离失败" 4
else
    docker exec "$PYANNOTE_CONTAINER" \
        python -u /app/diarize.py "$REMOTE_WAV" \
        --output "$REMOTE_JSON" \
        || fail "pyannote 说话人分离失败" 4
fi

docker cp "${PYANNOTE_CONTAINER}:${REMOTE_JSON}" "$LOCAL_JSON" \
    >/dev/null || fail "无法复制 Speaker JSON 到 workspace" 4

echo "[3/5] 生成 Speaker 时间轴..." >&2

docker exec "$PYANNOTE_CONTAINER" python -c "
import json
p='$REMOTE_JSON'
with open(p, encoding='utf-8') as f:
    data=json.load(f)
for i,s in enumerate(data.get('segments', []), 1):
    print(f\"{i}\\t{s['start']}\\t{s['end']}\\t{s['speaker']}\")
" > "$SEGMENT_LIST" || fail "无法生成 Speaker 时间轴" 5

[ -s "$SEGMENT_LIST" ] || fail "Speaker 时间轴为空" 5
SEGMENT_COUNT="$(wc -l < "$SEGMENT_LIST" | tr -d ' ')"

docker exec "$FFMPEG_CONTAINER" mkdir -p "$REMOTE_SEG_DIR_FFMPEG" \
    >/dev/null || fail "无法创建临时语音切片目录" 5

: > "$LOCAL_TXT"

echo "[4/5] FunASR 分段识别，共 ${SEGMENT_COUNT} 段..." >&2

TAB="$(printf '\t')"
CURRENT=0
WRITTEN=0

while IFS="$TAB" read -r INDEX START END SPEAKER; do
    CURRENT=$((CURRENT + 1))
    DURATION="$(awk -v s="$START" -v e="$END" 'BEGIN{d=e-s;if(d<0)d=0;printf "%.3f",d}')"
    TOO_SHORT="$(awk -v d="$DURATION" 'BEGIN{print (d<0.30)?1:0}')"
    [ "$TOO_SHORT" = "1" ] && continue

    SEG_NAME="$(printf '%05d.wav' "$INDEX")"
    FFMPEG_SEG="${REMOTE_SEG_DIR_FFMPEG}/${SEG_NAME}"
    FUNASR_SEG="${REMOTE_SEG_DIR_FUNASR}/${SEG_NAME}"

    printf '\r      [%d/%d] %-12s %.1fs - %.1fs' \
        "$CURRENT" "$SEGMENT_COUNT" "$SPEAKER" "$START" "$END" >&2

    docker exec "$FFMPEG_CONTAINER" \
        ffmpeg -hide_banner -loglevel error -y \
        -ss "$START" -t "$DURATION" -i "$REMOTE_WAV" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$FFMPEG_SEG" \
        || continue

    docker exec "$FFMPEG_CONTAINER" test -s "$FFMPEG_SEG" || continue

    # 不能使用 docker exec -i：while 的 stdin 正在读取 SEGMENT_LIST。
    ASR_RAW="$(
        docker exec "$FUNASR_CONTAINER" \
            python3 "$FUNASR_CLIENT" \
            --host "$FUNASR_HOST" --port "$FUNASR_PORT" \
            --mode offline --audio_in "$FUNASR_SEG" \
            --ssl 0 --use_itn 1 2>&1 || true
    )"

    TEXT="$(printf '%s\n' "$ASR_RAW" | awk '
        index($0,"demo:") {
            p=index($0,"demo:")
            text=substr($0,p+5)
            sub(/^[[:space:]]+/, "", text)
            print text
        }
    ')"

    docker exec "$FFMPEG_CONTAINER" rm -f "$FFMPEG_SEG" >/dev/null 2>&1 || true
    [ -n "$TEXT" ] || continue

    TIME_TEXT="$(awk -v t="$START" 'BEGIN{h=int(t/3600);m=int((t-h*3600)/60);s=int(t-h*3600-m*60);printf "%02d:%02d:%02d",h,m,s}')"
    printf '[%s] %s：%s\n' "$TIME_TEXT" "$SPEAKER" "$TEXT" >> "$LOCAL_TXT"
    WRITTEN=$((WRITTEN + 1))
done < "$SEGMENT_LIST"

echo >&2
[ -s "$LOCAL_TXT" ] || fail "FunASR 没有生成有效转写" 6

echo "[5/5] 写入处理元数据..." >&2

SOURCE_INPUT="$SOURCE_INPUT" \
SOURCE_FILE="$SOURCE_FILE" \
SOURCE_NAME="$SOURCE_NAME" \
SOURCE_HASH="$SOURCE_HASH" \
JOB_ID="$JOB_ID" \
NUM_SPEAKERS="$NUM_SPEAKERS" \
SPEAKER_MODE="$SPEAKER_TAG" \
ARCHIVE_FILE="$ARCHIVE_FILE" \
TRANSCRIPT="$LOCAL_TXT" \
SPEAKER_JSON="$LOCAL_JSON" \
SEGMENT_COUNT="$SEGMENT_COUNT" \
WRITTEN="$WRITTEN" \
node - <<'NODE' > "$LOCAL_META"
const data = {
  source_input: process.env.SOURCE_INPUT,
  source_file: process.env.SOURCE_FILE,
  source_name: process.env.SOURCE_NAME,
  source_hash: process.env.SOURCE_HASH,
  job_id: process.env.JOB_ID,
  speaker_mode: process.env.SPEAKER_MODE,
  requested_num_speakers: process.env.NUM_SPEAKERS ? Number(process.env.NUM_SPEAKERS) : null,
  archive: process.env.ARCHIVE_FILE,
  transcript: process.env.TRANSCRIPT,
  speaker_json: process.env.SPEAKER_JSON,
  raw_segments: Number(process.env.SEGMENT_COUNT),
  transcript_segments: Number(process.env.WRITTEN),
  processed_at: new Date().toISOString()
};
process.stdout.write(JSON.stringify(data, null, 2) + "\n");
NODE

[ -s "$LOCAL_META" ] || fail "无法生成会议处理元数据" 7

echo "STATUS=OK"
echo "CACHE=MISS"
echo "ARCHIVE=$ARCHIVE_FILE"
echo "TRANSCRIPT=$LOCAL_TXT"
echo "SPEAKER_JSON=$LOCAL_JSON"
echo "META=$LOCAL_META"
echo "SEGMENTS=$WRITTEN"
