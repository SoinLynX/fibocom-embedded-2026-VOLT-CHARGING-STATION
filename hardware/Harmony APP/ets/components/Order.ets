// Order.ets
import { router, curves } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { OrderItem, OrderItemLoadMockData, OrderStatus, OrderItemStatusApiResponse } from '../model/Orderltem';
import { hilog } from '@kit.PerformanceAnalysisKit';
import axios, { AxiosResponse, AxiosError } from '@ohos/axios'
import { AppIPConfig } from '../model/IP';

@Component
export struct Order {
  @State orders: OrderItem[] = [];
  @State showDetail: boolean = false;
  @State selectedOrder: OrderItem | null = null;
  @State timerId: number = 0;
  @State isRefreshing: boolean = false;
  @State isFirstLoad: boolean = true;

  // 统计变量
  @State totalCount: number = 0;
  @State pendingCount: number = 0;
  @State chargingCount: number = 0;
  @State completedCount: number = 0;

  aboutToAppear() {
    this.loadOrderData();

    this.timerId = setInterval(() => {
      this.loadOrderData();
    }, 100000);
  }

  aboutToDisappear() {
    if (this.timerId) {
      clearInterval(this.timerId);
      this.timerId = 0;
    }
  }

  async onRefresh(): Promise<void> {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    try {
      await this.fetchOrders();
      promptAction.showToast({
        message: '刷新成功',
        duration: 1500
      });
    } catch (error) {
      promptAction.showToast({
        message: '刷新失败，请重试',
        duration: 1500
      });
    } finally {
      this.isRefreshing = false;
    }
  }

  private loadOrderData() {
    this.fetchOrders()
      .then((orders: OrderItem[]) => {
        this.isFirstLoad = false;
        hilog.info(0x0000, 'OrderItem', '订单加载成功，共 %{public}d 条', orders.length);
      })
      .catch((error: Error) => {
        this.isFirstLoad = false;
        hilog.error(0x0000, 'OrderItem', '加载订单失败: %{public}s', error.message);
      });
  }

  async fetchOrders(status?: string): Promise<OrderItem[]> {
    try {
      const userId = AppStorage.get<string>('userId') || 'VOLT06300001';

      const response: AxiosResponse<OrderItemStatusApiResponse> = await axios.get<
      OrderItemStatusApiResponse,
      AxiosResponse<OrderItemStatusApiResponse>,
      null
      >(
        AppIPConfig.BASE_URL + '/api/nexus/orders',
        {
          params: {
            status: status || undefined,
            userId: userId
          }
        }
      );

      const apiData: OrderItemStatusApiResponse = response.data;
      hilog.info(0x0000, 'OrderPage', 'Status: %{public}s', apiData.status);
      hilog.info(0x0000, 'OrderPage', 'Data长度: %{public}d', apiData.data?.length || 0);

      const orders: OrderItem[] = apiData.data || [];
      if (orders.length > 0) {
        orders.forEach((order, index) => {
          hilog.info(0x0000, 'OrderPage', '订单%d status: %{public}s', index, order.status);
        });
      }

      // 更新数据
      this.orders = orders;
      // 更新统计
      this.updateStatistics();

      AppStorage.setOrCreate<OrderItem[]>('OrderItem', orders);
      return orders;
    } catch (error) {
      hilog.error(0x0000, 'OrderItem', 'Request failed: %{public}s', error.message);
      return [];
    }
  }

  // 更新统计数据
  private updateStatistics(): void {
    let total = this.orders.length;
    let pending = 0;
    let charging = 0;
    let completed = 0;

    this.orders.forEach((order: OrderItem) => {
      const statusText = this.getStatusText(order.status);
      switch (statusText) {
        case '待支付':
          pending++;
          break;
        case '充电中':
          charging++;
          break;
        case '已完成':
          completed++;
          break;
        default:
          break;
      }
    });

    this.totalCount = total;
    this.pendingCount = pending;
    this.chargingCount = charging;
    this.completedCount = completed;

    hilog.info(0x0000, 'OrderStat', '📊 统计: 全部=%d, 待支付=%d, 充电中=%d, 已完成=%d',
      total, pending, charging, completed);
  }

  getStatusText(status: OrderStatus | string): string {
    if (status === OrderStatus.PENDING || status === '待支付') {
      return '待支付';
    }
    if (status === OrderStatus.PAID || status === '已支付') {
      return '已支付';
    }
    if (status === OrderStatus.CHARGING || status === '充电中') {
      return '充电中';
    }
    if (status === OrderStatus.COMPLETED || status === '已完成') {
      return '已完成';
    }
    if (status === OrderStatus.CANCELLED || status === '已取消') {
      return '已取消';
    }
    return '未知';
  }

