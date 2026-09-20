#ifndef __LTC2944_H__
#define __LTC2944_H__

#include "lz_hardware.h"


typedef struct {
    float voltage;
    float current;
    float mAh;
    float temperature;
} ltc2944_data;

uint8_t ltc2944_init(uint8_t i2c_id);
uint8_t ltc2944_reset_charge(uint8_t i2c_id);
void ltc2944_read(uint8_t i2c_id, ltc2944_data *pData);

#endif