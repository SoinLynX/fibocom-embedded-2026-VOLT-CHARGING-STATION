import json
import sqlite3
import time
import threading
from datetime import datetime, timezone, timedelta
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from paho.mqtt import client as mqtt_client
from paho.mqtt.enums import CallbackAPIVersion
from typing import Optional
import uuid

# ==================== 配置 ====================
MQTT_BROKER = '127.0.0.1'
MQTT_PORT = 1883
DB_FILE = "/root/volt-nexus.db"  # 服务器环境


# DB_FILE = "volt-nexus.db"   # 12电脑环境


# ==================== 华为实况窗远程推送配置 ====================
# ⚠️ 以下三项需要到 AGC 控制台（AppGallery Connect）→ 项目设置 → 常规 里复制填入：
HW_PUSH_APP_ID = "101653523864464154"  # ⚠️ 你给的这是「项目ID」，如果推送报 appId 无效，请换成 AGC 里该应用的「APP ID」
HW_PUSH_CLIENT_ID = "1986600451453231872"
HW_PUSH_CLIENT_SECRET = "C691B587C1564FFA5D31D4A89E4A0B78AEB84F3963EA5819460F3C18058CEE0C"
HW_PUSH_TEST_MESSAGE = True  # 调试期=True（走测试通道，不受频控限制），上线前改 False

# 推送节流：每把枪 31 秒内最多推一次，且 SOC 变化 >= 1% 才推
# 华为限额（其余场景，RENT 属此类）：每设备每 5 分钟最多 10 次、每小时最多 60 次，
# 即平均 30 秒/次。取 31 秒留 1 秒余量，超额部分华为会直接丢弃不下发，绝不能超。
LIVEVIEW_PUSH_MIN_INTERVAL = 31
_g_liveview_last = {}  # {gunNumber: {"time": ts, "soc": int}}

_hw_token_cache = {"token": None, "expire": 0}


def _get_hw_push_token():
    """获取华为推送服务的 access_token（OAuth2 client_credentials），带缓存"""
    import urllib.request
    now = time.time()
    if _hw_token_cache["token"] and now < _hw_token_cache["expire"] - 60:
        return _hw_token_cache["token"]
    body = (
        "grant_type=client_credentials"
        f"&client_id={HW_PUSH_CLIENT_ID}"
        f"&client_secret={HW_PUSH_CLIENT_SECRET}"
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read().decode("utf-8"))
    _hw_token_cache["token"] = result["access_token"]
    _hw_token_cache["expire"] = now + int(result.get("expires_in", 3600))
    return _hw_token_cache["token"]


