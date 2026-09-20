#include "ohos_init.h"
#include "los_task.h"
#include "los_mux.h"
#include "VoltOS.h"
#include "ltc2944.h"
#include "sht30.h"
#include "lz_hardware.h"
#include "los_swtmr.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bh1750.h"
#include "lz_hardware.h"
#include "lz_hardware/i2c.h"     // 添加这个
#include "iot_pwm.h"     
#include "lcd.h"

// 简谱音调
#define C  262
#define D  294
#define E  330
#define F  349
#define G  392
#define A  440
#define B  494
#define C5 523

// 超声波引脚 —— 根据你的硬件改
#define TRIG_PIN  GPIO0_PB0   // 触发输出
#define ECHO_PIN  GPIO0_PB1   // 回响输入



unsigned int thread_id1=0,thread_id2=0,thread_id3=0;
unsigned int timer_id1,timer_id2;
int num=0;


float hcsr04_get_distance(void)
{
    LzGpioValue val;
    UINT64 start_cycle, end_cycle, timeout_cycle;

    // 触发
    LzGpioSetVal(TRIG_PIN, LZGPIO_LEVEL_HIGH);
    ToyUdelay(10);
    LzGpioSetVal(TRIG_PIN, LZGPIO_LEVEL_LOW);

    // 等 Echo 高，超时 10ms
    timeout_cycle = LOS_SysCycleGet() + (g_sysClock / 100);
    while (1) {
        LzGpioGetVal(ECHO_PIN, &val);
        if (val == LZGPIO_LEVEL_HIGH) break;
        if (LOS_SysCycleGet() > timeout_cycle) return -1;
    }

    start_cycle = LOS_SysCycleGet();

    // 等 Echo 低，超时 30ms
    timeout_cycle = start_cycle + (g_sysClock / 33);
    while (1) {
        LzGpioGetVal(ECHO_PIN, &val);
        if (val == LZGPIO_LEVEL_LOW) break;
        if (LOS_SysCycleGet() > timeout_cycle) return -1;
    }

    end_cycle = LOS_SysCycleGet();
    UINT64 us = OsCycle2US(end_cycle - start_cycle);
    return us / 58.0f;
}

