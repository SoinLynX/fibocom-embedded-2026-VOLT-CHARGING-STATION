#include "ohos_init.h"
#include "los_task.h"
#include "los_mux.h"
#include "VoltOS.h"
#include "ltc2944.h"
#include "sht30.h"
#include "lz_hardware.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*******************************************************************************
 * 0. 全局常量配置
 ******************************************************************************/

// ================== 核心配置：使用串口 2 作为小车通信端口 ==================
#define COMM_UART_ID         2              // 全面切换到串口 2
#define STRING_MAXSIZE       128
#define FIFO_MAX_UNIT        1024

#define DELAY_TICKS_COUNT    3  // 3 * 500ms = 1500ms 延迟上报

// 事件定义
#define EVENT_CMD_NULL        0x02001c01
#define EVENT_CMD_START_CH1   0x00000001  // 1号枪启动
#define EVENT_CMD_STOP_CH1    0x00000002  // 1号枪停止
#define EVENT_CMD_SUPER_CH1   0x00000010  // 1号枪快充握手

#define EVENT_CMD_START_CH2   0x00000020  // 2号枪启动
#define EVENT_CMD_STOP_CH2    0x00000040  // 2号枪停止
#define EVENT_CMD_SUPER_CH2   0x00000080  // 2号枪快充握手

#define EVENT_CMD_FULL_CH1    0x00000200  // 1号枪充满事件
#define EVENT_CMD_FULL_CH2    0x00000400  // 2号枪充满事件

#define EVENT_ALARM_TEMP_HIGH 0x00000004
#define EVENT_ALARM_VOLT_ERR  0x00000008

// 有效内核事件遮罩
#define VALID_EVENTS_MASK     (EVENT_CMD_START_CH1 | EVENT_CMD_STOP_CH1 | EVENT_CMD_SUPER_CH1 | \
                               EVENT_CMD_START_CH2 | EVENT_CMD_STOP_CH2 | EVENT_CMD_SUPER_CH2 | \
                               EVENT_CMD_FULL_CH1 | EVENT_CMD_FULL_CH2 | \
                               EVENT_ALARM_TEMP_HIGH | EVENT_ALARM_VOLT_ERR)

#define SHELL_INPUT_EVENT_MASK 0x1

/*******************************************************************************
 * 1. 数据结构定义
 ******************************************************************************/

// 环形缓冲区结构体，用于存放串口接收数据防止丢包
struct tagFifo {
    int max;            // 缓冲区最大单元数目
    int read;           // 读操作的偏移位置
    int write;          // 写操作的偏移位置
    unsigned char buffer[FIFO_MAX_UNIT];
};

// 充电桩状态机枚举
typedef enum {
    PILE_STATE_IDLE = 0,       // 空闲待机（没插枪）
    PILE_STATE_PLUGGED,        // 枪头已插入，配置参数阶段
    PILE_STATE_SUPER,          // 快充协议已握手
    PILE_STATE_CHARGING,       // 充电中
    PILE_STATE_FULL,           // 充满结束
    PILE_STATE_FAULT_TEMP,
    PILE_STATE_FAULT_VOLT,
    PILE_STATE_PAUSE
} VoltPileState_e;

// 充电枪结构体
typedef struct {
    uint8_t id;                     // 0代表1号枪，1代表2号枪
    uint32_t adc_channel;           // 对应的ADC通道
    volatile VoltPileState_e state; // 当前枪状态
    ltc2944_data ltcdata;           // 电量计数据

    // 小车动态数据缓存
    uint32_t battery_capacity;      // 电池总容量 (mAh)
    uint8_t init_soc;               // 初始电量 (%)
    uint8_t current_soc;            // 最新动态电量 (%)
    float car_temp;                 // 解析自小车的电池温度
    float start_mah;                // 开启充电瞬间底数

    // 停止原因与健康度记录
    float soh;                      // 电池健康度百分比
    uint8_t stop_reason;            // 停止原因 (1:用户 2:充满 3:高温 4:火警 0:无)

    uint8_t protocol;               // 充电协议 (0:无协议 1:普通速度充电 2:超级快充)

    // 结算延迟上报计数器
    int32_t delay_report_ticks;     // 负数或0代表无上报任务，正数表示剩余等待的 tick 数
} ChargeGun_t;

typedef struct {
    UINT8 rx_buf[128];
    UINT32 rx_cnt;
} cmd_buffer_t;

/*******************************************************************************
 * 2. 全局变量
 ******************************************************************************/

EVENT_CB_S g_shellInputEvent;
EVENT_CB_S g_coreEvent;

static struct tagFifo m_uart2_recv_fifo = {
    .max = FIFO_MAX_UNIT,
    .read = 0,
    .write = 0,
};

// 最后收到启动指令的枪号（0/1）：屏幕充电参数以它为显示源，
// 避免另一把枪残留 CHARGING 状态时误选
static volatile uint8_t g_last_started_gun = 0;

// 火灾告警标志：1=火灾中（昇腾通过 [U4]{"FireAlarm":x} 下发）
static volatile uint8_t g_fire_alarm = 0;

// ==================== 供电来源检测（PC6 ADC）与切换（PC2 GPIO） ====================
#define POW_ADC_CHANNEL    6      // PC6 对应的 SARADC 通道（RK2206 通道与PC引脚一一对应：PC0=0...PC6=6；若实测读数异常先改这里）
#define POW_RAW_THRESHOLD  697    // UPS反馈经电阻分压后的ADC原始值阈值：raw<697=市电供应，raw>697=储能供应
                                 // （RK2206 SARADC参考电压约2.2V，原3.16~3.3V信号超量程，故硬件分压后按原始值判定）
#define POW_STABLE_COUNT   3      // 连续3次采样（约3秒）落在同一侧才翻转状态，防边界抖动误报
#define POW_SUP_GRID       1      // 市电供应（协议值，与 PowSupCtr 约定一致）
#define POW_SUP_ESS        2      // 储能供应（协议值）

static uint8_t g_sys_pow_sup  = POW_SUP_GRID;   // SysPowSup：PC6 实测的系统供电来源，上电默认市电
static uint8_t g_char_pow_sup = POW_SUP_GRID;   // CharPowSup：PC2 当前电平决定的电桩供电来源，上电默认高电平=市电

static ChargeGun_t g_charge_guns[2] = {
    {
        .id = 0, .adc_channel = 0, .state = PILE_STATE_IDLE,
        .battery_capacity = 0, .init_soc = 0, .current_soc = 0,
        .car_temp = 0.0, .start_mah = 0.0, .soh = 0.0, .stop_reason = 0,
        .protocol = 0, .delay_report_ticks = 0
    },
    {
        .id = 1, .adc_channel = 1, .state = PILE_STATE_IDLE,
        .battery_capacity = 0, .init_soc = 0, .current_soc = 0,
        .car_temp = 0.0, .start_mah = 0.0, .soh = 0.0, .stop_reason = 0,
        .protocol = 0, .delay_report_ticks = 0
    }
};

static cmd_buffer_t g_cmd_buffer;
cmd_buffer_t *cmd_ptr = &g_cmd_buffer;

/*******************************************************************************
 * 3. FIFO 环形缓冲区基础底层驱动
 ******************************************************************************/

static void fifo_init(struct tagFifo *fifo)
{
    fifo->max = FIFO_MAX_UNIT;
    fifo->read = fifo->write = 0;
}

static int fifo_is_empty(struct tagFifo *fifo)
{
    return (fifo->write == fifo->read) ? 1 : 0;
}

static int fifo_is_full(struct tagFifo *fifo)
{
    int write_next = (fifo->write + 1) % (fifo->max);
    return (write_next == fifo->read) ? 1 : 0;
}

static int fifo_write(struct tagFifo *fifo, unsigned char *buffer, int buffer_length)
{
    for (int i = 0; i < buffer_length; i++) {
        if (fifo_is_full(fifo) != 0) {
            printf("%s, %d: fifo_write() fifo is full and loss data\n", __FILE__, __LINE__);
        }
        fifo->buffer[fifo->write] = buffer[i];
        fifo->write = (fifo->write + 1) % (fifo->max);
    }
    return buffer_length;
}

static int fifo_read(struct tagFifo *fifo, unsigned char *buffer, int buffer_maxlen, int *buffer_len)
{
    int valid_data_len = 0;
    for (int i = 0; i < buffer_maxlen; i++) {
        if (fifo_is_empty(fifo) == 0) {
            buffer[i] = fifo->buffer[fifo->read];
            fifo->read = (fifo->read + 1) % fifo->max;
            valid_data_len++;
        } else {
            break;
        }
    }
    *buffer_len = valid_data_len;
    return valid_data_len;
}

/*******************************************************************************
 * 4. 串口 2 底层硬件配置函数
 ******************************************************************************/

static void uart2_comm_init(void)
{
    unsigned int ret;
    UartAttribute attr;

    attr.baudRate = 115200;
    attr.dataBits = UART_DATA_BIT_8;
    attr.pad = FLOW_CTRL_NONE;
    attr.parity = UART_PARITY_NONE;
    attr.rxBlock = UART_BLOCK_STATE_NONE_BLOCK;
    attr.stopBits = UART_STOP_BIT_1;
    attr.txBlock = UART_BLOCK_STATE_NONE_BLOCK;

    PinctrlSet(GPIO0_PB3, MUX_FUNC3, PULL_KEEP, DRIVE_LEVEL2);
    PinctrlSet(GPIO0_PB2, MUX_FUNC3, PULL_KEEP, DRIVE_LEVEL2);

    ret = LzUartInit(COMM_UART_ID, &attr);
    if (ret != LZ_HARDWARE_SUCCESS) {
        printf("[UART2错误] 串口2配置失败: %d\n", ret);
    } else {
        printf("[UART2成功] 通信串口2初始化及IO配置完成。\n");
    }
}

// UART2 发送互斥锁：volt_thread（page/JSON上报）与 process_cmd（ACK）都会写串口，
// 加锁防止两条报文字节交错导致转发器收到烂帧丢包
static UINT32 g_uart2_tx_mux;

static void uart2_tx_lock(void)
{
    LOS_MuxPend(g_uart2_tx_mux, LOS_WAIT_FOREVER);
}