def push_liveview_update(push_token, activity_id, percent, power_kw, gun_temp, end=False):
    """
    向华为推送服务发送实况窗更新消息（push-type 7）。
    activity_id 必须与 App 端 startLiveView 的 id 一致（900001 + 枪号）。
    end=True 时发送 operation=2（结束实况窗）。
    """
    import urllib.request
    try:
        access_token = _get_hw_push_token()
    except Exception as e:
        print(f"[LiveView Push] 获取华为access_token失败: {e}", flush=True)
        return

    if end:
        payload = {
            "liveViewPayload": {
                "activityId": str(activity_id),
                "operation": 2  # 2 = 结束实况窗
            }
        }
    else:
        pct = max(0, min(100, int(round(percent))))
        payload = {
            "liveViewPayload": {
                "activityId": str(activity_id),
                "operation": 1,  # 1 = 更新实况窗
                "version": int(time.time() * 1000),
                "event": "RENT",  # 必须与 App 端 buildChargeLiveView 的 event 一致
                "title": "伏安超充 充电中",
                "content": f"电量 {pct}% | {power_kw:.1f}kW | 枪温 {gun_temp:.1f}℃",
                "isCapsuleDisplay": True,
                "capsule": {
                    "type": 2,  # 文本胶囊
                    "status": 1,
                    "title": f"{pct}%"
                },
                "richProgress": {
                    "type": 2,
                    "color": "#FFb1c623",  # 与 App 端 PROGRESS 布局颜色一致
                    "progress": pct
                }
            }
        }

    message = {
        "payload": {"notification": {"category": "LIVE_VIEW", **payload}},
        "target": {"token": [push_token]},
        "pushOptions": {"testMessage": HW_PUSH_TEST_MESSAGE}
    }
    url = f"https://push-api.cloud.huawei.com/v1/{HW_PUSH_APP_ID}/messages:send"
    req = urllib.request.Request(
        url,
        data=json.dumps(message).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {access_token}",
            "push-type": "7"  # 7 = 实况窗消息
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        print(f"[LiveView Push] activity={activity_id} end={end} 结果: {result}", flush=True)
    except Exception as e:
        print(f"[LiveView Push] activity={activity_id} 发送失败: {e}", flush=True)


def _maybe_push_liveview(cursor, data):
    """
    在 MQTT 状态入库后调用：查各枪是否有进行中的订单，
    有则按节流策略向该用户的 push token 推送实况窗更新。
    """
    for gun in (1, 2):
        soc = data.get(f"Gun{gun}CharSoc")
        if soc is None:
            continue
        try:
            soc = float(soc)
        except (ValueError, TypeError):
            continue

        # 查该枪进行中的订单
        cursor.execute(
            "SELECT id, userId FROM charging_order WHERE gunNumber = ? AND status = '充电中' "
            "ORDER BY startTime DESC LIMIT 1",
            (gun,)
        )
        order = cursor.fetchone()
        if not order:
            continue
        user_id = order["userId"]

        # 节流：31 秒内不重复，且 SOC 变化 >= 1% 才推（贴着华为 30 秒/次限额）
        now = time.time()
        last = _g_liveview_last.get(gun)
        if last and now - last["time"] < LIVEVIEW_PUSH_MIN_INTERVAL and abs(soc - last["soc"]) < 1:
            continue

        # 查该用户最新 push token
        cursor.execute("SELECT token FROM push_token WHERE userId = ?", (user_id,))
        row = cursor.fetchone()
        if not row or not row["token"]:
            print(f"[LiveView Push] 枪{gun} 用户{user_id} 无push token，跳过", flush=True)
            continue

        vol = data.get(f"Gun{gun}Vol") or 0
        cur = data.get(f"Gun{gun}Cur") or 0
        try:
            power_kw = float(vol) * float(cur) / 1000.0
        except (ValueError, TypeError):
            power_kw = 0.0
        temp = data.get(f"Gun{gun}Temp") or 0
        try:
            temp = float(temp)
        except (ValueError, TypeError):
            temp = 0.0

        activity_id = 900001 + gun  # 与 Charge.py buildChargeLiveView 的 id 一致
        # 推送放到独立线程，避免阻塞 MQTT 接收循环
        threading.Thread(
            target=push_liveview_update,
            args=(row["token"], activity_id, soc, power_kw, temp, False),
            daemon=True
        ).start()
        _g_liveview_last[gun] = {"time": now, "soc": soc}
        print(f"[LiveView Push] 枪{gun} SOC={soc}% 已触发推送 userId={user_id}", flush=True)


def push_liveview_end_for_order(order_id):
    """订单结束时调用：结束该订单对应枪的实况窗"""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT userId, gunNumber FROM charging_order WHERE id = ?", (order_id,))
        order = cursor.fetchone()
        if not order:
            return
        cursor.execute("SELECT token FROM push_token WHERE userId = ?", (order["userId"],))
        row = cursor.fetchone()
        if not row or not row["token"]:
            return
        activity_id = 900001 + int(order["gunNumber"])
        threading.Thread(
            target=push_liveview_update,
            args=(row["token"], activity_id, 0, 0.0, 0.0, True),
            daemon=True
        ).start()
        _g_liveview_last.pop(int(order["gunNumber"]), None)
        print(f"[LiveView Push] 订单{order_id} 结束实况窗 activity={activity_id}", flush=True)
    finally:
        cursor.close()
        conn.close()



# ==================== 生命周期管理 ====================
@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    替代原有的 @app.on_event("startup")，在应用启动时执行初始化，
    并在 yield 后（应用关闭时）可执行清理（此处留空，保持原逻辑）。
    """
    # ---------- 启动逻辑（原 startup_event 内容） ----------
    init_db()
    t = threading.Thread(target=start_mqtt_sync, daemon=True)
    t.start()
    pv_t = threading.Thread(target=pv_auto_loop, daemon=True)
    pv_t.start()
    print("[Gateway Startup] Dedicated MQTT Background Thread Started.", flush=True)
    # -----------------------------------------------------
    yield
    # 如果需要在应用关闭时做清理，可在此处添加（例如断开 MQTT），但原代码无此需求，保留为空。


# 创建 FastAPI 应用时传入 lifespan 参数
app = FastAPI(title="VOLT-NEXUS 智能网关系统 API", lifespan=lifespan)


# ==================== 工具函数 ====================
def get_beijing_dt():
    """获取北京时间 datetime 对象"""
    return datetime.now(timezone(timedelta(hours=8)))


def get_beijing_time():
    """获取北京时间字符串"""
    tz_beijing = timezone(timedelta(hours=8))
    return datetime.now(tz_beijing).strftime('%Y-%m-%d %H:%M:%S')


def parse_order_time(s):
    """解析订单时间，兼容 '2026-08-06 23:17:17' 和 APP 上报的 '2026/08/06 23:17:17'"""
    s = (s or '').strip().replace('/', '-')
    return datetime.strptime(s, '%Y-%m-%d %H:%M:%S')


def get_db_connection():
    """获取数据库连接"""
    conn = sqlite3.connect(DB_FILE, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    """初始化数据库表结构并开启 WAL 模式"""
    sql_list = get_all_table_sql_list()
    conn = get_db_connection()
    cursor = conn.cursor()

    # ✅ 核心优化：允许并发读写，彻底解决高频写入卡顿
    cursor.execute("PRAGMA journal_mode=WAL;")

    for create_sql in sql_list:
        cursor.execute(create_sql)
    conn.commit()
    conn.close()
    print("全部数据表创建完成！WAL 模式已开启！共4张表", flush=True)


def get_all_table_sql_list():
    """获取所有建表SQL语句（SQLite版本）"""

    # 1. 用户表
    sql_user = """
    CREATE TABLE IF NOT EXISTS user (
      userId TEXT PRIMARY KEY NOT NULL,
      userName TEXT NOT NULL,
      account TEXT NOT NULL UNIQUE,
      password TEXT NOT NULL,
      balance REAL DEFAULT 0
    );
    """

    # 2. 充电桩站点表
    sql_charging_station = """
    CREATE TABLE IF NOT EXISTS charging_station (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL,
      address TEXT,
      distance TEXT,
      status TEXT NOT NULL DEFAULT 'available' CHECK(status IN ('available','occupied','broken')),
      price TEXT,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL
    );
    """

    # 3. 充电桩实时状态表 - ✅ 全部改为 REAL
    sql_nexus_status = """
    CREATE TABLE IF NOT EXISTS charging_station_status (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic TEXT,
      timestamp TEXT,
      Gun1UserName TEXT,
      Gun2UserName TEXT,
      Gun1UserBal INTEGER,
      Gun2UserBal INTEGER,
      Gun1Stop TEXT,
      Gun2Stop TEXT,
      Gun1BatCap INTEGER,
      Gun2BatCap INTEGER,
      Gun1Agt TEXT,
      Gun2Agt TEXT,
      Gun1State TEXT,
      Gun2State TEXT,
      Gun1Temp REAL,
      Gun2Temp REAL,
      SysTemp REAL,
      SysHumi REAL,
      Gun1Vol REAL,
      Gun2Vol REAL,
      Gun1Cur REAL,
      Gun2Cur REAL,
      Gun1CharSoc REAL,
      Gun2CharSoc REAL,
      Gun1Soc REAL,
      Gun2Soc REAL,
      Gun1CharTemp REAL,
      Gun2CharTemp REAL,
      Gun1Soh INTEGER,
      Gun2Soh INTEGER,
      SysPowSup INTEGER,
      CharPowSup INTEGER,
      EssSoc REAL,
      EssVol REAL,
      EssCur REAL,
      EssTemp REAL,
      PvVol REAL,
      PvCur REAL
    );
    """

    # 4. 充电订单表（增加 userId 字段）
    sql_order = """
    CREATE TABLE IF NOT EXISTS charging_order (
      id TEXT PRIMARY KEY NOT NULL,
      userId TEXT,
      stationName TEXT NOT NULL,
      stationAddress TEXT NOT NULL,
      gunNumber INTEGER NOT NULL,
      startTime TEXT NOT NULL,
      endTime TEXT,
      endReason TEXT,
      duration TEXT NOT NULL,
      totalAmount INTEGER NOT NULL,
      unitPrice INTEGER NOT NULL,
      electricity INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('待支付','已支付','充电中','已完成','已取消')),
      statusColor TEXT
    );
    """

    # 5. 实况窗 Push Token 表（userId -> 该用户最新设备的 push token）
    sql_push_token = """
    CREATE TABLE IF NOT EXISTS push_token (
      userId TEXT PRIMARY KEY NOT NULL,
      token TEXT NOT NULL,
      updateTime TEXT NOT NULL
    );
    """

    return [sql_user, sql_charging_station, sql_nexus_status, sql_order, sql_push_token]


# ==================== MQTT 核心落库驱动 ====================
mqtt_paho = mqtt_client.Client(callback_api_version=CallbackAPIVersion.VERSION2)


def update_station_status(gun1_state: str, gun2_state: str):
    """
    根据Gun1State和Gun2State更新充电桩状态
    状态规则：
    - 空闲 (available): 00, 10, 01, 11, 21, 12, 20, 02
    - 占用 (occupied): 22
    - 损坏 (broken): 任何一方为3或4
    """
    try:
        # 转换为整数进行比较
        g1 = int(gun1_state) if gun1_state is not None else 0
        g2 = int(gun2_state) if gun2_state is not None else 0
    except (ValueError, TypeError):
        print(f"[Station Status] 无法转换枪状态值: Gun1={gun1_state}, Gun2={gun2_state}", flush=True)
        return

    # 判断状态
    # 损坏：任何一方为3或4
    if (g1 == 3 or g1 == 4 or g2 == 3 or g2 == 4):
        new_status = 'broken'
    # 占用：两个都为2
    elif (g1 == 2 and g2 == 2):
        new_status = 'occupied'
    # 空闲：其他所有组合（00, 10, 01, 11, 21, 12, 20, 02）
    else:
        new_status = 'available'

    # 更新数据库
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "UPDATE charging_station SET status = ? WHERE id = 'VOLT0001'",
            (new_status,)
        )
        conn.commit()
        print(f"[Station Status] 充电桩 VOLT0001 状态更新为: {new_status} (Gun1={g1}, Gun2={g2})", flush=True)
    except sqlite3.Error as e:
        print(f"[Station Status] 更新状态失败: {e}", flush=True)
    finally:
        conn.close()


def on_connect(client, userdata, flags, rc, properties=None):
    if rc == 0:
        print("MQTT Connected successfully!", flush=True)
        client.subscribe([("SouthData", 0), ("SorthData", 0), ("Control", 0), ("NorthData", 0)])
    else:
        print(f"MQTT Connection failed, rc: {rc}", flush=True)


def on_message(client, userdata, msg):
    try:
        payload_str = msg.payload.decode('utf-8')
        data = json.loads(payload_str)

        # 兜底：昇腾 gateway 若未更新到含储能/光伏键映射的版本，
        # MQTT 上跑的会是缩写键 es/ev/ec/et/pvv/pvc，这里归一化为全名键再入库
        alias_map = {
            "es": "EssSoc", "ev": "EssVol", "ec": "EssCur",
            "pvv": "PvVol", "pvc": "PvCur"
        }
        for short_k, full_k in alias_map.items():
            if short_k in data and full_k not in data:
                data[full_k] = data.pop(short_k)

        conn = get_db_connection()
        cursor = conn.cursor()

        fields = [
            'topic', 'timestamp', 'Gun1UserName', 'Gun2UserName', 'Gun1UserBal', 'Gun2UserBal',
            'Gun1Stop', 'Gun2Stop', 'Gun1BatCap', 'Gun2BatCap', 'Gun1Agt', 'Gun2Agt',
            'Gun1State', 'Gun2State', 'Gun1Temp', 'Gun2Temp', 'SysTemp', 'SysHumi',
            'Gun1Vol', 'Gun2Vol', 'Gun1Cur', 'Gun2Cur', 'Gun1CharSoc', 'Gun2CharSoc',
            'Gun1Soc', 'Gun2Soc', 'Gun1CharTemp', 'Gun2CharTemp', 'Gun1Soh', 'Gun2Soh',
            'SysPowSup', 'CharPowSup', 'EssSoc', 'EssVol', 'EssCur', 'PvVol', 'PvCur'
        ]
        bj_time_str = get_beijing_time()
        other_fields = fields[2:]

        real_fields = [
            'Gun1Temp', 'Gun2Temp', 'SysTemp', 'SysHumi',
            'Gun1Vol', 'Gun2Vol', 'Gun1Cur', 'Gun2Cur',
            'Gun1CharSoc', 'Gun2CharSoc', 'Gun1Soc', 'Gun2Soc',
            'Gun1CharTemp', 'Gun2CharTemp',
            'EssSoc', 'EssVol', 'EssCur', 'PvVol', 'PvCur'
        ]

        values = [msg.topic, bj_time_str]
        for f in other_fields:
            val = data.get(f)

            # ✅ 核心容错：严格用 is not None 判断，数字 0 也必须放行通过！
            if f in real_fields and val is not None:
                try:
                    val = float(val)
                except (ValueError, TypeError):
                    val = 0.0

            # ⚠️ 确保你这里没有把 val == 0 的情况错杀成 None
            values.append(val)

        placeholders = ', '.join(['?'] * len(fields))
        sql = f"INSERT INTO charging_station_status ({', '.join(fields)}) VALUES ({placeholders})"
        cursor.execute(sql, values)
        conn.commit()
        print(f"[MQTT Recv & Logged] Topic: {msg.topic} at {bj_time_str}", flush=True)

        # ========== 实况窗远程更新（有进行中订单时按节流推送） ==========
        _maybe_push_liveview(cursor, data)

        # ========== 监听 Control 主题的 GunStop ==========
        if msg.topic == "Control":
            # GunStop 停止原因：4=火灾停止, 5=拔枪异常停止, 6=桩端屏幕主动停止
            # 注意：统一 str() 后比较，兼容数字和字符串两种上发格式
            for gun_key in ('Gun1Stop', 'Gun2Stop'):
                stop_val = data.get(gun_key)
                if stop_val is None:
                    continue
                stop_str = str(stop_val).strip()
                print(f"[Control Recv] {gun_key} = {stop_str} (原始类型: {type(stop_val).__name__})", flush=True)
                if stop_str == '4':
                    end_order_by_user("VOLT06300001", '火灾停止')
                elif stop_str == '5':
                    end_order_by_user("VOLT06300001", '拔枪停止')
                elif stop_str == '6':
                    end_order_by_user("VOLT06300001", '屏幕停止')

        gun1_state = data.get('Gun1State')
        gun2_state = data.get('Gun2State')
        if gun1_state is not None and gun2_state is not None:
            update_station_status(gun1_state, gun2_state)

    except Exception as e:
        print(f"[MQTT DB Error] Failed to write data: {e}", flush=True)
    finally:
        cursor.close()
        conn.close()


mqtt_paho.on_connect = on_connect
mqtt_paho.on_message = on_message


def start_mqtt_sync():
    try:
        mqtt_paho.connect(MQTT_BROKER, MQTT_PORT, 60)
        mqtt_paho.loop_forever()
    except Exception as e:
        print(f"MQTT Loop error: {e}", flush=True)


# ==================== 查询接口 ====================

@app.get("/api/nexus/users")
async def get_all_users():
    """查询所有用户"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM user")
    res = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"status": "success", "data": res}


