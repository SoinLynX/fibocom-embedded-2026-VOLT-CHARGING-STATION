
#ifndef __VOLTOS_H__
#define __VOLTOS_H__

#include "lz_hardware.h"



void volt_basic_peripherals_init();
void charge_gun_init();
void charge_start(uint8_t speed,uint8_t number);
void charge_stop(uint8_t number);

#endif /*__VOLTOS_H__*/
