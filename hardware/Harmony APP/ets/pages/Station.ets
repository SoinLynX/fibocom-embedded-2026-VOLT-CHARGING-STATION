// Station.ets
// 充电枪监控页：保留 Details 页上半部分样式，移除电站详情卡片与底部固定栏
// 新增双枪监控卡片（假数据），停止充电按钮暂无实际效果
import { router, curves } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { ChargingStation } from '../model/ChargingStation';
import { stopCharging, StopChargingRequest } from '../model/createOrder';
import { AppIPConfig } from '../model/IP';
import axios, { AxiosResponse } from '@ohos/axios';

// ✅ 视频监控控制指令体（ArkTS 不允许无类型的对象字面量）
interface StreamCtrData {
  StreamCtr: number;
}

interface StreamCtrPayload {
  data: StreamCtrData;
}

// ✅ 供电来源切换指令体：1=市电(PC2高电平) 2=储能(PC2低电平)
interface PowSupCtrData {
  PowSupCtr: number;
}

interface PowSupCtrPayload {
  data: PowSupCtrData;
}

// ✅ /api/nexus/status/latest 响应体（ArkTS 不允许 any，必须显式声明）
interface LatestStatusData {
  SysPowSup?: number;
  CharPowSup?: number;
  Gun1State?: string;   // 桩端上报为文本：0=空闲 1=已插枪 2=充电中 3=高温警报 4=火灾
  Gun2State?: string;
  Gun1Vol?: number;
  Gun1Cur?: number;
  Gun1Temp?: number;
  Gun2Vol?: number;
  Gun2Cur?: number;
  Gun2Temp?: number;
  SysTemp?: number;
  SysHumi?: number;
  EssSoc?: number;    // 储能 SOC (%)，voltsun(WS63) 经 SA59202 实测上报
  EssVol?: number;    // 储能电压 (V)
  EssCur?: number;    // 储能电流 (A)，正=充电 负=放电
  PvVol?: number;     // 光伏电压 (V)，INA226 实测
  PvCur?: number;     // 光伏电流 (A)
  PvAngle?: number;   // 云端最近一次实际下发的追光角度（真值，null=还没下发过）
  PvAuto?: boolean;   // 云端自动追光开关状态
}

// ✅ 光伏追踪接口请求体（ArkTS 不允许对象字面量裸写，必须显式声明）
interface PvAutoPayload {
  auto: boolean;
}

interface PvAnglePayload {
  angle: number;
}

// ✅ 参数行（按引用传递）：@Builder 按值传基本类型参数不会随状态刷新，动态内容必须用对象字面量
interface KvItem {
  label: string;
  value: string;
  unit: string;
}

// ✅ 修改电价请求体
interface PriceUpdatePayload {
  stationId: string;
  price: string;
}

// ✅ /api/nexus/stations 响应（只关心 id 和 price）
interface StationPriceItem {
  id: string;
  price?: string;
}

interface StationsResp {
  status: string;
  data?: StationPriceItem[];
}

// ✅ /api/nexus/stats/daily 响应（Station 页两张图表真值）
interface DayCharge {
  day: string;    // 号数，如 "6"
  value: number;  // 当日充电量（度）
}

interface PvSample {
  hour: number;   // 小时 0~23
  power: number;  // 该小时平均发电功率（W）
}

interface DailyStatsData {
  week?: DayCharge[];
  pv?: PvSample[];
}

interface DailyStatsResp {
  status: string;
  data?: DailyStatsData;
}

// ===== 修改电价弹窗（沿用全站风格：品牌绿 + 圆角白卡） =====
@CustomDialog
struct PriceEditDialog {
  controller: CustomDialogController;
  onConfirm: (price: string) => void = () => {};
  @State inputValue: string = '';

  build() {
    Column() {
      Text('修改电价')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
        .margin({ bottom: 16 })
      TextInput({ placeholder: '请输入新电价', text: '' })
        .type(InputType.NUMBER_DECIMAL)
        .height(46)
        .fontSize(15)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .margin({ bottom: 20 })
        .onChange((value: string) => {
          this.inputValue = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor('#666666')
          .backgroundColor('#F0F0F0')
          .borderRadius(21)
          .onClick(() => {
            this.controller.close();
          })
        Button('确定')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor('#b1c623')
          .borderRadius(21)
          .onClick(() => {
            this.controller.close();
            this.onConfirm(this.inputValue);
          })
      }
      .width('100%')
    }
    .width('78%')
    .padding({ left: 24, right: 24, top: 24, bottom: 24 })
    .backgroundColor(Color.White)
    .borderRadius(20)
  }
}

interface LatestStatusResp {
  status: string;
  data?: LatestStatusData;
}

// ✅ 充电枪面板参数接口
interface GunPanelParam {
  gunNumber: number;
  gunName: string;
  status: string;
  voltage: string;
  current: string;
  power: string;
  powerUnit: string;
  temp: string;
}

@Entry
@Component
struct Station {
  @State station: ChargingStation | null = null;

  // ✅ 假数据 - 充电站环境参数
  @State stationTemp: string = '31.2';
  @State stationHumidity: string = '58';

  // ✅ 假数据 - UPS 供电路径（grid-市电 ess-储能）
  @State systemPowerPath: string = 'grid';
  @State chargePowerPath: string = 'ess';
  @State showSwitchDialog: boolean = false;
  // 自动追光开启确认弹窗
  @State showPvAutoDialog: boolean = false;
  // 停止充电确认弹窗：pendingStopGun 记录要停哪把枪（1/2）
  @State showStopDialog: boolean = false;
  @State pendingStopGun: number = 0;
  @State isStoppingGun: boolean = false;

  // ✅ 真实供电状态轮询
  private statusTimer: number = -1;
  private lastSwitchTime: number = 0;   // 切换指令成功后的保护窗口：5秒内不让轮询覆盖本地显示