@app.get("/api/nexus/users/{userId}/balance")
async def get_user_balance(userId: str):
    """查询单个用户余额"""
    if not userId:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute("SELECT userId, userName, balance FROM user WHERE userId = ?", (userId,))
        user = cursor.fetchone()

        if not user:
            raise HTTPException(status_code=404, detail="用户不存在")

        return {
            "status": "success",
            "data": {
                "userId": user["userId"],
                "userName": user["userName"],
                "balance": user["balance"]
            }
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"查询失败: {str(e)}")
    finally:
        conn.close()


@app.get("/api/nexus/stations")
async def get_all_stations():
    """查询所有充电桩站点"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM charging_station")
    res = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"status": "success", "data": res}


@app.get("/api/nexus/stations/status")
async def get_all_station_status():
    """查询所有充电桩实时状态"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM charging_station_status")
    res = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"status": "success", "data": res}


@app.get("/api/nexus/status/latest")
async def get_latest_status():
    """查询最新实时状态：VOLTos 与 voltsun 分开发报文（各占一行、字段互不相同），
    单取最新一行必然缺另一半字段。改为取最近20行，按列合并——
    每个字段取时间最新的非空值，拼成一份完整状态返回。"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM charging_station_status ORDER BY id DESC LIMIT 20")
    rows = cursor.fetchall()
    conn.close()
    if not rows:
        return {"status": "empty", "data": {}}
    merged = {}
    for key in rows[0].keys():
        for r in rows:
            if r[key] is not None:
                merged[key] = r[key]
                break
    # 附带光伏追踪的云端真值：最近一次实际下发的角度 + 自动模式开关，供 APP 同步显示
    with pv_lock:
        merged["PvAngle"] = PV_LAST_SENT["angle"]
        merged["PvAuto"] = PV_AUTO_STATE["auto"]
    return {"status": "success", "data": merged}


@app.get("/api/nexus/stations/available")
async def get_available_stations():
    """查询可用充电桩站点"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM charging_station WHERE status = 'available'")
    res = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"status": "success", "data": res}


BEIJING_TZ = timezone(timedelta(hours=8))


