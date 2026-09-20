#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import time
import random
import serial  # 需要安装 pyserial 库: pip install pyserial
import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion  # 引入新版 API 规范枚举
import subprocess  # 新增：用于运行外部脚本
import sys  # 新增：用于获取脚本路径
import os  # 新增：用于检查文件是否存在

# ==================== 【配置区域】 ====================

# 0. 运行模式开关
# 设置为 'MOCK'   -> 向上模拟发假数据，向下无论如何都会把云端命令转发到串口
# 设置为 'SERIAL' -> 纯真实硬件透传，双向读写真实串口
RUN_MODE = 'SERIAL'  # 切换到了真实串口模式

# 1. 硬件串口配置（昇腾板子已确认关闭系统登录占用的串口节点）
SERIAL_PORT = '/dev/ttyAMA0'
BAUD_RATE = 115200
SERIAL_TIMEOUT = 0.5

# 2. 远端 MQTT 服务器配置 —— 🚀 【已根据图片内容完成适配修改】 🚀
MQTT_BROKER = "193.112.129.57"  # 服务器地址
MQTT_PORT = 1883  # 标准 MQTT 端口（非 WebSocket 端口）
MQTT_CLIENT_ID = "mqttx_20430706"  # Client ID
MQTT_USER = "ha"  # 用户名
MQTT_PASSWORD = "your_password_here"  # ⚠️ 请在此处填入图片中隐藏的密码字符串

# 【协议V1.3 适配】细化三向主题
MQTT_TOPIC_CONTROL = "Control"  # 接收北向控制指令 / 南向事件型上报
MQTT_TOPIC_NORTH_DATA = "NorthData"  # 接收北向用户数据（下行）
MQTT_TOPIC_SOUTH_DATA = "SouthData"  # 南向定时上报状态与数据（上行）

# =====================================================
# 3. 字典映射表：下位机简写 Key -> MQTT 云端标准 Key (上行)
KEY_MAP = {
    # 枪1 基础数据
    "g1s": "Gun1State",
    "g1t": "Gun1Temp",
    "g1v": "Gun1Vol",
    "g1c": "Gun1Cur",
    "g1cs": "Gun1CharSoc",  # 充电充入容量 (mAh)
    # 枪1 新增被充车协议参数
    "g1soc": "Gun1Soc",  # 当前被充车电量 (整数)
    "g1ct": "Gun1CharTemp",  # 当前被充车温度 (1位小数)
    "g1stop": "Gun1Stop",  # 停止原因 (1:用户 2:充满 3:高温 4:火警)
    "g1soh": "Gun1Soh",  # 电池健康度 (整数)
    "g1bc": "Gun1BatCap",  # 枪1电池容量
    "g2bc": "Gun2BatCap",  # 枪2电池容量
    "g1a": "Gun1Agt",  # 枪1充电协议
    "g2a": "Gun2Agt",  # 枪2充电协议

    # 枪2 基础数据
    "g2s": "Gun2State",
    "g2t": "Gun2Temp",
    "g2v": "Gun2Vol",
    "g2c": "Gun2Cur",
    "g2cs": "Gun2CharSoc",  # 充电充入容量 (mAh)
    # 枪2 新增被充车协议参数
    "g2soc": "Gun2Soc",  # 当前被充车电量 (整数)
    "g2ct": "Gun2CharTemp",  # 当前被充车温度 (1位小数)
    "g2stop": "Gun2Stop",  # 停止原因 (1:用户 2:充满 3:高温 4:火警)
    "g2soh": "Gun2Soh",  # 电池健康度 (整数)

    # 系统环境
    "st": "SysTemp",
    "sh": "SysHumi"
}

# 4. 新增字典映射表：云端长 Key -> 下位机简写 Key (下行)
DOWN_KEY_MAP = {
    "Gun1UserName": "g1un",  # 枪1用户名 (字符串)
    "Gun2UserName": "g2un",  # 枪2用户名 (字符串)
    "Gun1UserBal": "g1ub",  # 枪1余额 (整数，扩大了10倍)
    "Gun2UserBal": "g2ub"  # 枪2余额 (整数，扩大了10倍)
}

# 全局串口对象
ser = None


