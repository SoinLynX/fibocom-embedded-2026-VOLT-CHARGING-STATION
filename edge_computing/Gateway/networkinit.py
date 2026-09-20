#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import serial
import time
import sys

def send_at_command(ser, command, wait_time=1.0):
    """
    发送 AT 指令并等待回复
    
    Args:
        ser: serial 对象
        command: 要发送的 AT 指令（不需要加 \r\n）
        wait_time: 等待回复的时间（秒）
    """
    # 清空输入缓冲区，避免残留数据干扰
    ser.reset_input_buffer()
    
    # 发送指令（AT指令需要以 \r\n 结尾）
    cmd = command + "\r\n"
    ser.write(cmd.encode('utf-8'))
    print(f"[发送] {command}")
    
    # 等待设备响应
    time.sleep(wait_time)
    
    # 读取所有可用的响应数据
    response = ""
    while ser.in_waiting > 0:
        response += ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
    
    if response:
        print(f"[接收] {response.strip()}")
    else:
        print("[接收] (无响应)")
    
    print("-" * 50)
    return response

def main():
    # 串口配置
    PORT = "/dev/ttyUSB5"
    BAUDRATE = 115200
    TIMEOUT = 2  # 读取超时（秒）
    
    # 要发送的两条 AT 指令
    commands = [
        'AT+CGDCONT=1,"IP","cmnet"',
        'AT+GTRNDIS=1,1'
    ]
    
    try:
        # 打开串口
        print(f"正在打开串口 {PORT}，波特率 {BAUDRATE}...")
        ser = serial.Serial(
            port=PORT,
            baudrate=BAUDRATE,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=TIMEOUT
        )
        
        # 检查串口是否成功打开
        if ser.is_open:
            print(f"✅ 串口 {PORT} 打开成功！\n")
        else:
            print(f"❌ 无法打开串口 {PORT}")
            sys.exit(1)
        
        # 等待设备就绪（某些模块需要时间启动）
        print("等待设备就绪...")
        time.sleep(0.5)
        
        # 先发送一个 "AT" 测试指令，检查通信是否正常
        print("【通信测试】发送 AT...")
        ser.reset_input_buffer()
        ser.write(b"AT\r\n")
        time.sleep(0.5)
        test_response = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
        if "OK" in test_response:
            print("✅ 设备响应正常 (AT OK)\n")
        else:
            print("⚠️ 设备无响应或响应异常，继续尝试发送...\n")
        
        # 依次发送两条 AT 指令
        for cmd in commands:
            send_at_command(ser, cmd, wait_time=0.5)
            # 指令之间稍作延时
            time.sleep(0.5)
        
        print("✅ 所有指令发送完成！")
        
    except serial.SerialException as e:
        print(f"❌ 串口错误: {e}")
        print(f"   请检查:")
        print(f"   1. 设备是否已连接到 {PORT}")
        print(f"   2. 是否有读写权限 (尝试: sudo chmod 666 {PORT})")
        print(f"   3. 设备是否被其他程序占用")
        sys.exit(1)
    except Exception as e:
        print(f"❌ 发生错误: {e}")
        sys.exit(1)
    finally:
        # 确保串口被正确关闭
        if 'ser' in locals() and ser.is_open:
            ser.close()
            print("串口已关闭。")

if __name__ == "__main__":
    main()
