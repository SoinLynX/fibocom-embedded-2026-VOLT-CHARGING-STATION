#include "ltc2944.h"

// 移除原本写死的单总线宏定义，改为通用的地址定义
#define LTC2944_ADDR                               0x64


/***************************************************************
* 函数名称: ltc2944_reset_charge
* 说    明: 停止库仑计，将累计电荷寄存器(ACR)清零，然后重新启动库仑计
* 参    数: i2c_id - I2C总线编号 (0 代表 IA_I2C0, 1 代表 IA_I2C1)
* 返 回 值: LZ_HARDWARE_SUCCESS(0) 成功，LZ_HARDWARE_FAILURE(1) 失败
***************************************************************/
uint8_t ltc2944_reset_charge(uint8_t i2c_id)
{
    uint8_t stop_cmd[2] = {0x01, 0xDD};
    if (LzI2cWrite(i2c_id, LTC2944_ADDR, stop_cmd, 2) != LZ_HARDWARE_SUCCESS) {
        printf("[I2C%d] LTC2944 停止模拟积分失败!\n", i2c_id);
        return LZ_HARDWARE_FAILURE;
    }

    uint8_t clear_data[3] = {0x02, 0x00, 0x00}; 
    if (LzI2cWrite(i2c_id, LTC2944_ADDR, clear_data, 3) != LZ_HARDWARE_SUCCESS) {
        printf("[I2C%d] LTC2944 清零累计电荷寄存器失败!\n", i2c_id);
        // 尝试把工作状态恢复，防止芯片一直死在休眠状态
        stop_cmd[1] = 0xDC;
        LzI2cWrite(i2c_id, LTC2944_ADDR, stop_cmd, 2);
        return LZ_HARDWARE_FAILURE;
    }

    uint8_t start_cmd[2] = {0x01, 0xD0};
    if (LzI2cWrite(i2c_id, LTC2944_ADDR, start_cmd, 2) != LZ_HARDWARE_SUCCESS) {
        printf("[I2C%d] LTC2944 恢复模拟积分失败!\n", i2c_id);
        return LZ_HARDWARE_FAILURE;
    }

    printf("[I2C%d] LTC2944 累计电荷已成功清零，重新开始计数...\n", i2c_id);
    return LZ_HARDWARE_SUCCESS;
}


/***************************************************************
* 函数名称: ltc2944_init
* 说    明: 初始化指定I2C总线上的LTC2944
* 参    数: i2c_id - I2C总线编号 (0 代表 IA_I2C0, 1 代表 IA_I2C1)
* 返 回 值: LZ_HARDWARE_SUCCESS(0) 成功，LZ_HARDWARE_FAILURE(1) 失败
***************************************************************/
uint8_t ltc2944_init(uint8_t i2c_id)
{
    int ret;
    // 要写入的数据：[寄存器地址, 配置值]
    // 配置 0xD0 = 1101 0000
    //   B[7:6]=11 (自动模式)
    //   B[5:3]=011 (M=64)
    //   B[2:1]=00 (Alert 关闭)
    //   B[0]=0 (正常工作)
    uint8_t send_data[2] = {0x01, 0xD0};
    LzI2cWrite(i2c_id, LTC2944_ADDR, send_data, /*send_len = */ 2);
    
    uint8_t status_reg = 0x00;
    uint8_t status_val = 0;
    
    // 复位对应总线上的芯片电荷
    ltc2944_reset_charge(i2c_id);
    
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &status_reg, 1, &status_val, 1);
    if (ret == LZ_HARDWARE_SUCCESS) {
        return LZ_HARDWARE_SUCCESS; // LZ_HARDWARE_SUCCESS == 0
    } else {
        printf("[I2C%d] LTC2944 芯片初始化读取状态失败!\n", i2c_id);
        return LZ_HARDWARE_FAILURE; // LZ_HARDWARE_FAILURE == 1
    }
}


/***************************************************************
* 函数名称: ltc2944_read
* 说    明: 测量指定LTC2944的电压、电流、电荷与温度
* 参    数: i2c_id - I2C总线编号 (0 或者 1)
* pData  - 数据存储结构体指针
* 返 回 值: 无
***************************************************************/
void ltc2944_read(uint8_t i2c_id, ltc2944_data *pData)
{
    int ret;
    uint8_t recv_data[2] = {0};
    uint8_t ltc_reg;

    if (pData == NULL) return;

    // 1. 读取芯片温度 (寄存器 0x14)
    ltc_reg = 0x14;
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &ltc_reg, 1, recv_data, 2);
    if (ret == LZ_HARDWARE_SUCCESS) {
        uint16_t raw_temp = ((uint16_t)recv_data[0] << 8) | recv_data[1];
        float temp_k = 510.0 * (float)raw_temp / 65535.0;
        float temp_c = temp_k - 273.15;
        pData->temperature = temp_c;
        // 打印时带上充电枪编号，方便观察
        printf("[枪%d] 芯片温度: %.2f °C\n", i2c_id + 1, temp_c);
    } else {
        printf("[枪%d] LTC2944 读取温度失败!\n", i2c_id + 1);
    }

    // 2. 读取电压 (寄存器 0x08)
    ltc_reg = 0x08;
    memset(recv_data, 0, 2);
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &ltc_reg, 1, recv_data, 2);
    if (ret == LZ_HARDWARE_SUCCESS) {
        uint16_t raw_voltage = ((uint16_t)recv_data[0] << 8) | recv_data[1];
        pData->voltage = 70.8 * ((float)raw_voltage / 65535.0);
        printf("[枪%d] Voltage: %.2f V\n", i2c_id + 1, pData->voltage);
    } else {
        printf("[枪%d] LTC2944 读取电压失败!\n", i2c_id + 1);
    }

    // 3. 读取电流 (寄存器 0x0E)
    ltc_reg = 0x0E;
    memset(recv_data, 0, 2);
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &ltc_reg, 1, recv_data, 2);
    if (ret == LZ_HARDWARE_SUCCESS) {
        uint16_t raw_current = ((uint16_t)recv_data[0] << 8) | recv_data[1];
        pData->current = (0.064 / 0.05) * (((float)raw_current - 32767.0) / 32767.0);
        printf("[枪%d] Current: %.3f A\n", i2c_id + 1, pData->current);
    } else {
        printf("[枪%d] LTC2944 读取电流失败!\n", i2c_id + 1);
    }

    // 4. 读取电荷累计量 (寄存器 0x02)
    ltc_reg = 0x02;
    memset(recv_data, 0, 2);
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &ltc_reg, 1, recv_data, 2);
    if (ret == LZ_HARDWARE_SUCCESS) {
        uint16_t raw_mAh = ((uint16_t)recv_data[0] << 8) | recv_data[1];
        pData->mAh = 0.0053125 * (float)raw_mAh;
        printf("[枪%d] 累计充电: %.4f mAh\n", i2c_id + 1, pData->mAh);
    } else {
        printf("[枪%d] LTC2944 读取放电量失败!\n", i2c_id + 1);
    }

    // 5. 读取状态寄存器 (寄存器 0x00)
    uint8_t status_reg = 0x00;
    uint8_t status_val = 0;
    ret = LzI2cReadReg(i2c_id, LTC2944_ADDR, &status_reg, 1, &status_val, 1);
    if (ret == LZ_HARDWARE_SUCCESS) {
        printf("[枪%d] Status: 0x%02X\n", i2c_id + 1, status_val);
    }
}