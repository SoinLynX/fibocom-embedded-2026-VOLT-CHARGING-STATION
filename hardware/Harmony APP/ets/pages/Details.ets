import { router, curves } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import axios, { AxiosResponse, AxiosError } from '@ohos/axios'
import { ChargingStation, ChargingStationStatusApiResponse } from '../model/ChargingStation';
import { CreateOrderRequest, CreateOrderResponse, createOrder, getUserBalance,startCharging, StartChargingRequest } from '../model/createOrder';
import { GunStateApiResponse } from '../model/ChargingStation';
import Intl from '@ohos.intl';
import { AppIPConfig } from '../model/IP';

@Entry
@Component
struct Details {
  @State station: ChargingStation | null = null;
  @State scrollOffset: number = 0;
  @State showGunSelector: boolean = false;
  @State selectedGun: number = 1;
  @State showLoading: boolean = false;
  @State showChargingConflictDialog: boolean = false;
  @State showLowBalanceDialog: boolean = false;
  @State private refreshTimer: number = 0;
  // ✅ 枪状态（数字）
  @State gun1State: number = 0;
  @State gun2State: number = 0;

  private scroller: Scroller = new Scroller();

  jumpToGaode(lng: string, lat: string, addressName: string) {
    let uri = 'amapuri://route/plan?' +
      `dlon=${lng}&dlat=${lat}&dname=${addressName}&t=0`
    let want: Want = { uri: uri }
    const content = getContext(this) as common.UIAbilityContext
    content.startAbility(want, (err: BusinessError) => {
    })
  }