  // ✅ 储能站/光伏参数（真值：voltsun 每约1秒上报，随 status/latest 轮询刷新；未收到前显示占位）
  @State essSoc: string = '--';
  @State essVoltage: string = '--';
  @State essCurrent: string = '--';
  @State pvVoltage: string = '--';
  @State pvCurrent: string = '--';

  // ✅ 追光角度（真值随轮询从云端同步；lastPvManualTime 保护本地操作不被覆盖）
  @State trackAngle: number = 0;
  @State autoTrack: boolean = false;
  private lastPvManualTime: number = 0;

  // ✅ 图表真值（/api/nexus/stats/daily，进页拉取 + 每分钟刷新）
  @State weekChargeData: number[] = [0, 0, 0, 0, 0, 0, 0]; // 近7日充电量（度）
  @State weekDays: string[] = ['', '', '', '', '', '', ''];     // 近7日号数
  @State pvHours: string[] = [];                            // 今日采样小时
  @State pvPowerData: number[] = [];                        // 今日发电功率（W）
  private statsTimer: number = -1;
  private lineCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  // ✅ 假数据 - 充电枪状态（charging-充电中 idle-空闲）
  @State gun1Status: string = 'charging';
  @State gun2Status: string = 'idle';

  // ✅ 假数据 - 充电枪1
  @State gun1Voltage: string = '220.5';
  @State gun1Current: string = '32.8';
  @State gun1Power: string = '7.2';
  @State gun1PowerUnit: string = 'kW';
  @State gun1Temp: string = '36.5';

  // ✅ 假数据 - 充电枪2
  @State gun2Voltage: string = '219.8';
  @State gun2Current: string = '0.0';
  @State gun2Power: string = '0.0';
  @State gun2PowerUnit: string = 'kW';
  @State gun2Temp: string = '28.3';

  // ✅ 视频监控（按需推流：进页面开启，退出页面关闭）
  @State videoSrc: string = '';
  @State videoLoading: boolean = true;
  @State videoError: boolean = false;
  private videoController: VideoController = new VideoController();
  private streamTimer: number = -1;

  // 由 BASE_URL 推导流媒体播放地址：http://ip:端口 -> http://ip:8080/live/fire.flv
  getStreamUrl(): string {
    const base = AppIPConfig.BASE_URL;
    const endIdx = base.lastIndexOf(':');
    const host = endIdx > 5 ? base.substring(0, endIdx) : base;
    return host + ':8080/live/fire.flv';
  }

  // 通知云端开启/关闭摄像头推流（复用现有 Control 下发接口）
  async sendStreamCtr(on: boolean): Promise<void> {
    try {
      const payload: StreamCtrPayload = { data: { StreamCtr: on ? 1 : 0 } };
      await axios.post(AppIPConfig.BASE_URL + '/api/nexus/publish/Control', payload);
      console.info('视频监控指令已发送: ' + (on ? '开启' : '关闭'));
    } catch (e) {
      console.error('视频监控指令发送失败: ' + JSON.stringify(e));
    }
  }

  // ✅ 拉取最新设备状态：同步系统/电桩供电来源显示（SysPowSup/CharPowSup: 1=市电 2=储能）
  async fetchLatestStatus(): Promise<void> {
    try {
      const resp: AxiosResponse<LatestStatusResp> =
        await axios.get<LatestStatusResp, AxiosResponse<LatestStatusResp>, null>(
          AppIPConfig.BASE_URL + '/api/nexus/status/latest');
      const body = resp.data;
      const d = body.data;
      if (!d) {
        return;
      }
      // 调试：打印储能/光伏字段实际收到的值（定位 "--" 问题后删除）
      console.info('ESS/PV调试: EssSoc=' + d.EssSoc + ' EssVol=' + d.EssVol +
        ' PvVol=' + d.PvVol + ' 原始报文=' + JSON.stringify(d));
      if (d.SysPowSup === 1 || d.SysPowSup === 2) {
        this.systemPowerPath = d.SysPowSup === 1 ? 'grid' : 'ess';
      }
      // 切换指令发出后 5 秒内不覆盖电桩路径显示（等桩端上报追上来，避免"切了没反应"的假象）
      if ((d.CharPowSup === 1 || d.CharPowSup === 2) && Date.now() - this.lastSwitchTime > 5000) {
        this.chargePowerPath = d.CharPowSup === 1 ? 'grid' : 'ess';
      }
      // ✅ 管理看板环境温湿度（协议默认保留1位小数）
      if (d.SysTemp !== undefined && d.SysTemp !== null) {
        this.stationTemp = d.SysTemp.toFixed(1);
      }
      if (d.SysHumi !== undefined && d.SysHumi !== null) {
        this.stationHumidity = d.SysHumi.toFixed(1);
      }
      // ✅ 双枪面板：与 Charge 页同源（gun-status 查的也是这张表），合并到本次轮询不再单独发请求
      this.fillGunPanel(1, d.Gun1State, d.Gun1Vol, d.Gun1Cur, d.Gun1Temp);
      this.fillGunPanel(2, d.Gun2State, d.Gun2Vol, d.Gun2Cur, d.Gun2Temp);
      // ✅ 储能/光伏真值（voltsun 上报；SA59202 无测温功能，储能温度已从链路移除）
      if (d.EssSoc !== undefined && d.EssSoc !== null) {
        this.essSoc = d.EssSoc.toFixed(1);
      }
      if (d.EssVol !== undefined && d.EssVol !== null) {
        this.essVoltage = d.EssVol.toFixed(2);
      }
      if (d.EssCur !== undefined && d.EssCur !== null) {
        this.essCurrent = d.EssCur.toFixed(2);
      }
      if (d.PvVol !== undefined && d.PvVol !== null) {
        this.pvVoltage = d.PvVol.toFixed(2);
      }
      if (d.PvCur !== undefined && d.PvCur !== null) {
        this.pvCurrent = d.PvCur.toFixed(2);
      }
      // ✅ 追光角度/自动开关同步云端真值：滑条操作后3秒内不覆盖，避免拖动被轮询打断
      if (d.PvAngle !== undefined && d.PvAngle !== null && Date.now() - this.lastPvManualTime > 3000) {
        this.trackAngle = d.PvAngle;
      }
      if (d.PvAuto !== undefined && d.PvAuto !== null && Date.now() - this.lastPvManualTime > 3000) {
        this.autoTrack = d.PvAuto;
      }
    } catch (e) {
      console.error('获取设备状态失败: ' + JSON.stringify(e));
    }
  }

