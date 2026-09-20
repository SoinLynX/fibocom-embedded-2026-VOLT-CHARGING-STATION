#ifndef __BH1750_H
#define __BH1750_H

#include <stdio.h>
#include <string.h>
#include "los_task.h"
#include "lz_hardware.h"
#include "lz_hardware/i2c.h"     // 添加这个

typedef struct {
    float lux;
} bh1750_data;

void bh1750_init(void);
float bh1750_calc_lux(uint16_t raw_data);
void bh1750_read_lux(bh1750_data *pData);

#endif