def run_network_init():
    """
    在程序启动时运行 networkinit.py，等待它执行完毕后再继续
    """
    print("\n" + "=" * 60)
    print("🔧 [初始化] 开始执行网络初始化脚本 networkinit.py...")
    print("=" * 60)

    # 【修改点】使用绝对路径指定 networkinit.py 的位置
    script_path = "/home/HwHiAiUser/VOLT/networkinit.py"

    # 检查文件是否存在
    if not os.path.exists(script_path):
        print(f"❌ [初始化] 找不到 networkinit.py 文件！")
        print(f"   查找路径: {script_path}")
        print("   程序将继续运行，但网络可能未正确初始化...")
        print("=" * 60 + "\n")
        time.sleep(2)
        return

    try:
        # 使用 subprocess 运行 networkinit.py，并等待它完成
        result = subprocess.run(
            [sys.executable, script_path],  # 使用绝对路径
            capture_output=True,  # 捕获输出
            text=True,  # 以文本模式处理输出
            timeout=120  # 设置超时时间 120 秒，防止脚本卡死
        )

        # 打印 networkinit.py 的标准输出
        if result.stdout:
            print(f"[networkinit.py 输出]\n{result.stdout}")

        # 打印 networkinit.py 的错误输出（如果有）
        if result.stderr:
            print(f"[networkinit.py 错误输出]\n{result.stderr}")

        # 检查返回码
        if result.returncode == 0:
            print("✅ [初始化] networkinit.py 执行成功！")
        else:
            print(f"⚠️ [初始化] networkinit.py 执行失败，返回码: {result.returncode}")
            print("   程序将继续运行，但网络可能未正确初始化...")

    except subprocess.TimeoutExpired:
        print("❌ [初始化] networkinit.py 执行超时（超过120秒）！")
        print("   程序将继续运行，但网络可能未正确初始化...")
    except Exception as e:
        print(f"❌ [初始化] 运行 networkinit.py 时发生异常: {e}")
        print("   程序将继续运行，但网络可能未正确初始化...")

    print("=" * 60 + "\n")

    # 等待额外 2 秒，确保网络设备稳定
    time.sleep(2)


def on_connect(client, userdata, flags, rc, properties=None):
    """MQTT v5 连接成功的回调函数 (已适配 5 参数新版规范)"""
    # 兼容处理：新版 paho-mqtt 的 rc 是一个 ReasonCode 对象，可以通过 .value 拿到整数错误码
    reason_code = rc.value if hasattr(rc, "value") else rc

    if reason_code == 0:
        print("\n==========================================")
        mode_str = "🟢 [混合模拟模式]" if RUN_MODE == 'MOCK' else "🟢 [真实透传模式]"
        print(f"{mode_str} 成功连接到图片中的 MQTT 服务器!")
        print(f"   服务器: {MQTT_BROKER}:{MQTT_PORT}")
        print(f"   客户端ID: {MQTT_CLIENT_ID}")
        print("==========================================")

        client.subscribe(MQTT_TOPIC_CONTROL, qos=0)
        client.subscribe(MQTT_TOPIC_NORTH_DATA, qos=0)
        print(f"📥 已订阅云端下行控制主题: {MQTT_TOPIC_CONTROL}")
        print(f"📥 已订阅云端下行数据主题: {MQTT_TOPIC_NORTH_DATA}")
        print("==========================================")
    else:
        print(f"🔴 连接云端失败，错误码(Reason Code): {reason_code}")


def on_disconnect(client, userdata, disconnect_flags, rc, properties=None):
    """MQTT v5 断开连接的回调函数"""
    print("⚠️ 与 MQTT 服务器断开连接，正在尝试自动重连...")