  // ✅ 切换电桩供电来源：APP -> 云端 Control 接口 -> MQTT -> 昇腾网关 -> VOLTos PC2 电平
  // target: 'grid'=市电(PowSupCtr:1) 'ess'=储能(PowSupCtr:2)
  async switchPowerPath(target: string): Promise<boolean> {
    const ctrValue = target === 'grid' ? 1 : 2;
    try {
      const payload: PowSupCtrPayload = { data: { PowSupCtr: ctrValue } };
      await axios.post(AppIPConfig.BASE_URL + '/api/nexus/publish/Control', payload);
      console.info('供电切换指令已发送: ' + target);
      this.lastSwitchTime = Date.now();
      return true;
    } catch (e) {
      console.error('供电切换指令发送失败: ' + JSON.stringify(e));
      return false;
    }
  }

  // 修改电价弹窗控制器
  private priceDialog: CustomDialogController = new CustomDialogController({
    builder: PriceEditDialog({
      onConfirm: (input: string) => {
        this.submitPrice(input);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    // 弹簧出场动画（与全站弹窗同款）
    openAnimation: { duration: 300, curve: curves.springMotion(0.45, 0.75) }
  });

  // ✅ 电价显示：剥离单位后缀只显示数值（单位已写在标签里），兼容库内各种历史格式
  getPriceText(): string {
    const p = this.station?.price;
    if (!p) {
      return '--';
    }
    return p.replace('元/度', '').replace('元', '').trim();
  }

  // ✅ 提交电价修改：APP -> 云端落库，成功后更新本地显示（Manage 页 5 秒轮询也会同步）
  async submitPrice(input: string): Promise<void> {
    const num = parseFloat(input);
    if (isNaN(num) || num <= 0) {
      promptAction.showToast({ message: '请输入有效电价', duration: 1500 });
      return;
    }
    if (!this.station || !this.station.id) {
      promptAction.showToast({ message: '站点信息缺失', duration: 1500 });
      return;
    }
    const priceText = num.toFixed(2) + '元/度';
    try {
      const payload: PriceUpdatePayload = { stationId: this.station.id, price: priceText };
      await axios.post(AppIPConfig.BASE_URL + '/api/nexus/stations/price', payload);
      this.station.price = priceText;
      promptAction.showToast({ message: '电价已更新', duration: 1500 });
    } catch (e) {
      console.error('电价修改失败: ' + JSON.stringify(e));
      promptAction.showToast({ message: '修改失败，请检查网络', duration: 1500 });
    }
  }

  // ✅ 进页拉取最新电价（路由参数里的是列表页旧快照，可能与库内不一致）
  async fetchStationPrice(): Promise<void> {
    if (!this.station || !this.station.id) {
      return;
    }
    try {
      const resp: AxiosResponse<StationsResp> =
        await axios.get<StationsResp, AxiosResponse<StationsResp>, null>(
          AppIPConfig.BASE_URL + '/api/nexus/stations');
      const list = resp.data.data;
      if (!list) {
        return;
      }
      const mine = list.find((item: StationPriceItem) => item.id === this.station?.id);
      if (mine && mine.price && this.station) {
        this.station.price = mine.price;
      }
    } catch (e) {
      console.error('获取最新电价失败: ' + JSON.stringify(e));
    }
  }

  // ✅ 拉取图表统计：近7日充电量（度）+ 今日发电功率（W=PvVol×PvCur）
  async fetchDailyStats(): Promise<void> {
    try {
      const resp: AxiosResponse<DailyStatsResp> =
        await axios.get<DailyStatsResp, AxiosResponse<DailyStatsResp>, null>(
          AppIPConfig.BASE_URL + '/api/nexus/stats/daily');
      const d = resp.data.data;
      if (!d) {
        return;
      }
      if (d.week && d.week.length === 7) {
        this.weekChargeData = d.week.map((item: DayCharge) => item.value);
        this.weekDays = d.week.map((item: DayCharge) => item.day);
      }
      if (d.pv && d.pv.length >= 2) {
        this.pvHours = d.pv.map((item: PvSample) => String(item.hour));
        this.pvPowerData = d.pv.map((item: PvSample) => item.power);
        this.drawLineChart();
      }
    } catch (e) {
      console.error('获取图表统计失败: ' + JSON.stringify(e));
    }
  }

  // ✅ 开关光伏自动追踪：云端接管，开启后每3秒按北京时间日照计划自动下发角度
  async setPvAuto(auto: boolean): Promise<boolean> {
    try {
      const payload: PvAutoPayload = { auto: auto };
      await axios.post(AppIPConfig.BASE_URL + '/api/nexus/pv/auto', payload);
      return true;
    } catch (e) {
      console.error('自动追光开关失败: ' + JSON.stringify(e));
      return false;
    }
  }

  // ✅ 桩端停止充电：确认弹窗点确定后调用，下发真实停止指令
  async stopGunCharging() {
    if (this.pendingStopGun !== 1 && this.pendingStopGun !== 2) {
      return;
    }
    this.isStoppingGun = true;
    try {
      const req: StopChargingRequest = { gunNumber: this.pendingStopGun };
      const result = await stopCharging(req);
      if (result.status === 'success') {
        promptAction.showToast({
          message: `${this.pendingStopGun}号枪停止指令已下发`,
          duration: 1500
        });
      } else {
        promptAction.showToast({
          message: result.message || '停止失败，请稍后重试',
          duration: 1500
        });
      }
    } catch (e) {
      console.error('停止充电失败: ' + JSON.stringify(e));
      promptAction.showToast({ message: '停止失败，请检查网络', duration: 1500 });
    } finally {
      this.isStoppingGun = false;
      this.showStopDialog = false;
      this.pendingStopGun = 0;
    }
  }

  // ✅ 手动下发追光角度（滑条松手时调用；云端自动对齐15°并去重）
  async sendPvAngle(angle: number): Promise<void> {
    try {
      const payload: PvAnglePayload = { angle: Math.round(angle) };
      await axios.post(AppIPConfig.BASE_URL + '/api/nexus/pv/angle', payload);
    } catch (e) {
      console.error('追光角度下发失败: ' + JSON.stringify(e));
    }
  }

  // ✅ 跳转高德导航（照搬 Details 页）
  jumpToGaode(lng: string, lat: string, addressName: string) {
    let uri = 'amapuri://route/plan?' +
      `dlon=${lng}&dlat=${lat}&dname=${addressName}&t=0`
    let want: Want = { uri: uri }
    const content = getContext(this) as common.UIAbilityContext
    content.startAbility(want, (err: BusinessError) => {
      if (err) {
        console.error('跳转高德失败：' + JSON.stringify(err));
        promptAction.showToast({
          message: '未安装高德地图',
          duration: 2000
        });
      }
    })
  }

  aboutToAppear() {
    try {
      const params = router.getParams() as Record<string, Object>;
      if (params && params['station']) {
        this.station = params['station'] as ChargingStation;
      }
    } catch (error) {
      console.error('获取参数失败：' + JSON.stringify(error));
    }

    // ✅ 进入本页：开启视频监控推流，并每30秒续期一次（防异常退出流量空耗）
    this.videoSrc = this.getStreamUrl();
    this.sendStreamCtr(true);
    this.streamTimer = setInterval(() => {
      this.sendStreamCtr(true);
    }, 30000);

    // ✅ 拉取最新电价（覆盖路由参数里的旧值）
    this.fetchStationPrice();

    // ✅ 图表统计：进页拉取 + 每分钟刷新
    this.fetchDailyStats();
    this.statsTimer = setInterval(() => {
      this.fetchDailyStats();
    }, 60000);

    // ✅ 启动供电状态轮询（3秒一次，同步真实 SysPowSup/CharPowSup）
    this.fetchLatestStatus();
    this.statusTimer = setInterval(() => {
      this.fetchLatestStatus();
    }, 3000);
  }

  aboutToDisappear() {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    // ✅ 退出本页：停掉续期定时器，通知云端关闭推流（带宽归零）
    if (this.streamTimer !== -1) {
      clearInterval(this.streamTimer);
      this.streamTimer = -1;
    }
    if (this.statsTimer !== -1) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    this.videoController.stop();
    this.sendStreamCtr(false);
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

  getGunStateText(status: string): string {
    switch (status) {
      case 'charging': return '充电中';
      case 'plugged': return '已插枪';
      case 'idle': return '空闲';
      case 'fault': return '故障';
      default: return '未知';
    }
  }

  getGunStateColor(status: string): string {
    switch (status) {
      case 'charging': return '#FF9800';
      case 'plugged': return '#2196F3';
      case 'idle': return '#4CAF50';
      case 'fault': return '#F44336';
      default: return '#999999';
    }
  }

  // ✅ 桩端状态码 -> 面板状态（0=空闲 1=已插枪 2=充电中 3=高温 4=火灾）
  mapGunState(code: number): string {
    if (code === 2) {
      return 'charging';
    }
    if (code === 1) {
      return 'plugged';
    }
    if (code === 3 || code === 4) {
      return 'fault';
    }
    return 'idle';
  }

  // ✅ 用最新上报填充一把枪的面板（功率 = 电压×电流，W 换算 kW 保留1位小数）
  fillGunPanel(gun: number, state: string | undefined, vol: number | undefined,
    cur: number | undefined, temp: number | undefined): void {
    const status = this.mapGunState(Number(state ?? 0));
    const v = vol ?? 0;
    const c = cur ?? 0;
    const t = temp ?? 0;
    // 功率自适应单位：<1kW 按 W 显示（小功率测试负载下 0.0kW 没意义），>=1kW 按 kW
    const watt = v * c;
    const powerStr = watt < 1000 ? watt.toFixed(1) : (watt / 1000).toFixed(2);
    const powerUnit = watt < 1000 ? 'W' : 'kW';
    if (gun === 1) {
      this.gun1Status = status;
      this.gun1Voltage = v.toFixed(1);
      this.gun1Current = c.toFixed(1);
      this.gun1Power = powerStr;
      this.gun1PowerUnit = powerUnit;
      this.gun1Temp = t.toFixed(1);
    } else {
      this.gun2Status = status;
      this.gun2Voltage = v.toFixed(1);
      this.gun2Current = c.toFixed(1);
      this.gun2Power = powerStr;
      this.gun2PowerUnit = powerUnit;
      this.gun2Temp = t.toFixed(1);
    }
  }

  getPathText(path: string): string {
    return path === 'grid' ? '市电' : '储能';
  }

  getPathColor(path: string): string {
    return path === 'grid' ? '#1565C0' : '#b1c623';
  }

  // ===== 折线图绘制（今日发电功率） =====
  drawLineChart(): void {
    const ctx = this.lineCtx;
    const w = ctx.width;
    const h = ctx.height;
    const padL = 30, padR = 8, padT = 10, padB = 20;
    // 纵轴上限取数据峰值的 1.2 倍（至少 1W），单位 W
    let peak = 1;
    this.pvPowerData.forEach((v: number) => {
      if (v > peak) {
        peak = v;
      }
    });
    const maxVal = peak * 1.2;

    ctx.clearRect(0, 0, w, h);
    ctx.lineWidth = 1;
    ctx.font = '9vp sans-serif';

    // 横向网格线 + 纵坐标刻度（0 / 半峰 / 峰值）
    const ySteps: number[] = [0, maxVal / 2, maxVal];
    ySteps.forEach((v: number) => {
      const y = padT + (h - padT - padB) * (1 - v / maxVal);
      ctx.strokeStyle = '#F0F0F0';
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(w - padR, y);
      ctx.stroke();
      ctx.fillStyle = '#999999';
      ctx.fillText(v >= 100 ? v.toFixed(0) : v.toFixed(1), 2, y + 3);
    });

    // 数据不足两个点时只画坐标轴
    if (this.pvPowerData.length < 2) {
      return;
    }

    // 计算数据点
    const pts: number[][] = [];
    for (let i = 0; i < this.pvPowerData.length; i++) {
      const x = padL + (w - padL - padR) * i / (this.pvPowerData.length - 1);
      const y = padT + (h - padT - padB) * (1 - this.pvPowerData[i] / maxVal);
      pts.push([x, y]);
    }

    // 折线
    ctx.strokeStyle = '#b1c623';
    ctx.lineWidth = 2;
    ctx.beginPath();
    pts.forEach((p: number[], i: number) => {
      if (i === 0) {
        ctx.moveTo(p[0], p[1]);
      } else {
        ctx.lineTo(p[0], p[1]);
      }
    });
    ctx.stroke();

    // 数据点 + 横坐标小时标签
    pts.forEach((p: number[], i: number) => {
      ctx.fillStyle = '#b1c623';
      ctx.beginPath();
      ctx.arc(p[0], p[1], 2.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#999999';
      const label = this.pvHours[i];
      ctx.fillText(label, p[0] - (label.length > 1 ? 5 : 3), h - 6);
    });
  }

  // 近7日充电量纵轴上限：取最大值，至少为 1，防止除零和柱高溢出
  getWeekMax(): number {
    let m = 1;
    this.weekChargeData.forEach((v: number) => {
      if (v > m) {
        m = v;
      }
    });
    return m;
  }

  // ===== 柱状图（近7日充电量） =====
  @Builder
  barChart() {
    Row({ space: 4 }) {
      // 纵坐标刻度（上限取 7 日最大值，至少为 1，与柱高换算 val/max*70 对应）
      Column() {
        Text(this.getWeekMax().toFixed(0))
          .fontSize(9)
          .fontColor('#999999')
        Blank()
        Text((this.getWeekMax() / 2).toFixed(0))
          .fontSize(9)
          .fontColor('#999999')
        Blank()
        Text('0')
          .fontSize(9)
          .fontColor('#999999')
      }
      .width(13)
      .height(70)
      .margin({ bottom: 18 })
      .alignItems(HorizontalAlign.Start)

      ForEach(this.weekChargeData, (val: number, index: number) => {
        Column() {
          Blank()
          Column()
            .width(14)
            .height(Math.max(4, val / this.getWeekMax() * 70))
            .backgroundColor('#b1c623')
            .borderRadius({ topLeft: 4, topRight: 4 })
          Text(this.weekDays[index])
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .height(100)
        .alignItems(HorizontalAlign.Center)
      }, (val: number, index: number) => `bar_${this.weekDays[index]}_${val}`)
    }
    .width('100%')
    .height(100)
    .alignItems(VerticalAlign.Bottom)
  }

  // ===== 单个参数项 =====
  @Builder
  paramItem(label: string, value: string, unit: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#999999')
      Blank()
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#b1c623')
      Text(unit)
        .fontSize(11)
        .fontColor('#999999')
        .margin({ left: 2 })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  // ===== 参数行（动态值版）：参数为对象字面量，按引用传递，状态变化才会刷新 =====
  @Builder
  paramItemRef(item: KvItem) {
    Row() {
      Text(item.label)
        .fontSize(13)
        .fontColor('#999999')
      Blank()
      Text(item.value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#b1c623')
      Text(item.unit)
        .fontSize(11)
        .fontColor('#999999')
        .margin({ left: 2 })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  // ===== 单侧充电枪面板 =====
  @Builder
  gunPanel($$: GunPanelParam) {
    Column() {
      // 枪标题 + 状态
      Row() {
        Text('🔌')
          .fontSize(16)
          .margin({ right: 4 })
        Text($$.gunName)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
        Blank()
        Circle()
          .width(7)
          .height(7)
          .fill(this.getGunStateColor($$.status))
          .margin({ right: 4 })
        Text(this.getGunStateText($$.status))
          .fontSize(12)
          .fontColor(this.getGunStateColor($$.status))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .margin({ bottom: 10 })

      // ✅ 空闲状态的枪，所有参数显示 N/A
      if ($$.status === 'idle') {
        this.paramItem('电压', 'N/A', '')
        this.paramItem('电流', 'N/A', '')
        this.paramItem('功率', 'N/A', '')
        this.paramItem('温度', 'N/A', '')
      } else {
        this.paramItem('电压', $$.voltage, 'V')
        this.paramItem('电流', $$.current, 'A')
        this.paramItem('功率', $$.power, $$.powerUnit)
        this.paramItem('温度', $$.temp, '℃')
      }

      Button($$.status === 'charging' ? '停止充电' : '未在充电')
        .width('100%')
        .height(36)
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor($$.status === 'charging' ? '#FF6B6B' : '#C0C0C0')
        .borderRadius(18)
        .margin({ top: 10 })
        .enabled($$.status === 'charging')
        .onClick(() => {
          // 弹出确认弹窗，确认后真正下发停止指令
          this.pendingStopGun = $$.gunNumber;
          this.showStopDialog = true;
        })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      // 主内容 - 可滚动
      Scroll() {
        Column() {
          // ===== 顶部图片区域（保留 Details 上半部分） =====
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
            // ===== 认证 + 地址卡片 =====
            Column() {
              Text('管理看板')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ bottom: 10 })

              // ===== 温度 / 湿度 双卡片 =====
              Column() {
                Row({ space: 10 }) {
                  Row() {
                    Text('温度')
                      .fontSize(13)
                      .fontColor('#999999')
                    Blank()
                    Row() {
                      Text(this.stationTemp)
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#b1c623')
                      Text(' ℃')
                        .fontSize(13)
                        .fontColor('#999999')
                    }
                  }
                  .layoutWeight(1)
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .backgroundColor(Color.White)
                  .borderRadius(12)
                  .shadow({
                    radius: 16,
                    color: 'rgba(0, 0, 0, 0.15)',
                    offsetX: 0,
                    offsetY: 4
                  })

                  Row() {
                    Text('湿度')
                      .fontSize(13)
                      .fontColor('#999999')
                    Blank()
                    Row() {
                      Text(this.stationHumidity)
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#b1c623')
                      Text(' %')
                        .fontSize(13)
                        .fontColor('#999999')
                    }
                  }
                  .layoutWeight(1)
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .backgroundColor(Color.White)
                  .borderRadius(12)
                  .shadow({
                    radius: 16,
                    color: 'rgba(0, 0, 0, 0.15)',
                    offsetX: 0,
                    offsetY: 4
                  })
                }
                .width('100%')

                // ===== 地址卡片 + 电价卡片（并排，电价接近正方形） =====
                Row({ space: 10 }) {
                  // 地址卡片：占满剩余空间，导航按钮在右下角
                  Column() {
                    Text('地址')
                      .fontSize(13)
                      .fontColor('#999999')
                      .width('100%')
                      .textAlign(TextAlign.Start)

                    Text(this.station?.address || '地址未知')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#333333')
                      .width('100%')
                      .textAlign(TextAlign.Start)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 6 })

                    Blank()

                    Row() {
                      Blank()
                      Button() {
                        Image($r('app.media.location'))
                          .width(18)
                          .height(18)
                      }
                      .width(34)
                      .height(34)
                      .backgroundColor('rgba(177, 198, 35, 0.12)')
                      .borderRadius(17)
                      .onClick(() => {
                        const lng = this.station?.longitude ? String(this.station.longitude) : '118.4124';
                        const lat = this.station?.latitude ? String(this.station.latitude) : '24.5235';
                        this.jumpToGaode(lng, lat, this.station?.name || '伏安超冲充电站');
                      })
                    }
                    .width('100%')
                  }
                  .layoutWeight(1)
                  .height(120)
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .backgroundColor(Color.White)
                  .borderRadius(12)
                  .shadow({
                    radius: 16,
                    color: 'rgba(0, 0, 0, 0.15)',
                    offsetX: 0,
                    offsetY: 4
                  })

                  // 电价卡片：宽度接近正方形（标签带单位，大数字只显示数值，避免截断）
                  Column() {
                    Text('电价（元/度）')
                      .fontSize(13)
                      .fontColor('#999999')
                      .width('100%')
                      .textAlign(TextAlign.Start)

                    Text(this.getPriceText())
                      .fontSize(24)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#badc3d')
                      .width('100%')
                      .textAlign(TextAlign.Start)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 6 })

                    Blank()

                    Row() {
                      Blank()
                      Button('修改')
                        .height(28)
                        .fontSize(11)
                        .fontColor(Color.White)
                        .backgroundColor('#b1c623')
                        .borderRadius(14)
                        .padding({ left: 10, right: 10 })
                        .onClick(() => {
                          this.priceDialog.open();
                        })
                    }
                    .width('100%')
                  }
                  .width(120)
                  .height(120)
                  .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                  .backgroundColor(Color.White)
                  .borderRadius(12)
                  .shadow({
                    radius: 16,
                    color: 'rgba(0, 0, 0, 0.15)',
                    offsetX: 0,
                    offsetY: 4
                  })
                }
                .width('100%')
                .margin({ top: 10 })
                .alignItems(VerticalAlign.Top)
              }

              // ===== 近7日充电量 + 今日发电功率 图表卡片 =====
              Row({ space: 10 }) {
                Column() {
                  Row() {
                    Text('近7日充电量')
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#333333')
                    Blank()
                    Text('kWh')
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                  .width('100%')
                  .margin({ bottom: 8 })
                  this.barChart()
                }
                .layoutWeight(1)
                .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                .backgroundColor(Color.White)
                .borderRadius(12)
                .shadow({
                  radius: 16,
                  color: 'rgba(0, 0, 0, 0.15)',
                  offsetX: 0,
                  offsetY: 4
                })

                Column() {
                  Row() {
                    Text('今日发电功率')
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#333333')
                    Blank()
                    Text('kW')
                      .fontSize(11)
                      .fontColor('#999999')
                  }
                  .width('100%')
                  .margin({ bottom: 8 })
                  Canvas(this.lineCtx)
                    .width('100%')
                    .height(100)
                    .onReady(() => {
                      this.drawLineChart();
                    })
                }
                .layoutWeight(1)
                .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                .backgroundColor(Color.White)
                .borderRadius(12)
                .shadow({
                  radius: 16,
                  color: 'rgba(0, 0, 0, 0.15)',
                  offsetX: 0,
                  offsetY: 4
                })
              }
              .width('100%')
              .margin({ top: 10 })
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ top: -15, bottom: 12 })

            // ===== 充电站视频监控卡片 =====
            Column() {
              Row() {
                Text('充电站视频监控')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
                Blank()
                // LIVE 指示
                Row() {
                  Circle()
                    .width(7)
                    .height(7)
                    .fill(this.videoError ? '#999999' : '#F44336')
                    .margin({ right: 4 })
                  Text(this.videoError ? 'OFFLINE' : 'LIVE')
                    .fontSize(11)
                    .fontColor(this.videoError ? '#999999' : '#F44336')
                    .fontWeight(FontWeight.Bold)
                }
              }
              .width('100%')
              .margin({ bottom: 12 })

              Stack() {
                // 播放器：原始摄像头画面（无检测框）
                Video({ src: this.videoSrc, controller: this.videoController })
                  .width('100%')
                  .height(200)
                  .autoPlay(true)
                  .controls(false)
                  .objectFit(ImageFit.Cover)
                  .onStart(() => {
                    this.videoLoading = false;
                    this.videoError = false;
                  })
                  .onError(() => {
                    this.videoLoading = false;
                    this.videoError = true;
                  })

                // 加载占位：从点击进页到出画面约3~5秒（指令下发+ffmpeg启动+首帧缓冲）
                if (this.videoLoading) {
                  Column() {
                    LoadingProgress()
                      .width(36)
                      .height(36)
                      .color('#b1c623')
                    Text('正在连接摄像头…')
                      .fontSize(13)
                      .fontColor('#999999')
                      .margin({ top: 10 })
                  }
                  .width('100%')
                  .height(200)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor('#F7F7F7')
                }

                // 错误占位：FLV 播放失败时提示（可重试）
                if (this.videoError) {
                  Column() {
                    Text('视频连接失败')
                      .fontSize(14)
                      .fontColor('#666666')
                    Button('重新连接')
                      .height(30)
                      .fontSize(12)
                      .fontColor(Color.White)
                      .backgroundColor('#b1c623')
                      .borderRadius(15)
                      .padding({ left: 14, right: 14 })
                      .margin({ top: 10 })
                      .onClick(() => {
                        this.videoError = false;
                        this.videoLoading = true;
                        this.sendStreamCtr(true);
                        this.videoSrc = '';
                        setTimeout(() => {
                          this.videoSrc = this.getStreamUrl();
                        }, 300);
                      })
                  }
                  .width('100%')
                  .height(200)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor('#F7F7F7')
                }
              }
              .width('100%')
              .height(200)
              .borderRadius(12)
              .clip(true)
              .backgroundColor('#000000')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ bottom: 12 })

            // ===== 双枪监控卡片（替代原电站详情卡片） =====
            Column() {
              Text('充电枪实时监控')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .width('100%')
                .margin({ bottom: 16 })

              Row() {
                // 左边 - 充电枪1
                this.gunPanel({ gunNumber: 1, gunName: '充电枪 1', status: this.gun1Status, voltage: this.gun1Voltage, current: this.gun1Current, power: this.gun1Power, powerUnit: this.gun1PowerUnit, temp: this.gun1Temp })

                // 中间分隔线
                Divider()
                  .vertical(true)
                  .height(190)
                  .color('#F0F0F0')
                  .margin({ left: 14, right: 14 })

                // 右边 - 充电枪2
                this.gunPanel({ gunNumber: 2, gunName: '充电枪 2', status: this.gun2Status, voltage: this.gun2Voltage, current: this.gun2Current, power: this.gun2Power, powerUnit: this.gun2PowerUnit, temp: this.gun2Temp })
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ bottom: 12 })

            // ===== UPS 管理卡片 =====
            Column() {
              Text('UPS 管理')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .width('100%')
                .margin({ bottom: 16 })

              Row({ space: 10 }) {
                // 当前系统供电路径
                Column() {
                  Text('当前系统供电路径')
                    .fontSize(13)
                    .fontColor('#999999')
                    .width('100%')
                    .textAlign(TextAlign.Start)

                  Blank()

                  Row() {
                    Text(this.getPathText(this.systemPowerPath))
                      .fontSize(20)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.getPathColor(this.systemPowerPath))
                    Blank()
                  }
                  .width('100%')
                }
                .layoutWeight(1)
                .height(90)
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .backgroundColor(Color.White)
                .borderRadius(12)
                .shadow({
                  radius: 16,
                  color: 'rgba(0, 0, 0, 0.15)',
                  offsetX: 0,
                  offsetY: 4
                })

                // 当前充电供应路径（右下角带切换按钮）
                Column() {
                  Text('当前充电供应路径')
                    .fontSize(13)
                    .fontColor('#999999')
                    .width('100%')
                    .textAlign(TextAlign.Start)

                  Blank()

                  Row() {
                    Text(this.getPathText(this.chargePowerPath))
                      .fontSize(20)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.getPathColor(this.chargePowerPath))
                    Blank()
                    Button('切换供应')
                      .height(28)
                      .fontSize(11)
                      .fontColor(Color.White)
                      .backgroundColor('#b1c623')
                      .borderRadius(14)
                      .padding({ left: 10, right: 10 })
                      .onClick(() => {
                        this.showSwitchDialog = true;
                      })
                  }
                  .width('100%')
                }
                .layoutWeight(1)
                .height(90)
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .backgroundColor(Color.White)
                .borderRadius(12)
                .shadow({
                  radius: 16,
                  color: 'rgba(0, 0, 0, 0.15)',
                  offsetX: 0,
                  offsetY: 4
                })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ bottom: 12 })

            // ===== 储能站实时监控卡片 =====
            Column() {
              Text('储能站实时监控')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .width('100%')
                .margin({ bottom: 10 })

              this.paramItemRef({ label: '储能电量SOC', value: this.essSoc, unit: '%' })
              this.paramItemRef({ label: '储能电压', value: this.essVoltage, unit: 'V' })
              this.paramItemRef({ label: '储能放电流', value: this.essCurrent, unit: 'A' })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ bottom: 12 })

            // ===== 追光角度卡片 =====
            Column() {
              Row() {
                Text('光伏板实时监控')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#333333')
                Blank()
                Button('自动')
                  .height(30)
                  .fontSize(12)
                  .fontColor(this.autoTrack ? Color.White : '#666666')
                  .backgroundColor(this.autoTrack ? '#b1c623' : '#F0F0F0')
                  .borderRadius(15)
                  .padding({ left: 14, right: 14 })
                  .onClick(() => {
                    const target = !this.autoTrack;
                    if (target) {
                      // 开启自动追光前先弹确认弹窗
                      this.showPvAutoDialog = true;
                      return;
                    }
                    this.lastPvManualTime = Date.now();
                    this.setPvAuto(target).then((ok) => {
                      if (ok) {
                        this.autoTrack = target;
                        if (!target) {
                          // 关闭自动模式：把当前滑条角度下发给云端，接管为手动
                          this.sendPvAngle(this.trackAngle);
                        }
                        promptAction.showToast({
                          message: target ? '已开启自动追光' : '已关闭自动追光',
                          duration: 1500
                        });
                      } else {
                        promptAction.showToast({ message: '操作失败，请检查网络', duration: 1500 });
                      }
                    });
                  })
              }
              .width('100%')
              .margin({ bottom: 10 })

              this.paramItemRef({ label: '光伏发电电压', value: this.pvVoltage, unit: 'V' })
              this.paramItemRef({ label: '光伏发电电流', value: this.pvCurrent, unit: 'A' })

              Text('当前追光角度')
                .fontSize(13)
                .fontColor('#999999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 14, bottom: 4 })

              Row() {
                Blank()
                Text(this.trackAngle.toFixed(0))
                  .fontSize(40)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#badc3d')
                Text(' 度')
                  .fontSize(16)
                  .fontColor('#999999')
                  .margin({ left: 4 })
                Blank()
              }
              .width('100%')

              Stack() {
                Slider({
                  value: this.trackAngle,
                  min: 0,
                  max: 180,
                  step: 15,
                  style: SliderStyle.OutSet
                })
                  .width('100%')
                  .trackColor('#E8E8E8')
                  .selectedColor('#badc3d')
                  .blockColor('#badc3d')
                  .margin({ top: 10 })
                  // 自动模式下彻底锁定，拖不动
                  .enabled(!this.autoTrack)
                  .opacity(this.autoTrack ? 0.4 : 1)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    this.trackAngle = value;
                    this.lastPvManualTime = Date.now();
                    // 松手或点击轨道时才下发，拖动过程中不刷屏（云端另有15°对齐+去重兜底）
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.sendPvAngle(value);
                    }
                  })

                // 自动模式下的透明拦截层：滑条被禁用收不到触摸，由它提示
                if (this.autoTrack) {
                  Column()
                    .width('100%')
                    .height(44)
                    .backgroundColor('rgba(0,0,0,0)')
                    .onClick(() => {
                      promptAction.showToast({ message: '请先关闭自动模式', duration: 1500 });
                    })
                }
              }
              .width('100%')

              Row() {
                Text('0°')
                  .fontSize(12)
                  .fontColor('#999999')
                Blank()
                Text('180°')
                  .fontSize(12)
                  .fontColor('#999999')
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .backgroundColor(Color.White)
            .borderRadius(12)
            .shadow({
              radius: 18,
              color: 'rgba(0, 0, 0, 0.16)',
              offsetX: 0,
              offsetY: 5
            })
            .margin({ bottom: 30 })
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

      // ===== 切换供电路径确认弹窗 =====
      if (this.showSwitchDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {
            this.showSwitchDialog = false;
          })
          .zIndex(30)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('提示')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 14 })

          Text('请问是否确认切换供电路径操作')
            .fontSize(15)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 24 })

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .borderRadius(21)
              .onClick(() => {
                this.showSwitchDialog = false;
              })

            Button('确定')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#b1c623')
              .borderRadius(21)
              .onClick(() => {
                // 切换充电供应路径：发真实指令到 VOLTos 的 PC2 引脚
                const target = this.chargePowerPath === 'grid' ? 'ess' : 'grid';
                this.showSwitchDialog = false;
                this.switchPowerPath(target).then((ok) => {
                  if (ok) {
                    this.chargePowerPath = target;
                    promptAction.showToast({
                      message: '已切换至' + this.getPathText(target),
                      duration: 1500
                    });
                  } else {
                    promptAction.showToast({
                      message: '切换指令发送失败，请检查网络',
                      duration: 1500
                    });
                  }
                });
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding({ left: 24, right: 24, top: 24, bottom: 24 })
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.2)',
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

      // ========== 自动追光开启确认弹窗 ==========
      if (this.showPvAutoDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {
            this.showPvAutoDialog = false;
          })
          .zIndex(32)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('确认开启自动追光模式')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 14 })

