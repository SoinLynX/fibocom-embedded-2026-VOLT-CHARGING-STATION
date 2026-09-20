#!/usr/bin/env python3
"""
火灾检测 - 连续10次确认/解除模式 + 帧差闪烁门槛(误报治理) + 通知网关
"""

import os
import sys
import cv2
import numpy as np
import time
import signal
import json  # 新增：用于写状态文件

from mindx.sdk import base, Tensor

os.environ['ASCEND_RT_VISIBLE_DEVICES'] = '0'
os.environ['QT_QPA_PLATFORM'] = 'offscreen'

# ================== 可调参数（误报治理） ==================
conf_thresh = 0.5           # 置信度阈值
CONFIRM_THRESHOLD = 8       # 火灾确认所需连续检出次数
EXTINCT_THRESHOLD = 15      # 熄灭解除所需连续无火次数
FLICKER_MIN = 5.0           # 闪烁门槛下限
FLICKER_RATIO = 3.0         # 自适应系数
# --- 新增：小目标过滤参数 ---
MIN_BOX_AREA = 1500          # 最小面积阈值 (例: 30x30像素 = 900)，小于此面积直接丢弃
MIN_BOX_WIDTH = 20          # 最小宽度限制 (像素)
MIN_BOX_HEIGHT = 20         # 最小高度限制 (像素)
# ==========================================================

print("="*60)
print("🔥 火灾检测 - 双向连续确认 + 静态过滤 + 通知网关")
print("="*60)

# 初始化
base.mx_init()
model_path = "/home/HwHiAiUser/VOLT/best.om"
model = base.model(modelPath=model_path, deviceId=0)

print(f"✅ 模型加载成功")
print(f"   输入形状: {model.input_shape(0)}")
print(f"   输出形状: {model.output_shape(0)}")

# 摄像头打开
cap = None
for index in [1, 2, -1]:  # 从1开始避免0的错误
    cap = cv2.VideoCapture(index)
    if cap is not None and cap.isOpened():
        print(f"✅ 摄像头已打开 (索引 {index})")
        break
    else:
        if cap:
            cap.release()
        cap = None

if cap is None:
    cap = cv2.VideoCapture("/dev/video0")
    if cap is not None and cap.isOpened():
        print("✅ 摄像头已打开 (/dev/video0)")
    else:
        print("❌ 无法打开摄像头")
        sys.exit(1)

print("按 Ctrl+C 退出\n")

# 输出目录
output_dir = "/home/HwHiAiUser/VOLT/detections"
os.makedirs(output_dir, exist_ok=True)

# 状态变量
fire_counter = 0
fire_confirmed = False
no_fire_counter = 0

# 新增：上一次通知的状态（避免重复通知）
last_notified_status = None  # True 或 False

def write_fire_status(status):
    """将火灾状态写入 /tmp/fire_status.json 供网关程序读取"""
    try:
        with open("/tmp/fire_status.json", "w") as f:
            json.dump({"fire": status, "time": time.time()}, f)
    except Exception as e:
        print(f"⚠️ 写入状态文件失败: {e}")

def signal_handler(sig, frame):
    print("\n⚠️ 用户中断")
    if cap:
        cap.release()
    # 退出时清除状态文件（可选）
    try:
        os.remove("/tmp/fire_status.json")
    except:
        pass
    sys.exit(0)
signal.signal(signal.SIGINT, signal_handler)