static void uart2_tx_unlock(void)
{
    LOS_MuxPost(g_uart2_tx_mux);
}

static void uart2_send_string(const char *str)
{
    // 分块发送：UART 单次写入过长会被底层截断（实测充电长报文 128 字节附近丢尾），
    // 32 字节一块稳妥；互斥锁包住整个循环，块间不会被其他发送者插入。
    // 注意：底层发送FIFO约128字节，连续写满后多余字节会被直接丢弃（返回值也看不出），
    // 所以每块之间必须等FIFO腾空——32字节@115200约需2.8ms，留余量等4ms。
    if (str != NULL) {
        size_t len = strlen(str);
        size_t off = 0;
        uart2_tx_lock();
        while (off < len) {
            size_t chunk = (len - off > 32) ? 32 : (len - off);
            LzUartWrite(COMM_UART_ID, (unsigned char *)(str + off), chunk);
            off += chunk;
            if (off < len) {
                LOS_Msleep(4); // 等底层FIFO腾空，防止尾块被丢弃
            }
        }
        uart2_tx_unlock();
    }
}

/*******************************************************************************
 * 4.5 串口屏显示命令封装（每条命令末尾固定跟 \xff\xff\xff 结束符）
 ******************************************************************************/

// 向串口屏发送一条命令：加 [U5] 帧头（供串口转发器路由），末尾追加 3 字节 0xFF 结束符
static void display_send_cmd(const char *cmd)
{
    if (cmd == NULL) {
        return;
    }
    uart2_tx_lock();
    LzUartWrite(COMM_UART_ID, (unsigned char *)"[U5]", 4);
    LzUartWrite(COMM_UART_ID, (unsigned char *)cmd, strlen(cmd));
    LzUartWrite(COMM_UART_ID, (unsigned char *)"\xff\xff\xff", 3);
    uart2_tx_unlock();
}

// ================== 屏幕跳页命令队列（全页面切换均走 pageok 确认重传） ==================
// 任何线程要切页只负责入队；由 display_manager_thread 独立线程负责
// 发送、等待 [U5]pageok 回执、超时重发。避免在解析线程里等回执造成死等。
#define DISPLAY_PAGE_Q_SIZE 8

static char g_page_queue[DISPLAY_PAGE_Q_SIZE][32];
static volatile int g_page_q_head = 0; // 消费位置
static volatile int g_page_q_tail = 0; // 入队位置

// 屏幕跳页回执标志：屏幕成功切换页面后会回 [U5]pageok，由 process_cmd 置位
static volatile uint8_t g_display_page_ack = 0;

// 屏幕当前页跟踪（TJC 各页控件独立编号，非本页控件写入会串数据）：
// 由显示管理线程在跳页成功后更新；仅当处于 page 2 时才允许刷新温湿度 t5/t6
static volatile int g_display_cur_page = 0;
static uint32_t g_page5_wait_ticks = 0; // page 5 等待回主页的计时（1.5s 粒度）
static volatile uint32_t g_pageok_count = 0;   // 累计收到的 pageok 次数（dispatch 中自增）
static uint32_t g_page5_baseline = 0;          // 进入 page 5 时的 pageok 基准计数

// 跳页命令入队（任何线程可调用，立即返回）
static void display_send_page_cmd(const char *cmd)
{
    int next_tail = (g_page_q_tail + 1) % DISPLAY_PAGE_Q_SIZE;

    uart2_tx_lock(); // 与显示管理线程互斥，保护队列头尾指针
    if (next_tail == g_page_q_head) {
        printf("[显示警告] 跳页队列已满，丢弃命令: %s\n", cmd);
        uart2_tx_unlock();
        return;
    }
    strncpy(g_page_queue[g_page_q_tail], cmd, sizeof(g_page_queue[0]) - 1);
    g_page_queue[g_page_q_tail][sizeof(g_page_queue[0]) - 1] = '\0';
    g_page_q_tail = next_tail;
    uart2_tx_unlock();
}

// 显示管理线程：逐条消费跳页命令，发送后等 pageok，超时重发最多 3 次
void display_manager_thread(void)
{
    while (1) {
        if (g_page_q_head != g_page_q_tail) {
            char cmd[32];

            uart2_tx_lock();
            strncpy(cmd, g_page_queue[g_page_q_head], sizeof(cmd) - 1);
            cmd[sizeof(cmd) - 1] = '\0';
            uart2_tx_unlock();

            for (int attempt = 0; attempt < 3; attempt++) {
                g_display_page_ack = 0;
                display_send_cmd(cmd);

                // 50ms 粒度轮询，最长等 500ms
                for (int wait = 0; wait < 10; wait++) {
                    LOS_Msleep(50);
                    if (g_display_page_ack) {
                        break;
                    }
                }
                if (g_display_page_ack) {
                    // 跳页成功，跟踪当前页码（用于温湿度等页面专属数据的写入许可）
                    int page_no = 0;
                    if (sscanf(cmd, "page %d", &page_no) == 1) {
                        g_display_cur_page = page_no;
                        printf("[显示] 页码跟踪更新: page %d\n", page_no);
                        if (page_no == 5) {
                            g_page5_wait_ticks = 0;
                            // 记录 pageok 基准：跳 page5 的 pageok 已计入，
                            // 之后再来新的 pageok 才是屏幕自动回主页的信号
                            g_page5_baseline = g_pageok_count;
                        }
                    }
                    break;
                }
                printf("[显示警告] %s 未收到 pageok 回执，重发第 %d 次...\n", cmd, attempt + 1);
            }
            if (!g_display_page_ack) {
                printf("[显示错误] %s 重发 3 次仍无回执，放弃（屏幕可能离线）。\n", cmd);
            }

            g_page_q_head = (g_page_q_head + 1) % DISPLAY_PAGE_Q_SIZE;
        } else {
            LOS_Msleep(20);
        }
    }
}

// 向串口屏合并发送两条命令：整个帧只有一个 [U5] 帧头，
// 但每条子命令各自带 \xff\xff\xff 结束符
static void display_send_cmd2(const char *cmd1, const char *cmd2)
{
    if (cmd1 == NULL || cmd2 == NULL) {
        return;
    }
    uart2_tx_lock();
    LzUartWrite(COMM_UART_ID, (unsigned char *)"[U5]", 4);
    LzUartWrite(COMM_UART_ID, (unsigned char *)cmd1, strlen(cmd1));
    LzUartWrite(COMM_UART_ID, (unsigned char *)"\xff\xff\xff", 3);
    LzUartWrite(COMM_UART_ID, (unsigned char *)cmd2, strlen(cmd2));
    LzUartWrite(COMM_UART_ID, (unsigned char *)"\xff\xff\xff", 3);
    uart2_tx_unlock();
}

// 待机状态下向屏幕刷新设备温湿度显示（t5=温度, t6=湿度）
static void display_send_env_th(float sys_temp, float sys_humi)
{
    char cmd1[32];
    char cmd2[32];

    snprintf(cmd1, sizeof(cmd1), "t5.txt=\"%.1f\"", sys_temp);
    snprintf(cmd2, sizeof(cmd2), "t6.txt=\"%.1f\"", sys_humi);

    // 一帧合并发送：[U5]t3.txt="xx"\xff\xff\xff t4.txt="xx"\xff\xff\xff
    display_send_cmd2(cmd1, cmd2);
}

// 向串口屏发送一个"多命令合并帧"：[U5] + N条命令（每条各带\xff\xff\xff）
// 整帧一次发出，要么完整到达要么整帧丢失，保证同帧内所有控件数据来自同一采样时刻
static void display_send_multi(const char *cmds[], int n)
{
    static uint8_t frame[512];
    int pos = 0;

    pos += snprintf((char *)frame + pos, sizeof(frame) - pos, "[U5]");
    for (int i = 0; i < n; i++) {
        int clen = strlen(cmds[i]);
        if (pos + clen + 3 >= (int)sizeof(frame)) break; // 溢出保护
        memcpy(frame + pos, cmds[i], clen);
        pos += clen;
        frame[pos++] = 0xFF;
        frame[pos++] = 0xFF;
        frame[pos++] = 0xFF;
    }

    uart2_tx_lock();
    LzUartWrite(COMM_UART_ID, frame, pos);
    uart2_tx_unlock();
}

// 充电中向屏幕刷新实时参数（page 3/4 充电页）：
// t1=电压(V) t2=电流(A) t3=功率(W) t4=累计输出电量(kWh)
// t5=枪温 t6=车温 t8=当前SOC(%) t7=枪号(NO.1/NO.2)
static void display_send_charging_params(ChargeGun_t *gun)
{
    // 电压电流先按云端口径保留 1 位小数再算功率（云端上报为 %.1f，
    // 改 %.2f 会导致服务端异常已回退），保证屏幕与手机显示口径一致
    float v = (float)((int)(gun->ltcdata.voltage * 10 + 0.5f)) / 10.0f;
    float c = (float)((int)(gun->ltcdata.current * 10 + 0.5f)) / 10.0f;
    float p = v * c;

    // 累计输出电量：与手机端口径完全一致——直接取电量计累计值
    // （手机端 累积度数 = 云端 charSoc = ltcdata.mAh 原值）
    float charged = gun->ltcdata.mAh;

    // 8 条命令合并为一帧发送：杜绝逐条发送时部分帧丢失导致
    // 屏幕各控件显示不同采样时刻的值（如 0.2A 配 4.9W 的矛盾现象）
    static char s_t1[20], s_t2[20], s_t3[20], s_t4[20], s_t5[20], s_t6[20], s_t8[20], s_t7[20];
    snprintf(s_t1, sizeof(s_t1), "t1.txt=\"%.2fV\"", v);
    snprintf(s_t2, sizeof(s_t2), "t2.txt=\"%.2fA\"", c);
    snprintf(s_t3, sizeof(s_t3), "t3.txt=\"%.2fW\"", p);
    snprintf(s_t4, sizeof(s_t4), "t4.txt=\"%.2fkWh\"", charged);
    snprintf(s_t5, sizeof(s_t5), "t5.txt=\"%.1f\"", gun->ltcdata.temperature); // 枪温不带单位（屏幕摄氏度显示有bug）
    snprintf(s_t6, sizeof(s_t6), "t6.txt=\"%.1f\"", gun->car_temp);            // 车温同上
    snprintf(s_t8, sizeof(s_t8), "t8.txt=\"%d%%\"", gun->current_soc);
    snprintf(s_t7, sizeof(s_t7), "t7.txt=\"NO.%d\"", gun->id + 1);

    const char *cmds[8] = { s_t1, s_t2, s_t3, s_t4, s_t5, s_t6, s_t8, s_t7 };
    display_send_multi(cmds, 8);
}