// 初始化超声波
void hcsr04_init(void)
{
    LzGpioInit(TRIG_PIN);
    PinctrlSet(TRIG_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    LzGpioSetDir(TRIG_PIN, LZGPIO_DIR_OUT);
    LzGpioSetVal(TRIG_PIN, LZGPIO_LEVEL_LOW);

    LzGpioInit(ECHO_PIN);
    PinctrlSet(ECHO_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    LzGpioSetDir(ECHO_PIN, LZGPIO_DIR_IN);

    LOS_Msleep(300);  // 等模块稳定
    hcsr04_get_distance();  // 空读一次，丢弃
}

void beep(int freq, int ms) {
    IoTPwmStart(EPWMDEV_PWM5_M0, 50, freq);
    LOS_Msleep(ms);
    IoTPwmStop(EPWMDEV_PWM5_M0);   // 用 IoTPwmStop 静音
    LOS_Msleep(50);
}

void timer1_timeout(UINT32 arg){
    unsigned int ret;
    if(arg < 10){
        printf("timersystime:%llu\n", LOS_TickCountGet());
        num++;
    }
    printf("PWM(%d) end\n", EPWMDEV_PWM5_M0);
    ret = IoTPwmStop(EPWMDEV_PWM5_M0);
    if (ret != 0) {
        printf("IoTPwmStop failed(%d)\n", ret);
    }  
}

void timer2_timeout(UINT32 arg){
    unsigned int ret;
    

    printf("i m time2\n");
    if(num > 10){
        LOS_SwtmrStop(timer_id1);
        printf("[time1]byebye~");
    }
}

void i2c_init()
{
    I2cBusIo m_ia_i2c0m2 = {
    .scl =  {.gpio = GPIO0_PA1, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP},
    .sda =  {.gpio = GPIO0_PA0, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP}, //gpio设置来自gpio.h
    .id = FUNC_ID_I2C0, //推测为i2c编号
    .mode = FUNC_MODE_M2, //推测为i2c模式
    };//来自device.h

        /*初始化I2C*/
    if (I2cIoInit(m_ia_i2c0m2) != LZ_HARDWARE_SUCCESS) //推测为初始化i2c硬件，调整复用模式
    {
        printf("init I2C I2C0 io fail\n");
    }


    /*I2C时钟频率100K*/
    if (LzI2cInit(0, 100000) != LZ_HARDWARE_SUCCESS)
    {
        printf("init I2C I2C0 fail\n");
    }

}

/*******************************************************************************
 * 13. 主业务线程
 ******************************************************************************/

void volt_thread(void)
{   

    unsigned int ret;
    ret = IoTPwmInit(EPWMDEV_PWM5_M0);
    printf("IoTPwmInit(%d) = 0x%x\n", EPWMDEV_PWM5_M0, ret);
    if (ret != 0) {
        printf("IoTPwmInit failed: 0x%x\n", ret);
        return;
    }
    printf("IoTPwmInit OK\n");
   
    
    i2c_init();
    bh1750_init();
    bh1750_data light_data;
    hcsr04_init();
    while(1){
        float cm=hcsr04_get_distance();
         printf("距离：%.1f",cm);
        if(cm>25){
            ret = IoTPwmStart(EPWMDEV_PWM5_M0, 50, 1000);
            if (ret != 0) {
                printf("IoTPwmStart failed(%d)\n", ret);
            }
        }else if(cm<25 &&cm>15){
            ret = IoTPwmStart(EPWMDEV_PWM5_M0, 50, 2000);
            if (ret != 0) {
                printf("IoTPwmStart failed(%d)\n", ret);
            }
        }else if(cm<15){
            ret = IoTPwmStart(EPWMDEV_PWM5_M0, 50, 4000);
            if (ret != 0) {
                printf("IoTPwmStart failed(%d)\n", ret);
            }
        }
        

        LOS_Msleep(800);
    }
   
}

void volt_thread2(void)
{
    while(1){
        UINT32 id=LOS_CurTaskIDGet();
        char * name = LOS_CurTaskNameGet();
        printf("my id is %u,my name is %s\n",id,name);
        LOS_Msleep(1000);
    }
   
}

void volt_thread3(void)
{
    LzGpioInit(GPIO0_PA5);
    PinctrlSet(GPIO0_PA5, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    LzGpioSetDir(GPIO0_PA5, LZGPIO_DIR_OUT);
    LzGpioSetVal(GPIO0_PA5, LZGPIO_LEVEL_LOW);

    LzSaradcInit();
    PinctrlSet(GPIO0_PC7, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);

    /* 按键编码：0=无 1=↑ 2=← 3=↓ 4=→ */
    int cur_key   = 0;   // 当前认定的按键
    int last_key  = 0;   // 上一次采样（消抖用）
    int hold_tick = 0;   // 按住时长计数，1秒 = 10次

    while (1) {
        unsigned int rawadc = 0;
        LOS_Msleep(100);                       // 固定节拍，先睡再采

        if (LzSaradcReadValue(7, &rawadc) != LZ_HARDWARE_SUCCESS)
            continue;

        /* ADC 值 → 按键（<5→  <242↓  <475←  <740↑，边界取相邻中点） */
        int key;
        if (rawadc >= 860)
            key = 0;          // 无按键
        else if (rawadc >= 608)
            key = 1;          // ↑ (740)
        else if (rawadc >= 359)
            key = 2;          // ← (475)
        else if (rawadc >= 121)
            key = 3;          // ↓ (242)
        else
            key = 4;          // → (<5)

        if (cur_key == 0) {
            /* 空闲：连续两次读到同一键 → 确认按下 */
            if (key != 0 && key == last_key) {
                cur_key   = key;
                hold_tick = 0;
            }
        } else {
            if (key == cur_key) {
                /* 持续按住 */
                if (++hold_tick == 10) {
                    printf("key=%d 长按\n", cur_key);   // 长按只发一次
                }
            } else if (key == 0) {
                /* 松手了 */
                if (hold_tick < 10)
                    LzGpioSetVal(GPIO0_PA5, LZGPIO_LEVEL_HIGH);
                    LOS_Msleep(800);
                    LzGpioSetVal(GPIO0_PA5, LZGPIO_LEVEL_LOW);
                    printf("key=%d 短按\n", cur_key);   // 没发过长按 → 短按
                cur_key = 0;
            }
        }

        last_key = key;
    }
}

/*******************************************************************************
 * 14. 系统任务创建总入口run
 ******************************************************************************/

void VoltOS(void)
{   
    TSK_INIT_PARAM_S task1 = {0};
    TSK_INIT_PARAM_S task2 = {0};
    TSK_INIT_PARAM_S task3 = {0};
    
    unsigned int ret;

    ret = LOS_SwtmrCreate(1000, LOS_SWTMR_MODE_PERIOD, timer1_timeout, &timer_id1, 1);
    if (ret == LOS_OK)
    {
        ret = LOS_SwtmrStart(timer_id1);
        if (ret != LOS_OK)
        {
            printf("start timer1 fail ret:0x%x\n", ret);
            return;
        }
    }
    else
    {
        printf("create timer1 fail ret:0x%x\n", ret);
        return;
    }

    ret = LOS_SwtmrCreate(3000, LOS_SWTMR_MODE_PERIOD, timer2_timeout, &timer_id2, 0);
    if (ret == LOS_OK)
    {
        ret = LOS_SwtmrStart(timer_id2);
        if (ret != LOS_OK)
        {
            printf("start timer2 fail ret:0x%x\n", ret);
            return;
        }
    }
    else
    {
        printf("create timer2 fail ret:0x%x\n", ret);
        return;
    }


    task1.pfnTaskEntry = (TSK_ENTRY_FUNC)volt_thread;
    task1.uwStackSize = 2048;
    task1.pcName = "volt_thread";
    task1.usTaskPrio = 25;
    LOS_TaskCreate(&thread_id1, &task1);

    task2.pfnTaskEntry = (TSK_ENTRY_FUNC)volt_thread2;
    task2.uwStackSize = 2048;
    task2.pcName = "volt_thread2";
    task2.usTaskPrio = 23;
    LOS_TaskCreate(&thread_id2, &task2);

    task3.pfnTaskEntry = (TSK_ENTRY_FUNC)volt_thread3;
    task3.uwStackSize = 2048;
    task3.pcName = "volt_thread3";
    task3.usTaskPrio = 22;
    LOS_TaskCreate(&thread_id3, &task3);


    printf("helloOpenHarmony\n");
}

APP_FEATURE_INIT(VoltOS);