import { Me } from '../components/Me';
import { HomePage } from '../components/HomePage';
import { AiServer } from '../components/AiServer';
import { Order } from '../components/Order';
import window from '@ohos.window';
import { scanCore, scanBarcode } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { ChargingStation, getMockStations, ChargingStationStatusApiResponse } from '../model/ChargingStation';
import { AppIPConfig } from '../model/IP';
import axios, { AxiosResponse, AxiosError } from '@ohos/axios'

@Entry
@Component
struct Home {
  @State chargingStations: ChargingStation[] = [];
  @State currentIndex: number = 0;
  @State scanfdata: string = '';
  @State currentInfoWindowStation: ChargingStation | null = null;
  private tabsController: TabsController = new TabsController();

  aboutToAppear() {
    this.setStatusBarImmersive();
    this.loadStationsData();
    this.handleRouteParams();
  }

  onPageShow() {
    this.handleRouteParams();
    // ✅ 切换到"我的"Tab时发送刷新信号
    if (this.currentIndex === 3) {
      AppStorage.setOrCreate('refreshMe', Date.now());
    }
  }

  // 处理路由参数
  handleRouteParams() {
    try {
      const params = router.getParams() as Record<string, Object>;
      if (params && params['tabIndex'] !== undefined) {
        const tabIndex = params['tabIndex'] as number;
        if (tabIndex >= 0 && tabIndex <= 3) {
          setTimeout(() => {
            this.currentIndex = tabIndex;
            this.tabsController.changeIndex(tabIndex);
            // ✅ 切换到"我的"Tab时发送刷新信号
            if (tabIndex === 3) {
              AppStorage.setOrCreate('refreshMe', Date.now());
            }
          }, 100);
        }
      }
    } catch (error) {
      console.error('处理路由参数失败：' + JSON.stringify(error));
    }
  }

  loadStationsData() {
    if (AppStorage.has("ChargingStation")) {
      hilog.info(0x0000, 'Home', '有ChargingStation')
      const storedData = AppStorage.get<ChargingStation[]>('ChargingStation');
      if (storedData) {
        this.chargingStations = storedData;
      }
    } else {
      hilog.info(0x0000, 'Home', '无ChargingStation ' + AppIPConfig.BASE_URL + '/api/nexus/stations')

      axios.get<ChargingStationStatusApiResponse, AxiosResponse<ChargingStationStatusApiResponse>, null>(
        AppIPConfig.BASE_URL + '/api/nexus/stations'
      )
        .then((response: AxiosResponse<ChargingStationStatusApiResponse>) => {
          const apiData: ChargingStationStatusApiResponse = response.data
          hilog.info(0x0000, 'ChargingStation', 'Status: %{public}s', apiData.status)
          hilog.info(0x0000, 'ChargingStation', 'Status: %{public}s', apiData.data)

          AppStorage.setOrCreate<ChargingStation[]>('ChargingStation', apiData.data);
          this.chargingStations = apiData.data;
        })
        .catch((error: AxiosError) => {
          hilog.error(0x0000, 'ChargingStation', 'Request failed: %{public}s', error.message)
        })
    }
    console.error('测试：' + JSON.stringify(this.chargingStations));
    getMockStations();
  }