  makePhoneCall(phoneNumber: string) {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      let uri = `tel:${phoneNumber}`;
      let want: Want = {
        uri: uri
      };
      context.startAbility(want, (err: BusinessError) => {
        if (err) {
          console.error('拨号失败：' + JSON.stringify(err));
          promptAction.showToast({
            message: '拨号失败，请检查是否安装拨号应用',
            duration: 2000
          });
        }
      });
    } catch (error) {
      console.error('拨号异常：' + JSON.stringify(error));
      promptAction.showToast({
        message: '拨号失败，请稍后重试',
        duration: 2000
      });
    }
  }

  aboutToAppear() {
    try {
      const params = router.getParams() as Record<string, Object>;
      if (params && params['station']) {
        this.station = params['station'] as ChargingStation;
        console.info('接收到充电站数据：' + JSON.stringify(this.station));
      } else {
        console.error('未接收到充电站数据');
      }
    } catch (error) {
      console.error('获取参数失败：' + JSON.stringify(error));
    }

    // ✅ 首次获取枪状态
    this.fetchGunStates();

    // ✅ 启动定时器，每隔1秒刷新
    this.startRefreshTimer();
  }

  aboutToDisappear() {
    this.stopRefreshTimer();
  }

  // ✅ 单独获取充电枪状态
  async fetchGunStates(): Promise<void> {
    try {
      const response: AxiosResponse<GunStateApiResponse> = await axios.get<GunStateApiResponse>(
        AppIPConfig.BASE_URL + '/api/nexus/gun-states'
      );

      if (response.data && response.data.data) {
        this.gun1State = response.data.data.gun1State ?? 0;
        this.gun2State = response.data.data.gun2State ?? 0;
        console.info('✅ 获取枪状态成功 - 1号: ' + this.gun1State + ', 2号: ' + this.gun2State);
      }
    } catch (error) {
      const err: AxiosError = error as AxiosError;
      console.error('获取枪状态失败: ' + err.message);
      // ✅ 如果接口不存在，使用默认值 0（空闲）
      this.gun1State = 0;
      this.gun2State = 0;
    }
  }

  startRefreshTimer(): void {
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
    }
    this.refreshTimer = setInterval(() => {
      this.refreshData();
    }, 1000);
  }

  stopRefreshTimer(): void {
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = 0;
    }
  }

  // ✅ 刷新数据（同时刷新充电桩状态和枪状态）
  async refreshData(): Promise<void> {
    try {
      await this.refreshStationStatus();
      await this.fetchGunStates();
    } catch (error) {
      console.error('刷新数据失败: ' + JSON.stringify(error));
    }
  }

  async refreshStationStatus(): Promise<void> {
    if (!this.station || !this.station.id) {
      return;
    }

    try {
      const response: AxiosResponse<ChargingStationStatusApiResponse> = await axios.get<ChargingStationStatusApiResponse>(
        AppIPConfig.BASE_URL + '/api/nexus/stations'
      );
      if (response.data && response.data.data) {
        const stations: ChargingStation[] = response.data.data;
        const updatedStation = stations.find(s => s.id === this.station?.id);
        if (updatedStation) {
          this.station.status = updatedStation.status;
          console.info('✅ 充电桩状态已更新: ' + updatedStation.status);
        }
      }
    } catch (error) {
      const err: AxiosError = error as AxiosError;
      console.error('刷新充电桩状态失败: ' + err.message);
    }
  }

  getTime(): string {
    let date = new Date();
    let dateFormatter = new Intl.DateTimeFormat('zh-CN', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false
    });
    return dateFormatter.format(date);
  }

  async checkBalance(): Promise<boolean> {
    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
    const balance = await getUserBalance(userId);
    if (balance < 10) {
      this.showGunSelector = false;
      this.showLowBalanceDialog = true;
      return false;
    }
    return true;
  }

  checkChargingStatus(): boolean {
    const isCharging = AppStorage.get<boolean>('isCharging') || false;
    if (isCharging) {
      this.showGunSelector = false;
      this.showChargingConflictDialog = true;
      return true;
    }
    return false;
  }

  // ✅ 获取枪状态文本（显示用）
  getGunStatusText(state: number): string {
    switch (state) {
      case 0: return '闲';
      case 1: return '插枪';
      case 2: return '占用';
      default: return '';
    }
  }

  // ✅ 获取枪状态颜色
  getGunStatusColor(state: number): string {
    switch (state) {
      case 0: return '#4CAF50';
      case 1: return '#FF9800';
      case 2: return '#FF6B6B';
      default: return '#999999';
    }
  }

  // ✅ 判断枪是否可用（0-闲 和 1-插枪 都可用，2-占用 不可用）
  isGunAvailable(state: number): boolean {
    return state === 0 || state === 1;
  }

  // ✅ 判断枪是否空闲（状态0）
  isGunIdle(state: number): boolean {
    return state === 0;
  }

  // ✅ 判断枪是否已插枪（状态1）
  isGunPlugged(state: number): boolean {
    return state === 1;
  }
  async startCharging() {
    if (this.checkChargingStatus()) {
      return;
    }

    const hasEnoughBalance = await this.checkBalance();
    if (!hasEnoughBalance) {
      return;
    }

    // ✅ 检查选中的枪是否可用（0-闲 或 1-插枪）
    const gunState = this.selectedGun === 1 ? this.gun1State : this.gun2State;
    if (!this.isGunAvailable(gunState)) {
      promptAction.showToast({
        message: `充电枪 ${this.selectedGun} 当前${this.getGunStatusText(gunState)}，不可选择`,
        duration: 2000
      });
      return;
    }

    // ✅ 如果枪状态为0（空闲），提示请先插枪
    if (this.isGunIdle(gunState)) {
      promptAction.showToast({
        message: `请先插枪再开始充电`,
        duration: 2000
      });
      return;
    }

    // ✅ 状态1（插枪）- 调用MQTT下发接口
    this.showGunSelector = false;
    this.showLoading = true;

    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';

    // ✅ 1. 调用下发充电指令接口
    const startParams: StartChargingRequest = {
      userId: userId,
      gunNumber: this.selectedGun
    };

    try {
      const startResult = await startCharging(startParams);
      if (startResult.status !== 'success') {
        this.showLoading = false;
        promptAction.showToast({
          message: startResult.message || '下发充电指令失败',
          duration: 2000
        });
        return;
      }
      console.info('✅ 充电指令已下发:', JSON.stringify(startResult.data));

      // ✅ 2. 持续检测枪状态，直到变为3（充电中）或超时
      const checkInterval = 1000; // 每秒检测一次
      const maxRetries = 30; // 最多等待30秒
      let retryCount = 0;

      const checkGunState = () => {
        return new Promise<void>((resolve, reject) => {
          const timer = setInterval(async () => {
            try {
              retryCount++;
              // 重新获取枪状态
              await this.fetchGunStates();
              const currentState = this.selectedGun === 1 ? this.gun1State : this.gun2State;

              console.info(`🔍 检测枪状态: ${currentState} (第${retryCount}次)`);

              if (currentState === 2) {
                // ✅ 枪状态变为3，跳转
                clearInterval(timer);
                resolve();
              } else if (retryCount >= maxRetries) {
                // ❌ 超时
                clearInterval(timer);
                reject(new Error('等待充电启动超时'));
              }
            } catch (error) {
              clearInterval(timer);
              reject(error);
            }
          }, checkInterval);
        });
      };

      // ✅ 3. 等待枪状态变为3
      try {
        await checkGunState();
        this.showLoading = false;

        // ✅ 4. 创建订单
        // 单价从站点档案价格解析（如 "1.21元/度" -> 121 分），解析失败兜底 140
        const priceText = this.station?.price || '';
        const priceYuan = parseFloat(priceText);
        const unitPriceFen = (!isNaN(priceYuan) && priceYuan > 0) ? Math.round(priceYuan * 100) : 140;
        const orderData: CreateOrderRequest = {
          stationName: this.station?.name || "白宫充电站",
          stationAddress: this.station?.address || "华盛顿",
          gunNumber: this.selectedGun,
          startTime: this.getTime(),
          unitPrice: unitPriceFen,
          userId: userId
        };

        const orderResult: CreateOrderResponse = await createOrder(orderData);
        console.info('订单创建结果:', JSON.stringify(orderResult));

        if (orderResult.status === "success" && orderResult.orderId) {
          AppStorage.setOrCreate('currentOrderId', orderResult.orderId);
          AppStorage.setOrCreate('isCharging', true);

          // 跳转到充电页面（pushUrl保留Details在栈中，Charge返回可回到本页）
          router.pushUrl({
            url: 'pages/Charge',
            params: {
              station: this.station,
              gunNumber: this.selectedGun,
              orderId: orderResult.orderId,
              unitPrice: unitPriceFen
            }
          }).catch((err: BusinessError) => {
            console.error('跳转失败：' + JSON.stringify(err));
            promptAction.showToast({
              message: '跳转失败，请重试',
              duration: 2000
            });
          });
        } else {
          promptAction.showToast({
            message: '创建订单失败：' + (orderResult.message || '未知错误'),
            duration: 2000
          });
        }
      } catch (error) {
        this.showLoading = false;
        console.error('等待充电启动超时:', error);
        promptAction.showToast({
          message: '充电启动超时，请检查设备状态',
          duration: 2000
        });
      }

    } catch (error) {
      this.showLoading = false;
      console.error('下发充电指令异常:', error);
      promptAction.showToast({
        message: '下发充电指令异常，请重试',
        duration: 2000
      });
    }
  }

  goToChargingPage() {
    this.showChargingConflictDialog = false;
    router.pushUrl({
      url: 'pages/Charge'
    }).catch((err: BusinessError) => {
      console.error('跳转失败：' + JSON.stringify(err));
      promptAction.showToast({
        message: '跳转失败，请重试',
        duration: 2000
      });
    });
  }

  goToMePage() {
    this.showLowBalanceDialog = false;
    this.showGunSelector = false;
    router.replaceUrl({
      url: 'pages/Home',
      params: {
        tabIndex: 3
      }
    }).catch((err: BusinessError) => {
      console.error('跳转失败：' + JSON.stringify(err));
      promptAction.showToast({
        message: '跳转失败，请重试',
        duration: 2000
      });
    });
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 主内容 - 可滚动
      Scroll(this.scroller) {
        Column() {
          // 顶部图片区域
          Stack() {
            Image($r('app.media.main_charge'))
              .width('100%')
              .height(400)
              .objectFit(ImageFit.Cover)
              .margin({ top: -100 })

            Column() {
            }
            .width('100%')
            .height(90)
            .margin({ top: 210 })
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [
                ['rgba(255, 255, 255, 0)', 0],
                ['rgba(255, 255, 255, 0.02)', 0.15],
                ['rgba(255, 255, 255, 0.05)', 0.3],
                ['rgba(255, 255, 255, 0.10)', 0.5],
                ['rgba(255, 255, 255, 0.15)', 0.7],
                ['rgba(255, 255, 255, 0.25)', 0.85],
                ['rgba(255, 255, 255, 0.35)', 1]
              ]
            })
            .backdropBlur(7)

            Column() {
              Text(this.station?.name || '充电站')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .textAlign(TextAlign.Start)
                .width('100%')
                .margin({ bottom: 8 })

              Row() {
                Circle()
                  .width(10)
                  .height(10)
                  .fill(this.getStatusColor(this.station?.status || 'available'))
                  .margin({ right: 8 })
                Text(this.getStatusText(this.station?.status || 'available'))
                  .fontSize(16)
                  .fontColor(Color.White)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 30 })
            .margin({ top: 250 })
            .zIndex(5)
          }
          .width('100%')
          .height(400)

          Column() {
            Column() {
              Column() {
                Row() {
                  Image($r('app.media.gold'))
                    .width(50)
                    .height(50)
                    .offset({ x: -10 })
                  Text("本电桩已通过VOLT-SUPER快充认证")
                    .fontSize(15)
                    .fontWeight(FontWeight.Bolder)
                    .offset({ x: -5, y: -2 })
                }
              }

              Divider()
                .height(12)
                .color(Color.Gray)
                .padding({ left: 20, right: 20 })

              Column() {
                Row() {
                  Text(this.station?.address || '地址未知')
                    .fontSize(16)
                    .fontColor('#333333')
                    .flexShrink(1)
                  Button() {
                    Image($r('app.media.location'))
                      .width(18)
                      .height(18)
                  }
                  .width(30)
                  .height(30)
                  .backgroundColor('rgba(255, 255, 255, 0.85)')
                  .borderRadius(25)
                  .shadow({
                    radius: 8,
                    color: 'rgba(0,0,0,0.1)',
                    offsetX: 0,
                    offsetY: 2
                  })
                  .margin({ left: 10 })
                  .onClick(async () => {
                    this.jumpToGaode('118.4124', '24.5235', '伏安超冲充电站')
                  })
                }
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .margin({ top: -15, bottom: 12 })

            Row() {
              Column() {
                Text('距离')
                  .fontSize(14)
                  .fontColor('#999999')
                  .margin({ bottom: 4 })
                Text(this.station?.distance || '--')
                  .fontSize(20)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)

              Divider()
                .height(30)
                .vertical(true)
                .margin({ left: 10, right: 10 })

              Column() {
                Text('状态')
                  .fontSize(14)
                  .fontColor('#999999')
                  .margin({ bottom: 4 })
                Text(this.getStatusText(this.station?.status || 'available'))
                  .fontSize(20)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#333333')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)

              Divider()
                .height(30)
                .vertical(true)
                .margin({ left: 10, right: 10 })

              Column() {
                Text('电价')
                  .fontSize(14)
                  .fontColor('#999999')
                  .margin({ bottom: 4 })
                Text(this.station?.price || '--')
                  .fontSize(20)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#badc3d')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .margin({ bottom: 12 })

            Column() {
              Text('电站详情')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .width('100%')
                .margin({ bottom: 16 })

              Row() {
                Text('服务提供：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('24小时充电服务')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })

              Divider()
                .height(1)
                .color('#F0F0F0')

              Row() {
                Text('开放时间：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('周一至周日 00:00-24:00')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })

              Divider()
                .height(1)
                .color('#F0F0F0')

              Row() {
                Text('支付方式：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('微信支付、支付宝、银联')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })

              Divider()
                .height(1)
                .color('#F0F0F0')

              Row() {
                Text('发票类型：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('电子发票 / 增值税专用发票')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })

              Divider()
                .height(1)
                .color('#F0F0F0')

              Row() {
                Text('服务电话：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('400-888-9999')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
                  .margin({ right: 12 })
                Button('拨打')
                  .width(60)
                  .height(28)
                  .fontSize(13)
                  .fontColor(Color.White)
                  .backgroundColor('#badc3d')
                  .borderRadius(14)
                  .onClick(() => {
                    this.makePhoneCall('400-888-9999')
                  })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })

              Divider()
                .height(1)
                .color('#F0F0F0')

              Row() {
                Text('其他服务：')
                  .fontSize(15)
                  .fontColor('#999999')
                Text('休息区、便利店、卫生间、免费WiFi')
                  .fontSize(15)
                  .fontColor('#333333')
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .margin({ bottom: 90 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: -10 })
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .expandSafeArea([SafeAreaType.SYSTEM])

      // 底部固定操作栏
      Column() {
        Divider()
          .height(1)
          .color('#E8E8E8')

        Row() {
          Column() {
            Row() {
              Text(this.station?.price?.replace('/度', '') || '--')
                .fontSize(27)
                .fontWeight(FontWeight.Bold)
                .fontColor('#badc3d')
              Text('/度')
                .fontSize(16)
                .fontColor('#999999')
                .margin({ left: 4 })
            }
          }
          .margin({ right: 20 })

          Blank()

          Button(this.getButtonText())
            .width(140)
            .height(48)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(this.getButtonColor())
            .borderRadius(25)
            .onClick(async () => {
              if (this.station?.status === 'available') {
                if (this.checkChargingStatus()) {
                  return;
                }
                const hasEnoughBalance = await this.checkBalance();
                if (!hasEnoughBalance) {
                  return;
                }
                this.showGunSelector = true;
                this.selectedGun = 1;
              } else if (this.station?.status === 'occupied') {
                promptAction.showToast({
                  message: '该充电桩当前被占用',
                  duration: 2000
                });
              } else {
                promptAction.showToast({
                  message: '该充电桩当前故障，请选择其他充电桩',
                  duration: 2000
                });
              }
            })
            .enabled(this.station?.status === 'available')
            .opacity(1)
        }
        .width('100%')
        .height(80)
        .padding({ left: 20, right: 20 })
        .backgroundColor(Color.White)
        .expandSafeArea([SafeAreaType.SYSTEM])
      }
      .width('100%')
      .position({ bottom: 0 })
      .zIndex(20)
      .backgroundColor(Color.White)

      // ========== 充电枪选择弹窗 ==========
      if (this.showGunSelector) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {
            this.showGunSelector = false;
          })
          .zIndex(30)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('选择充电枪')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 24 })

          Row() {
            // ✅ 1号充电枪
            Stack() {
              Column() {
                Text('🔌')
                  .fontSize(40)
                  .margin({ bottom: 8 })
                Text('1号充电枪')
                  .fontSize(16)
                  .fontColor(
                    this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ?
                      Color.White : '#333333'
                  )
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .height(120)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(
                this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ? '#badc3d' :
                  this.isGunAvailable(this.gun1State) ? '#F5F5F5' : '#E8E8E8'
              )
              .borderRadius(16)
              .border({
                width: this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ? 2 : 1,
                color: this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ?
                  '#badc3d' : '#E0E0E0'
              })
              .shadow({
                radius: this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ? 12 : 4,
                color: this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ?
                  'rgba(186, 220, 61, 0.4)' : 'rgba(0,0,0,0.05)',
                offsetX: 0,
                offsetY: this.selectedGun === 1 && this.isGunAvailable(this.gun1State) ? 4 : 2
              })
              .onClick(() => {
                if (this.isGunAvailable(this.gun1State)) {
                  this.selectedGun = 1;
                } else {
                  promptAction.showToast({
                    message: `1号充电枪${this.getGunStatusText(this.gun1State)}，不可选择`,
                    duration: 1500
                  });
                }
              })

              // ✅ 右上角状态标签 - 只显示0、1、2
              if (this.gun1State === 0 || this.gun1State === 1 || this.gun1State === 2) {
                Row() {
                  Text(this.getGunStatusText(this.gun1State))
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                }
                .backgroundColor(this.getGunStatusColor(this.gun1State))
                .borderRadius(10)
                .offset({ x: 40, y: -45 })
                .margin({ top: 8 })
              }
            }
            .layoutWeight(1)

            // ✅ 中间间距
            Blank()
              .width(12)

            // ✅ 2号充电枪
            Stack() {
              Column() {
                Text('🔌')
                  .fontSize(40)
                  .margin({ bottom: 8 })
                Text('2号充电枪')
                  .fontSize(16)
                  .fontColor(
                    this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ?
                      Color.White : '#333333'
                  )
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .height(120)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(
                this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ? '#badc3d' :
                  this.isGunAvailable(this.gun2State) ? '#F5F5F5' : '#E8E8E8'
              )
              .borderRadius(16)
              .border({
                width: this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ? 2 : 1,
                color: this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ?
                  '#badc3d' : '#E0E0E0'
              })
              .shadow({
                radius: this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ? 12 : 4,
                color: this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ?
                  'rgba(186, 220, 61, 0.4)' : 'rgba(0,0,0,0.05)',
                offsetX: 0,
                offsetY: this.selectedGun === 2 && this.isGunAvailable(this.gun2State) ? 4 : 2
              })
              .onClick(() => {
                if (this.isGunAvailable(this.gun2State)) {
                  this.selectedGun = 2;
                } else {
                  promptAction.showToast({
                    message: `2号充电枪${this.getGunStatusText(this.gun2State)}，不可选择`,
                    duration: 1500
                  });
                }
              })

              // ✅ 右上角状态标签 - 只显示0、1、2
              if (this.gun2State === 0 || this.gun2State === 1 || this.gun2State === 2) {
                Row() {
                  Text(this.getGunStatusText(this.gun2State))
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                }
                .backgroundColor(this.getGunStatusColor(this.gun2State))
                .borderRadius(10)
                .offset({ x: 40, y: -45 })
                .margin({ top: 8 })
              }
            }
            .layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 24 })

          Button('开始充电')
            .width('100%')
            .height(50)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#badc3d')
            .borderRadius(25)
            .onClick(() => {
              this.startCharging();
            })
            .enabled(this.isGunAvailable(
              this.selectedGun === 1 ? this.gun1State : this.gun2State
            ))
            .opacity(this.isGunAvailable(
              this.selectedGun === 1 ? this.gun1State : this.gun2State
            ) ? 1 : 0.5)
        }
        .width('85%')
        .padding({ left: 24, right: 24, top: 32, bottom: 28 })
        .backgroundColor('rgba(255, 255, 255, 0.80)')
        .backdropBlur(20)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.15)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(31)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      // ========== 加载动画弹窗 ==========
      if (this.showLoading) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .zIndex(40)

        Column() {
          LoadingProgress()
            .width(50)
            .height(50)
            .color('#badc3d')
            .margin({ bottom: 20 })

          Text('正在启动充电')
            .fontSize(17)
            .fontColor('#333333')
            .fontWeight(FontWeight.Medium)
        }
        .width(160)
        .height(160)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({
          radius: 20,
          color: 'rgba(0, 0, 0, 0.15)',
          offsetX: 0,
          offsetY: 8
        })
        .zIndex(41)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
      }

      // ========== 充电冲突弹窗 ==========
      if (this.showChargingConflictDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {})
          .zIndex(50)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('⚡')
            .fontSize(56)
            .margin({ bottom: 16 })

          Text('已有充电中的订单')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 12 })

          Text('当前有一笔正在进行中的充电订单，请先完成当前充电再发起新的充电')
            .fontSize(15)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ bottom: 24 })

          Row() {
            Button('查看充电详情')
              .width('100%')
              .height(48)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .backgroundColor('#badc3d')
              .borderRadius(24)
              .onClick(() => {
                this.goToChargingPage();
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding({ left: 24, right: 24, top: 32, bottom: 28 })
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.15)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(51)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      // ========== 余额不足弹窗 ==========
      if (this.showLowBalanceDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {})
          .zIndex(60)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('💰')
            .fontSize(56)
            .margin({ bottom: 16 })

          Text('余额不足')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 12 })

          Text('账户余额低于10元，请先充值')
            .fontSize(15)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ bottom: 24 })

          Row() {
            Button('取消')
              .width('45%')
              .height(48)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#666666')
              .backgroundColor('#F5F5F5')
              .borderRadius(24)
              .onClick(() => {
                this.showLowBalanceDialog = false;
                this.showGunSelector = false;
              })

            Blank()
              .width('10%')

            Button('去充值')
              .width('45%')
              .height(48)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .backgroundColor('#b1c623')
              .borderRadius(24)
              .onClick(() => {
                this.goToMePage();
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding({ left: 24, right: 24, top: 32, bottom: 28 })
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.15)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(61)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F2')
    .expandSafeArea([SafeAreaType.SYSTEM])
  }

  getStatusColor(status: string): string {
    switch (status) {
      case 'available': return '#4CAF50';
      case 'occupied': return '#FF9800';
      case 'broken': return '#F44336';
      default: return '#999';
    }
  }

  getStatusText(status: string): string {
    switch (status) {
      case 'available': return '空闲';
      case 'occupied': return '占用';
      case 'broken': return '故障';
      default: return '未知';
    }
  }

  getButtonText(): string {
    switch (this.station?.status) {
      case 'available': return '立即充电';
      case 'occupied': return '暂无空闲';
      case 'broken': return '暂不可用';
      default: return '暂不可用';
    }
  }

  getButtonColor(): string {
    switch (this.station?.status) {
      case 'available': return '#badc3d';
      case 'occupied': return '#BDBDBD';
      case 'broken': return '#BDBDBD';
      default: return '#BDBDBD';
    }
  }
}