// 跳转到 page 5 结算页并下发结算数据：
// t0=累积充入电荷数（与手机端 charSoc 同口径），t2=金额（电荷数 x 1.2）
// 跳页命令走 pageok 确认队列；结算数据等跳页生效后以合并帧连发 3 次防丢包
static void display_goto_settlement(ChargeGun_t *gun)
{
    // 火灾期间禁止跳订单页：火灾停止也走停止分支，但 page 6 火灾告警页
    // 必须保持，不能被 page 5 覆盖（结算数据无意义，云端只认 gxstop=4）
    if (g_fire_alarm) {
        return;
    }

    display_send_page_cmd("page 5");

    // 等待跳页完成（正常 pageok 确认 50ms 内返回，600ms 留足余量），
    // 否则数据会写到旧页面的同名控件上
    LOS_Msleep(600);

    float charged = gun->ltcdata.mAh;
    float price = charged * 1.2f;

    static char s_t0[24], s_t2[24];
    snprintf(s_t0, sizeof(s_t0), "t0.txt=\"%.2f\"", charged);
    snprintf(s_t2, sizeof(s_t2), "t2.txt=\"%.2f\"", price);

    const char *cmds[2] = { s_t0, s_t2 };
    for (int i = 0; i < 3; i++) { // 连发 3 次防丢包
        display_send_multi(cmds, 2);
        LOS_Msleep(200);
    }
}

// 插枪/拔枪时更新对应枪的两个文本控件透明度
// gun_id: 0 -> t1/t3，1 -> t2/t4；plugged: 1 插枪(tX.aph=0, tX+2.aph=127)，0 拔枪(对调)
static void display_set_gun_aph(uint8_t gun_id, uint8_t plugged)
{
    char cmd1[32];
    char cmd2[32];

    // 枪1使用 t1/t3，枪2使用 t2/t4
    uint8_t t_first  = gun_id + 1;   // 枪1->t1, 枪2->t2
    uint8_t t_second = gun_id + 3;   // 枪1->t3, 枪2->t4

    int aph_first  = plugged ? 0 : 127;
    int aph_second = plugged ? 127 : 0;

    snprintf(cmd1, sizeof(cmd1), "t%d.aph=%d", t_first, aph_first);
    snprintf(cmd2, sizeof(cmd2), "t%d.aph=%d", t_second, aph_second);

    // 一帧合并发送：[U5]tX.aph=N\xff\xff\xff tX+2.aph=N\xff\xff\xff
    display_send_cmd2(cmd1, cmd2);
}

/*******************************************************************************
 * 5. 业务机能函数（参数复位 / SOH 结算）
 ******************************************************************************/

static void reset_gun_parameters(ChargeGun_t *gun)
{
    gun->battery_capacity = 0;
    gun->init_soc = 0;
    gun->current_soc = 0;
    gun->car_temp = 0.0;
    gun->start_mah = 0.0;

    gun->soh = 0.0;         // 清空SOH
    gun->stop_reason = 0;   // 清空停止标志

    gun->protocol = 0;      // 恢复为无协议
    gun->delay_report_ticks = 0; // 清空延迟计数器
    printf("[清理机能] %d号充电枪动态参数已全部清空，复位就绪。\n", gun->id + 1);
}

static void calculate_battery_soh(ChargeGun_t *gun)
{
    if (gun->battery_capacity == 0) {
        printf("[枪%d] SOH结算失败：小车未提供有效的电池容量参数(CAP)。\n", gun->id + 1);
        gun->soh = 1.0;
        return;
    }

    float q_actual = gun->ltcdata.mAh;
    int32_t soc_diff = (int32_t)gun->current_soc - (int32_t)gun->init_soc;
    if (soc_diff <= 0) {
        printf("[枪%d] SOH计算警告：SOC电量未发生净增（初始:%d%%, 结束:%d%%），无法结算。\n",
               gun->id + 1, gun->init_soc, gun->current_soc);
        gun->soh = 1.0;
        return;
    }

    float q_theory = (float)gun->battery_capacity * ((float)soc_diff / 100.0);
    float soh = (q_actual / q_theory) * 100.0;
    if (soh > 100) soh = 100;
    if (soh < 1) soh = 1; // 进一步确保计算出的正数也不低于 1%

    gun->soh = soh; // 缓存供上报使用

    printf("\n============================================\n");
    printf("         [枪%d] 充入能量与SOH健康度报告        \n", gun->id + 1);
    printf("--------------------------------------------\n");
    printf(" * 电池标称总容量 : %d mAh\n", gun->battery_capacity);
    printf(" * 初始/当前SOC   : %d%%  -->  %d%% (提升 %d%%)\n", gun->init_soc, gun->current_soc, soc_diff);
    printf(" * 小车末端电池温度: %.2f °C\n", gun->car_temp);
    printf(" * 理论理应获得   : %.2f mAh\n", q_theory);
    printf(" * 硬件实际冲入   : %.2f mAh \n", q_actual);
    printf(" * 电池健康度(SOH) : %.2f%%\n", soh);
    printf("============================================\n\n");
}

/*******************************************************************************
 * 6. 串口接收线程（中断式轮询收包入 FIFO）
 ******************************************************************************/

void uart2_recv_process(void)
{
    unsigned char recv_buffer[STRING_MAXSIZE];
    int recv_length = 0;

    while (1) {
        recv_length = LzUartRead(COMM_UART_ID, recv_buffer, sizeof(recv_buffer));
        if (recv_length > 0) {
            fifo_write(&m_uart2_recv_fifo, recv_buffer, recv_length);
        } else {
            LOS_Msleep(1);
        }
    }
}

/*******************************************************************************
 * 7. 小车 JSON 协议解析工具函数
 ******************************************************************************/

/***************************************************************
* 函数名称: parse_json_handshake
* 说    明: 解析小车握手JSON参数 [Ux]{CAP:1000,INIT_SOC:90,AGT:VOLT_SUPER}
***************************************************************/
static int parse_json_handshake(const char *json_str, uint32_t *cap, uint8_t *soc, char *agt, int agt_len)
{
    char *p_cap = strstr(json_str, "CAP:");
    char *p_soc = strstr(json_str, "INIT_SOC:");
    char *p_agt = strstr(json_str, "AGT:");

    if (p_cap && p_soc && p_agt) {
        *cap = (uint32_t)atoi(p_cap + 4);
        *soc = (uint8_t)atoi(p_soc + 9);
        int i = 0;
        char *src = p_agt + 4;
        while (src[i] != '\0' && src[i] != '}' && src[i] != ',' && i < (agt_len - 1)) {
            agt[i] = src[i];
            i++;
        }
        agt[i] = '\0';
        return 1;
    }
    return 0;
}

/***************************************************************
* 函数名称: parse_json_runtime
* 说    明: 解析充电中动态JSON参数 [Ux]{SOC:92,Rat:-6.65,Temp:31.00}
***************************************************************/
static int parse_json_runtime(const char *json_str, uint8_t *soc, float *temp)
{
    char *p_soc = strstr(json_str, "SOC:");
    char *p_temp = strstr(json_str, "Temp:");

    if (p_soc && p_temp) {
        *soc = (uint8_t)atoi(p_soc + 4);
        *temp = (float)atof(p_temp + 5);
        return 1;
    }
    return 0;
}

/*******************************************************************************
 * 8. [U4] 上位机指令处理（控制指令；V1.5起不再下发用户名/余额）
 ******************************************************************************/

// 解析 [U4] 枪控制状态字段并派发内核事件 ("Gun1CtrSta"/"Gun2CtrSta": 13个字符)
static void u4_parse_gun_control(char *buf, const char *key, int gun_idx,
                                 uint32_t start_event, uint32_t stop_event)
{
    char *p_val;

    if ((p_val = strstr(buf, key)) != NULL) {
        int status = atoi(p_val + 13);
        if (status == 1) {
            printf("[U4控制] 收到指令：%d号枪用户待支付，等待启动...\n", gun_idx + 1);
        } else if (status == 2) {
            printf("[U4控制] 收到指令：启动%d号枪充电\n", gun_idx + 1);
            LOS_EventWrite(&g_coreEvent, start_event);
        } else if (status == 3 || status == 4) { // 明确云端停止原因 1
            g_charge_guns[gun_idx].stop_reason = 1;
            printf("[U4控制] 收到指令：云端关停%d号枪 (状态:%d)\n", gun_idx + 1, status);
            LOS_EventWrite(&g_coreEvent, stop_event);
        }
    }
}