  getStatusLabel(status: OrderStatus | string): string {
    return this.getStatusText(status);
  }

  getStatusBgColor(status: OrderStatus | string): string {
    const statusText = this.getStatusText(status);
    switch (statusText) {
      case '待支付':
        return '#FFF3E0';
      case '已支付':
        return '#E3F2FD';
      case '充电中':
        return '#FFF3E0';
      case '已完成':
        return '#E8F5E9';
      case '已取消':
        return '#F5F5F5';
      default:
        return '#F5F5F5';
    }
  }

  getStatusTextColor(status: OrderStatus | string): string {
    const statusText = this.getStatusText(status);
    switch (statusText) {
      case '待支付':
        return '#E65100';
      case '已支付':
        return '#1565C0';
      case '充电中':
        return '#E65100';
      case '已完成':
        return '#2E7D32';
      case '已取消':
        return '#757575';
      default:
        return '#757575';
    }
  }

  openOrderDetail(order: OrderItem) {
    this.selectedOrder = order;
    // 延迟 150ms 再弹出：先让卡片的按压深色反馈显示出来，再带动画进场
    setTimeout(() => {
      this.showDetail = true;
    }, 150);
  }

  closeOrderDetail() {
    this.showDetail = false;
    this.selectedOrder = null;
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏
        Row() {
          Text('订单')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor('#b1c623')
            .margin({ top: 35, left: 4 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(Color.White)

        // ✅ 统计栏 - 直接写在 build 里
        Row() {
          // 全部
          Column() {
            Text(this.totalCount.toString())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#333333')
            Text('全部')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Divider()
            .vertical(true)
            .height(24)
            .strokeWidth(1.5)
            .color('#E0E0E0')
            .margin({ left: 4, right: 4 })

          // 待支付
          Column() {
            Text(this.pendingCount.toString())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#E65100')
            Text('待支付')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Divider()
            .vertical(true)
            .height(24)
            .strokeWidth(1.5)
            .color('#E0E0E0')
            .margin({ left: 4, right: 4 })

          // 充电中
          Column() {
            Text(this.chargingCount.toString())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FF9800')
            Text('充电中')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Divider()
            .vertical(true)
            .height(24)
            .strokeWidth(1.5)
            .color('#E0E0E0')
            .margin({ left: 4, right: 4 })

          // 已完成
          Column() {
            Text(this.completedCount.toString())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#4CAF50')
            Text('已完成')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })
        .backgroundColor(Color.White)
        .margin({ bottom: 12 })

        Refresh({
          refreshing: this.isRefreshing,
          builder: this.customRefreshBuilder
        }) {
          Scroll() {
            Column() {
              if (this.orders.length > 0) {
                Column() {
                  ForEach(this.orders, (order: OrderItem) => {
                    Column() {
                      this.OrderCard(order)
                    }
                    .width('100%')
                    .onClick(() => {
                      this.openOrderDetail(order);
                    })
                  }, (order: OrderItem) => order.id)
                }
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 20 })

                Column()
                  .width('100%')
                  .height(80)
              } else {
                Column() {
                  Image($r('app.media.close'))
                    .width(120)
                    .height(120)
                    .margin({ bottom: 20 })
                  Text('暂无订单')
                    .fontSize(18)
                    .fontColor('#999999')
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
              }
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.onRefresh();
        })
        .refreshOffset(80)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5F5')

      if (this.showDetail && this.selectedOrder) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {
            this.closeOrderDetail();
          })
          .zIndex(10)
          // 遮罩淡入淡出（animation 挂在 TransitionEffect 上才生效）
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 200, curve: Curve.EaseOut }))

        Column() {
          this.OrderDetailContent(this.selectedOrder)
        }
        .width('90%')
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.2)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(11)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        // 弹簧曲线：像系统弹窗一样从更小尺寸弹出，带轻微回弹
        // （animation 挂在 TransitionEffect 上，驱动进场/离场全过程）
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  @Builder
  customRefreshBuilder() {
    Column() {
      LoadingProgress()
        .width(30)
        .height(30)
        .color('#b1c623')
      Text('加载中...')
        .fontSize(14)
        .fontColor('#999999')
        .margin({ top: 8 })
    }
    .width('100%')
    .height(60)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(255,255,255,0.9)')
  }

  @Builder
  OrderCard(order: OrderItem) {
    Column() {
      Row() {
        Text(`订单号：${order.id}`)
          .fontSize(14)
          .fontColor('#666666')
        Blank()
        Text(order.startTime?.substring(0, 16) || '')
          .fontSize(13)
          .fontColor('#999999')
      }
      .width('100%')
      .margin({ bottom: 12 })

      Row() {
        Column() {
          Text(order.stationName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
          Text(order.stationAddress)
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text(`¥${((order.totalAmount ?? 0) / 100).toFixed(2)}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#badc3d')
          Text(`${(order.electricity / 100).toFixed(2)}度`)
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .margin({ bottom: 12 })

      Row() {
        Row() {
          Text(`🔌 ${order.gunNumber}号枪`)
            .fontSize(13)
            .fontColor('#666666')
        }
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor('#F5F5F5')
        .borderRadius(12)

        Blank()

        Text(order.duration)
          .fontSize(13)
          .fontColor('#666666')
          .margin({ right: 12 })

        Text(this.getStatusLabel(order.status))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.getStatusTextColor(order.status))
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .backgroundColor(this.getStatusBgColor(order.status))
          .borderRadius(12)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(12)
    .stateStyles({
      normal: { .backgroundColor(Color.White) },
      pressed: { .backgroundColor('#DCDCDC') }
    })
    .shadow({
      radius: 12,
      color: 'rgba(0, 0, 0, 0.15)',
      offsetX: 0,
      offsetY: 6
    })
    .margin({ bottom: 12 })
  }

  @Builder
  OrderDetailContent(order: OrderItem) {
    Column() {
      Row() {
        Text('订单详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
        Blank()
        Button() {
          Image($r('app.media.close'))
            .width(20)
            .height(20)
        }
        .width(36)
        .height(36)
        .backgroundColor('rgba(0,0,0,0.05)')
        .borderRadius(18)
        .onClick(() => {
          this.closeOrderDetail();
        })
      }
      .width('100%')
      .margin({ bottom: 12 })

      Row() {
        Text(this.getStatusLabel(order.status))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.getStatusTextColor(order.status))
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .backgroundColor(this.getStatusBgColor(order.status))
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 12 })

      Column() {
        this.DetailRow('订单编号', order.id)
        this.DetailRow('充电站', order.stationName)
        this.DetailRow('充电地址', order.stationAddress)
        this.DetailRow('充电枪', `${order.gunNumber}号枪`)
        this.DetailRow('开始时间', order.startTime)
        if (order.endTime) {
          this.DetailRow('结束时间', order.endTime)
        }
        this.DetailRow('充电时长', order.duration)
        this.DetailRow('充电量', `${(order.electricity / 100).toFixed(2)} 度`)
        this.DetailRow('单价', `¥${(order.unitPrice / 100).toFixed(2)} / 度`)

        Divider()
          .height(1)
          .color('#F0F0F0')
          .margin({ top: 8, bottom: 8 })

        Row() {
          Text('总计金额')
            .fontSize(16)
            .fontColor('#666666')
          Blank()
          Text(`¥${(order.totalAmount / 100).toFixed(2)}`)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#badc3d')
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }
      .width('100%')
      .margin({ bottom: 12 })

      if (order.status === OrderStatus.PENDING || order.status === '待支付') {
        Row() {
          Button('取消订单')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontColor('#999999')
            .backgroundColor('#F5F5F5')
            .borderRadius(22)
            .onClick(() => {
              promptAction.showToast({
                message: '订单已取消',
                duration: 2000
              });
              this.closeOrderDetail();
            })

          Blank()
            .width('10%')

          Button('立即支付')
            .width('45%')
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#badc3d')
            .borderRadius(22)
            .onClick(() => {
              promptAction.showToast({
                message: '正在跳转到支付页面...',
                duration: 2000
              });
            })
        }
        .width('100%')
      } else if (order.status === OrderStatus.CHARGING || order.status === '充电中') {
        Button('查看充电详情')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor('#badc3d')
          .borderRadius(24)
          .onClick(() => {
            router.pushUrl({
              url: 'pages/Charge',
              params: {
                orderId: order.id
              }
            }).catch((err: Error) => {
              console.error('跳转失败:', err);
            });
          })
      } else if (order.status === OrderStatus.COMPLETED || order.status === '已完成') {
        Button('再次充电')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor('#badc3d')
          .borderRadius(24)
          .onClick(() => {
            promptAction.showToast({
              message: '正在跳转到充电站...',
              duration: 2000
            });
          })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 20, bottom: 24 })
  }

  @Builder
  DetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor('#999999')
        .width(80)
      Text(value)
        .fontSize(15)
        .fontColor('#333333')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
}