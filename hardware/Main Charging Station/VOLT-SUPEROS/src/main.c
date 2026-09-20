#include "VoltOS.h"
#include "ltc2944.h"
#include "sht30.h"
#include "los_task.h"


// i2c地址定义
#define IA_I2C0             0
#define IA_I2C1             1

#define CHRG1_LOW_CTRL_PIN       GPIO0_PB0    
#define CHRG1_HIGH_CTRL_PIN      GPIO0_PB1  
#define CHRG2_LOW_CTRL_PIN       GPIO0_PB6    
#define CHRG2_HIGH_CTRL_PIN      GPIO0_PB4  
#define CHRG1_ADC                GPIO0_PC0
#define CHRG2_ADC                GPIO0_PC1


/***************************************************************
* 函数名称: init_i2c_Device
* 说    明: 初始化所有i2c总线设备
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void init_i2c_Device()
{
    sht30_init();
}



/***************************************************************
* 函数名称: volt_basic_peripherals_init
* 说    明: 初始化i2c
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void volt_basic_peripherals_init()
{
    I2cBusIo m_ia_i2c0m2 = {
    .scl =  {.gpio = GPIO0_PA1, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP},
    .sda =  {.gpio = GPIO0_PA0, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP}, //gpio设置来自gpio.h
    .id = FUNC_ID_I2C0, //推测为i2c编号
    .mode = FUNC_MODE_M2, //推测为i2c模式
    };//来自device.h

    I2cBusIo m_ia_i2c1m2 = {
    .scl =  {.gpio = GPIO0_PA2, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP},
    .sda =  {.gpio = GPIO0_PA3, .func = MUX_FUNC3, .type = PULL_NONE, .drv = DRIVE_KEEP, .dir = LZGPIO_DIR_KEEP, .val = LZGPIO_LEVEL_KEEP}, //gpio设置来自gpio.h
    .id = FUNC_ID_I2C1, //推测为i2c编号
    .mode = FUNC_MODE_M2, //推测为i2c模式
    };//来自device.h

        /*初始化I2C*/
    if (I2cIoInit(m_ia_i2c0m2) != LZ_HARDWARE_SUCCESS) //推测为初始化i2c硬件，调整复用模式
    {
        printf("init I2C I2C0 io fail\n");
    }

    if (I2cIoInit(m_ia_i2c1m2) != LZ_HARDWARE_SUCCESS) //推测为初始化i2c硬件，调整复用模式
    {
        printf("init I2C I2C1 io fail\n");
    }

    /*I2C时钟频率100K*/
    if (LzI2cInit(IA_I2C0, 100000) != LZ_HARDWARE_SUCCESS)
    {
        printf("init I2C I2C0 fail\n");
    }

    /*I2C时钟频率100K*/
    if (LzI2cInit(IA_I2C1, 100000) != LZ_HARDWARE_SUCCESS)
    {
        printf("init I2C I2C1 fail\n");
    }


    init_i2c_Device();
}

/***************************************************************
* 函数名称: charge_gun_init
* 说    明: 初始化充电枪有关外设
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void charge_gun_init(){
    unsigned int ret = 0;
    LzGpioInit(CHRG1_LOW_CTRL_PIN);
    LzGpioInit(CHRG1_HIGH_CTRL_PIN);
    LzGpioInit(CHRG1_ADC);
    LzGpioInit(CHRG2_LOW_CTRL_PIN);
    LzGpioInit(CHRG2_HIGH_CTRL_PIN);
    LzGpioInit(CHRG2_ADC);
    PinctrlSet(CHRG1_LOW_CTRL_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    PinctrlSet(CHRG1_HIGH_CTRL_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    PinctrlSet(CHRG1_ADC, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);
    PinctrlSet(CHRG2_LOW_CTRL_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    PinctrlSet(CHRG2_HIGH_CTRL_PIN, MUX_FUNC0, PULL_DOWN, DRIVE_LEVEL0);
    PinctrlSet(CHRG2_ADC, MUX_FUNC1, PULL_NONE, DRIVE_KEEP);
    LzGpioSetDir(CHRG1_LOW_CTRL_PIN, LZGPIO_DIR_OUT);
    LzGpioSetDir(CHRG1_HIGH_CTRL_PIN, LZGPIO_DIR_OUT);
    LzGpioSetDir(CHRG1_ADC, LZGPIO_DIR_IN);
    LzGpioSetDir(CHRG2_LOW_CTRL_PIN, LZGPIO_DIR_OUT);
    LzGpioSetDir(CHRG2_HIGH_CTRL_PIN, LZGPIO_DIR_OUT);
    LzGpioSetDir(CHRG2_ADC, LZGPIO_DIR_IN);
    LzGpioSetVal(CHRG1_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
    LzGpioSetVal(CHRG1_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
    LzGpioSetVal(CHRG2_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
    LzGpioSetVal(CHRG2_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
    ret = LzSaradcInit();
    if (ret != LZ_HARDWARE_SUCCESS) {
        printf("ADC Init fail\n");
    }
}


/***************************************************************
* 函数名称: standard_charge_start
* 说    明: 启动标准速度充电
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void charge_start(uint8_t speed,uint8_t number){
    if(number==0){
        if(speed==0){
            LzGpioSetVal(CHRG1_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
            LzGpioSetVal(CHRG1_LOW_CTRL_PIN, LZGPIO_LEVEL_HIGH);
        }
        else{
            LzGpioSetVal(CHRG1_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
            LzGpioSetVal(CHRG1_HIGH_CTRL_PIN, LZGPIO_LEVEL_HIGH);
        }
    }else{
        if(speed==0){
            LzGpioSetVal(CHRG2_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
            LzGpioSetVal(CHRG2_LOW_CTRL_PIN, LZGPIO_LEVEL_HIGH);
        }
        else{
            LzGpioSetVal(CHRG2_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
            LzGpioSetVal(CHRG2_HIGH_CTRL_PIN, LZGPIO_LEVEL_HIGH);
        }
    }
    LOS_Msleep(100);
    if(ltc2944_init(number)==LZ_HARDWARE_FAILURE){
        printf("充电枪初始化失败:LTC2944 初始化失败!\n");
    }
    LOS_Msleep(700);
}



/***************************************************************
* 函数名称: charge_stop
* 说    明: 停止充电
* 参    数: 无
* 返 回 值: 无
***************************************************************/
void charge_stop(uint8_t number){
    if(number==0){
        LzGpioSetVal(CHRG1_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
        LzGpioSetVal(CHRG1_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
    }else{
        LzGpioSetVal(CHRG2_LOW_CTRL_PIN, LZGPIO_LEVEL_LOW);
        LzGpioSetVal(CHRG2_HIGH_CTRL_PIN, LZGPIO_LEVEL_LOW);
    }
}




