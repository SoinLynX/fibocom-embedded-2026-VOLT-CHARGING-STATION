#ifndef __SHT30_H__
#define __SHT30_H__

#include "lz_hardware.h"

typedef struct
{
    float humidity;/*湿度*/
    float temperature;/*温度*/
} sht30_data;


void sht30_init();
void sht30_read_temp_humi(sht30_data *p_data);

#endif