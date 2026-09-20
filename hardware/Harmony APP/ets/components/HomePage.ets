import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { ChargingCard } from '../components/ChargingCard';
import { geoLocationManager } from '@kit.LocationKit';
import { router, curves } from '@kit.ArkUI';
import { AppIPConfig } from '../model/IP';
import {
  abilityAccessCtrl,
  bundleManager,
  common,
  PermissionRequestResult,
  Permissions
} from '@kit.AbilityKit';
import { ChargingStation, getMockStations, ChargingStationStatusApiResponse } from '../model/ChargingStation';
import axios, { AxiosResponse, AxiosError } from '@ohos/axios'
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { formProvider, formBindingData } from '@kit.FormKit';
import { checkChargingOrder, ChargingOrderData, getGunStatus } from '../model/createOrder';

// ✅ 充电卡片数据接口
interface ChargingCardData {
  isCharging: boolean;
  batteryLevel: number;
  chargeTime: string;
}

// applyDistances 排序用的临时结构（ArkTS 要求对象字面量有显式类型）
interface StationWithDist {
  station: ChargingStation;
  km: number;
}

@Component
export struct HomePage {
  @State mapOptions: mapCommon.MapOptions = {
    position: {
      target: { latitude: 0, longitude: 0 },
      zoom: 12
    },
  };
  @State mapLoaded: boolean = false;
  @State isDrawerOpen: boolean = false;
  @State drawerOffset: number = 0;
  // 用户定位（已转GCJ02），用于计算站点距离
  @State userLat: number = 0;
  @State userLng: number = 0;
  @State hasUserLocation: boolean = false;
  @StorageLink('chargingStations') chargingStations: ChargingStation[] = [];
  @State selectedStation: ChargingStation | null = null;
  @State currentInfoWindowStation: ChargingStation | null = null;
  @State showAdImage: boolean = false;
  @StorageLink('isCharging') isCharging: boolean = false;
  @StorageLink('chargePercent') chargePercent: number = 0;
  @StorageLink('chargeTime') chargeTime: string = '00:00:00';
  @StorageLink('token') token: string = '';
  @State chargingOrderData: ChargingOrderData | null = null;
  @State private refreshTimer: number = 0;
  private lastStationsSignature: string = '';

  // ✅ 充电卡片独立数据
  @State chargingCardData: ChargingCardData = {
    isCharging: false,
    batteryLevel: 0,
    chargeTime: '00:00:00'
  };

  // ✅ 保存当前打开的信息窗对应的标记ID
  private currentOpenMarkerId: string | null = null;

  private callback?: AsyncCallback<map.MapComponentController>;
  private mapController?: map.MapComponentController;
  private mapEventManager?: map.MapEventManager;
  private startY: number = 0;
  private markers: map.Marker[] = [];
  private markerStationMap: Map<string, ChargingStation> = new Map();

  @BuilderParam customInfoWindow: ($$: map.MarkerDelegate) => void = this.customInfoWindowBuilder;

  aboutToAppear(): void {
    const hasShownAd = AppStorage.get<boolean>('hasShownAd');
    if (hasShownAd === undefined) {
      this.showAdImage = true;
      AppStorage.setOrCreate('hasShownAd', true);
    } else {
      this.showAdImage = false;
    }

    this.checkChargingStatus();
    this.getLocationAndInitMap();

    // ✅ 首次加载数据
    this.loadStationsData();

    // ✅ 启动定时器，每隔1秒刷新
    this.startRefreshTimer();


    this.customInfoWindow = ($$: map.MarkerDelegate) => { this.customInfoWindowBuilder($$) };
  }

  aboutToDisappear(): void {
    // ✅ 清除定时器，防止内存泄漏
    this.stopRefreshTimer();
  }

