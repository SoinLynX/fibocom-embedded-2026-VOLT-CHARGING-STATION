#include "bh1750.h"

#define IA_I2C0                                    0
#define BH1750_ADDR                                0x23

/* BH1750FVI 命令定义 */
#define BH1750_POWER_DOWN                          0x00
#define BH1750_POWER_ON                            0x01
#define BH1750_RESET                               0x07
#define BH1750_CONT_H_RES_MODE                     0x10  /* 连续高分辨率模式 1lx分辨率 测量时间120ms */
#define BH1750_CONT_H_RES_MODE2                    0x11  /* 连续高分辨率模式2 0.5lx分辨率 测量时间120ms */
#define BH1750_CONT_L_RES_MODE                     0x13  /* 连续低分辨率模式 4lx分辨率 测量时间16ms */
#define BH1750_ONE_TIME_H_RES_MODE                 0x20  /* 一次高分辨率模式 */
#define BH1750_ONE_TIME_H_RES_MODE2                0x21  /* 一次高分辨率模式2 */
#define BH1750_ONE_TIME_L_RES_MODE                 0x23  /* 一次低分辨率模式 */

/***************************************************************
* 函数名称: bh1750_init
* 说    明: 初始化BH1750FVI，Power ON并设置连续高分辨率模式
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void bh1750_init()
{
    uint8_t cmd;

    /* Power ON */
    cmd = BH1750_POWER_ON;
    LzI2cWrite(IA_I2C0, BH1750_ADDR, &cmd, /*send_len = */ 1);
    LOS_Msleep(10);

    /* 设置连续高分辨率模式 (1lx分辨率) */
    cmd = BH1750_CONT_H_RES_MODE;
    LzI2cWrite(IA_I2C0, BH1750_ADDR, &cmd, /*send_len = */ 1);
    LOS_Msleep(180);  /* 等待首次测量完成，高分辨率模式需120ms以上 */
}


/***************************************************************
* 函数名称: bh1750_calc_lux
* 说    明: 光照强度计算
* 参    数: raw_data：读取到的光照原始数据
* 返 回 值: 计算后的光照强度数据，单位 lx
***************************************************************/
float bh1750_calc_lux(uint16_t raw_data)
{
    float lux = 0;

    /* 计算光照强度 [lx] */
    /* lux = raw_data / 1.2 */
    lux = ((float)raw_data / 1.2f);

    return lux;
}


/***************************************************************
* 函数名称: bh1750_read_lux
* 说    明: 测量光照强度
* 参    数: pData：存储光照数据的结构体指针
* 返 回 值: 无
***************************************************************/
void bh1750_read_lux(bh1750_data *pData)
{
    uint8_t data[2];
    uint16_t raw_data;

    memset(data, 0, 2);

    /* 读取2字节光照数据 (MSB在前) */
    if(LzI2cRead(IA_I2C0, BH1750_ADDR, data, /*receive_len = */ 2) != LZ_HARDWARE_SUCCESS) {
        printf("bh1750 error\n");
        return;
    }

    raw_data = ((uint16_t)data[0] << 8) | data[1];
    pData->lux = bh1750_calc_lux(raw_data);
}