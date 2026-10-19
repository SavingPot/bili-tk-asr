import os
import subprocess
import tempfile
import glob
import uuid
from fastapi import FastAPI, UploadFile, File, BackgroundTasks
from fastapi.responses import JSONResponse
from funasr_onnx import SenseVoiceSmall
from pathlib import Path

app = FastAPI()
MODEL_DIR = str(Path(__file__).parent / "SenseVoiceSmall-onnx")

print(f"正在从本地加载 SenseVoice 模型: {MODEL_DIR}")
model = SenseVoiceSmall(model_dir=MODEL_DIR, batch_size=1, quantize=False)
print("模型加载完成！")

# 全局字典，用于保存所有任务的状态
TASKS = {}

def process_audio_task(task_id, m4s_path):
    """后台处理任务：直接切片并识别"""
    wav_dir = tempfile.mkdtemp()
    try:
        TASKS[task_id].update({"status": "processing", "message": "正在切片...", "progress": 0})
        
        # 直接按 5 分钟（300秒）硬切片，速度极快
        out_pattern = os.path.join(wav_dir, "out_%03d.wav")
        subprocess.run(
            ["ffmpeg", "-y", "-i", m4s_path, "-ar", "16000", "-ac", "1", 
             "-f", "segment", "-segment_time", "120", "-reset_timestamps", "1", out_pattern],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

        wav_files = sorted(glob.glob(os.path.join(wav_dir, "out_*.wav")))
        total = len(wav_files)
        if total == 0:
            TASKS[task_id].update({"status": "failed", "message": "音频切片失败"})
            return

        final_text = ""
        for i, wav_file in enumerate(wav_files):
            # 更新进度
            TASKS[task_id].update({
                "progress": int((i / total) * 100),
                "message": f"正在识别 ({i}/{total})..."
            })
            res = model(wav_file, language="auto", use_itn=True)
            if res:
                if isinstance(res, str):
                    final_text += res
                elif isinstance(res, list) and len(res) > 0:
                    first_item = res[0]
                    if isinstance(first_item, dict):
                        final_text += first_item.get("text", "")
                    elif isinstance(first_item, str):
                        final_text += first_item

        TASKS[task_id].update({
            "status": "completed", "progress": 100, "text": final_text, "message": "识别完成"
        })

    except Exception as e:
        TASKS[task_id].update({"status": "failed", "message": str(e)})
    finally:
        if os.path.exists(m4s_path): os.remove(m4s_path)
        for f in glob.glob(os.path.join(wav_dir, "*.wav")):
            if os.path.exists(f): os.remove(f)
        if os.path.exists(wav_dir): os.rmdir(wav_dir)

@app.post("/api/transcribe")
async def transcribe(background_tasks: BackgroundTasks, file: UploadFile = File(...)):
    """接收文件并立刻返回 task_id"""
    task_id = str(uuid.uuid4())
    with tempfile.NamedTemporaryFile(delete=False, suffix=".m4s") as tmp_m4s:
        while chunk := await file.read(1024 * 1024 * 5):
            tmp_m4s.write(chunk)
        m4s_path = tmp_m4s.name
    
    TASKS[task_id] = {"status": "queued", "progress": 0, "text": "", "message": "排队中..."}
    background_tasks.add_task(process_audio_task, task_id, m4s_path)
    return JSONResponse({"task_id": task_id})

@app.get("/api/progress/{task_id}")
async def get_progress(task_id: str):
    """前端轮询调用的接口"""
    task = TASKS.get(task_id)
    if not task:
        return JSONResponse({"error": "任务不存在"}, status_code=404)
    return JSONResponse(task)

import shutil

def clean_temp_on_startup():
    """启动时清理之前残留的临时文件"""
    temp_dir = tempfile.gettempdir()
    # 清理残留的 m4s
    for f in glob.glob(os.path.join(temp_dir, "*.m4s")):
        try: os.remove(f)
        except: pass
    # 清理残留的切片区目录 (通常包含 out_*.wav)
    for d in glob.glob(os.path.join(temp_dir, "tmp*")):
        if os.path.isdir(d) and glob.glob(os.path.join(d, "out_*.wav")):
            try: shutil.rmtree(d)
            except: pass

if __name__ == "__main__":
    clean_temp_on_startup()
    print("已清理历史残留文件。")
    import uvicorn
    try:
        uvicorn.run(app, host="127.0.0.1", port=8001)
    except KeyboardInterrupt:
        print("\n服务已手动关闭。")