def letterbox(img, new_shape=(640, 640), color=(114, 114, 114)):
    shape = img.shape[:2]
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    new_unpad = int(round(shape[1] * r)), int(round(shape[0] * r))
    dw, dh = new_shape[1] - new_unpad[0], new_shape[0] - new_unpad[1]
    dw, dh = dw/2, dh/2
    if shape[::-1] != new_unpad:
        img = cv2.resize(img, new_unpad, interpolation=cv2.INTER_LINEAR)
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    img = cv2.copyMakeBorder(img, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    return img, r, (dw, dh)

def simple_nms(boxes, iou_thresh=0.5):
    if len(boxes) == 0:
        return []
    boxes = np.array(boxes)
    idxs = np.argsort(boxes[:, 4])[::-1]
    keep = []
    while len(idxs) > 0:
        i = idxs[0]
        keep.append(i)
        if len(idxs) == 1:
            break
        x1 = np.maximum(boxes[i, 0], boxes[idxs[1:], 0])
        y1 = np.maximum(boxes[i, 1], boxes[idxs[1:], 1])
        x2 = np.minimum(boxes[i, 2], boxes[idxs[1:], 2])
        y2 = np.minimum(boxes[i, 3], boxes[idxs[1:], 3])
        w = np.maximum(0, x2 - x1)
        h = np.maximum(0, y2 - y1)
        inter = w * h
        area_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        area_j = (boxes[idxs[1:], 2] - boxes[idxs[1:], 0]) * (boxes[idxs[1:], 3] - boxes[idxs[1:], 1])
        iou = inter / (area_i + area_j - inter + 1e-6)
        idxs = np.delete(idxs, np.concatenate(([0], np.where(iou > iou_thresh)[0] + 1)))
    return boxes[keep]

def box_iou(b1, b2):
    """计算两个框的 IoU，b=[x1,y1,x2,y2]"""
    x1 = max(b1[0], b2[0])
    y1 = max(b1[1], b2[1])
    x2 = min(b1[2], b2[2])
    y2 = min(b1[3], b2[3])
    w = max(0, x2 - x1)
    h = max(0, y2 - y1)
    inter = w * h
    area1 = (b1[2] - b1[0]) * (b1[3] - b1[1])
    area2 = (b2[2] - b2[0]) * (b2[3] - b2[1])
    return inter / (area1 + area2 - inter + 1e-6)

# 帧差闪烁检测：上一帧推理时的灰度图（火焰像素高频闪动，橙色静物像素不变）
prev_gray = None

def filter_by_flicker(boxes, diff):
    """
    闪烁门槛（误报治理主力）：
    计算每个候选框内部的灰度帧差均值，像素不闪的框当场判死剔除 ——
    不进火灾确认计数，也不进静态跟踪表。
    真火即使烧得很稳、框不动，框内像素也在高频闪动，必然通过。
    diff 为 None（首帧）时不做过滤，直接放行。
    """
    if diff is None or len(boxes) == 0:
        return boxes
    h, w = diff.shape
    baseline = float(np.median(diff))            # 全画面噪声/曝光基线
    thresh = max(FLICKER_MIN, FLICKER_RATIO * baseline + 1.0)
    alive = []
    for box in boxes:
        x1, y1, x2, y2 = box[:4]
        bw, bh = x2 - x1, y2 - y1
        # ROI 向中心收缩 20%，避免框边缘切到背景带来干扰
        cx1 = int(max(0, x1 + bw * 0.2)); cy1 = int(max(0, y1 + bh * 0.2))
        cx2 = int(min(w, x2 - bw * 0.2)); cy2 = int(min(h, y2 - bh * 0.2))
        if cx2 <= cx1 or cy2 <= cy1:
            alive.append(box)
            continue
        mad = float(diff[cy1:cy2, cx1:cx2].mean())
        if mad > thresh:
            alive.append(box)
        else:
            print(f"🟠 死目标剔除(像素不闪): mad={mad:.1f} ≤ 阈值{thresh:.1f} "
                  f"({int(x1)},{int(y1)})-({int(x2)},{int(y2)})")
    return alive

frame_count = 0
infer_count = 0
fps_start = time.time()
fps_counter = 0

try:
    while True:
        ret, frame = cap.read()
        if not ret:
            cap.release()
            time.sleep(1)
            cap = cv2.VideoCapture(0)
            if not cap.isOpened():
                break
            continue

        frame_count += 1
        fps_counter += 1

        if frame_count % 3 != 0:
            continue

        # 帧差准备：本帧灰度（高斯模糊降噪），与上一推理帧求差
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (5, 5), 0)
        diff = cv2.absdiff(gray, prev_gray) if prev_gray is not None else None
        prev_gray = gray

        # 预处理
        img, scale_ratio, pad_size = letterbox(frame, new_shape=[640, 640])
        img_rgb = img[:, :, ::-1].transpose(2, 0, 1)
        img_np = np.expand_dims(img_rgb, 0).astype(np.float32)
        img_np = np.ascontiguousarray(img_np) / 255.0
        tensor = Tensor(img_np)

        try:
            outputs = model.infer([tensor])
            infer_count += 1
        except Exception as e:
            print(f"推理错误: {e}")
            continue

        outputs[0].to_host()
        output_np = np.array(outputs[0])

        boxes = []
        for i in range(output_np.shape[2]):
            conf = output_np[0, 4, i]
            if conf < conf_thresh:
                continue
            cls = int(output_np[0, 5, i])
            if cls != 0:
                continue
            x = output_np[0, 0, i]
            y = output_np[0, 1, i]
            w = output_np[0, 2, i]
            h = output_np[0, 3, i]

            x1 = (x - w / 2 - pad_size[0]) / scale_ratio
            y1 = (y - h / 2 - pad_size[1]) / scale_ratio
            x2 = (x + w / 2 - pad_size[0]) / scale_ratio
            y2 = (y + h / 2 - pad_size[1]) / scale_ratio

            x1 = max(0, min(x1, frame.shape[1]))
            y1 = max(0, min(y1, frame.shape[0]))
            x2 = max(0, min(x2, frame.shape[1]))
            y2 = max(0, min(y2, frame.shape[0]))

            if x2 > x1 and y2 > y1:
                # --- 新增：小目标过滤逻辑 ---
                box_w = x2 - x1
                box_h = y2 - y1
                box_area = box_w * box_h

                if box_area < MIN_BOX_AREA or box_w < MIN_BOX_WIDTH or box_h < MIN_BOX_HEIGHT:
                    # 如果需要调试看被过滤的框有多大，可以取消下面这行的注释
                    # print(f"🤏 过滤极小目标: 面积={box_area:.0f}, 尺寸={box_w:.0f}x{box_h:.0f}")
                    continue
                # ----------------------------

                boxes.append([x1, y1, x2, y2, conf, cls])

        if len(boxes) > 0:
            boxes = simple_nms(boxes, iou_thresh=0.5)
            # 闪烁门槛：像素不闪的死目标当场剔除（橙色静物误报治理的唯一手段）
            boxes = filter_by_flicker(boxes, diff)

        # ========== 核心逻辑 ==========
        if len(boxes) > 0:
            no_fire_counter = 0
            if not fire_confirmed:
                fire_counter += 1
                print(f"🔥 检测到火 ({fire_counter}/{CONFIRM_THRESHOLD})")
                if fire_counter >= CONFIRM_THRESHOLD:
                    fire_confirmed = True
                    # 保存图片
                    result_img = frame.copy()
                    for box in boxes:
                        x1, y1, x2, y2, conf, cls = box
                        label = "🔥 Fire"
                        cv2.rectangle(result_img, (int(x1), int(y1)), (int(x2), int(y2)), (0, 0, 255), 2)
                        cv2.putText(result_img, f"{label} {conf:.2f}", (int(x1), int(y1)-5),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1)
                    timestamp = time.strftime("%Y%m%d_%H%M%S")
                    filename = f"{output_dir}/fire_confirmed_{timestamp}.jpg"
                    cv2.imwrite(filename, result_img)
                    print(f"🚨 火灾确认！已保存: {filename}")
                    # 写状态文件：fire=True
                    write_fire_status(True)
                    last_notified_status = True
            else:
                print("🔥 FIRE (持续)")
        else:
            if fire_confirmed:
                no_fire_counter += 1
                if no_fire_counter >= EXTINCT_THRESHOLD:
                    print("✅ 火已熄灭，重置状态")
                    fire_confirmed = False
                    fire_counter = 0
                    no_fire_counter = 0
                    # 写状态文件：fire=False
                    write_fire_status(False)
                    last_notified_status = False
                else:
                    print(f"🔥 无火检测 ({no_fire_counter}/{EXTINCT_THRESHOLD})")
            else:
                if fire_counter > 0:
                    print(f"❌ 未检测到火，计数器重置 (之前 {fire_counter})")
                fire_counter = 0

        # FPS
        if time.time() - fps_start >= 2.0:
            fps = int(fps_counter / (time.time() - fps_start))
            print(f"📊 FPS: {fps}")
            fps_counter = 0
            fps_start = time.time()

except KeyboardInterrupt:
    print("\n⚠️ 用户中断")
finally:
    cap.release()
    # 清除状态文件
    try:
        os.remove("/tmp/fire_status.json")
    except:
        pass
    print("\n" + "="*60)
    print("程序退出")
    print(f"  火灾确认: {'是' if fire_confirmed else '否'}")
    print(f"  保存图片: {output_dir}/fire_confirmed_*.jpg")
    print("="*60)