def on_message(client, userdata, msg):
    """【核心转发】处理云端下发（北向 -> 南向）的指令并百分之百透传至串口"""
    global ser
    try:
        payload_str = msg.payload.decode('utf-8')
        data = json.loads(payload_str)

        # 1. 优先过滤掉南向自己发到 Control 主题的事件上报（防自产自销的回音刷屏）
        if msg.topic == MQTT_TOPIC_CONTROL and ("Gun1Stop" in data or "Gun2Stop" in data):
            return

        print(f"\n[⬇️ 云端下发 | Topic: {msg.topic}]")
        print(f"📦 原始报文: {payload_str}")

        # 2. 核心转发逻辑：只要接收到了合法的云端北向命令，并且串口是打开状态，就必须原样吐给单片机！
        if ser and ser.is_open:
            # --- 【核心转换】提取并转换长 Key 为短 Key 发给单片机 ---
            short_data = {}
            for k, v in data.items():
                short_k = DOWN_KEY_MAP.get(k, k)
                short_data[short_k] = v

            # 重新序列化 JSON 移除多余空格，并拼装 [U4] 头部
            compact_json_str = json.dumps(short_data, separators=(',', ':'))
            mcu_cmd = f"[U4]{compact_json_str}\n"

            ser.write(mcu_cmd.encode('utf-8'))
            print(f"➡️ [硬件转发] 成功将命令通过串口({SERIAL_PORT})发送给单片机: {mcu_cmd.strip()}")
        else:
            print("⚠️ [硬件转发] 失败！当前串口对象未建立或未打开，命令仅在屏幕打印。")

        # 3. 如果是 MOCK 模式，在屏幕上额外提供可读的中文解析，方便肉眼观察
        if RUN_MODE == 'MOCK':
            print("--- [屏幕终端模拟解析] ---")
            if msg.topic == MQTT_TOPIC_CONTROL:
                if "Gun1CtrSta" in data: print(f"⚙️ [控制] 枪1状态变更为: {data['Gun1CtrSta']}")
                if "Gun2CtrSta" in data: print(f"⚙️ [控制] 枪2状态变更为: {data['Gun2CtrSta']}")
                if "PowSupCtr" in data:
                    mode = "市电供电" if data['PowSupCtr'] == 1 else (
                        "储能供电" if data['PowSupCtr'] == 2 else "未知状态")
                    print(f"🔌 [控制] 电源路径已切换为 -> {mode}")
                if "StopAllChar" in data and data["StopAllChar"] == 1: print("🚨 [控制] 紧急动作：已切断所有充电枪电源！")

            elif msg.topic == MQTT_TOPIC_NORTH_DATA:
                if "Gun1UserName" in data: print(f"👤 [业务] 枪1屏幕显示欢迎: {data['Gun1UserName']}")
                if "Gun2UserName" in data: print(f"👤 [业务] 枪2屏幕显示欢迎: {data['Gun2UserName']}")
                if "Gun1UserBal" in data: print(
                    f"💰 [业务] 枪1原始整形 {data['Gun1UserBal']} -> 实际余额: {float(data['Gun1UserBal']) / 10.0} 元")
                if "Gun2UserBal" in data: print(
                    f"💰 [业务] 枪2原始整形 {data['Gun2UserBal']} -> 实际余额: {float(data['Gun2UserBal']) / 10.0} 元")

    except json.JSONDecodeError:
        print("❌ 云端下发的数据非标准 JSON，已丢弃。")
    except Exception as e:
        print(f"❌ 下行处理与转发失败: {e}")


def generate_mock_south_data():
    """生成符合 V1.3 规范的全量南向定时状态数据"""
    return {
        "Gun1Temp": round(random.uniform(35.0, 42.0), 1),
        "Gun2Temp": round(random.uniform(34.0, 39.0), 1),
        "Gun1Vol": round(random.uniform(350.0, 420.0), 1),
        "Gun2Vol": 0.0,
        "Gun1Cur": round(random.uniform(100.0, 150.0), 1),
        "Gun2Cur": 0.0,
        "Gun1CharSoc": round(random.uniform(15.5, 85.0), 1),
        "Gun2CharSoc": 0.0,
        "Gun1Soc": int(random.uniform(10, 95)),
        "Gun2Soc": 0,
        "Gun1CharTemp": round(random.uniform(30.0, 45.0), 1),
        "Gun2CharTemp": 0.0,
        "Gun1Soh": int(random.uniform(95, 100)),
        "Gun2Soh": 0,
        "SysTemp": round(random.uniform(26.0, 29.0), 1),
        "SysHumi": round(random.uniform(55.0, 68.0), 1),
        "SysPowSup": random.choice([1, 2]),
        "CharPowSup": random.choice([1, 2]),
        "EssSoc": round(random.uniform(40.0, 92.0), 1),
        "EssVol": round(random.uniform(650.0, 720.0), 1),
        "EssCur": round(random.uniform(-20.0, 50.0), 1),
        "EssTemp": round(random.uniform(30.0, 35.5), 1),
        "PvVol": round(random.uniform(400.0, 600.0), 1),
        "PvCur": round(random.uniform(5.0, 25.0), 1)
    }