          Text('开启后，光伏板将按日照计划自动调整角度')
            .fontSize(15)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 24 })

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .borderRadius(21)
              .onClick(() => {
                this.showPvAutoDialog = false;
              })

            Button('确定')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#b1c623')
              .borderRadius(21)
              .onClick(() => {
                this.showPvAutoDialog = false;
                this.lastPvManualTime = Date.now();
                this.setPvAuto(true).then((ok) => {
                  if (ok) {
                    this.autoTrack = true;
                    promptAction.showToast({ message: '已开启自动追光', duration: 1500 });
                  } else {
                    promptAction.showToast({ message: '操作失败，请检查网络', duration: 1500 });
                  }
                });
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding({ left: 24, right: 24, top: 24, bottom: 24 })
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.2)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(33)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      // ========== 停止充电确认弹窗 ==========
      if (this.showStopDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .onClick(() => {
            this.showStopDialog = false;
          })
          .zIndex(34)
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('提示')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 14 })

          Text(`确定要停止 ${this.pendingStopGun} 号枪的充电吗？`)
            .fontSize(15)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 24 })

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor('#666666')
              .backgroundColor('#F0F0F0')
              .borderRadius(21)
              .onClick(() => {
                this.showStopDialog = false;
              })

            Button(this.isStoppingGun ? '停止中' : '确定')
              .layoutWeight(1)
              .height(42)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#FF6B6B')
              .borderRadius(21)
              .enabled(!this.isStoppingGun)
              .onClick(() => {
                this.stopGunCharging();
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding({ left: 24, right: 24, top: 24, bottom: 24 })
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 30,
          color: 'rgba(0, 0, 0, 0.2)',
          offsetX: 0,
          offsetY: 10
        })
        .zIndex(35)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}