// [U4] 指令总控入口
static void u4_handle_command(char *buf)
{
    char *p_val;

    // ================== 火灾告警（昇腾火灾检测脚本下发） ==================
    if ((p_val = strstr(buf, "\"FireAlarm\":")) != NULL) {
        int fire = atoi(p_val + 12);
        if (fire == 1 && g_fire_alarm == 0) {
            g_fire_alarm = 1;
            printf(">>> [火灾告警] 收到火灾指令，切断充电并切换 page 6！\n");

            // 对所有充电中的枪执行火灾停止（stop_reason=4，延迟结算上报 gxstop=4）
            for (int i = 0; i < 2; i++) {
                if (g_charge_guns[i].state == PILE_STATE_CHARGING) {
                    g_charge_guns[i].stop_reason = 4; // 4: 火灾
                    LOS_EventWrite(&g_coreEvent, (i == 0) ? EVENT_CMD_STOP_CH1 : EVENT_CMD_STOP_CH2);
                }
            }
            // 无论是否在充电，都切到 page 6 火灾告警页
            display_send_page_cmd("page 6");
        } else if (fire == 0 && g_fire_alarm == 1) {
            g_fire_alarm = 0;
            printf(">>> [火灾解除] 火灾结束，切回 page 2，枪状态恢复上报 0。\n");
            display_send_page_cmd("page 2");
        }
    }

    // 1. 枪1控制状态解析
    u4_parse_gun_control(buf, "\"Gun1CtrSta\":", 0, EVENT_CMD_START_CH1, EVENT_CMD_STOP_CH1);

    // 2. 枪2控制状态解析
    u4_parse_gun_control(buf, "\"Gun2CtrSta\":", 1, EVENT_CMD_START_CH2, EVENT_CMD_STOP_CH2);

    // 3. 电桩供电来源切换 ("PowSupCtr": 12个字符)：1=市电(PC2输出高电平) 2=储能(PC2输出低电平)
    if ((p_val = strstr(buf, "\"PowSupCtr\":")) != NULL) {
        int mode = atoi(p_val + 12);
        if (mode == POW_SUP_GRID || mode == POW_SUP_ESS) {
            g_char_pow_sup = (uint8_t)mode;
            LzGpioSetVal(GPIO0_PC2, (mode == POW_SUP_GRID) ? LZGPIO_LEVEL_HIGH : LZGPIO_LEVEL_LOW);
            printf("[U4控制] 电桩供电来源切换 -> %s (PC2 %s)\n",
                   (mode == POW_SUP_GRID) ? "市电" : "储能",
                   (mode == POW_SUP_GRID) ? "高电平" : "低电平");
        }
    }
}

/*******************************************************************************
 * 9. [U2]/[U3] 小车通路数据流解析（握手 / 动态参数 / 充满）
 ******************************************************************************/

// 处理小车握手包 {CAP:...,INIT_SOC:...,AGT:...}
static void gun_handle_handshake(char *buf, char *json_start, int gun_idx)
{
    if (g_charge_guns[gun_idx].state != PILE_STATE_IDLE) {
        uint32_t t_cap = 0;
        uint8_t t_soc = 0;
        char t_agt[16] = {0};

        if (parse_json_handshake(json_start, &t_cap, &t_soc, t_agt, sizeof(t_agt))) {
            g_charge_guns[gun_idx].battery_capacity = t_cap;
            g_charge_guns[gun_idx].init_soc = t_soc;
            g_charge_guns[gun_idx].current_soc = t_soc;

            // 核心修改：在这里记录它是快充还是普通充电
            if (strcmp(t_agt, "VOLT_SUPER") == 0) {
                g_charge_guns[gun_idx].protocol = 2; // 快充
            } else {
                g_charge_guns[gun_idx].protocol = 1; // 普充 (预留扩展)
            }

            printf("[通道%d] 统一握手成功 -> CAP:%d, INIT_SOC:%d%%, 协议:%s\n",
                   gun_idx + 1, t_cap, t_soc, t_agt);

            if (gun_idx == 0) {
                uart2_send_string("[U2]ACK\n");
                if (strcmp(t_agt, "VOLT_SUPER") == 0) {
                    LOS_EventWrite(&g_coreEvent, EVENT_CMD_SUPER_CH1);
                }
            } else {
                uart2_send_string("[U3]ACK\n");
                if (strcmp(t_agt, "VOLT_SUPER") == 0) {
                    LOS_EventWrite(&g_coreEvent, EVENT_CMD_SUPER_CH2);
                }
            }
        }
    } else {
        printf("[通道%d警告] 拒绝握手包：未检测到插枪物理信号！\n", gun_idx + 1);
    }
}

// 处理小车动态数据包 {SOC:...,Temp:...}
static void gun_handle_runtime(char *json_start, int gun_idx)
{
    if (g_charge_guns[gun_idx].state == PILE_STATE_CHARGING) {
        uint8_t t_soc = 0;
        float t_temp = 0.0;
        if (parse_json_runtime(json_start, &t_soc, &t_temp)) {
            g_charge_guns[gun_idx].current_soc = t_soc;
            g_charge_guns[gun_idx].car_temp = t_temp;
        }
    }
}

// 处理小车充满指令 FULL
static void gun_handle_full(int gun_idx)
{
    if (g_charge_guns[gun_idx].state == PILE_STATE_CHARGING) {
        printf("[通道%d] 收到小车充满指令，电桩执行ACK反馈。\n", gun_idx + 1);
        if (gun_idx == 0) {
            uart2_send_string("[U2]ACK\n");
            LOS_EventWrite(&g_coreEvent, EVENT_CMD_FULL_CH1);
        } else {
            uart2_send_string("[U3]ACK\n");
            LOS_EventWrite(&g_coreEvent, EVENT_CMD_FULL_CH2);
        }
    }
}

// [U2]/[U3] 通路数据分发
static void gun_handle_message(char *buf, int gun_idx)
{
    char *json_start = strchr(buf, '{');

    if (json_start != NULL && strstr(buf, "CAP:") != NULL) {
        gun_handle_handshake(buf, json_start, gun_idx);
    } else if (json_start != NULL && strstr(buf, "SOC:") != NULL) {
        gun_handle_runtime(json_start, gun_idx);
    } else if (strstr(buf, "FULL") != NULL) {
        gun_handle_full(gun_idx);
    }
}

/*******************************************************************************
 * 10. 串口指令协议解析消费线程
 ******************************************************************************/

// 空闲超时冲刷门限：15ms * 7 ≈ 100ms 无新数据则强制按一条完整命令解析
#define RX_FLUSH_IDLE_TICKS  7

// 分发一条已拼完整的串口命令行
static void dispatch_rx_line(char *buf)
{
    int gun_idx = -1;

    // 转发收到的完整串口命令到调试打印口
    printf("[串口接收] %s\n", buf);

    if (strncmp(buf, "[U2]", 4) == 0) gun_idx = 0;
    else if (strncmp(buf, "[U3]", 4) == 0) gun_idx = 1;

    // ================== [U4] 上位机指令总控 (JSON解析) ==================
    if (strncmp(buf, "[U4]", 4) == 0) {
        u4_handle_command(buf);
    }
    // ================== [U2]/[U3] 小车通路数据流解析 ==================
    // 注意：屏幕 prints 无结束符，靠空闲超时成帧，可能与前一条数据粘包，
    // 形成 "[U2]{...}[U5]closeok" 这样的混合行，因此 [U5] 改用在整行内搜索识别
    else if (gun_idx != -1 && strstr(buf, "[U5]") == NULL) {
        gun_handle_message(buf, gun_idx);
    }
    // ================== [U5] 串口屏指令（允许出现在行内任意位置） ==================
    else if (strstr(buf, "[U5]") != NULL) {
        if (strstr(buf, "displayok") != NULL) {
            // 屏幕若用定时器循环发 displayok，不能每次都回 page 2，
            // 否则会把后续的 page 3/page 5 顶回去。只在首次（或屏幕重启后）响应一次。
            static uint8_t display_ready_done = 0;
            if (!display_ready_done) {
                display_ready_done = 1;
                printf("[U5业务] 串口屏就绪，切换到 page 2。\n");
                display_send_page_cmd("page 2");
            }
        } else if (strstr(buf, "closeok") != NULL) {
            // 屏幕侧用户主动停止：对所有充电中的枪发起停止，停止原因记 6
            printf("[U5业务] 屏幕侧用户主动停止充电。\n");
            int stopped = 0;
            for (int i = 0; i < 2; i++) {
                if (g_charge_guns[i].state == PILE_STATE_CHARGING) {
                    g_charge_guns[i].stop_reason = 6;
                    LOS_EventWrite(&g_coreEvent, (i == 0) ? EVENT_CMD_STOP_CH1 : EVENT_CMD_STOP_CH2);
                    stopped = 1;
                }
            }
            if (!stopped) {
                printf("[U5警告] 收到 closeok 但当前无充电中的枪，忽略。\n");
            }
        } else if (strstr(buf, "pageok") != NULL) {
            g_display_page_ack = 1; // 屏幕跳页回执，供 display_send_page_cmd 确认
            g_pageok_count++;       // 累计计数，用于 page 5 监听"下一个"pageok（屏幕回主页）
        } else if (strstr(buf, "chargeok") != NULL) {
            printf("[U5业务] 串口屏确认充电页，切换到 page 4。\n");
            display_send_page_cmd("page 4");
        }
    } else {
        printf("\n>>> 未知串扰数据或无效格式: %s\n", buf);
    }
}

/***************************************************************
* 函数名称: process_cmd
* 说    明: 串口指令协议解析消费线程 (支持混合JSON文本提取 + 空闲超时冲刷)
***************************************************************/
void process_cmd(void)
{
    UINT32 event_ret;
    unsigned char pop_ch;
    int pop_len;
    uint32_t idle_ticks = 0; // 连续无数据轮次计数（用于超时冲刷）

    memset(cmd_ptr->rx_buf, 0, sizeof(cmd_ptr->rx_buf));
    cmd_ptr->rx_cnt = 0;

    while (1) {
        event_ret = LOS_EventRead(&g_shellInputEvent, SHELL_INPUT_EVENT_MASK,
                                  LOS_WAITMODE_OR | LOS_WAITMODE_CLR, 0);
        (void)event_ret;

        while (fifo_read(&m_uart2_recv_fifo, &pop_ch, 1, &pop_len) > 0) {
            // \r\n 为常规行结束符；0xFF 为串口屏(TJC)命令结束符(\xff\xff\xff)，
            // 三个 0xFF 中第一个触发解析，后两个因 rx_cnt 已为 0 被自动忽略
            if (pop_ch == '\r' || pop_ch == '\n' || pop_ch == 0xFF) {
                if (cmd_ptr->rx_cnt > 0) {
                    cmd_ptr->rx_buf[cmd_ptr->rx_cnt] = '\0';
                    dispatch_rx_line((char *)cmd_ptr->rx_buf);
                    cmd_ptr->rx_cnt = 0;
                }
            } else {
                if (cmd_ptr->rx_cnt < (sizeof(cmd_ptr->rx_buf) - 1)) {
                    cmd_ptr->rx_buf[cmd_ptr->rx_cnt++] = pop_ch;
                    idle_ticks = 0; // 有新数据，重置空闲计数
                } else {
                    cmd_ptr->rx_cnt = 0;
                }
            }
        }

        // ================== 空闲超时冲刷：兼容不带任何结束符的发送方 ==================
        // 例如串口屏 prints 指令只发字符串本身，没有 \xff\xff\xff 也没有 \r\n
        if (cmd_ptr->rx_cnt > 0) {
            idle_ticks++;
            if (idle_ticks >= RX_FLUSH_IDLE_TICKS) {
                cmd_ptr->rx_buf[cmd_ptr->rx_cnt] = '\0';
                dispatch_rx_line((char *)cmd_ptr->rx_buf);
                cmd_ptr->rx_cnt = 0;
                idle_ticks = 0;
            }
        } else {
            idle_ticks = 0;
        }

        LOS_Msleep(15);
    }
}

