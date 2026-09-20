import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ChargingStation, ChargingStationStatusApiResponse } from '../model/ChargingStation';
import { AppIPConfig } from '../model/IP';
import axios, { AxiosResponse } from '@ohos/axios';
import { hilog } from '@kit.PerformanceAnalysisKit';

// ✅ 统计卡片参数接口（ArkTS 不允许内联对象字面量类型）
interface StatCardParam {
  label: string;
  count: number;
  color: string;
}

// ===== 无权限提示弹窗（沿用全站卡片风格：品牌绿 + 圆角白卡） =====
@CustomDialog
struct NoPermissionDialog {
  controller: CustomDialogController;

  build() {
    Column() {
      Text('无法查看')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
        .margin({ bottom: 12 })
      Text('该充电站查看权限未向您账户开放，请联系超级管理员')
        .fontSize(14)
        .fontColor('#666666')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 20 })
      Button('我知道了')
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor(Color.White)
        .backgroundColor('#b1c623')
        .borderRadius(21)
        .onClick(() => {
          this.controller.close();
        })
    }
    .width('78%')
    .padding({ left: 24, right: 24, top: 24, bottom: 24 })
    .backgroundColor(Color.White)
    .borderRadius(20)
  }
}

@Entry
@Component
struct Manage {
  @State chargingStations: ChargingStation[] = [];
  @State private refreshTimer: number = 0;
  @State isRefreshing: boolean = false;

  // 无权限弹窗控制器
  private noPermDialog: CustomDialogController = new CustomDialogController({
    builder: NoPermissionDialog(),
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    this.loadStationsData();
    // 每 5 秒刷新一次状态，后台管理对实时性要求低一些
    this.refreshTimer = setInterval(() => {
      this.loadStationsData();
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = 0;
    }
  }

  // ✅ 下拉刷新（参照 Order 页逻辑）
  async onRefresh(): Promise<void> {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    try {
      await this.loadStationsData();
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

  async loadStationsData(): Promise<void> {
    try {
      const response: AxiosResponse<ChargingStationStatusApiResponse> =
        await axios.get<ChargingStationStatusApiResponse>(
          AppIPConfig.BASE_URL + '/api/nexus/stations'
        );
      if (response.data?.data) {
        this.chargingStations = response.data.data;
      }
    } catch (error) {
      hilog.error(0x0000, 'Manage', '加载充电桩数据失败: %{public}s', JSON.stringify(error));
    }
  }

  // ===== 统计方法 =====
  getCountByStatus(status: string): number {
    return this.chargingStations.filter((s: ChargingStation) => s.status === status).length;
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

  // ===== 统计小卡片 =====
  @Builder
  statCard($$: StatCardParam) {
    Column() {
      Text(`${$$.count}`)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor($$.color)
      Text($$.label)
        .fontSize(12)
        .fontColor('#888888')
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .height(72)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(255, 255, 255, 0.55)')
    .backdropBlur(20)
    .borderRadius(14)
    .shadow({
      radius: 10,
      color: 'rgba(0, 0, 0, 0.06)',
      offsetX: 0,
      offsetY: 3
    })
  }

  // ===== 下拉刷新指示器（参照 Order 页） =====
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

  // ===== 充电桩卡片（沿用抽屉卡片样式，微调美化） =====
  @Builder
  stationCard(station: ChargingStation) {
    Column() {
      Row() {
        Image($r('app.media.main_charge'))
          .width(60)
          .height(60)
          .borderRadius(10)
          .backgroundColor('#F0F0F0')
          .objectFit(ImageFit.Cover)
          .margin({ right: 12 })

        Column() {
          Row() {
            Circle()
              .width(8)
              .height(8)
              .fill(this.getStatusColor(station.status))
              .margin({ right: 5 })
            Text(station.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
          }
          .margin({ bottom: 4 })

          Row() {
            Text(station.address)
              .fontSize(12)
              .fontColor('#999999')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .margin({ bottom: 4 })

          Row() {
            Text(`价格: ${station.price}`)
              .fontSize(12)
              .fontColor('#666666')
          }
        }
        .layoutWeight(1)

        Column() {
          Text(this.getStatusText(station.status))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .backgroundColor(this.getStatusColor(station.status))
            .borderRadius(12)
        }
        .margin({ left: 10 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(14)
    .stateStyles({
      normal: { .backgroundColor('rgba(255, 255, 255, 0.85)') },
      pressed: { .backgroundColor('rgba(200, 200, 200, 0.9)') }
    })
    .shadow({
      radius: 12,
      color: 'rgba(0, 0, 0, 0.07)',
      offsetX: 0,
      offsetY: 4
    })
    .onClick(() => {
      // 仅 VOLT0001 对本账户开放，其余桩弹出无权限提示
      if (station.id !== 'VOLT0001') {
        this.noPermDialog.open();
        return;
      }
      router.pushUrl({
        url: 'pages/Station',
        params: { station: station }
      }).catch((err: BusinessError) => {
        console.error('页面跳转失败：' + JSON.stringify(err));
      });
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ===== 页面背景：浅灰 + 顶部品牌色渐变 =====
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Top,
          colors: [
            ['#eef3d8', 0],
            ['#f5f6f7', 0.35],
            ['#f5f6f7', 1]
          ]
        })

      // ===== 主内容（可滑动部分） =====
      Column() {
        // 列表标题
        Row() {
          Text(`全部充电桩 (${this.chargingStations.length})`)
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 205, bottom: 12 })

        // 卡片列表（直接陈列，无抽屉，支持下拉刷新）
        Refresh({ refreshing: this.isRefreshing, builder: this.customRefreshBuilder }) {
          List({ space: 10 }) {
            ForEach(this.chargingStations, (station: ChargingStation) => {
              ListItem() {
                this.stationCard(station)
              }
            })
          }
          .layoutWeight(1)
          .padding({ left: 20, right: 20 })
          .scrollBar(BarState.Off)
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

      // ===== 顶部虚化栏（与首页同一风格） =====
      Column() {
        Row()
          .height('30%')

        Row() {
          Text("管理")
            .fontSize(32)
            .fontColor('#b1c623')
            .fontWeight(FontWeight.Bolder)
            .textAlign(TextAlign.Start)

          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
        .height(50)

        // ===== 统计卡片（固定在顶部栏内，不滑动） =====
        Row({ space: 10 }) {
          this.statCard({ label: '总数', count: this.chargingStations.length, color: '#b1c623' })
          this.statCard({ label: '空闲', count: this.getCountByStatus('available'), color: '#4CAF50' })
          this.statCard({ label: '占用', count: this.getCountByStatus('occupied'), color: '#FF9800' })
          this.statCard({ label: '故障', count: this.getCountByStatus('broken'), color: '#F44336' })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 12 })
      }
      .width('100%')
      .height(200)
      .linearGradient({
        direction: GradientDirection.Top,
        colors: [
          ['rgba(255, 255, 255, 0)', 0],
          ['rgba(255, 255, 255, 0)', 0.3],
          ['rgba(255, 255, 255, 0.15)', 0.6],
          ['rgba(255, 255, 255, 0.3)', 0.85],
          ['rgba(255, 255, 255, 0.35)', 1]
        ]
      })
      .backdropBlur(15)
    }
    .height('100%')
    .width('100%')
  }
}