@app.get("/api/nexus/orders")
async def get_orders(status: Optional[str] = None, userId: Optional[str] = None):
    """
    查询订单，支持按状态和用户过滤（不传返回全部）
    - 充电中：duration 动态计算（当前时间 - 开始时间）
    - 其他：保留数据库原值
    - 全部按 startTime 降序排列
    """
    conn = get_db_connection()
    cursor = conn.cursor()

    # 构建查询条件
    query = "SELECT * FROM charging_order"
    params = []
    conditions = []

    if status:
        conditions.append("status = ?")
        params.append(status)

    if userId:
        conditions.append("userId = ?")
        params.append(userId)

    if conditions:
        query += " WHERE " + " AND ".join(conditions)

    query += " ORDER BY startTime DESC"

    cursor.execute(query, params)
    rows = cursor.fetchall()
    conn.close()

    now = datetime.now(BEIJING_TZ)
    result = []
    for row in rows:
        row_dict = dict(row)
        # 充电中：动态计算
        if row_dict.get('status') == '充电中' and row_dict.get('startTime'):
            try:
                start = parse_order_time(row_dict['startTime'])
                start = start.replace(tzinfo=BEIJING_TZ)
                delta = now - start
                minutes = max(0, int(delta.total_seconds() // 60))
                row_dict['duration'] = f"{minutes}分钟"
            except Exception:
                pass  # 解析失败则保留原值

        result.append(row_dict)

    return {"status": "success", "data": result}


@app.get("/api/nexus/system/status")
async def get_system_status():
    """获取系统概览状态"""
    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute("SELECT COUNT(*) as total FROM user")
    user_count = cursor.fetchone()['total']

    cursor.execute("SELECT COUNT(*) as total FROM charging_station")
    station_count = cursor.fetchone()['total']

    cursor.execute("SELECT COUNT(*) as total FROM charging_station WHERE status = 'available'")
    available_count = cursor.fetchone()['total']

    cursor.execute("SELECT COUNT(*) as total FROM charging_order")
    order_count = cursor.fetchone()['total']

    cursor.execute("SELECT COUNT(*) as total FROM charging_order WHERE status = '充电中'")
    charging_count = cursor.fetchone()['total']

    cursor.execute("SELECT * FROM charging_station_status ORDER BY id DESC LIMIT 1")
    latest_status = cursor.fetchone()

    conn.close()

    return {
        "status": "success",
        "data": {
            "userCount": user_count,
            "stationCount": station_count,
            "availableStationCount": available_count,
            "orderCount": order_count,
            "chargingOrderCount": charging_count,
            "latestStatus": dict(latest_status) if latest_status else {}
        }
    }


# ==================== 用户余额修改接口 ====================

@app.post("/api/nexus/users/balance")
async def update_user_balance(request: Request):
    """
    修改用户余额
    userId: 用户ID
    amount: 正数=充值，负数=扣费
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    if "userId" not in body or not body["userId"]:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    if "amount" not in body:
        raise HTTPException(status_code=400, detail="缺少金额")

    try:
        amount = float(body["amount"])
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="金额必须为数字")

    if amount == 0:
        raise HTTPException(status_code=400, detail="金额不能为0")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute("SELECT userId, userName, balance FROM user WHERE userId = ?", (body["userId"],))
        user = cursor.fetchone()

        if not user:
            raise HTTPException(status_code=404, detail="用户不存在")

        old_balance = user["balance"]
        new_balance = old_balance + amount

        cursor.execute(
            "UPDATE user SET balance = ? WHERE userId = ?",
            (new_balance, body["userId"])
        )
        conn.commit()

        return {
            "status": "success",
            "userId": body["userId"],
            "oldBalance": old_balance,
            "newBalance": new_balance
        }
    except sqlite3.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    finally:
        conn.close()


# ==================== 实况窗 Push Token 接口 ====================

@app.post("/api/pushToken")
async def report_push_token(request: Request):
    """
    App 启动时上报 push token（userId + token）。
    token 在卸载重装/恢复出厂后会变，所以每次启动都应上报，按 userId 覆盖更新。
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    if not body.get("userId"):
        raise HTTPException(status_code=400, detail="缺少 userId")
    if not body.get("token"):
        raise HTTPException(status_code=400, detail="缺少 token")

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT INTO push_token (userId, token, updateTime) VALUES (?, ?, ?) "
            "ON CONFLICT(userId) DO UPDATE SET token = excluded.token, updateTime = excluded.updateTime",
            (body["userId"], body["token"], get_beijing_time())
        )
        conn.commit()
        return {"status": "success", "userId": body["userId"]}
    except sqlite3.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    finally:
        conn.close()


@app.get("/api/pushToken/{userId}")
async def get_push_token(userId: str):
    """查询某用户最新上报的 push token（服务器推实况窗时取用）"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT token, updateTime FROM push_token WHERE userId = ?", (userId,))
    row = cursor.fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="该用户尚未上报 push token")
    return {"userId": userId, "token": row["token"], "updateTime": row["updateTime"]}


# ==================== 检查充电中订单接口 ====================

@app.get("/api/nexus/orders/charging/check")
async def check_charging_order(userId: str):
    """
    检查用户是否有正在充电中的订单
    参数：userId（必填）
    返回：是否有充电中的订单，以及订单详情（如果有）
    """
    if not userId:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 查询该用户状态为"充电中"的订单
        cursor.execute(
            "SELECT * FROM charging_order WHERE userId = ? AND status = '充电中' ORDER BY startTime DESC LIMIT 1",
            (userId,)
        )
        row = cursor.fetchone()

        if row:
            order_dict = dict(row)
            return {
                "status": "success",
                "hasChargingOrder": True,
                "data": order_dict
            }
        else:
            return {
                "status": "success",
                "hasChargingOrder": False,
                "data": None
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"查询失败: {str(e)}")
    finally:
        conn.close()


# ==================== 创建订单接口 ====================

@app.post("/api/createOrder")
async def create_order(request: Request):
    """
    创建充电订单（状态固定为"充电中"）
    必填字段：stationName, stationAddress, gunNumber, startTime, unitPrice
    可选字段：userId（关联用户）
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    # 必填字段校验
    required_fields = ["stationName", "stationAddress", "gunNumber", "startTime", "unitPrice"]
    for field in required_fields:
        if field not in body or body[field] is None:
            raise HTTPException(status_code=400, detail=f"缺少必填字段: {field}")

    # 类型校验
    try:
        gun_number = int(body["gunNumber"])
        unit_price = int(body["unitPrice"])
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="gunNumber 和 unitPrice 必须为整数")

    # 生成订单 ID
    order_id = str(uuid.uuid4())[:11]

    # 从请求体获取数据（带默认值）
    station_name = body["stationName"]
    station_address = body["stationAddress"]
    start_time = body["startTime"]
    user_id = body.get("userId", "")  # 新增：获取 userId，默认为空字符串
    total_amount = body.get("totalAmount", 0)
    electricity = body.get("electricity", 0)
    duration = body.get("duration", "0分钟")
    status_color = body.get("statusColor", "")

    status = "充电中"
    end_time = None
    end_reason = None

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 检查是否存在正在充电的订单
        cursor.execute("SELECT 1 FROM charging_order WHERE status = '充电中' LIMIT 1")
        if cursor.fetchone():
            raise HTTPException(status_code=400, detail="存在正在充电的订单，无法创建新订单")

        # 插入新订单（增加 userId 字段）
        cursor.execute("""
            INSERT INTO charging_order (
                id, userId, stationName, stationAddress, gunNumber, startTime, endTime,
                endReason, duration, totalAmount, unitPrice, electricity,
                status, statusColor
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            order_id,
            user_id,  # 新增 userId
            station_name,
            station_address,
            gun_number,
            start_time,
            end_time,
            end_reason,
            duration,
            total_amount,
            unit_price,
            electricity,
            status,
            status_color
        ))
        conn.commit()
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=f"订单 ID 冲突或数据异常: {str(e)}")
    except Exception as e:
        conn.rollback()
        # 如果已经是 HTTPException，直接抛出（避免包装）
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=f"数据库写入失败: {str(e)}")
    finally:
        conn.close()

    return {"status": "success", "message": "订单创建成功", "orderId": order_id}


# ==================== 结束订单接口 ====================

@app.post("/api/endOrder")
async def end_order(request: Request):
    """
    结束充电订单
    必填字段：orderId
    可选字段：endTime（默认当前时间）, endReason（默认"正常结束"）,
             totalAmount, electricity, duration（实际充电时长）
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    # 必填字段校验
    if "orderId" not in body or not body["orderId"]:
        raise HTTPException(status_code=400, detail="缺少订单ID")

    order_id = body["orderId"]

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 查询订单是否存在（不再强制要求"充电中"：订单可能已被 stop-charging 提前关闭，
        # 此时仍允许补写金额/电量等字段，保证接口幂等）
        cursor.execute(
            "SELECT * FROM charging_order WHERE id = ?",
            (order_id,)
        )
        order = cursor.fetchone()
        if not order:
            raise HTTPException(status_code=404, detail="订单不存在")

        # 构建更新语句
        update_fields = []
        update_values = []

        # endTime：默认当前时间
        if "endTime" in body and body["endTime"]:
            update_fields.append("endTime = ?")
            update_values.append(body["endTime"])
        else:
            update_fields.append("endTime = ?")
            update_values.append(get_beijing_time())

        # endReason：默认"正常结束"
        if "endReason" in body and body["endReason"]:
            update_fields.append("endReason = ?")
            update_values.append(body["endReason"])
        else:
            update_fields.append("endReason = ?")
            update_values.append("正常结束")

        # 可选字段：totalAmount
        if "totalAmount" in body and body["totalAmount"] is not None:
            try:
                total_amount = int(body["totalAmount"])
                update_fields.append("totalAmount = ?")
                update_values.append(total_amount)
            except (ValueError, TypeError):
                raise HTTPException(status_code=400, detail="totalAmount 必须为整数")

        # 可选字段：electricity
        if "electricity" in body and body["electricity"] is not None:
            try:
                electricity = int(body["electricity"])
                update_fields.append("electricity = ?")
                update_values.append(electricity)
            except (ValueError, TypeError):
                raise HTTPException(status_code=400, detail="electricity 必须为整数")

        # 可选字段：duration（实际充电时长）
        if "duration" in body and body["duration"]:
            update_fields.append("duration = ?")
            update_values.append(body["duration"])
        else:
            # 如果未提供 duration，自动计算（从 startTime 到 endTime）
            try:
                start_time = order['startTime']
                end_time = update_values[
                    update_fields.index('endTime = ?')] if 'endTime = ?' in update_fields else get_beijing_time()
                start = parse_order_time(start_time)
                end = parse_order_time(end_time)
                delta = end - start
                minutes = max(0, int(delta.total_seconds() // 60))
                calculated_duration = f"{minutes}分钟"
                update_fields.append("duration = ?")
                update_values.append(calculated_duration)
            except Exception as e:
                # 计算失败则保留原值，不报错
                pass

        # 更新状态为"已完成"
        update_fields.append("status = ?")
        update_values.append("已完成")

        # 执行更新
        update_values.append(order_id)
        sql = f"UPDATE charging_order SET {', '.join(update_fields)} WHERE id = ?"
        cursor.execute(sql, update_values)
        conn.commit()

    except sqlite3.Error as e:
        conn.rollback()
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    except Exception as e:
        conn.rollback()
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=f"更新订单失败: {str(e)}")
    finally:
        conn.close()

    return {"status": "success", "message": "订单已结束", "orderId": order_id}


# ==================== 查询枪全部实时状态接口（已去重且修正类型） ====================
@app.get("/api/nexus/gun-status")
async def get_gun_status(gunNumber: int):
    """
    查询指定枪号的最新实时状态数据
    参数：gunNumber（必填，1 或 2）
    返回：GunxSoc, GunxCharSoc, GunxVol, GunxCur, GunxCharTemp, GunxTemp, GunxBatCap, GunxAgt
    """
    if gunNumber not in [1, 2]:
        raise HTTPException(status_code=400, detail="枪号必须为1或2")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 根据枪号选择字段
        if gunNumber == 1:
            fields = {
                "soc": "Gun1Soc",
                "charSoc": "Gun1CharSoc",
                "vol": "Gun1Vol",
                "cur": "Gun1Cur",
                "charTemp": "Gun1CharTemp",
                "temp": "Gun1Temp",
                "batCap": "Gun1BatCap",
                "agt": "Gun1Agt"
            }
        else:
            fields = {
                "soc": "Gun2Soc",
                "charSoc": "Gun2CharSoc",
                "vol": "Gun2Vol",
                "cur": "Gun2Cur",
                "charTemp": "Gun2CharTemp",
                "temp": "Gun2Temp",
                "batCap": "Gun2BatCap",
                "agt": "Gun2Agt"
            }

        # 构建查询SQL
        field_names = list(fields.values())
        # voltsun 的储能/光伏报文不含枪字段，需跳过，只取 VOLTos 上报的行
        sql = (f"SELECT {', '.join(field_names)} FROM charging_station_status "
               f"WHERE Gun1State IS NOT NULL OR Gun2State IS NOT NULL ORDER BY id DESC LIMIT 1")
        cursor.execute(sql)
        row = cursor.fetchone()

        if row is None:
            return {
                "status": "success",
                "data": {
                    "gunNumber": gunNumber,
                    "soc": 0,
                    "charSoc": 0.0,
                    "vol": 0.0,
                    "cur": 0.0,
                    "charTemp": 0.0,
                    "temp": 0.0,
                    "batCap": 0,
                    "agt": 0
                },
                "message": "暂无实时数据，返回默认值"
            }

        # 严格区分 int 和 float，确保精度不丢失
        result_data = {
            "gunNumber": gunNumber,
            "soc": int(row[fields["soc"]]) if row[fields["soc"]] is not None else 0,
            "charSoc": float(row[fields["charSoc"]]) if row[fields["charSoc"]] is not None else 0.0,
            "vol": float(row[fields["vol"]]) if row[fields["vol"]] is not None else 0.0,
            "cur": float(row[fields["cur"]]) if row[fields["cur"]] is not None else 0.0,
            "charTemp": float(row[fields["charTemp"]]) if row[fields["charTemp"]] is not None else 0.0,
            "temp": float(row[fields["temp"]]) if row[fields["temp"]] is not None else 0.0,
            "batCap": int(row[fields["batCap"]]) if row[fields["batCap"]] is not None else 0,
            "agt": int(row[fields["agt"]]) if row[fields["agt"]] is not None else 0
        }

        return {
            "status": "success",
            "data": result_data
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库查询失败: {str(e)}")
    finally:
        conn.close()

# ==================== MQTT 下发充电指令接口 ====================

@app.post("/api/nexus/start-charging")
async def start_charging(request: Request):
    """
    下发充电指令到MQTT
    请求体：{"userId": "xxx", "gunNumber": 1}
    gunNumber: 1 或 2
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    # 必填字段校验
    if "userId" not in body or not body["userId"]:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    if "gunNumber" not in body:
        raise HTTPException(status_code=400, detail="缺少枪号")

    user_id = body["userId"]
    gun_number = body["gunNumber"]

    # 枪号校验
    if gun_number not in [1, 2]:
        raise HTTPException(status_code=400, detail="枪号必须为1或2")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 查询用户信息
        cursor.execute(
            "SELECT userId, userName, balance FROM user WHERE userId = ?",
            (user_id,)
        )
        user = cursor.fetchone()

        if not user:
            raise HTTPException(status_code=404, detail="用户不存在")

        user_name = user["userName"]
        user_balance = int(user["balance"]) if user["balance"] is not None else 0

        # 构建MQTT消息（V1.5协议：仅下发控制状态，不再附带用户名/余额到单片机）
        if gun_number == 1:
            mqtt_topic = "Control"
            mqtt_payload = {"Gun1CtrSta": 2}
        else:  # gun_number == 2
            mqtt_topic = "Control"
            mqtt_payload = {"Gun2CtrSta": 2}

        # 发布MQTT消息
        result = mqtt_paho.publish(mqtt_topic, json.dumps(mqtt_payload))
        if result.rc == mqtt_client.MQTT_ERR_SUCCESS:
            print(f"[MQTT Publish] 已下发充电指令: {mqtt_payload}", flush=True)
            return {
                "status": "success",
                "message": f"充电指令已下发到枪 {gun_number}",
                "data": {
                    "userId": user_id,
                    "userName": user_name,
                    "balance": user_balance,
                    "gunNumber": gun_number,
                    "topic": mqtt_topic,
                    "payload": mqtt_payload
                }
            }
        else:
            print(f"[MQTT Publish] 下发失败, rc: {result.rc}", flush=True)
            raise HTTPException(status_code=500, detail=f"MQTT下发失败，错误码: {result.rc}")

    except HTTPException:
        raise
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库查询失败: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"下发充电指令失败: {str(e)}")
    finally:
        conn.close()

# ==================== 新增：查询充电枪实时状态码接口 ====================
@app.get("/api/nexus/gun-states")
async def get_gun_states():
    """
    专门查询两把充电枪的当前状态码（Gun1State 和 Gun2State）
    返回：gun1State, gun2State
    """
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 从最新一条"含枪状态"的记录中提取（voltsun 的储能/光伏报文不带枪状态，需跳过）
        cursor.execute(
            "SELECT Gun1State, Gun2State FROM charging_station_status "
            "WHERE Gun1State IS NOT NULL OR Gun2State IS NOT NULL ORDER BY id DESC LIMIT 1"
        )
        row = cursor.fetchone()

        if row is None:
            return {
                "status": "success",
                "data": {
                    "gun1State": 0,
                    "gun2State": 0
                },
                "message": "暂无实时数据，返回默认值 0"
            }

        # 转换为整数格式返回给前端或 cURL
        gun1_state = int(row["Gun1State"]) if row["Gun1State"] is not None else 0
        gun2_state = int(row["Gun2State"]) if row["Gun2State"] is not None else 0

        return {
            "status": "success",
            "data": {
                "gun1State": gun1_state,
                "gun2State": gun2_state
            }
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库查询失败: {str(e)}")
    finally:
        conn.close()


# ==================== MQTT 停止充电指令接口 ====================

@app.post("/api/nexus/stop-charging")
async def stop_charging(request: Request):
    """
    下发停止充电指令到MQTT
    请求体：{"gunNumber": 1}
    gunNumber: 1 或 2
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    # 必填字段校验
    if "gunNumber" not in body:
        raise HTTPException(status_code=400, detail="缺少枪号")

    gun_number = body["gunNumber"]

    # 枪号校验
    if gun_number not in [1, 2]:
        raise HTTPException(status_code=400, detail="枪号必须为1或2")

    # 构建MQTT消息
    if gun_number == 1:
        mqtt_topic = "Control"
        mqtt_payload = {
            "Gun1CtrSta": 3
        }
    else:  # gun_number == 2
        mqtt_topic = "Control"
        mqtt_payload = {
            "Gun2CtrSta": 3
        }

    try:
        # 发布MQTT消息
        result = mqtt_paho.publish(mqtt_topic, json.dumps(mqtt_payload))
        if result.rc == mqtt_client.MQTT_ERR_SUCCESS:
            print(f"[MQTT Publish] 已下发停止充电指令: {mqtt_payload}", flush=True)

            # 同步关闭该枪进行中的订单：桩端/远程停止后，订单必须落库为已完成，
            # 否则 APP 端（首页充电卡片等）会一直认为有充电中的订单。
            # WHERE 限定 status='充电中'，硬件稍后重复上报停止时不会重复关单。
            try:
                conn = get_db_connection()
                cursor = conn.cursor()
                cursor.execute(
                    "SELECT id, startTime FROM charging_order WHERE gunNumber = ? AND status = '充电中'",
                    (gun_number,)
                )
                active = cursor.fetchone()
                if active:
                    end_time = get_beijing_time()
                    duration_str = None
                    try:
                        delta = parse_order_time(end_time) - parse_order_time(active['startTime'])
                        duration_str = f"{max(0, int(delta.total_seconds() // 60))}分钟"
                    except Exception:
                        pass
                    if duration_str:
                        cursor.execute(
                            "UPDATE charging_order SET status = '已完成', endTime = ?, endReason = '远程停止', duration = ? WHERE id = ?",
                            (end_time, duration_str, active['id'])
                        )
                    else:
                        cursor.execute(
                            "UPDATE charging_order SET status = '已完成', endTime = ?, endReason = '远程停止' WHERE id = ?",
                            (end_time, active['id'])
                        )
                    conn.commit()
                    print(f"[Order] 枪{gun_number}停止充电，订单 {active['id']} 已同步关闭（远程停止）", flush=True)
                    push_liveview_end_for_order(active['id'])
                conn.close()
            except sqlite3.Error as e:
                # 关单失败不影响停止指令的下发结果，仅记录
                print(f"[Order] 停止充电后同步关单失败: {e}", flush=True)

            return {
                "status": "success",
                "message": f"停止充电指令已下发到枪 {gun_number}",
                "data": {
                    "gunNumber": gun_number,
                    "topic": mqtt_topic,
                    "payload": mqtt_payload
                }
            }
        else:
            print(f"[MQTT Publish] 下发失败, rc: {result.rc}", flush=True)
            raise HTTPException(status_code=500, detail=f"MQTT下发失败，错误码: {result.rc}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"下发停止充电指令失败: {str(e)}")


@app.get("/api/nexus/gun-soh")
async def get_gun_soh(gunNumber: int):
    if gunNumber not in [1, 2]:
        raise HTTPException(status_code=400, detail="枪号必须为1或2")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        field = "Gun1Soh" if gunNumber == 1 else "Gun2Soh"

        # 只要是 Control 主题的最后一条，不管字段是不是 0 或 NULL，先捞出来
        sql = f"SELECT {field} FROM charging_station_status WHERE topic = 'Control' ORDER BY id DESC LIMIT 1"
        cursor.execute(sql)
        row = cursor.fetchone()

        if row is None:
            return {"status": "success", "data": {"gunNumber": gunNumber, "soh": 0}, "message": "未找到Control记录"}

        raw_val = row[field]

        # 只要不是真正的 None，就算是 0 也正常返回
        soh_value = int(raw_val) if raw_val is not None else 0

        return {
            "status": "success",
            "data": {
                "gunNumber": gunNumber,
                "soh": soh_value
            }
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库失败: {str(e)}")
    finally:
        conn.close()


# ==================== 自动结束订单函数 ====================
def end_order_by_user(user_id: str, reason: str = '拔枪停止'):
    """当 GunStop 触发时，结束用户的充电订单（5=拔枪停止, 6=屏幕停止）"""
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 查找该用户正在充电的订单
        cursor.execute(
            "SELECT * FROM charging_order WHERE userId = ? AND status = '充电中' ORDER BY startTime DESC LIMIT 1",
            (user_id,)
        )
        order = cursor.fetchone()

        if order:
            # 更新订单状态为"已完成"，endReason 按实际停止原因记录
            cursor.execute("""
                UPDATE charging_order
                SET status = '已完成',
                    endTime = ?,
                    endReason = ?
                WHERE id = ?
            """, (get_beijing_time(), reason, order['id']))
            conn.commit()
            print(f"[Auto End] 用户 {user_id} 的订单 {order['id']} 已自动结束，原因：{reason}", flush=True)
            push_liveview_end_for_order(order['id'])
        else:
            print(f"[Auto End] 用户 {user_id} 没有正在充电的订单", flush=True)

    except Exception as e:
        print(f"[Auto End] 失败: {e}", flush=True)
    finally:
        conn.close()

# ==================== 查询订单是否异常停止 ====================
@app.get("/api/nexus/order/abnormal-check")
async def check_order_abnormal_stop(orderId: str):
    """
    查询订单是否因拔枪而异常停止
    参数：orderId（订单ID）
    返回：isAbnormalStop: 1=拔枪停止, 0=正常结束
    """
    if not orderId:
        raise HTTPException(status_code=400, detail="缺少订单ID")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute(
            "SELECT endReason FROM charging_order WHERE id = ?",
            (orderId,)
        )
        row = cursor.fetchone()

        if row is None:
            raise HTTPException(status_code=404, detail="订单不存在")

        end_reason = row["endReason"] or ""

        # 判断是否拔枪停止
        is_abnormal = 1 if end_reason == "拔枪停止" else 0

        return {
            "status": "success",
            "data": {
                "orderId": orderId,
                "isAbnormalStop": is_abnormal,
                "endReason": end_reason
            }
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"查询失败: {str(e)}")
    finally:
        conn.close()

# ==================== 用户管理接口 ====================

@app.post("/api/nexus/users/register")
async def register_user(request: Request):
    """
    用户注册
    请求体：{"account": "xxx", "password": "xxx", "userName": "xxx"}
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    # 必填字段校验
    required_fields = ["account", "password", "userName"]
    for field in required_fields:
        if field not in body or not body[field]:
            raise HTTPException(status_code=400, detail=f"缺少必填字段: {field}")

    account = body["account"]
    password = body["password"]
    user_name = body["userName"]

    # 生成用户ID
    user_id = "USER" + str(uuid.uuid4())[:8].upper()

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 检查账号是否已存在
        cursor.execute("SELECT account FROM user WHERE account = ?", (account,))
        if cursor.fetchone():
            raise HTTPException(status_code=400, detail="账号已存在")

        # 插入新用户
        cursor.execute("""
            INSERT INTO user (userId, userName, account, password, balance)
            VALUES (?, ?, ?, ?, ?)
        """, (user_id, user_name, account, password, 0))
        conn.commit()

        return {
            "status": "success",
            "message": "注册成功",
            "data": {
                "userId": user_id,
                "userName": user_name,
                "account": account,
                "balance": 0
            }
        }
    except sqlite3.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    finally:
        conn.close()

@app.post("/api/nexus/users/login")
async def login_user(request: Request):
    """
    用户登录
    请求体：{"account": "xxx", "password": "xxx"}
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    if "account" not in body or not body["account"]:
        raise HTTPException(status_code=400, detail="缺少账号")
    if "password" not in body or not body["password"]:
        raise HTTPException(status_code=400, detail="缺少密码")

    account = body["account"]
    password = body["password"]

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute(
            "SELECT userId, userName, account, balance FROM user WHERE account = ? AND password = ?",
            (account, password)
        )
        user = cursor.fetchone()

        if not user:
            raise HTTPException(status_code=401, detail="账号或密码错误")

        return {
            "status": "success",
            "message": "登录成功",
            "data": {
                "userId": user["userId"],
                "userName": user["userName"],
                "account": user["account"],
                "balance": user["balance"]
            }
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库查询失败: {str(e)}")
    finally:
        conn.close()

@app.put("/api/nexus/users/{userId}")
async def update_user(userId: str, request: Request):
    """
    更新用户信息
    请求体：{"userName": "xxx", "password": "xxx"} (可选字段)
    """
    if not userId:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 检查用户是否存在
        cursor.execute("SELECT userId FROM user WHERE userId = ?", (userId,))
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="用户不存在")

        # 构建更新语句
        update_fields = []
        update_values = []

        if "userName" in body and body["userName"]:
            update_fields.append("userName = ?")
            update_values.append(body["userName"])

        if "password" in body and body["password"]:
            update_fields.append("password = ?")
            update_values.append(body["password"])

        if not update_fields:
            raise HTTPException(status_code=400, detail="没有需要更新的字段")

        # 执行更新
        update_values.append(userId)
        sql = f"UPDATE user SET {', '.join(update_fields)} WHERE userId = ?"
        cursor.execute(sql, update_values)
        conn.commit()

        # 查询更新后的用户信息
        cursor.execute("SELECT userId, userName, account, balance FROM user WHERE userId = ?", (userId,))
        updated_user = cursor.fetchone()

        return {
            "status": "success",
            "message": "用户信息更新成功",
            "data": dict(updated_user)
        }
    except sqlite3.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/nexus/users/{userId}")
async def delete_user(userId: str):
    """
    删除用户
    参数：userId
    """
    if not userId:
        raise HTTPException(status_code=400, detail="缺少用户ID")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 检查用户是否存在
        cursor.execute("SELECT userId FROM user WHERE userId = ?", (userId,))
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="用户不存在")

        # 删除用户
        cursor.execute("DELETE FROM user WHERE userId = ?", (userId,))
        conn.commit()

        return {
            "status": "success",
            "message": f"用户 {userId} 已删除"
        }
    except sqlite3.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"数据库操作失败: {str(e)}")
    finally:
        conn.close()

@app.get("/api/nexus/users/search")
async def search_users(keyword: str):
    """
    搜索用户（按账号或用户名模糊查询）
    参数：keyword（搜索关键词）
    """
    if not keyword:
        raise HTTPException(status_code=400, detail="缺少搜索关键词")

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # 模糊搜索
        search_pattern = f"%{keyword}%"
        cursor.execute(
            "SELECT userId, userName, account, balance FROM user WHERE account LIKE ? OR userName LIKE ?",
            (search_pattern, search_pattern)
        )
        users = [dict(row) for row in cursor.fetchall()]

        return {
            "status": "success",
            "data": users,
            "count": len(users)
        }
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"查询失败: {str(e)}")
    finally:
        conn.close()


# ==================== 通用 Control 主题透传接口 ====================
@app.post("/api/nexus/publish/Control")
async def publish_control(request: Request):
    """
    通用下行控制透传接口：把 body 里 data 字段的 JSON 原样发布到 MQTT Control 主题。
    用于 APP 端发起各类控制指令（如视频监控推流开关 StreamCtr、供电路径切换 PowSupCtr 等），
    无需为每个新指令单独增加接口。

    请求体示例: {"data": {"StreamCtr": 1}}
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="请求体不是合法 JSON")

    data = body.get("data")
    if not isinstance(data, dict) or len(data) == 0:
        raise HTTPException(status_code=400, detail="请求体必须包含非空的 data 对象")

    try:
        result = mqtt_paho.publish("Control", json.dumps(data))
        if result.rc == mqtt_client.MQTT_ERR_SUCCESS:
            print(f"[MQTT Publish] Control 透传成功: {data}", flush=True)
            return {
                "status": "success",
                "message": "控制指令已下发",
                "data": {
                    "topic": "Control",
                    "payload": data
                }
            }
        else:
            print(f"[MQTT Publish] Control 透传失败, rc: {result.rc}", flush=True)
            raise HTTPException(status_code=500, detail=f"MQTT下发失败，错误码: {result.rc}")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"控制指令下发失败: {str(e)}")
# ==================== 每日统计接口（Station 页图表） ====================

@app.get("/api/nexus/stats/daily")
async def get_daily_stats():
    """Station 页两张图表的真值数据：
    - week: 近7日（含今天）每日充电量（度），订单 electricity 字段单位为 0.01 度，按 startTime 日期汇总
    - pv:   今日发电功率（W），voltsun 上报的 PvVol×PvCur 按小时平均
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        today = get_beijing_dt().date()
        days = [today - timedelta(days=i) for i in range(6, -1, -1)]

        cursor.execute(
            "SELECT substr(startTime, 1, 10) AS d, SUM(electricity) AS e "
            "FROM charging_order WHERE substr(startTime, 1, 10) >= ? GROUP BY d",
            (str(days[0]),)
        )
        charge_map = {row["d"]: (row["e"] or 0) for row in cursor.fetchall()}
        week = [
            {"day": str(d.day), "value": round(charge_map.get(str(d), 0) / 100.0, 2)}
            for d in days
        ]

        # 每3小时一个点：0/3/6/9/12/15/18/21 八个桶，桶内取平均
        cursor.execute(
            "SELECT (CAST(substr(timestamp, 12, 2) AS INTEGER) / 3) * 3 AS h4, AVG(PvVol * PvCur) AS p "
            "FROM charging_station_status "
            "WHERE substr(timestamp, 1, 10) = ? AND PvVol IS NOT NULL AND PvCur IS NOT NULL "
            "GROUP BY h4 ORDER BY h4",
            (str(today),)
        )
        pv = [
            {"hour": int(row["h4"]), "power": max(0.0, round(row["p"], 1))}
            for row in cursor.fetchall()
        ]

        return {"status": "success", "data": {"week": week, "pv": pv}}
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"统计查询失败: {str(e)}")
    finally:
        conn.close()


# ==================== 充电桩电价修改接口 ====================

@app.post("/api/nexus/stations/price")
async def update_station_price(request: Request):
    """修改指定充电桩的电价。请求体: {"stationId": "VOLT0001", "price": "1.50元/度"}"""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")

    station_id = body.get("stationId")
    price = body.get("price")
    if not station_id:
        raise HTTPException(status_code=400, detail="缺少 stationId")
    if price is None or str(price).strip() == "":
        raise HTTPException(status_code=400, detail="缺少 price")

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("UPDATE charging_station SET price = ? WHERE id = ?",
                       (str(price).strip(), station_id))
        conn.commit()
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"充电桩 {station_id} 不存在")
        print(f"[Station] 电价已更新: {station_id} -> {price}", flush=True)
        return {"status": "success", "data": {"stationId": station_id, "price": str(price).strip()}}
    except sqlite3.Error as e:
        raise HTTPException(status_code=500, detail=f"数据库更新失败: {str(e)}")
    finally:
        conn.close()