/*******************************************************************************
 * 11. 北向 [U4] 上报函数（停止事件 / 定时状态）
 ******************************************************************************/

// 向 [U4] 专门上报停止原因及SOH
static void send_stop_event_to_u4(ChargeGun_t *gun)
{
    char json_packet[128] = {0};
    int soh_val = (int)gun->soh; // 根据协议要求强制转换为整数百分比

    if (gun->id == 0) {
        snprintf(json_packet, sizeof(json_packet), "[U4]{\"g1stop\":%d,\"g1soh\":%d}\n", gun->stop_reason, soh_val);
    } else {
        snprintf(json_packet, sizeof(json_packet), "[U4]{\"g2stop\":%d,\"g2soh\":%d}\n", gun->stop_reason, soh_val);
    }
    uart2_send_string(json_packet);
}

// 底层状态与 MQTT 协议字典映射
static int map_state_to_mqtt(VoltPileState_e internal_state)
{
    // 火灾告警期间：无论充没充电，枪状态一律上报 4；
    // 火灾结束后回落到下面的正常映射（空闲即为 0）
    if (g_fire_alarm) {
        return 4;
    }

    switch (internal_state) {
        case PILE_STATE_IDLE:
            return 0; // 0：空闲

        case PILE_STATE_PLUGGED:
        case PILE_STATE_SUPER:
        case PILE_STATE_FULL:
            return 1; // 1：已插枪 (包括刚插枪、握手完毕、以及充满但没拔枪)

        case PILE_STATE_CHARGING:
            return 2; // 2：充电中

        case PILE_STATE_FAULT_TEMP:
            return 3; // 3：高温警报

        default:
            return 0; // 其他未知或故障状态默认回落
    }
}

// 构造单枪上报片段（g1 或 g2，充电时附带动态数据，否则只带状态）
// 注意：该函数仅为消除 1/2 号枪片段拼装的完全重复代码，拼接格式与原实现逐字符一致
static void build_gun_report_part(int gun_idx, int mqtt_state, char *out_buf, size_t out_size)
{
    if (g_charge_guns[gun_idx].state == PILE_STATE_CHARGING) {
        if (gun_idx == 0) {
            snprintf(out_buf, out_size,
                     "\"g1s\":%d,\"g1v\":%.1f,\"g1c\":%.1f,\"g1cs\":%.1f,\"g1t\":%.1f,\"g1soc\":%d,\"g1ct\":%.1f,\"g1bc\":%u,\"g1a\":%d,",
                     mqtt_state,
                     g_charge_guns[0].ltcdata.voltage,
                     g_charge_guns[0].ltcdata.current,
                     g_charge_guns[0].ltcdata.mAh,
                     g_charge_guns[0].ltcdata.temperature, // 1号枪端温度
                     g_charge_guns[0].current_soc,
                     g_charge_guns[0].car_temp,
                     g_charge_guns[0].battery_capacity,
                     g_charge_guns[0].protocol);
        } else {
            snprintf(out_buf, out_size,
                     "\"g2s\":%d,\"g2v\":%.1f,\"g2c\":%.1f,\"g2cs\":%.1f,\"g2t\":%.1f,\"g2soc\":%d,\"g2ct\":%.1f,\"g2bc\":%u,\"g2a\":%d,",
                     mqtt_state,
                     g_charge_guns[1].ltcdata.voltage,
                     g_charge_guns[1].ltcdata.current,
                     g_charge_guns[1].ltcdata.mAh,
                     g_charge_guns[1].ltcdata.temperature, // 2号枪端温度
                     g_charge_guns[1].current_soc,
                     g_charge_guns[1].car_temp,
                     g_charge_guns[1].battery_capacity,
                     g_charge_guns[1].protocol);
        }
    } else {
        if (gun_idx == 0) {
            snprintf(out_buf, out_size, "\"g1s\":%d,", mqtt_state);
        } else {
            snprintf(out_buf, out_size, "\"g2s\":%d,", mqtt_state);
        }
    }
}

// 向北向 [U4] 定时发送状态函数
// PC6 ADC 供电来源检测：每 1.5 秒采样一次，连续 POW_STABLE_COUNT 次同侧才翻转 g_sys_pow_sup
static void pow_sup_adc_poll(void)
{
    unsigned int rawadc = 0;
    static uint8_t last_side = 0;     // 上一次采样落在哪一侧（0=未初始化）
    static uint8_t stable_cnt = 0;    // 连续落在"另一侧"的次数

    if (LzSaradcReadValue(POW_ADC_CHANNEL, &rawadc) != LZ_HARDWARE_SUCCESS) {
        return; // 读失败本轮跳过，保持原状态
    }
    float adc_val = (float)(rawadc * 2.2 / 1024.0);   // 分压后引脚电压（参考2.2V），仅用于显示
    uint8_t side = (rawadc > POW_RAW_THRESHOLD) ? POW_SUP_ESS : POW_SUP_GRID;
    printf("[供电检测] PC6 ADC: %.2fV (raw=%u) -> %s (当前判定: %s)\n", adc_val, rawadc,
           (side == POW_SUP_ESS) ? "储能侧" : "市电侧",
           (g_sys_pow_sup == POW_SUP_ESS) ? "储能" : "市电");

    if (side == g_sys_pow_sup) {
        stable_cnt = 0; // 与当前状态一致，无需翻转
        return;
    }
    if (side == last_side) {
        stable_cnt++;
    } else {
        last_side = side;
        stable_cnt = 1;
    }
    if (stable_cnt >= POW_STABLE_COUNT) {
        g_sys_pow_sup = side;
        stable_cnt = 0;
        printf("[供电检测] 系统供电来源变更 -> %s (PC6 ADC %.2fV)\n",
               (side == POW_SUP_ESS) ? "储能" : "市电", adc_val);
    }
}

static void send_south_data_to_u4(float sys_temp, float sys_humi)
{
    char json_packet[288] = {0};
    char g1_part[128] = {0};
    char g2_part[128] = {0};

    // 获取经过 MQTT 协议规范映射后的状态值
    int mqtt_g1s = map_state_to_mqtt(g_charge_guns[0].state);
    int mqtt_g2s = map_state_to_mqtt(g_charge_guns[1].state);

    // 1号枪数据：充电时上报 枪温(g1t)、车温(g1ct)、协议(g1a)、容量(g1bc) 等动态数据
    build_gun_report_part(0, mqtt_g1s, g1_part, sizeof(g1_part));

    // 2号枪数据：同上，加入 枪温(g2t) 持续上报
    build_gun_report_part(1, mqtt_g2s, g2_part, sizeof(g2_part));

    // 拼装完整 JSON 字符串包并附带 [U4] 协议头发送
    snprintf(json_packet, sizeof(json_packet),
             "[U4]{%s%s\"st\":%.1f,\"sh\":%.1f,\"sps\":%d,\"cps\":%d}\n",
             g1_part, g2_part, sys_temp, sys_humi, g_sys_pow_sup, g_char_pow_sup);

    uart2_send_string(json_packet);
}

/*******************************************************************************
 * 12. 充电枪状态机核心处理
 ******************************************************************************/

// ADC 插拔枪物理检测
static void gun_detect_plug(ChargeGun_t *gun, uint8_t *heartbeat_tick)
{
    unsigned int rawadc = 0;

    if (LzSaradcReadValue(gun->adc_channel, &rawadc) == LZ_HARDWARE_SUCCESS) {
        float adc_val = (float)(rawadc * 3.3 / 1024.0);

        // 注意：插拔枪不再即时发送 aph 命令！aph 是主页(page 2)控件属性，
        // 在其他页面发送会打错控件（曾导致订单页 t2 被隐藏、t4 被显示）。
        // 主页显示统一由 1.5s 周期的自愈刷新（仅 cur_page==2 时发送）负责，
        // 插拔枪后最迟 1.5s 自动更新，功能不受影响。
        if ((adc_val > 1.0 && adc_val < 2.0) && gun->state == PILE_STATE_IDLE) {
            gun->state = PILE_STATE_PLUGGED;
            heartbeat_tick[gun->id] = 0;
            printf("%d号充电枪已插入，进入动态握手与参数配置阶段...\n", gun->id + 1);
        } else if (adc_val > 3.0 && (gun->state == PILE_STATE_PLUGGED || gun->state == PILE_STATE_SUPER)) {
            gun->state = PILE_STATE_IDLE;
            printf("%d号充电枪在未充电状态下被拔出。\n", gun->id + 1);
            reset_gun_parameters(gun);
        } else if (adc_val > 3.0 && gun->state == PILE_STATE_CHARGING) {
            // 意外拔枪触发停止
            gun->stop_reason = 5;
            charge_stop(gun->id);
            gun->state = PILE_STATE_IDLE;
            display_goto_settlement(gun); // 停止充电，通知串口屏切换页面
            printf("%d号充电枪充电中被拔出,正在紧急停止（已登记延迟上报）!\n", gun->id + 1);

            // 启动延迟计数器，不在这里直接 reset_gun_parameters
            gun->delay_report_ticks = DELAY_TICKS_COUNT;
        }
    }
}

// 握手心跳：插枪后未收到握手包时周期性向小车广播充电能力
static void gun_heartbeat_broadcast(ChargeGun_t *gun, uint8_t *heartbeat_tick)
{
    if (gun->state == PILE_STATE_IDLE || gun->state == PILE_STATE_CHARGING || gun->state == PILE_STATE_FULL) {
        heartbeat_tick[gun->id] = 0;
    } else if (gun->state == PILE_STATE_PLUGGED && gun->battery_capacity == 0) {
        heartbeat_tick[gun->id]++;
        if (heartbeat_tick[gun->id] >= 2) {
            heartbeat_tick[gun->id] = 0;
            if (gun->id == 0) {
                uart2_send_string("[U2]VOLT_CHARGE\n");
            } else {
                uart2_send_string("[U3]VOLT_CHARGE\n");
            }
        }
    }
}