  startScan() {
    let options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: true,
      enableAlbum: true
    };
    try {
      scanBarcode.startScanForResult(this.getUIContext().getHostContext(), options)
        .then((data: scanBarcode.ScanResult) => {
          hilog.info(0x0001, '[Scan CPSample]',
            `Succeeded in getting ScanResult by promise with options, result is ${JSON.stringify(data)}`);
          this.scanfdata = data.originalValue
          let currentInfoWindowStation: ChargingStation | null = null
          let ifID: boolean = false;
          for (let station of this.chargingStations) {
            if (station.id == this.scanfdata) {
              currentInfoWindowStation = station
              ifID = true;
              break;
            }
          }

          console.error('结束：' + JSON.stringify(currentInfoWindowStation));
          if (ifID) {
            router.pushUrl({
              url: 'pages/Details',
              params: {
                station: currentInfoWindowStation
              }
            }).catch((err: BusinessError) => {
              console.error('页面跳转失败：' + JSON.stringify(err));
            });
          }
        })
        .catch((err: BusinessError) => {
          hilog.error(0x0001, '[Scan CPSample]',
            `Failed to get ScanResult by promise with options. Code:${err.code}, message: ${err.message}`);
        });
    } catch (err) {
      hilog.error(0x0001, '[Scan CPSample]',
        `Failed to start the scanning service. Code:${err.code}, message: ${err.message}`);
    }
  }

  async setStatusBarImmersive() {
    try {
      const windowClass = await window.getLastWindow(getContext(this));
      await windowClass.setWindowSystemBarEnable(['status', 'navigation']);
      await windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#000000',
        navigationBarContentColor: '#000000'
      });
      await windowClass.setWindowLayoutFullScreen(true);
    } catch (error) {
      console.error('设置沉浸式状态栏失败: ' + JSON.stringify(error));
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({
        barPosition: BarPosition.End,
        controller: this.tabsController
      }) {
        TabContent() {
          HomePage()
        }

        TabContent() {
          Order()
        }

        TabContent() {
          AiServer()
        }

        TabContent() {
          Me()
        }
      }
      .animationDuration(300)
      .barHeight(0)
      .scrollable(false)
      .onChange((index: number) => {
        this.currentIndex = index;
        // ✅ 切换到"我的"Tab时发送刷新信号
        if (index === 3) {
          AppStorage.setOrCreate('refreshMe', Date.now());
        }
      })

      // 自定义悬浮胶囊导航栏
      Column() {
        Row() {
          this.NavItem(0, '首页', $r('app.media.home0'), $r('app.media.home1'))
          this.NavItem(1, '订单', $r('app.media.od0'), $r('app.media.od1'))

          Column() {
            Row() {
              Image($r('app.media.scanf'))
                .width(24)
                .height(24)
            }
            .width(56)
            .height(56)
            .margin({ top: 3 })
            .backgroundColor('#badc3d')
            .borderRadius(30)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .shadow({
              radius: 10,
              color: 'rgba(186, 220, 61, 0.5)',
              offsetX: 0,
              offsetY: 3
            })
          }
          .width('20%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            this.startScan();
          })

          this.NavItem(2, '管家', $r('app.media.ai0'), $r('app.media.ai1'))
          this.NavItem(3, '我的', $r('app.media.me0'), $r('app.media.me1'))
        }
        .width('100%')
        .height(60)
        .padding({ left: 4, right: 4 })

        Image($r('app.media.logo3'))
          .height(15)
          .width(65)
          .objectFit(ImageFit.Contain)
          .offset({ x: 1, y: 4 })
      }
      .width('92%')
      .height(90)
      .backgroundColor('rgba(255, 255, 255, 0.92)')
      .borderRadius(40)
      .shadow({
        radius: 12,
        color: 'rgba(0, 0, 0, 0.12)',
        offsetX: 0,
        offsetY: 3
      })
      .border({
        width: 1,
        color: 'rgba(255, 255, 255, 0.3)'
      })
      .backdropBlur(20)
      .margin({ bottom: 16 })
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  NavItem(index: number, title: string, normalIcon: Resource, selectedIcon: Resource) {
    Column() {
      Image(this.currentIndex === index ? selectedIcon : normalIcon)
        .width(31)
        .height(31)
      Text(title)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? '#badc3d' : '#999999')
        .margin({ top: 2 })
        .fontWeight(FontWeight.Medium)
    }
    .margin({ top: 13 })
    .width('20%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.currentIndex = index;
      this.tabsController.changeIndex(index);
    })
  }

  @Builder
  tabBuilder(index: number, title: string, normalIcon: Resource, selectedIcon: Resource) {
    Column() {
      Image(this.currentIndex === index ? selectedIcon : normalIcon)
        .width(24)
        .height(24)
      Text(title)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? '#badc3d' : '#999999')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 4, bottom: 4 })
    .onClick(() => {
      this.currentIndex = index;
      this.tabsController.changeIndex(index);
    })
  }
}