def main():
    global ser

    # ==================== 【新增】先运行网络初始化脚本 ====================
    run_network_init()
    time.sleep(1.5)

    # ---------------- 步骤 1：尝试初始化串口 ----------------
    print(f"⏳ 正在尝试打开单片机串口 ({SERIAL_PORT})...")
    try:
        ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=SERIAL_TIMEOUT)
        print(f"✅ 串口 {SERIAL_PORT} 打开成功！")
    except Exception as e:
        if RUN_MODE == 'SERIAL':
            print(f"❌ [致命错误] 纯透传模式下串口必须打开成功，程序退出: {e}")
            return
        else:
            print(f"⚠️ [警告] 串口未连接或被占用。当前处于混合模拟模式: {e}")
            ser = None

    # ---------------- 步骤 2：初始化 MQTT ----------------
    print("⏳ 正在初始化网络模块...")

    # 使用新版 API 核心绑定，完美契合库版本并启用协议 5.0
    client = mqtt.Client(
        callback_api_version=CallbackAPIVersion.VERSION2,
        client_id=MQTT_CLIENT_ID,
        protocol=mqtt.MQTTv5
    )

    # 绑定配置信息
    client.username_pw_set(username=MQTT_USER, password=MQTT_PASSWORD)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    try:
        # 配合图片中设定的 10 秒超时时间
        client.connect(MQTT_BROKER, MQTT_PORT, keepalive=10)
        client.loop_start()
    except Exception as e:
        print(f"❌ 无法连接到服务器: {e}")
        return

    last_report_time = 0
    report_interval = 3
    serial_buffer = ""

    # ---------------- 步骤 3：核心业务循环 ----------------
    try:
        while True:
            if RUN_MODE == 'SERIAL':
                # ================= 真实硬件纯透传模式 =================
                if ser and ser.in_waiting > 0:
                    try:
                        serial_buffer += ser.read(ser.in_waiting).decode('utf-8')

                        if '\n' in serial_buffer:
                            lines = serial_buffer.split('\n')
                            serial_buffer = lines[-1]

                            for raw_data in lines[:-1]:
                                raw_data = raw_data.strip()
                                if not raw_data:
                                    continue

                                if raw_data.startswith("[U4]"):
                                    raw_data = raw_data[4:]

                                try:
                                    short_data = json.loads(raw_data)

                                    expanded_data = {}
                                    for k, v in short_data.items():
                                        expanded_data[KEY_MAP.get(k, k)] = v

                                    final_json = json.dumps(expanded_data)

                                    if "Gun1Stop" in expanded_data or "Gun2Stop" in expanded_data:
                                        target_topic = MQTT_TOPIC_CONTROL
                                        icon = "🚨"
                                    else:
                                        target_topic = MQTT_TOPIC_SOUTH_DATA
                                        icon = "📈"

                                    client.publish(target_topic, payload=final_json, qos=0)
                                    print(
                                        f"[{time.strftime('%H:%M:%S')}] {icon} [MCU->云端({target_topic})]: {final_json}")

                                except json.JSONDecodeError:
                                    print(f"🔧 [MCU调试日志]: {raw_data}")
                    except Exception as e:
                        print(f"❌ 串口读取与组包失败: {e}")
                time.sleep(0.01)

            else:
                # ================= 混合模拟测试模式 =================
                if ser and ser.is_open and ser.in_waiting > 0:
                    ser.reset_input_buffer()

                current_time = time.time()
                if current_time - last_report_time >= report_interval:
                    mock_data = generate_mock_south_data()
                    south_json = json.dumps(mock_data)
                    client.publish(MQTT_TOPIC_SOUTH_DATA, payload=south_json, qos=0)

                    print(f"[{time.strftime('%H:%M:%S')}] 📈 [模拟状态上报 -> SouthData]: {south_json}")
                    last_report_time = current_time

                time.sleep(0.1)

    except KeyboardInterrupt:
        print("\n👋 收到退出信号，正在安全关闭软硬件资源...")

    finally:
        client.loop_stop()
        client.disconnect()
        if ser and ser.is_open:
            ser.close()
        print("🏁 程序安全退出。")


if __name__ == '__main__':
    main()