// 异步延迟结算计数器轮训检查
static void gun_delay_report_poll(ChargeGun_t *gun)
{
    if (gun->delay_report_ticks > 0) {
        gun->delay_report_ticks--;
        if (gun->delay_report_ticks == 0) {
            // 时间到！读取最后一次电量计，执行结算并向北向上报
            ltc2944_read(gun->id, &(gun->ltcdata));
            calculate_battery_soh(gun);
            send_stop_event_to_u4(gun);
            printf("[延迟机制] %d号枪延时结算完毕，[U4]报文已发出，开始清空参数...\n", gun->id + 1);
            reset_gun_parameters(gun);
        }
    }
}

// 返回值：本轮实际处理掉的事件位（供主循环判断哪些事件可以安全丢弃、哪些必须回写）
static uint32_t handle_gun_state_machine(ChargeGun_t *gun, uint32_t start_event, uint32_t stop_event,
                                         uint32_t super_event, uint32_t full_event, uint32_t global_event)
{
    static uint8_t heartbeat_tick[2] = {0, 0};

    // 异步延迟计数器轮训检查
    gun_delay_report_poll(gun);

    // ADC 插拔枪物理检测
    gun_detect_plug(gun, heartbeat_tick);

    // 握手心跳广播
    gun_heartbeat_broadcast(gun, heartbeat_tick);

    if (global_event == EVENT_CMD_NULL || global_event == 0) {
        if (gun->state == PILE_STATE_CHARGING) {
            ltc2944_read(gun->id, &(gun->ltcdata));
        }
        return 0;
    }

    if (global_event & EVENT_ALARM_TEMP_HIGH) {
        if (gun->state == PILE_STATE_CHARGING) {
            gun->stop_reason = 3;
            charge_stop(gun->id);
            display_goto_settlement(gun); // 停止充电，通知串口屏切换页面
            gun->delay_report_ticks = DELAY_TICKS_COUNT; // 挂起延迟上报
        }
        gun->state = PILE_STATE_FAULT_TEMP;
        printf(">>> 紧急状态：%d号枪由于温度过高，切断电源！\n", gun->id + 1);
        // 注意：由于状态进入了 FAULT_TEMP，reset 移交到计数器清零或复位时处理，这里不直接破坏数据
        return EVENT_ALARM_TEMP_HIGH;
    } else if (global_event & full_event) {
        if (gun->state == PILE_STATE_CHARGING) {
            gun->stop_reason = 2; // 2: 充满断电
            charge_stop(gun->id);
            display_goto_settlement(gun); // 停止充电，通知串口屏切换页面（如充满需单独页面可改此处）
            gun->state = PILE_STATE_FULL;
            printf(">>> 状态切换：%d号枪已充满，断电保护。\n", gun->id + 1);

            gun->delay_report_ticks = DELAY_TICKS_COUNT; // 挂起延迟上报
        }
        return full_event;
    } else if (global_event & super_event) {
        if (gun->state == PILE_STATE_PLUGGED) {
            gun->state = PILE_STATE_SUPER;
            printf(">>> 状态切换：%d号枪快充握手成功，等待启动！\n", gun->id + 1);
        }
        return super_event;
    } else if (global_event & start_event) {
        if (gun->state == PILE_STATE_PLUGGED || gun->state == PILE_STATE_SUPER) {
            if (gun->battery_capacity == 0 || gun->init_soc == 0) {
                // 未握手完毕就收到云端充电指令：依旧启动，但强制慢充，
                // 协议按 0、电池容量按 0 上报（即"无协议盲充"模式）
                printf(">>> [%d号枪] 未握手完毕即收到充电指令，强制按慢充盲启（协议:0, CAP:0上报）。\n", gun->id + 1);
                gun->protocol = 0;
                gun->battery_capacity = 0;

                ltc2944_read(gun->id, &(gun->ltcdata));
                gun->start_mah = gun->ltcdata.mAh;

                charge_start(0, gun->id); // 0: 慢充
                gun->state = PILE_STATE_CHARGING;
                g_last_started_gun = gun->id; // 记录显示源枪号
                printf(">>> 状态切换：%d号枪进入慢充（未握手盲启）。\n", gun->id + 1);
                display_send_page_cmd("page 3"); // 通知串口屏切换到充电中页面
                return start_event;
            }

            printf(">>> 状态切换：%d号充电枪正式锁定参数并启动...\n", gun->id + 1);

            ltc2944_read(gun->id, &(gun->ltcdata));
            gun->start_mah = gun->ltcdata.mAh;

            if (gun->state == PILE_STATE_PLUGGED) {
                charge_start(0, gun->id);
                printf(">>> 状态切换：%d号枪进入标准充电。(初始SOC:%d%%)\n", gun->id + 1, gun->init_soc);
            } else if (gun->state == PILE_STATE_SUPER) {
                charge_start(1, gun->id);
                printf(">>> 状态切换：%d号枪进入超级快充。(初始SOC:%d%%)\n", gun->id + 1, gun->init_soc);
            }
            gun->state = PILE_STATE_CHARGING;
            g_last_started_gun = gun->id; // 记录显示源枪号
            display_send_page_cmd("page 3"); // 通知串口屏切换到充电中页面
        } else {
            printf(">>> %d号枪拒绝启动：当前硬件处于未插枪状态！\n", gun->id + 1);
        }
        return start_event;
    } else if (global_event & stop_event) {
        if (gun->state == PILE_STATE_CHARGING) {
            // 屏幕主动停止已预设 stop_reason=6，此处只在未预设时记默认原因 1
            if (gun->stop_reason == 0) {
                gun->stop_reason = 1; // 1:主动停止
            }
            charge_stop(gun->id);
            display_goto_settlement(gun); // 停止充电，通知串口屏切换页面

            gun->delay_report_ticks = DELAY_TICKS_COUNT; // 挂起延迟上报
        }
        gun->state = PILE_STATE_IDLE;
        printf(">>> 状态切换：%d号枪停止充电，进入结算倒计时。\n", gun->id + 1);
        return stop_event;
    }

    if (gun->state == PILE_STATE_CHARGING) {
        ltc2944_read(gun->id, &(gun->ltcdata));
        printf("[枪%d] 小车同步SOC: %d%%, 电池温度: %.2f °C\n", gun->id + 1, gun->current_soc, gun->car_temp);
    }
    return 0; // 未命中任何本枪事件分支（如另一把枪的事件或未处理的事件位）
}

/*******************************************************************************
 * WS2812B 灯带驱动（A4 长灯条36颗 + A5/C5 短灯条12颗，GPIO 翻转 + 指令周期级延时）
 ******************************************************************************/
// WS2812B 时序要求（800kHz）：T0H≈0.40us T0L≈0.85us，T1H≈0.80us T1L≈0.45us，复位低电平>50us
// 实现方式：GPIO 直接翻转 + subs/bne 汇编延时循环（每轮 2 个时钟周期），
// 发送整帧期间关中断（36颗×24bit×1.25us≈1.1ms），防止任务切换打乱时序
#define WS2812_LED_COUNT     36   // 长灯条(A4)灯珠数
#define WS2812_LED_COUNT_S   12   // 短灯条(A5/C5)灯珠数
#define WS2812_STRIP_COUNT   3
#define WS2812_SYS_CLK_MHZ   40u  // RK2206 实测核频 40MHz（SystemCoreClock=40000000）

#define WS2812_ITERS(ns)     ((WS2812_SYS_CLK_MHZ * (ns)) / 2000u)  // ns -> 循环轮数(2周期/轮)

// ===== 高速直写寄存器（关键！）=====
// LzGpioSetVal 实测开销约 60~80 条指令（stack_chk+查表+HAL_GPIO_SetPinLevel 两级调用），
// 数百 ns 起步，直接把 T0H(400ns) 顶破 0/1 判决线，导致所有 bit 被读成 1（现象：永远全白）。
// 改为直写 GPIO0 数据寄存器，一次 store 仅几个时钟周期。
// GPIO0_BASE=0x41010000（rk2206.h）：DR_L(+0x00)=PA/PB(0~15脚)，DR_H(+0x04)=PC/PD(16~31脚)。
// RK2206 GPIO v2 写使能格式：高 16 位=写掩码，低 16 位=数据。
// PA4→DR_L 第4位；PA5→DR_L 第5位；PC5→DR_H 第5位。
typedef struct {
    volatile uint32_t *dr;  // 数据寄存器地址
    uint32_t bit;           // 寄存器内位号
    uint32_t count;         // 灯珠数
    uint8_t  kill_ends;     // 1=首尾强制熄灭（仅长灯条：第1颗帧首失真恒绿，末颗对称熄灭）
    uint8_t  buf[WS2812_LED_COUNT][3]; // [颗][0=G 1=R 2=B]，WS2812B 按 GRB 顺序发送
} ws2812_strip_t;

static ws2812_strip_t g_strips[WS2812_STRIP_COUNT] = {
    { (volatile uint32_t *)(0x41010000u + 0x00u),  4u, WS2812_LED_COUNT,   0, {{0}} }, // A4 长灯条(全量36颗)
    { (volatile uint32_t *)(0x41010000u + 0x00u),  5u, WS2812_LED_COUNT_S, 0, {{0}} }, // A5 短灯条
    { (volatile uint32_t *)(0x41010000u + 0x04u),  5u, WS2812_LED_COUNT_S, 0, {{0}} }, // C5 短灯条
};
#define WS2812_PIN_LONG  GPIO0_PA4
#define WS2812_PIN_S1    GPIO0_PA5
#define WS2812_PIN_S2    GPIO0_PC5

static inline void ws2812_pin_high(const ws2812_strip_t *s) { *s->dr = (1u << (s->bit + 16u)) | (1u << s->bit); }
static inline void ws2812_pin_low(const ws2812_strip_t *s)  { *s->dr = (1u << (s->bit + 16u)); }