# ==================== 光伏追踪控制（voltsun / WS63） ====================
# 自动模式：云端按北京时间 12 小时日照计划每 3 秒下发一次角度（6:00→0°，18:00→180°，15°/小时）
# 手动模式：APP 直接调用 /pv/angle 下发滑条角度；角度与上次相同则跳过不重复下发

PV_AUTO_STATE = {"auto": False}          # 自动追踪开关
PV_LAST_SENT = {"angle": None}           # 最近一次已下发的角度（去重）
PV_AUTO_INTERVAL = 3                     # 自动模式下发间隔（秒）
pv_lock = threading.Lock()


def pv_schedule_angle(dt: datetime) -> int:
    """按北京时间计算日照追踪角度：
    6:00 -> 0°，每小时 +15°，18:00 -> 180°；
    其余 12 小时（18:00~次日6:00）一律回到 0°"""
    hour = dt.hour + dt.minute / 60.0
    if hour < 6 or hour >= 18:
        return 0
    return int((hour - 6) * 15 // 15) * 15  # 对齐 15° 步进


def pv_publish_angle(angle: int) -> bool:
    """角度对齐 15°、钳位 0~180 后发布到 Control；与上次相同则跳过"""
    angle = max(0, min(180, int(angle)))
    angle = (angle // 15) * 15
    with pv_lock:
        if PV_LAST_SENT["angle"] == angle:
            return False
        PV_LAST_SENT["angle"] = angle
    result = mqtt_paho.publish("Control", json.dumps({"PvAngle": angle}))
    ok = (result.rc == mqtt_client.MQTT_ERR_SUCCESS)
    print(f"[PV] 下发光伏角度: {angle}° -> {'成功' if ok else '失败'}", flush=True)
    return ok


def pv_auto_loop():
    """自动追踪后台线程：开启期间每 3 秒按时间表下发一次角度"""
    while True:
        try:
            if PV_AUTO_STATE["auto"]:
                pv_publish_angle(pv_schedule_angle(get_beijing_dt()))
        except Exception as e:
            print(f"[PV] 自动追踪循环异常: {e}", flush=True)
        time.sleep(PV_AUTO_INTERVAL)


@app.post("/api/nexus/pv/auto")
async def set_pv_auto(request: Request):
    """开关光伏自动追踪。请求体: {"auto": true/false}"""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")
    if "auto" not in body:
        raise HTTPException(status_code=400, detail="缺少 auto 字段")

    auto = bool(body["auto"])
    PV_AUTO_STATE["auto"] = auto
    if auto:
        # 开启瞬间立即按当前时间下发一次，避免等待下个周期
        with pv_lock:
            PV_LAST_SENT["angle"] = None
        pv_publish_angle(pv_schedule_angle(get_beijing_dt()))
    print(f"[PV] 自动追踪已{'开启' if auto else '关闭'}", flush=True)
    return {"status": "success", "data": {"auto": auto}}


@app.post("/api/nexus/pv/angle")
async def set_pv_angle(request: Request):
    """手动下发光伏角度。请求体: {"angle": 0~180}，自动对齐 15° 步进"""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="无效的 JSON 格式")
    if "angle" not in body:
        raise HTTPException(status_code=400, detail="缺少 angle 字段")

    try:
        angle = int(body["angle"])
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="angle 必须为整数")
    if not (0 <= angle <= 180):
        raise HTTPException(status_code=400, detail="angle 必须在 0~180 之间")

    snapped = (angle // 15) * 15
    sent = pv_publish_angle(snapped)
    return {"status": "success", "data": {"angle": snapped, "sent": sent}}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)