  // ✅ 启动定时器
  startRefreshTimer(): void {
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
    }
    this.refreshTimer = setInterval(() => {
      this.refreshData();
    }, 1000);
  }

  // ✅ 停止定时器
  stopRefreshTimer(): void {
    if (this.refreshTimer > 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = 0;
    }
  }



  // ✅ 刷新数据（定时器调用）
  async refreshData(): Promise<void> {
    try {
      // 1. 刷新充电桩数据
      await this.loadStationsData();

      // 2. 刷新充电中的订单状态
      await this.checkChargingStatus();

      // 3. 如果有充电中的订单，更新充电卡片和时长
      if (this.isCharging && this.chargingOrderData) {
        // ✅ 从订单 startTime 计算真实已充时长
        this.chargeTime = this.calculateChargeTime(this.chargingOrderData.startTime || '');
        // ✅ 更新充电卡片数据
        await this.updateChargingCardStatus();
      }
    } catch (error) {
      const err: AxiosError = error as AxiosError;
      hilog.error(0x0000, 'HomePage', '刷新数据失败: %{public}s', err.message || JSON.stringify(err));
    }
  }

  // ✅ 修改后的 updateChargingCardStatus
  async updateChargingCardStatus(): Promise<void> {
    try {
      if (!this.isCharging || !this.chargingOrderData) {
        return;
      }

      const gunNumber = this.chargingOrderData.gunNumber || 1;
      const result = await getGunStatus(gunNumber);

      if (result.status === 'success') {
        const data = result.data;
        this.chargingCardData = {
          isCharging: true,
          batteryLevel: data.soc || 0,
          chargeTime: this.calculateChargeTime(this.chargingOrderData.startTime || '')
        };
        // 同步更新 Storage
        AppStorage.setOrCreate('chargePercent', data.soc || 0);
        AppStorage.setOrCreate('chargeTime', this.chargingCardData.chargeTime);
        console.log('✅ 充电卡片数据已更新: SOC=', data.soc);
      } else {
        this.chargingCardData = {
          isCharging: true,
          batteryLevel: this.chargePercent || 0,
          chargeTime: this.calculateChargeTime(this.chargingOrderData.startTime || '')
        };
      }
    } catch (error) {
      console.error('❌ 更新充电卡片状态失败:', error);
      if (this.chargingOrderData) {
        this.chargingCardData = {
          isCharging: true,
          batteryLevel: this.chargePercent || 0,
          chargeTime: this.calculateChargeTime(this.chargingOrderData.startTime || '')
        };
      }
    }
  }

  // Haversine 公式：两个经纬度之间的球面距离（公里）
  calcDistanceKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const rad = (d: number): number => d * Math.PI / 180;
    const R = 6371.0; // 地球半径 km
    const dLat = rad(lat2 - lat1);
    const dLng = rad(lng2 - lng1);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(rad(lat1)) * Math.cos(rad(lat2)) *
        Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 2 * R * Math.asin(Math.sqrt(a));
  }

  formatDistance(km: number): string {
    if (km < 1) {
      return `${Math.round(km * 1000)}m`;
    }
    return `${km.toFixed(1)}km`;
  }

  // 根据用户定位计算每个站点距离、写回 distance 字段并按距离升序排序
  applyDistances(stations: ChargingStation[]): ChargingStation[] {
    if (!this.hasUserLocation) {
      return stations;
    }
    const withDist: StationWithDist[] = stations.map((s: ChargingStation): StationWithDist => {
      const km = this.calcDistanceKm(this.userLat, this.userLng, s.latitude, s.longitude);
      const item: StationWithDist = { station: s, km: km };
      return item;
    });
    withDist.sort((a, b) => a.km - b.km);
    withDist.forEach(item => {
      item.station.distance = this.formatDistance(item.km);
    });
    return withDist.map(item => item.station);
  }

  async loadStationsData(): Promise<void> {
    try {
      const response: AxiosResponse<ChargingStationStatusApiResponse> =
        await axios.get<ChargingStationStatusApiResponse>(
          AppIPConfig.BASE_URL + '/api/nexus/stations'
        );
      if (response.data?.data) {
        // 数据签名对比：无变更则跳过，避免标点闪动
        const raw = response.data.data;
        const signature = raw.map((s: ChargingStation) =>
        `${s.id}|${s.status}|${s.name}|${s.address}|${s.price}|${s.latitude}|${s.longitude}`
        ).join(';');
        if (signature === this.lastStationsSignature) {
          return;
        }
        this.lastStationsSignature = signature;
        const newStations = this.applyDistances(raw);
        AppStorage.setOrCreate('ChargingStation', newStations);
        this.chargingStations = newStations;
        // ✅ 使用增量更新，并保持信息窗打开状态
        await this.addStationMarkers(newStations, true);
        hilog.info(0x0000, 'HomePage', '刷新充电桩数据成功，共 %{public}d 个', newStations.length);
      }
    } catch (error) {
      hilog.error(0x0000, 'HomePage', '加载充电桩数据失败: %{public}s', JSON.stringify(error));
    }
  }

  // ✅ 修改后的 checkChargingStatus
  async checkChargingStatus(): Promise<void> {
    try {
      const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
      if (!userId) {
        hilog.warn(0x0000, 'HomePage', '未找到userId，跳过检查充电状态');
        return;
      }

      const result = await checkChargingOrder(userId);
      hilog.info(0x0000, 'HomePage', '检查充电状态结果: hasChargingOrder=%{public}s', String(result.hasChargingOrder));

      if (result.status === 'success' && result.hasChargingOrder && result.data) {
        this.isCharging = true;
        this.chargingOrderData = result.data;
        AppStorage.setOrCreate('isCharging', true);
        AppStorage.setOrCreate('currentOrderId', result.data.id);

        // ✅ 初始化充电卡片数据，时长从订单 startTime 算
        this.chargingCardData = {
          isCharging: true,
          batteryLevel: this.chargePercent || 0,
          chargeTime: this.calculateChargeTime(result.data.startTime || '')
        };

        // ✅ 获取实时枪状态更新卡片
        await this.updateChargingCardStatus();

        hilog.info(0x0000, 'HomePage', '✅ 有充电中的订单，订单ID: %{public}s', result.data.id);
      } else {
        // 充电中 -> 已结束 的跳变：推一次待机数据给桌面卡片
        // （充电可能从 Station 桩端被停掉，Charge 页没参与，卡片没人通知）
        if (this.isCharging) {
          this.pushIdleToForm();
        }
        this.isCharging = false;
        AppStorage.setOrCreate('isCharging', false);
        // ✅ 清空充电卡片数据
        this.chargingCardData = {
          isCharging: false,
          batteryLevel: 0,
          chargeTime: '00:00:00'
        };
        hilog.info(0x0000, 'HomePage', '❌ 没有充电中的订单');
      }
    } catch (error) {
      hilog.error(0x0000, 'HomePage', '检查充电状态异常: %{public}s', JSON.stringify(error));
    }
  }

  // 推待机数据到桌面充电卡片（与 Charge 页共用 volt_form_store 里的 formId）
  private async pushIdleToForm(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      preferences.removePreferencesFromCacheSync(ctx, { name: 'volt_form_store' });
      const store = preferences.getPreferencesSync(ctx, { name: 'volt_form_store' });
      const ids = store.getSync('formIds', []) as string[];
      if (!ids || ids.length === 0) {
        return;
      }
      const data: Record<string, string | number> = {
        'soc': 0,
        'power': '0.0',
        'temp': '0.0',
        'duration': '00:00',
        'charging': 0
      };
      const bindingData = formBindingData.createFormBindingData(data);
      for (const formId of ids) {
        formProvider.updateForm(formId, bindingData).catch((err: BusinessError) => {
          hilog.error(0x0000, 'HomePage', '卡片待机推送失败: %{public}s', JSON.stringify(err));
        });
      }
    } catch (e) {
      hilog.error(0x0000, 'HomePage', '更新桌面卡片失败: %{public}s', JSON.stringify(e));
    }
  }

  calculateChargeTime(startTime: string): string {
    try {
      // startTime 可能是 2026/08/06 23:17:17 斜杠格式，统一转成 ISO 再解析
      const start = new Date(startTime.replace(/\//g, '-').replace(' ', 'T'));
      const now = new Date();
      let diffMs = now.getTime() - start.getTime();
      if (isNaN(diffMs) || diffMs < 0) {
        return '00:00:00';
      }
      const hours = Math.floor(diffMs / 3600000);
      const minutes = Math.floor((diffMs % 3600000) / 60000);
      const seconds = Math.floor((diffMs % 60000) / 1000);
      return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
    } catch (e) {
      return '00:00:00';
    }
  }

  // ✅ 添加 keepInfoWindowOpen 参数
  async addStationMarkers(stations: ChargingStation[], keepInfoWindowOpen: boolean = false): Promise<void> {
    if (!this.mapController) {
      console.error('地图控制器未初始化');
      return;
    }

    // ✅ 如果保持信息窗打开，先保存当前打开的标记ID和对应的充电站
    let savedMarkerId: string | null = null;
    let savedStation: ChargingStation | null = null;
    if (keepInfoWindowOpen && this.currentOpenMarkerId) {
      savedMarkerId = this.currentOpenMarkerId;
      savedStation = this.markerStationMap.get(savedMarkerId) || null;
    }

    // 移除旧标记
    for (let marker of this.markers) {
      try {
        marker.remove();
      } catch (e) {
        console.error('移除标记失败：' + JSON.stringify(e));
      }
    }
    this.markers = [];
    this.markerStationMap.clear();

    // 添加新标记
    for (let station of this.chargingStations) {
      try {
        let markerOptions: mapCommon.MarkerOptions = {
          position: {
            latitude: station.latitude,
            longitude: station.longitude
          },
          clickable: true,
          title: station.name,
          snippet: station.address,
          icon: $r('app.media.volt_charging'),
        };

        const marker = await this.mapController.addMarker(markerOptions);
        this.markers.push(marker);
        this.markerStationMap.set(marker.getId(), station);
        console.info(`添加标记成功：${station.name}`);
      } catch (error) {
        console.error(`添加标记失败 ${station.name}: ${JSON.stringify(error)}`);
      }
    }

    // ✅ 如果保持信息窗打开，且之前有打开的标记，重新打开
    if (keepInfoWindowOpen && savedMarkerId && savedStation) {
      // 根据充电站ID找到对应的标记
      let targetMarker: map.Marker | null = null;
      for (let marker of this.markers) {
        const station = this.markerStationMap.get(marker.getId());
        if (station && station.id === savedStation.id) {
          targetMarker = marker;
          break;
        }
      }
      if (targetMarker) {
        this.currentInfoWindowStation = savedStation;
        targetMarker.setInfoWindowVisible(true);
        this.currentOpenMarkerId = targetMarker.getId();
        console.info(`✅ 信息窗已重新打开: ${savedStation.name}`);
      } else {
        // 如果找不到对应的充电站（可能已被删除），清除状态
        this.currentOpenMarkerId = null;
        this.currentInfoWindowStation = null;
      }
    }
  }

  async getLocationAndInitMap(): Promise<void> {
    try {
      const defaultLocation: mapCommon.LatLng = {
        latitude: 39.9,
        longitude: 116.4
      };
      let target: mapCommon.LatLng = defaultLocation;

      const hasPermission = await this.checkPermissionsSilently();
      if (hasPermission) {
        try {
          const location = await this.getCurrentLocation();
          // 同样要转成GCJ02，否则初始视野也会偏移
          target = await map.convertCoordinate(
            mapCommon.CoordinateType.WGS84,
            mapCommon.CoordinateType.GCJ02,
            { latitude: location.latitude, longitude: location.longitude }
          );
          // 记录用户位置（GCJ02），并重算站点距离排序
          this.userLat = target.latitude;
          this.userLng = target.longitude;
          this.hasUserLocation = true;
          if (this.chargingStations.length > 0) {
            this.chargingStations = this.applyDistances(this.chargingStations);
          }
          console.info(`定位成功：纬度 ${location.latitude}, 经度 ${location.longitude}`);
        } catch (err) {
          console.error('获取当前位置失败，使用默认位置：' + JSON.stringify(err));
        }
      } else {
        console.info('无定位权限，使用默认位置');
      }

      this.mapOptions = {
        position: {
          target: target,
          zoom: 14
        },
        compassControlsEnabled: false,
        zoomControlsEnabled: false,
        scaleControlsEnabled: false,
        myLocationControlsEnabled: false,
        alwaysShowScaleEnabled: false
      };

      this.callback = async (err: BusinessError | undefined, mapController: map.MapComponentController) => {
        if (!err) {
          this.mapController = mapController;
          this.mapEventManager = this.mapController.getEventManager();
          console.info('地图初始化成功');
          await this.addStationMarkers(this.chargingStations);

          if (this.mapEventManager) {
            this.mapEventManager.on('markerClick', (marker: map.Marker) => {
              console.info(`标记被点击，ID: ${marker.getId()}`);
              const station = this.markerStationMap.get(marker.getId());
              if (station) {
                this.selectedStation = station;
                this.currentInfoWindowStation = station;
                // ✅ 保存当前打开的标记ID
                this.currentOpenMarkerId = marker.getId();
                marker.setInfoWindowVisible(true);
                // 标点坐标即地图坐标系，直接居中即可
                const markerPos = marker.getPosition();
                this.mapController?.animateCamera(
                  map.newCameraPosition({
                    target: markerPos,
                    zoom: 14,
                    tilt: 0,
                    bearing: 0
                  }), 500);
                console.info(`选中充电桩: ${station.name}`);
              }
            });
            // ✅ 新增：监听信息窗关闭事件
            this.mapEventManager.on('infoWindowClose', (marker: map.Marker) => {
              console.info(`信息窗关闭，标记ID: ${marker.getId()}`);
              if (this.currentOpenMarkerId === marker.getId()) {
                this.currentOpenMarkerId = null;
                this.currentInfoWindowStation = null;
                console.info('已清除信息窗打开状态');
              }
            });
          }

          const permit = await this.checkPermissionsSilently();
          if (permit) {
            this.mapController?.setMyLocationEnabled(true);
            this.mapController?.setMyLocationControlsEnabled(true);
            console.info('我的位置图层已启用');
          } else {
            this.requestPermissions();
          }
        } else {
          console.error('地图初始化失败：' + JSON.stringify(err));
        }
      };

      this.mapLoaded = true;
    } catch (error) {
      console.error('getLocationAndInitMap 出现异常：' + JSON.stringify(error));
    }
  }

  @Builder
  customInfoWindowBuilder($$: map.MarkerDelegate) {
    Column() {
      if ($$ && $$.marker) {
        if (this.currentInfoWindowStation) {
          Text(this.currentInfoWindowStation.name || '充电桩')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 4 })

          Row() {
            Column() {
              Row() {
                Text(`状态: ${this.getStatusText(this.currentInfoWindowStation.status)}`)
                  .fontSize(14)
                  .fontColor('#666666')
                  .textAlign(TextAlign.Start)

                Circle()
                  .width(8)
                  .height(8)
                  .fill(this.getStatusColor(this.currentInfoWindowStation.status))
                  .margin({ left: 4, bottom: 2 })
              }
              .width('100%')

              Text(`价格: ${this.currentInfoWindowStation.price}`)
                .fontSize(14)
                .fontColor('#666666')
                .textAlign(TextAlign.Start)
                .width('100%')
              Text(`距离: ${this.currentInfoWindowStation.distance}`)
                .fontSize(14)
                .fontColor('#666666')
                .textAlign(TextAlign.Start)
                .width('100%')
            }
            .width('70%')

            Image($r('app.media.main_charge'))
              .width(50)
              .height(50)
              .borderRadius(8)
              .backgroundColor('#F0F0F0')
              .objectFit(ImageFit.Cover)
          }
          .width('100%')

          Button('进入详情')
            .onClick(() => {
              router.pushUrl({
                url: 'pages/Details',
                params: {
                  station: this.currentInfoWindowStation
                }
              }).catch((err: BusinessError) => {
                console.error('页面跳转失败：' + JSON.stringify(err));
              });
            })
            .width('80%')
            .height('5%')
            .margin({ top: 7 })
            .backgroundColor('#badc3d')
        } else {
          Text($$.marker.getTitle() || '充电桩')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 4 })
          Text($$.marker.getSnippet() || '')
            .fontSize(14)
            .fontColor('#666666')
        }
      }
    }
    .width('47%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(8)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.1)' })
  }

  async getCurrentLocation(): Promise<geoLocationManager.Location> {
    const request: geoLocationManager.CurrentLocationRequest = {
      // 用 FIRST_FIX：启动时秒回，不阻塞地图加载
      priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
      scenario: geoLocationManager.LocationRequestScenario.UNSET,
      maxAccuracy: 0
    };
    return await geoLocationManager.getCurrentLocation(request);
  }

  async checkPermissionsSilently(): Promise<boolean> {
    const permissions: Permissions[] = ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'];
    for (let permission of permissions) {
      const grantStatus = await this.checkAccessToken(permission);
      if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
    }
    return false;
  }

  requestPermissions(): void {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(
      this.getUIContext().getHostContext() as common.UIAbilityContext,
      ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION']
    )
      .then((data: PermissionRequestResult) => {
        this.mapController?.setMyLocationEnabled(true);
        this.mapController?.setMyLocationControlsEnabled(true);
        console.info('权限申请成功，我的位置已启用');
      })
      .catch((err: BusinessError) => {
        console.error('权限申请失败：' + JSON.stringify(err));
      });
  }

  async checkAccessToken(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;

    try {
      let tokenId: number = 0;
      let bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;

      grantStatus = await atManager.checkAccessToken(tokenId, permission);
    } catch (error) {
      console.error('检查权限失败：' + JSON.stringify(error));
    }
    return grantStatus;
  }

  toggleDrawer(): void {
    this.isDrawerOpen = !this.isDrawerOpen;
  }

  // 从充电/结算页返回时收起抽屉（Details返回不收起）
  onPageShow(): void {
    if (AppStorage.get<boolean>('closeHomeDrawer')) {
      this.isDrawerOpen = false;
      AppStorage.setOrCreate('closeHomeDrawer', false);
    }
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 地图
      if (this.mapLoaded) {
        MapComponent({
          mapOptions: this.mapOptions,
          mapCallback: this.callback,
          customInfoWindow: this.customInfoWindow
        })
          .width('100%')
          .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM])
      }

      // 顶部标题
      Column() {
        Row()
          .height('30%')

        Row() {
          Text("首页")
            .fontSize(32)
            .fontColor('#b1c623')
            .fontWeight(FontWeight.Bolder)
            .textAlign(TextAlign.Start)

          Row()
            .width('70%')

          Button() {
            Image($r('app.media.location'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
          }
          .width(42)
          .height(42)
          .backgroundColor('rgba(255, 255, 255, 0.85)')
          .borderRadius(25)
          .shadow({
            radius: 8,
            color: 'rgba(0,0,0,0.1)',
            offsetX: 0,
            offsetY: 2
          })
          .onClick(async () => {
            // 定位SDK返回的是WGS84坐标，华为地图国内用GCJ02，
            // 直接用会偏移几百米（蓝点偏），必须先转坐标系
            const location = await this.getCurrentLocation();
            const target: mapCommon.LatLng = await map.convertCoordinate(
              mapCommon.CoordinateType.WGS84,
              mapCommon.CoordinateType.GCJ02,
              { latitude: location.latitude, longitude: location.longitude }
            );
            let cameraPosition: mapCommon.CameraPosition = {
              target: target,
              zoom: 14,
              tilt: 0,
              bearing: 0
            };
            let cameraUpdate = map.newCameraPosition(cameraPosition);
            this.mapController?.animateCamera(cameraUpdate, 1000);
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
        .height(50)

        // ✅ 使用独立数据渲染充电卡片（样式不变）
        if (this.chargingCardData.isCharging) {
          ChargingCard({
            isCharging: this.chargingCardData.isCharging,
            batteryLevel: this.chargingCardData.batteryLevel,
            chargeTime: this.chargingCardData.chargeTime
          })
        }
      }
      .width('100%')
      .height(130)
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
      .hitTestBehavior(HitTestMode.None)

      // 广告图片
      if (this.showAdImage) {
        Stack() {
          Image($r('app.media.guang'))
            .width('100%')
            .aspectRatio(3 / 4)
            .objectFit(ImageFit.Contain)
            .borderRadius(15)
            .opacity(0.85)
            .onClick(() => {
              console.info('图片被点击');
            })

          Button() {
            Image($r('app.media.close'))
              .width(16)
              .height(16)
          }
          .width(33)
          .height(33)
          .borderRadius(18)
          .backgroundColor('rgba(200, 200, 200, 0.3)')
          .backdropBlur(20)
          .position({ top: 8, right: 30 })
          .offset({ x: -35 })
          .onClick(() => {
            this.showAdImage = false;
            console.info('广告图片已关闭');
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 25 })
        .hitTestBehavior(HitTestMode.None)
        .margin({ top: 115 })
      }

      // 抽屉
      Column() {
        // 拖动手柄
        Row() {
          Column()
            .width(40)
            .height(4)
            .backgroundColor('#CCCCCC')
            .borderRadius(2)
        }
        .width('100%')
        .height(30)
        .justifyContent(FlexAlign.Center)
        .offset({ y: -5 })

        if (this.isDrawerOpen) {
          Row() {
            Text(`附近充电桩(${this.chargingStations.length})`)
              .fontSize(21)
              .fontWeight(FontWeight.Bold)
              .fontColor('#b1c623')
            Blank()
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 15 })

          List() {
            ForEach(this.chargingStations, (station: ChargingStation, index: number) => {
              ListItem() {
                Column() {
                  Row() {
                    Image($r('app.media.main_charge'))
                      .width(60)
                      .height(60)
                      .borderRadius(8)
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
                      }
                      .margin({ bottom: 4 })

                      Row() {
                        Text(`距离: ${station.distance}`)
                          .fontSize(12)
                          .fontColor('#666666')
                        Text(`价格: ${station.price}`)
                          .fontSize(12)
                          .fontColor('#666666')
                          .margin({ left: 8 })
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
                  .padding({ left: 20, right: 20, top: 12, bottom: 12 })
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
                .backdropBlur(20)
                .shadow(ShadowStyle.OUTER_DEFAULT_SM)
                .borderRadius(13)
                .stateStyles({
                  normal: { .backgroundColor('rgba(255, 255, 255, 0.7)') },
                  pressed: { .backgroundColor('rgba(200, 200, 200, 0.8)') }
                })
                .margin({ top: 2 })
                .onClick(() => {
                  router.pushUrl({
                    url: 'pages/Details',
                    params: {
                      station: station
                    }
                  }).catch((err: BusinessError) => {
                    console.error('页面跳转失败：' + JSON.stringify(err));
                  });
                })
              }
            })
            // 末尾垫两个透明占位卡：滚动行程变长，最后的真实卡片能多往上滑、
            // 露出到导航栏上方；占位卡完全透明，不挡底下的透视效果
            ListItem() {
              Column() {}
              .width('100%')
              .height(65)
            }
            ListItem() {
              Column() {}
              .width('100%')
              .height(65)
            }
          }
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height(this.isDrawerOpen ? '70%' : 125)
      .backgroundColor('rgba(255, 255, 255,0.4)')
      .shadow(ShadowStyle.OUTER_DEFAULT_LG)
      .backdropBlur(20)
      .borderRadius({
        topLeft: 20,
        topRight: 20,
        bottomLeft: 0,
        bottomRight: 0
      })
      .position({ bottom: 0 })
      .zIndex(10)
      .clip(false)
      .animation({
        duration: 300,
        curve: Curve.EaseInOut
      })
      .gesture(
        PanGesture()
          .onActionStart((event: GestureEvent) => {
            this.startY = event.offsetY;
          })
          .onActionUpdate((event: GestureEvent) => {
            const deltaY = event.offsetY - this.startY;

            if (this.isDrawerOpen) {
              if (deltaY > 30) {
                this.isDrawerOpen = false;
              }
            } else {
              if (deltaY < -30) {
                this.isDrawerOpen = true;
              }
            }
          })
      )
    }
    .height('100%')
    .width('100%')
    .clip(false)
  }
}