// 运行时自动校准的延时轮数（ws2812_calibrate 填充；兜底值按 WS2812_SYS_CLK_MHZ 假设）
static uint32_t g_it_t0h = WS2812_ITERS(400);
static uint32_t g_it_t0l = WS2812_ITERS(850);
static uint32_t g_it_t1h = WS2812_ITERS(800);
static uint32_t g_it_t1l = WS2812_ITERS(450);

// 指令级忙等：subs + bne，每轮 2 个时钟周期（已经 v9/v13 对照实验证实，勿动）
static void ws2812_delay(uint32_t iters)
{
    __asm volatile (
        "1: subs %0, #1\n"
        "   bne 1b\n"
        : "+r" (iters)
        :
        : "cc");
}

// 发送 1 位：先高后低，码型由高低电平宽度区分
static inline void ws2812_send_bit(const ws2812_strip_t *s, uint8_t bit)
{
    if (bit) {
        ws2812_pin_high(s);
        ws2812_delay(g_it_t1h);
        ws2812_pin_low(s);
        ws2812_delay(g_it_t1l);
    } else {
        ws2812_pin_high(s);
        ws2812_delay(g_it_t0h);
        ws2812_pin_low(s);
        ws2812_delay(g_it_t0l);
    }
}

// 发送单条灯带一帧（调用方需已关中断）
static void ws2812_show_strip(const ws2812_strip_t *s)
{
    for (uint32_t led = 0; led < s->count; led++) {
        for (uint32_t c = 0; c < 3; c++) {
            uint8_t byte = s->buf[led][c];
            for (int b = 7; b >= 0; b--) {
                ws2812_send_bit(s, (byte >> b) & 0x01);
            }
        }
    }
    ws2812_pin_low(s);
}

// 刷新全部灯带：三条数据线各自独立，一次关中断内连续发三帧
// （36+12+12 颗 × 24bit × 1.25us ≈ 1.8ms），末尾统一拉低 >50us 锁存
static void ws2812_show(void)
{
    UINT32 intSave = LOS_IntLock();
    for (uint32_t i = 0; i < WS2812_STRIP_COUNT; i++) {
        ws2812_show_strip(&g_strips[i]);
    }
    LOS_IntRestore(intSave);
    LOS_Msleep(1); // >50us 低电平，触发锁存
}

// 设置某一颗灯颜色（不立即生效，需调 ws2812_show 刷新）
static void ws2812_set(ws2812_strip_t *s, uint32_t index, uint8_t r, uint8_t g, uint8_t b)
{
    if (index >= s->count) return;
    // 长灯条(kill_ends=1)：第 1 颗帧首失真恒绿（软件无解）+ 末颗对称，首尾强制熄灭
    if (s->kill_ends && (index == 0 || index == s->count - 1)) { r = 0; g = 0; b = 0; }
    s->buf[index][0] = g;
    s->buf[index][1] = r;
    s->buf[index][2] = b;
}

// 整带同色
static void ws2812_fill(ws2812_strip_t *s, uint8_t r, uint8_t g, uint8_t b)
{
    for (uint32_t i = 0; i < s->count; i++) {
        ws2812_set(s, i, r, g, b);
    }
}

// 全部熄灭
static void ws2812_clear(void)
{
    for (uint32_t i = 0; i < WS2812_STRIP_COUNT; i++) {
        memset(g_strips[i].buf, 0, sizeof(g_strips[i].buf));
    }
    ws2812_show();
}

// 时序计算：SystemCoreClock（实测 40MHz）× 2周期/轮 换算。
// 实验定论：2 周期/轮是正确答案（v9 验证：36 颗颜色全部正确）。
// 曾试 3 周期口径：脉冲高电平过短，灯带识别为长低电平导致帧中途误复位（只剩尾部几颗亮）。
// 此函数数值已调死，勿动。
extern uint32_t SystemCoreClock; // CMSIS 标准变量（system_rk2206.c 维护，实测 40MHz）

static void ws2812_calibrate(void)
{
    uint32_t clk_mhz = SystemCoreClock / 1000000u;
    if (clk_mhz == 0) clk_mhz = WS2812_SYS_CLK_MHZ; // 兜底 40MHz

    g_it_t0h = (clk_mhz * 400u) / 2000u;  if (g_it_t0h == 0) g_it_t0h = 1; // 40MHz→8轮=400ns
    g_it_t0l = (clk_mhz * 850u) / 2000u;  if (g_it_t0l == 0) g_it_t0l = 1; // 40MHz→17轮=850ns
    g_it_t1h = (clk_mhz * 800u) / 2000u;  if (g_it_t1h == 0) g_it_t1h = 1; // 40MHz→16轮=800ns
    g_it_t1l = (clk_mhz * 450u) / 2000u;  if (g_it_t1l == 0) g_it_t1l = 1; // 40MHz→9轮=450ns

    printf("[WS2812] 时序: 主频=%uMHz, T0H=%u T0L=%u T1H=%u T1L=%u (轮)\n",
           clk_mhz, g_it_t0h, g_it_t0l, g_it_t1h, g_it_t1l);
}

static void ws2812_init(void)
{
    LzGpioInit(WS2812_PIN_LONG);
    PinctrlSet(WS2812_PIN_LONG, MUX_FUNC0, PULL_NONE, DRIVE_LEVEL0);
    LzGpioSetDir(WS2812_PIN_LONG, LZGPIO_DIR_OUT);
    LzGpioSetVal(WS2812_PIN_LONG, LZGPIO_LEVEL_LOW);
    LzGpioInit(WS2812_PIN_S1);
    PinctrlSet(WS2812_PIN_S1, MUX_FUNC0, PULL_NONE, DRIVE_LEVEL0);
    LzGpioSetDir(WS2812_PIN_S1, LZGPIO_DIR_OUT);
    LzGpioSetVal(WS2812_PIN_S1, LZGPIO_LEVEL_LOW);
    LzGpioInit(WS2812_PIN_S2);
    PinctrlSet(WS2812_PIN_S2, MUX_FUNC0, PULL_NONE, DRIVE_LEVEL0);
    LzGpioSetDir(WS2812_PIN_S2, LZGPIO_DIR_OUT);
    LzGpioSetVal(WS2812_PIN_S2, LZGPIO_LEVEL_LOW);
    ws2812_calibrate(); // 先校准时序，再发数据
    ws2812_clear(); // 上电全灭
}

// ===== 启动灯效（开机/开启充电共用，仅颜色不同）=====
// 1) 单亮点左->右扫 2) 单亮点右->左扫 3) 两边向中间聚拢加载 4) 全亮常驻
// 三条灯带同步开始、同步结束：短灯条 12 颗、步数是长灯条 1/3，每步时间 ×3
#define FX_SWEEP_MS 40  // 长灯条扫动每步
#define FX_GATHER_MS 60 // 长灯条聚拢每步

static void ws2812_boot_fx(uint8_t r, uint8_t g, uint8_t b)
{
    // 1) 单亮点从左扫到右（长条 36 步，短条 12 步，每 3 tick 走一步）
    for (uint32_t t = 0; t < WS2812_LED_COUNT; t++) {
        for (uint32_t k = 0; k < WS2812_STRIP_COUNT; k++) {
            ws2812_strip_t *s = &g_strips[k];
            memset(s->buf, 0, sizeof(s->buf));
            ws2812_set(s, t * s->count / WS2812_LED_COUNT, r, g, b);
        }
        ws2812_show();
        LOS_Msleep(FX_SWEEP_MS);
    }

    // 2) 单亮点从右扫回左
    for (int32_t t = WS2812_LED_COUNT - 1; t >= 0; t--) {
        for (uint32_t k = 0; k < WS2812_STRIP_COUNT; k++) {
            ws2812_strip_t *s = &g_strips[k];
            memset(s->buf, 0, sizeof(s->buf));
            ws2812_set(s, (uint32_t)t * s->count / WS2812_LED_COUNT, r, g, b);
        }
        ws2812_show();
        LOS_Msleep(FX_SWEEP_MS);
    }

    // 3) 全灭一拍，然后两边 -> 中间聚拢加载
    ws2812_clear();
    LOS_Msleep(200);
    for (uint32_t t = 0; t < WS2812_LED_COUNT / 2; t++) {
        for (uint32_t k = 0; k < WS2812_STRIP_COUNT; k++) {
            ws2812_strip_t *s = &g_strips[k];
            uint32_t i = t * (s->count / 2) / (WS2812_LED_COUNT / 2);
            ws2812_set(s, i, r, g, b);
            ws2812_set(s, s->count - 1 - i, r, g, b);
        }
        ws2812_show();
        LOS_Msleep(FX_GATHER_MS);
    }

    // 4) 全亮，进入常驻状态
    for (uint32_t k = 0; k < WS2812_STRIP_COUNT; k++) {
        ws2812_fill(&g_strips[k], r, g, b);
    }
    ws2812_show();
}

// 整带同色并刷新（状态切换用，无动画）
static void ws2812_fill_all(uint8_t r, uint8_t g, uint8_t b)
{
    for (uint32_t k = 0; k < WS2812_STRIP_COUNT; k++) {
        ws2812_fill(&g_strips[k], r, g, b);
    }
    ws2812_show();
}

// 状态灯颜色定义
#define LED_COLOR_IDLE_R     20  // 待机：浅蓝
#define LED_COLOR_IDLE_G     50
#define LED_COLOR_IDLE_B     80
#define LED_COLOR_CHG_R      8   // 充电中：浅绿（加重绿调）
#define LED_COLOR_CHG_G      80
#define LED_COLOR_CHG_B      15
#define LED_COLOR_FIRE_R     80  // 火灾：红闪
#define LED_COLOR_FIRE_G     0
#define LED_COLOR_FIRE_B     0

/*******************************************************************************
 * 13. 主业务线程
 ******************************************************************************/

