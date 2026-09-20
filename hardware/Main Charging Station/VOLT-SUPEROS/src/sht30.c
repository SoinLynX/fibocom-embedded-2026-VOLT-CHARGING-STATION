#include "sht30.h"

#define IA_I2C0                                    0
#define SHT30_ADDR                                 0x44

/***************************************************************
* 函数名称: init_sht30
* 说    明: 初始化SHT30，设置测量周期
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void sht30_init()
{
    uint8_t send_data[2] = {0x22, 0x36};
    LzI2cWrite(IA_I2C0, SHT30_ADDR, send_data, /*send_len = */ 2); 
}


/***************************************************************
* 函数名称: sht30_calc_RH
* 说    明: 湿度计算
* 参    数: u16sRH：读取到的湿度原始数据
* 返 回 值: 计算后的湿度数据
***************************************************************/
float sht30_calc_RH(uint16_t u16sRH)
{
    float humidityRH = 0;

    /*clear bits [1..0] (status bits)*/
    u16sRH &= ~0x0003;
    /*calculate relative humidity [%RH]*/
    /*RH = rawValue / (2^16-1) * 10*/
    humidityRH = (100 * (float)u16sRH / 65535);

    return humidityRH;
}

/***************************************************************
* 函数名称: sht30_calc_temperature
* 说    明: 温度计算
* 参    数: u16sT：读取到的温度原始数据
* 返 回 值: 计算后的温度数据
***************************************************************/
float sht30_calc_temperature(uint16_t u16sT)
{
    float temperature = 0;

    /*clear bits [1..0] (status bits)*/
    u16sT &= ~0x0003;
    /*calculate temperature [℃]*/
    /*T = -45 + 175 * rawValue / (2^16-1)*/
    temperature = (175 * (float)u16sT / 65535 - 45);

    return temperature;
}

/***************************************************************
* 函数名称: sht30_check_crc
* 说    明: 检查数据正确性
* 参    数: data：读取到的数据
            nbrOfBytes：需要校验的数量
            checksum：读取到的校对比验值
* 返 回 值: 校验结果，0-成功 1-失败
***************************************************************/
uint8_t sht30_check_crc(uint8_t *data, uint8_t nbrOfBytes, uint8_t checksum)
{
    uint8_t crc = 0xFF;
    uint8_t bit = 0;
    uint8_t byteCtr ;
    const int16_t POLYNOMIAL = 0x131;

    /*calculates 8-Bit checksum with given polynomial*/
    for(byteCtr = 0; byteCtr < nbrOfBytes; ++byteCtr)
    {
        crc ^= (data[byteCtr]);
        for ( bit = 8; bit > 0; --bit)
        {
            if (crc & 0x80) crc = (crc << 1) ^ POLYNOMIAL;
            else crc = (crc << 1);
        }
    }

    if(crc != checksum)
        return 1;
    else
        return 0;
}


/***************************************************************
* 函数名称: sht30_read_temp_humi
* 说    明: 测量光照强度、温度、湿度
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void sht30_read_temp_humi(sht30_data *pData)
{
    uint8_t rc;
    uint8_t data[3];
    uint16_t tmp;
    uint8_t SHT30_Data_Buffer[6];
    memset(SHT30_Data_Buffer, 0, 6);
    uint8_t send_data[2] = {0xE0, 0x00};

    LzI2cWrite(IA_I2C0, SHT30_ADDR, send_data, /*send_len = */ 2);
    if(LzI2cRead(IA_I2C0, SHT30_ADDR, SHT30_Data_Buffer,/*receive_len = */ 6)!=LZ_HARDWARE_SUCCESS){
        printf("sht30 error\n");
    }

    data[0] = SHT30_Data_Buffer[0];
    data[1] = SHT30_Data_Buffer[1];
    data[2] = SHT30_Data_Buffer[2]; 
    rc = sht30_check_crc(data, 2, data[2]);
    if(!rc)
    {
        tmp = ((uint16_t)data[0] << 8) | data[1];
        pData->temperature = sht30_calc_temperature(tmp);
    }
    
    data[0] = SHT30_Data_Buffer[3];
    data[1] = SHT30_Data_Buffer[4];
    data[2] = SHT30_Data_Buffer[5];
    rc = sht30_check_crc(data, 2, data[2]);
    if(!rc)
    {
        tmp = ((uint16_t)data[0] << 8) | data[1];
        pData->humidity = sht30_calc_RH(tmp);
    }
}