void volt_thread(void)
{
    sht30_data shtdata;
    UINT32 event_ret;
    uint32_t timer_tick = 0; // 1.5秒定时轮询计数器
    uint32_t pow_adc_tick = 0; // PC6 ADC 1秒采样计数器

    // 灯带数据线第一时间拉低并清屏：尽量缩短上电浮空窗口（WS2812B 上电寄存器随机，
    // 浮空杂波会被前几颗灯锁存，表现为"开机先亮几颗"）。彻底根除需硬件在数据线加 10kΩ 下拉。
    ws2812_init();

    volt_basic_peripherals_init();
    charge_gun_init();

    PinctrlSet(GPIO0_PC0, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);
    PinctrlSet(GPIO0_PC1, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);
    // PC6 复用为 ADC 输入（与 PC0/PC1 相同复用号），检测 UPS 反馈的系统供电电压
    PinctrlSet(GPIO0_PC6, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);
    // PC2 配置为 GPIO 输出：电桩供电来源切换，上电默认高电平=市电供应
    // （流程与 CHRG 控制脚一致；复用表显示 PC2 内部复位状态为 up，这里再用 PULL_UP 保持偏置，全程不偏离市电侧）
    LzGpioInit(GPIO0_PC2);
    PinctrlSet(GPIO0_PC2, MUX_FUNC0, PULL_UP, DRIVE_LEVEL0);
    LzGpioSetDir(GPIO0_PC2, LZGPIO_DIR_OUT);
    LzGpioSetVal(GPIO0_PC2, LZGPIO_LEVEL_HIGH);

    // ===== 开机灯效：浅蓝 =====
    printf("[WS2812] 开机灯效: 三灯条 亮点左扫->回扫->聚拢->全亮(浅蓝)\n");
    ws2812_boot_fx(LED_COLOR_IDLE_R, LED_COLOR_IDLE_G, LED_COLOR_IDLE_B);

    while (1) {
        event_ret = LOS_EventRead(&g_coreEvent, VALID_EVENTS_MASK,
                                  LOS_WAITMODE_OR | LOS_WAITMODE_CLR, 0);

        if (event_ret == 0 || (event_ret & 0x02000000)) {
            event_ret = EVENT_CMD_NULL;
        } else {
            event_ret &= VALID_EVENTS_MASK;
        }

        // 两把枪各自处理属于自己的事件分支，返回实际消费掉的事件位
        uint32_t handled = 0;
        handled |= handle_gun_state_machine(&g_charge_guns[0], EVENT_CMD_START_CH1, EVENT_CMD_STOP_CH1,
                                            EVENT_CMD_SUPER_CH1, EVENT_CMD_FULL_CH1, event_ret);
        handled |= handle_gun_state_machine(&g_charge_guns[1], EVENT_CMD_START_CH2, EVENT_CMD_STOP_CH2,
                                            EVENT_CMD_SUPER_CH2, EVENT_CMD_FULL_CH2, event_ret);

        // 关键修复：本轮没来得及处理的事件位（else-if 链一轮只走一个分支）回写到事件组，
        // 下一轮循环继续处理，杜绝事件被连带清空导致"停止充电但屏幕不跳页"的问题
        if (event_ret != EVENT_CMD_NULL) {
            uint32_t unhandled = (uint32_t)event_ret & ~handled;
            if (unhandled != 0) {
                LOS_EventWrite(&g_coreEvent, unhandled);
            }
        }

        sht30_read_temp_humi(&shtdata);
        //printf("Ambient Temperature:%.2f Humidity:%.2f\n", shtdata.temperature, shtdata.humidity);

        // ================== PC6 供电检测：每 1 秒采样打印一次 ==================
        pow_adc_tick++;
        if (pow_adc_tick >= 2) { // 500ms * 2 = 1000ms (1秒)
            pow_adc_tick = 0;
            pow_sup_adc_poll(); // 打印实测电压，刷新 g_sys_pow_sup（带去抖）
        }

        // ================== 定时 1.5 秒向 [U4] 发送精简 JSON 包 ==================
        timer_tick++;
        if (timer_tick >= 3) { // 500ms * 3 = 1500ms (1.5秒)
            timer_tick = 0;
            send_south_data_to_u4(shtdata.temperature, shtdata.humidity);

            // page 5 结算页：屏幕倒计时 10 秒后自动回 page 2。
            // 严格卡 10 秒（7×1.5s=10.5s）——未满 10 秒无论听到什么都不恢复刷新，
            // 杜绝提前恢复把普通数据写到结算页上；满 10 秒后再恢复主页刷新。
            if (g_display_cur_page == 5) {
                g_page5_wait_ticks++;
                if (g_page5_wait_ticks >= 7) { // 7*1.5s=10.5s，屏幕倒计时已结束
                    if (g_pageok_count <= g_page5_baseline) {
                        // 没听到屏幕回主页的 pageok，主动切回 page 2
                        printf("[显示] page 5 满10秒未收到回主页 pageok，主动切回 page 2。\n");
                        display_send_page_cmd("page 2");
                    }
                    g_display_cur_page = 2;
                    g_page5_wait_ticks = 0;
                }
            }

            // 待机状态且确认屏幕处于 page 2 时，才刷新温湿度 t5/t6
            // （TJC 各页控件独立编号，其他页面的 t5/t6 是不同含义，写入会串数据）
            if (g_display_cur_page == 2 &&
                g_charge_guns[0].state != PILE_STATE_CHARGING &&
                g_charge_guns[1].state != PILE_STATE_CHARGING) {
                display_send_env_th(shtdata.temperature, shtdata.humidity);

                // 主页插枪状态自愈刷新：TJC 切页会把 aph 重置回设计默认值，
                // 每次主页周期都按当前实际插枪状态重发，保证"已插枪"显示始终正确
                for (int gi = 0; gi < 2; gi++) {
                    display_set_gun_aph(gi, g_charge_guns[gi].state != PILE_STATE_IDLE ? 1 : 0);
                }
            }

            // 充电中刷新 t1~t9 实时充电参数：以"最后启动的枪"为显示源，
            // 避免另一把枪残留 CHARGING 状态时选错（残留状态下才回退到遍历选择）
            ChargeGun_t *disp_gun = &g_charge_guns[g_last_started_gun];
            if (disp_gun->state != PILE_STATE_CHARGING) {
                if (g_charge_guns[0].state == PILE_STATE_CHARGING) {
                    disp_gun = &g_charge_guns[0];
                } else if (g_charge_guns[1].state == PILE_STATE_CHARGING) {
                    disp_gun = &g_charge_guns[1];
                } else {
                    disp_gun = NULL;
                }
            }
            // 关键：必须确认屏幕当前在充电页(3/4)才刷新实时参数！
            // 否则停止充电跳 page 5 结算页后，若枪的 CHARGING 状态尚未清掉，
            // 这一拍会把 t2/t3 写成电流/功率，覆盖掉结算页刚下发的金额数据
            if (disp_gun != NULL && (g_display_cur_page == 3 || g_display_cur_page == 4)) {
                display_send_charging_params(disp_gun);
            }
        }

        // ================== 状态灯：待机浅蓝 / 充电浅绿 / 火灾红闪 ==================
        {
            static uint8_t s_led_mode = 0;   // 0=待机蓝 1=充电绿 2=火灾红闪
            static uint8_t s_fire_blink = 0;
            uint8_t want;
            if (g_fire_alarm) {
                want = 2;
            } else if (g_charge_guns[0].state == PILE_STATE_CHARGING ||
                       g_charge_guns[1].state == PILE_STATE_CHARGING) {
                want = 1;
            } else {
                want = 0;
            }

            if (want != s_led_mode) {
                if (want == 1) {
                    // 开启充电：同款启动灯效（浅绿），结束后保持绿色常驻
                    ws2812_boot_fx(LED_COLOR_CHG_R, LED_COLOR_CHG_G, LED_COLOR_CHG_B);
                } else if (want == 0) {
                    ws2812_fill_all(LED_COLOR_IDLE_R, LED_COLOR_IDLE_G, LED_COLOR_IDLE_B);
                }
                s_fire_blink = 0;
                s_led_mode = want;
            }

            if (s_led_mode == 2) { // 火灾：红灯每 500ms 来回闪烁，无动画
                s_fire_blink = !s_fire_blink;
                if (s_fire_blink) {
                    ws2812_fill_all(LED_COLOR_FIRE_R, LED_COLOR_FIRE_G, LED_COLOR_FIRE_B);
                } else {
                    ws2812_clear();
                }
            }
        }

        LOS_Msleep(500);
    }
}

/*******************************************************************************
 * 14. 系统任务创建总入口
 ******************************************************************************/

void VoltOS(void)
{
    uart2_comm_init();
    fifo_init(&m_uart2_recv_fifo);

    (VOID)LOS_MuxCreate(&g_uart2_tx_mux); // UART2 发送互斥锁
    (VOID)LOS_EventInit(&g_coreEvent);

    unsigned int thread_id1, thread_id2, thread_id3, thread_id4;
    TSK_INIT_PARAM_S task1 = {0};
    TSK_INIT_PARAM_S task2 = {0};
    TSK_INIT_PARAM_S task3 = {0};
    TSK_INIT_PARAM_S task4 = {0};

    task1.pfnTaskEntry = (TSK_ENTRY_FUNC)volt_thread;
    task1.uwStackSize = 2048;
    task1.pcName = "volt_thread";
    task1.usTaskPrio = 25;
    LOS_TaskCreate(&thread_id1, &task1);

    task2.pfnTaskEntry = (TSK_ENTRY_FUNC)uart2_recv_process;
    task2.uwStackSize = 2048;
    task2.pcName = "uart2_recv_process";
    task2.usTaskPrio = 15;
    LOS_TaskCreate(&thread_id2, &task2);

    task3.pfnTaskEntry = (TSK_ENTRY_FUNC)process_cmd;
    task3.uwStackSize = 4096;
    task3.pcName = "process_cmd";
    task3.usTaskPrio = 16;
    LOS_TaskCreate(&thread_id3, &task3);

    task4.pfnTaskEntry = (TSK_ENTRY_FUNC)display_manager_thread;
    task4.uwStackSize = 2048;
    task4.pcName = "display_manager";
    task4.usTaskPrio = 17;
    LOS_TaskCreate(&thread_id4, &task4);

    printf("\n>>>智能化双枪超充桩系统（JSON完备协议版）启动成功<<<\n");
}

APP_FEATURE_INIT(VoltOS);