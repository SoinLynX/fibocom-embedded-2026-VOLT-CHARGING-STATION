import { router, curves } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { liveViewManager } from '@kit.LiveViewKit';
import { Want, wantAgent } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';
import {
  endOrder,
  EndOrderRequest,
  stopCharging,
  StopChargingRequest,
  getGunSoh,
  getGunStatus,
  GunStatusData,
  getAgtText,
  updateUserBalance,
  checkChargingOrder,
  checkAbnormalStop,  // 新增
  AbnormalStopResponse  // 新增
} from '../model/createOrder';

// ==================== AI相关类型定义 ====================
interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ChoiceMessage {
  content: string;
}

interface Choice {
  message: ChoiceMessage;
}

interface ApiResponse {
  choices: Choice[];
}

interface RequestData {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  temperature: number;
  max_tokens: number;
}

@Entry
@Component
struct Charge {
  @State chargePercent: number = 0;
  @State isSuperCharge: boolean = false;
  @State accumulatedAmount: number = 0.12;
  @State accumulatedDuration: number = 0;
  @State accumulatedDegree: number = 0;
  @State timer: number = -1;
  @State isDialogVisible: boolean = false;
  @State isLoadingVisible: boolean = false;
  @State loadingText: string = '正在停止充电';

  @State showAbnormalDialog: boolean = false;  // 新增：异常停止弹窗控制

  @State voltage: number = 0;
  @State current: number = 0;
  @State power: number = 0;
  @State temperature: number = 0;
  @State gunTemp: number = 0;
  @State batteryType: string = 'Li-ion';
  @State batCap: number = 0;
  @State gunStopStatus: number = 0;  // 新增：枪停止状态
  private stopCheckInterval: number = -1;  // 新增：停止状态检查定时器
  private isHandlingExternalStop: boolean = false;  // 外部停止处理中标志，防轮询重叠导致重复跳转

  private batteryHealth: number = 0;
  private gunNumber: number = 1;
  private refreshInterval: number = -1;
  // 订单快照单价（元/度），进入页面时从路由参数或订单数据恢复
  private pricePerKwh: number = 0.58;
  // 页面级结束标志：三个结束路径置 true，置位后任何轮询回调不得再推卡片/实况窗
  // （不能只看全局 isCharging——Home 页轮询发现服务器订单未关时会把它改回 true）
  private sessionEnded: boolean = false;
  private liveViewStarted: boolean = false;  // 实况窗是否已尝试过创建
  private liveViewActive: boolean = false;   // 实况窗是否创建成功

  // ==================== 桌面卡片刷新 ====================
  // 卡片ID由 FormExtension.onAddForm 写入 preferences；
  // 注意：多进程下必须先清 preferences 缓存，否则读到旧数据
  async updateChargeForm(isCharging: boolean = true) {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      preferences.removePreferencesFromCacheSync(ctx, { name: 'volt_form_store' });
      const store = preferences.getPreferencesSync(ctx, { name: 'volt_form_store' });
      const ids = store.getSync('formIds', []) as string[];
      if (!ids || ids.length === 0) {
        console.warn('⚠️ 卡片刷新：没有找到已添加的卡片ID');
        return;
      }
      // 时长只显示 时:分，去掉秒；结束推送直接发全零，不读成员变量（此时可能残留旧值）
      // charging 用数字 1/0：卡片 IPC 管道对字符串 'true'/'false' 有兼容坑
      const durationShort = isCharging ? this.formatDuration(this.accumulatedDuration).substring(0, 5) : '00:00';
      const data: Record<string, string | number> = isCharging ? {
        'soc': Math.min(100, Math.max(0, Math.round(this.chargePercent))),
        'power': this.power.toFixed(1),
        'temp': this.gunTemp.toFixed(1),
        'duration': durationShort,
        'charging': 1
      } : {
        'soc': 0,
        'power': '0.0',
        'temp': '0.0',
        'duration': '00:00',
        'charging': 0
      };
      const bindingData = formBindingData.createFormBindingData(data);
      console.log('🃏 卡片刷新，数量:', ids.length, ' 数据:', JSON.stringify(data));
      for (const formId of ids) {
        formProvider.updateForm(formId, bindingData).catch((err: BusinessError) => {
          console.error('❌ 卡片刷新失败:', formId, JSON.stringify(err));
        });
      }
    } catch (e) {
      console.error('❌ 更新桌面卡片失败:', JSON.stringify(e));
    }
  }

  // ==================== 实况窗（RENT 共享租赁场景，覆盖汽车快充） ====================
  // 前提：AGC 后台已开通实况窗"共享租赁"场景权益，否则 startLiveView 会报错，仅打日志不影响充电

  async buildChargeLiveView(): Promise<liveViewManager.LiveView> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: 'com.example.volt',
          abilityName: 'EntryAbility'
        } as Want
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent = await wantAgent.getWantAgent(wantAgentInfo);
    const percent = Math.min(100, Math.max(0, Math.round(this.chargePercent)));
    return {
      id: 900001 + this.gunNumber,  // 每枪一个固定ID
      event: 'RENT',
      liveViewData: {
        primary: {
          title: '伏安超充 充电中',
          content: [
            { text: `电量 ${percent}%  |  ` },
            { text: `${this.power.toFixed(1)}kW`, textColor: '#FFb1c623' },
            { text: `  |  枪温 ${this.gunTemp.toFixed(1)}℃` }
          ],
          keepTime: 15,
          clickAction: agent,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: percent,
            color: '#FFb1c623',
            backgroundColor: '#FFE5E5E5',
            // nodeIcons 为必传字段：进度条两端节点图标，取 /resources/rawfile 下的文件名
            // 需把 icon_pile.png（充电桩）和 icon_car.png（汽车）放进 entry/src/main/resources/rawfile/
            nodeIcons: ['icon_pile.png', 'icon_car.png'],
            lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE
          }
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          backgroundColor: '#FFb1c623',
          title: `${percent}%`,
          // capsule.icon 同为必传字段，取 /resources/rawfile 下的文件名
          icon: 'logo3.png'
        }
      }
    };
  }

  async startChargingLiveView() {
    try {
      const enabled = await liveViewManager.isLiveViewEnabled();
      if (!enabled) {
        console.warn('⚠️ 实况窗开关未开启，跳过创建');
        this.liveViewStarted = true;  // 置为true防止每次刷新都重试；后续update会静默失败，不影响充电
        return;
      }
      await liveViewManager.startLiveView(await this.buildChargeLiveView());
      this.liveViewStarted = true;
      this.liveViewActive = true;
      console.log('✅ 充电实况窗已创建');
    } catch (e) {
      this.liveViewStarted = true;  // 失败也只尝试一次，不刷屏重试
      console.error('❌ 实况窗创建失败(可能未开通权益):', JSON.stringify(e));
    }
  }

  async updateChargingLiveView() {
    if (!this.liveViewStarted || !this.liveViewActive) {
      return;
    }
    try {
      await liveViewManager.updateLiveView(await this.buildChargeLiveView());
    } catch (e) {
      console.error('❌ 实况窗更新失败:', JSON.stringify(e));
    }
  }

  async stopChargingLiveView() {
    if (!this.liveViewStarted) {
      return;
    }
    try {
      await liveViewManager.stopLiveView(await this.buildChargeLiveView());
      console.log('✅ 充电实况窗已结束');
    } catch (e) {
      console.error('❌ 实况窗结束失败:', JSON.stringify(e));
    }
    this.liveViewStarted = false;
    this.liveViewActive = false;
  }

  // ✅ 从数据库订单的 startTime 恢复已充电时长，之后本地离线累计
  async seedDurationFromOrder() {
    try {
      const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
      console.log('⏱️ 开始恢复累计时长, userId:', userId);
      const result = await checkChargingOrder(userId);
      console.log('⏱️ 订单查询结果: status=', result.status,
        ' hasChargingOrder=', result.hasChargingOrder,
        ' startTime=', result.data ? result.data.startTime : 'null');
      if (result.status === 'success' && result.hasChargingOrder && result.data) {
        const startTimeStr = result.data.startTime;
        if (startTimeStr) {
          // startTime 可能是 2026/08/06 23:17:17 斜杠格式，统一转成 ISO 再解析
          const start = new Date(startTimeStr.replace(/\//g, '-').replace(' ', 'T'));
          const elapsed = Math.floor((Date.now() - start.getTime()) / 1000);
          console.log('⏱️ 解析结果: start=', start.toString(), ' elapsed=', elapsed, '秒');
          if (elapsed >= 0 && elapsed < 86400) {
            this.accumulatedDuration = elapsed;
            console.log('✅ 已从订单恢复累计时长:', elapsed, '秒');
          }
        }
      }
    } catch (error) {
      console.error('❌ 恢复累计时长失败:', error);
    }
  }

  // ✅ 进页先清空上一次充电的残留显示值，避免新会话短暂显示旧数据
  resetSessionState() {
    this.chargePercent = 0;
    this.accumulatedAmount = 0;
    // 时长不清零：先恢复本地暂存的值，等数据库播种返回后再覆盖校准
    this.accumulatedDuration = AppStorage.get<number>('chargeDuration') || 0;
    this.accumulatedDegree = 0;
    this.voltage = 0;
    this.current = 0;
    this.power = 0;
    this.temperature = 0;
    this.gunTemp = 0;
    this.batCap = 0;
    this.gunStopStatus = 0;
  }

  aboutToAppear() {
    console.log('📱 Charge页面加载');
    this.sessionEnded = false;  // 进入页面即视为新会话，解除页面级结束标志
    this.resetSessionState();
    this.seedDurationFromOrder();
    this.startTimer();

    // ✅ 1. 先从路由参数获取枪号
    let gunNumberFromParams: number | null = null;
    try {
      const params = router.getParams() as Record<string, Object>;
      console.log('📥 路由参数:', JSON.stringify(params));
      if (params && params['gunNumber']) {
        gunNumberFromParams = params['gunNumber'] as number;
        console.log('✅ 从路由参数获取枪号:', gunNumberFromParams);
      }
      // 单价快照（分）随路由传入，换算成 元/度
      if (params && params['unitPrice']) {
        const p = params['unitPrice'] as number;
        if (p > 0) {
          this.pricePerKwh = p / 100;
          console.log('✅ 从路由参数获取单价:', this.pricePerKwh, '元/度');
        }
      }
    } catch (error) {
      console.error('❌ 获取路由参数失败:', error);
    }

    // ✅ 2. 如果有路由参数，直接使用
    if (gunNumberFromParams && gunNumberFromParams > 0) {
      this.gunNumber = gunNumberFromParams;
      AppStorage.setOrCreate('gunNumber', this.gunNumber);
      console.log('✅ 使用路由参数枪号:', this.gunNumber);
      this.fetchGunStatus();
      this.startStatusRefresh();
      this.startStopStatusCheck();
      return;
    }

    // ✅ 3. 没有路由参数，从 AppStorage 读取
    const storedGunNumber = AppStorage.get<number>('gunNumber');
    if (storedGunNumber && storedGunNumber > 0) {
      this.gunNumber = storedGunNumber;
      console.log('✅ 从AppStorage读取枪号:', this.gunNumber);
      this.fetchGunStatus();
      this.startStatusRefresh();
      return;
    }

    // ✅ 4. 都没有，从正在充电的订单中获取枪号
    this.restoreFromChargingOrder();
  }

  // ✅ 新增：从充电订单恢复状态
  async restoreFromChargingOrder() {
    try {
      const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
      console.log('🔍 检查是否有充电中的订单，userId:', userId);

      const result = await checkChargingOrder(userId);
      console.log('📦 检查充电订单结果:', JSON.stringify(result));

      if (result.status === 'success' && result.hasChargingOrder && result.data) {
        const order = result.data;
        this.sessionEnded = false;  // 新会话开始，解除页面级结束标志
        this.gunNumber = order.gunNumber;
        AppStorage.setOrCreate('gunNumber', this.gunNumber);
        AppStorage.setOrCreate('isCharging', true);
        AppStorage.setOrCreate('currentOrderId', order.id);

        console.log('✅ 从订单恢复枪号:', this.gunNumber, '订单ID:', order.id);

        // 恢复充电状态
        this.accumulatedAmount = order.totalAmount / 100 || 0;
        this.accumulatedDegree = order.electricity || 0;
        // 恢复订单快照单价（分 -> 元/度），用于本地累计金额
        if (order.unitPrice && order.unitPrice > 0) {
          this.pricePerKwh = order.unitPrice / 100;
        }

        // 获取最新的枪状态
        this.fetchGunStatus();
        this.startStatusRefresh();
      } else {
        console.warn('⚠️ 没有找到充电中的订单，跳转到首页');
        promptAction.showToast({
          message: '没有找到正在充电的订单',
          duration: 2000
        });
        AppStorage.setOrCreate('closeHomeDrawer', true);
        router.replaceUrl({
          url: 'pages/Home'
        });
      }
    } catch (error) {
      console.error('❌ 恢复充电订单失败:', error);
      promptAction.showToast({
        message: '恢复充电状态失败',
        duration: 2000
      });
      AppStorage.setOrCreate('closeHomeDrawer', true);
      router.replaceUrl({
        url: 'pages/Home'
      });
    }
  }

  aboutToDisappear() {
    // ✅ 暂存累计时长，下次进页面先恢复，再等服务端校准；
    // 但订单已结束（sessionEnded）时结束路径已清零，不能用成员残留值覆盖回去
    if (!this.sessionEnded) {
      AppStorage.setOrCreate('chargeDuration', this.accumulatedDuration);
    }
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.refreshInterval !== -1) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = -1;
    }
    // ✅ 新增：清理停止状态检查定时器
    if (this.stopCheckInterval !== -1) {
      clearInterval(this.stopCheckInterval);
      this.stopCheckInterval = -1;
    }
  }



  async handleAbnormalStop() {
    this.sessionEnded = true;  // 页面级结束标志
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.refreshInterval !== -1) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = -1;
    }

    this.isLoadingVisible = true;
    this.loadingText = '正在处理异常停止...';
    AppStorage.setOrCreate('isCharging', false);
    AppStorage.setOrCreate('chargeDuration', 0);  // 充电结束，清空暂存时长
    this.stopChargingLiveView();  // 结束实况窗
    this.updateChargeForm(false);  // 通知卡片充电结束

    const gunNumber = this.gunNumber;
    const orderId = AppStorage.get<string>('currentOrderId') || '';

    try {
      // 1. 下发停止充电指令（枪可能已拔，下发失败不阻断后续结算）
      try {
        const stopReq: StopChargingRequest = {
          gunNumber: gunNumber
        };
        await stopCharging(stopReq);
        console.log('✅ 异常停止：已下发停止指令');
      } catch (error) {
        console.warn('⚠️ 异常停止：停止指令下发失败（枪可能已离线），继续结算', error);
      }

      // 2. 结束订单（订单通常已被服务端以"拔枪停止"结束，404 属正常，仅作兜底）
      if (orderId) {
        try {
          const totalAmountCents = Math.round(this.accumulatedAmount * 100);
          const electricityKwh = Math.round(this.accumulatedDegree * 100);  // 数据库单位为0.01度

          const endOrderReq: EndOrderRequest = {
            orderId: orderId,
            totalAmount: totalAmountCents,
            electricity: electricityKwh,
            endReason: '充电枪拔出，异常停止',
            endTime: this.getCurrentTime()
          };

          const result = await endOrder(endOrderReq);
          console.log('异常停止：endOrder 兜底结果', JSON.stringify(result));
        } catch (error) {
          console.warn('⚠️ 异常停止：订单已被服务端结束，跳过 endOrder', error);
        }
      }

      // 3. 扣费：不再依赖 endOrder 结果，直接按本地累计金额扣
      if (this.accumulatedAmount > 0) {
        const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
        const amountToDeduct = -this.accumulatedAmount;

        console.log(`💰 异常停止：开始扣费，用户 ${userId}，金额 ${amountToDeduct}`);

        const balanceResult = await updateUserBalance({
          userId: userId,
          amount: amountToDeduct
        });

        if (balanceResult.status === 'success') {
          console.log(`✅ 异常停止：扣费成功，新余额: ${balanceResult.newBalance}`);
          AppStorage.setOrCreate('userBalance', balanceResult.newBalance);
        } else {
          console.error('❌ 异常停止：扣费失败:', balanceResult.message);
          promptAction.showToast({
            message: `扣费失败: ${balanceResult.message}`,
            duration: 2000
          });
        }
      }

    } catch (error) {
      console.error('❌ 异常停止处理失败:', error);
    } finally {
      this.isLoadingVisible = false;

      // 查询订单异常状态（用于结算页展示）
      let isAbnormalStop = 1; // 默认认为是异常停止
      let endReason = '充电枪被异常拔出，充电已中断。';

      if (orderId) {
        try {
          const checkResult = await checkAbnormalStop(orderId);
          if (checkResult.status === 'success') {
            isAbnormalStop = checkResult.data.isAbnormalStop;
            endReason = checkResult.data.endReason || '充电枪被异常拔出，充电已中断。';
            console.log('📊 订单异常状态:', isAbnormalStop, endReason);
          }
        } catch (error) {
          console.error('❌ 查询订单异常状态失败:', error);
        }
      }

      router.replaceUrl({
        url: 'pages/Settlement',
        params: {
          batteryHealth: this.batteryHealth,
          aiAdvice: endReason,
          chargePercent: this.chargePercent,
          accumulatedAmount: this.accumulatedAmount,
          accumulatedDuration: this.accumulatedDuration,
          accumulatedDegree: this.accumulatedDegree,
          isSuperCharge: this.isSuperCharge,
          isAbnormalStop: isAbnormalStop === 1  // 转为布尔值
        }
      });
    }
  }

  startTimer() {
    this.timer = setInterval(() => {
      this.accumulatedDuration += 1;
      this.updatePower();
      // ✅ 每秒更新累计金额
      this.updateAccumulatedAmount();
    }, 1000);
  }

  // ✅ 新增：更新累计金额
  // 单价用订单快照单价（下单时从站点档案解析，单位：分 -> 元），兜底 0.58
  updateAccumulatedAmount() {
    this.accumulatedAmount = this.accumulatedDegree * this.pricePerKwh;
  }

  updatePower() {
    // 电压(V) * 电流(A) = 功率(W)
    this.power = this.voltage * this.current;
  }

  formatDuration(seconds: number): string {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
  }

  async fetchGunStatus() {
    try {
      console.log('🔍 开始获取枪状态，枪号:', this.gunNumber);
      const result = await getGunStatus(this.gunNumber);
      console.log('📦 完整响应数据:', JSON.stringify(result));

      if (result.status === 'success') {
        const data = result.data;

        // 会话已结束后，迟到的轮询不得再碰任何成员变量：
        // 服务器侧枪数据在停充后会变成待机零值，覆盖进来会把结算度数清成 0
        if (this.sessionEnded) {
          console.log('⛔ 会话已结束，丢弃迟到的枪状态刷新:', JSON.stringify(data));
          return;
        }

        // 更新UI数据
        this.chargePercent = data.soc;
        // 充电度数只增不减：防止停充瞬间服务器报 0 覆盖掉真实累计值
        this.accumulatedDegree = Math.max(this.accumulatedDegree, data.charSoc || 0);
        this.voltage = data.vol;
        this.current = data.cur;
        this.temperature = data.temp;
        this.gunTemp = data.charTemp;
        this.batCap = data.batCap;
        this.isSuperCharge = data.agt === 2;

        this.updatePower();

        // 充电已结束（三个结束路径先把 isCharging 置 false 并置 sessionEnded），
        // 但本请求可能在结束前就已发出、结束后才回来——
        // 此时不得再用 charging:1 覆盖卡片/实况窗，否则桌面卡片会被顶回充电页。
        // 注意必须同时查页面级 sessionEnded：Home 页轮询可能把全局 isCharging 改回 true
        const stillCharging = (AppStorage.get<boolean>('isCharging') ?? false) && !this.sessionEnded;
        if (stillCharging) {
          // 桌面卡片：每次枪状态刷新同步推送
          this.updateChargeForm(true);

          // 实况窗：首次拿到枪数据时创建，之后每次刷新同步更新
          if (!this.liveViewStarted) {
            this.startChargingLiveView();
          } else {
            this.updateChargingLiveView();
          }
        }

        console.log('✅ UI已更新:', {
          chargePercent: this.chargePercent,
          accumulatedDegree: this.accumulatedDegree,
          voltage: this.voltage,
          current: this.current,
          temperature: this.temperature,
          gunTemp: this.gunTemp,
          batCap: this.batCap,
          isSuperCharge: this.isSuperCharge,
          power: this.power
        });
      }
    } catch (error) {
      console.error('❌ 获取枪状态异常:', error);
    }
  }

  // ✅ 新增：监听枪停止状态
  startStopStatusCheck() {
    if (this.stopCheckInterval !== -1) {
      clearInterval(this.stopCheckInterval);
    }
    this.stopCheckInterval = setInterval(() => {
      this.checkGunStopStatus();
    }, 1000);
  }

  async checkGunStopStatus() {
    // 已在处理外部停止（网络请求未返回期间又来一轮轮询），直接丢弃
    if (this.isHandlingExternalStop) {
      return;
    }

    try {
      const orderId = AppStorage.get<string>('currentOrderId') || '';
      if (!orderId) {
        return;
      }

      const checkResult = await checkAbnormalStop(orderId);
      if (checkResult.status === 'success') {
        const isAbnormal = checkResult.data.isAbnormalStop === 1;
        const endReason = checkResult.data.endReason || '';

        if (isAbnormal) {
          console.log('⚠️ 检测到订单异常停止（拔枪）！');

          this.isHandlingExternalStop = true; // 立即上锁

          if (this.stopCheckInterval !== -1) {
            clearInterval(this.stopCheckInterval);
            this.stopCheckInterval = -1;
          }

          this.showAbnormalDialog = true;
        }
        // 火灾停止：属异常停止，走拔枪同款结算流程（结算页会显示服务端记录的"火灾停止"原因）
        else if (endReason === '火灾停止') {
          console.log('🚨 检测到火灾停止，进入异常结算流程');

          this.isHandlingExternalStop = true; // 立即上锁

          if (this.stopCheckInterval !== -1) {
            clearInterval(this.stopCheckInterval);
            this.stopCheckInterval = -1;
          }

          this.handleAbnormalStop();
        }
        // 桩端屏幕主动停止（订单已被服务端以"屏幕停止"结束）
        else if (endReason === '屏幕停止') {
          console.log('ℹ️ 检测到桩端屏幕主动停止，进入正常结算流程');

          this.isHandlingExternalStop = true; // 立即上锁，后续轮询全部丢弃

          if (this.stopCheckInterval !== -1) {
            clearInterval(this.stopCheckInterval);
            this.stopCheckInterval = -1;
          }

          this.handleScreenStop(endReason);
        }
      }
    } catch (error) {
      console.error('❌ 检查订单异常状态失败:', error);
    }
  }

  async handleScreenStop(endReason: string) {
    this.sessionEnded = true;  // 页面级结束标志
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.refreshInterval !== -1) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = -1;
    }

    this.isLoadingVisible = true;
    this.loadingText = '正在结算...';
    AppStorage.setOrCreate('isCharging', false);
    AppStorage.setOrCreate('chargeDuration', 0);  // 充电结束，清空暂存时长
    this.stopChargingLiveView();  // 结束实况窗
    this.updateChargeForm(false);  // 通知卡片充电结束

    try {
      // 1. 获取桩端结算上报的 SOH（与 g1soh 同批上报到云端）
      this.loadingText = '正在获取电池状态';
      try {
        const sohResult = await getGunSoh(this.gunNumber);
        if (sohResult.status === 'success' && sohResult.data.soh > 0) {
          this.batteryHealth = sohResult.data.soh;
        }
      } catch (error) {
        console.error('获取SOH失败:', error);
      }

      // 2. 扣费（订单已被服务端结束，此处直接按本地累计金额扣）
      if (this.accumulatedAmount > 0) {
        const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
        const balanceResult = await updateUserBalance({
          userId: userId,
          amount: -this.accumulatedAmount
        });

        if (balanceResult.status === 'success') {
          console.log(`✅ 屏幕停止：扣费成功，新余额: ${balanceResult.newBalance}`);
          AppStorage.setOrCreate('userBalance', balanceResult.newBalance);
        } else {
          console.error('❌ 屏幕停止：扣费失败:', balanceResult.message);
        }
      }
    } catch (error) {
      console.error('❌ 屏幕停止结算处理失败:', error);
    } finally {
      this.isLoadingVisible = false;

      // 3. 跳结算页：这是正常停止，isAbnormalStop 传 false
      router.replaceUrl({
        url: 'pages/Settlement',
        params: {
          batteryHealth: this.batteryHealth,
          aiAdvice: '您已在充电桩屏幕端停止充电，本次订单已正常结束。',
          chargePercent: this.chargePercent,
          accumulatedAmount: this.accumulatedAmount,
          accumulatedDuration: this.accumulatedDuration,
          accumulatedDegree: this.accumulatedDegree,
          isSuperCharge: this.isSuperCharge,
          isAbnormalStop: false
        }
      });
    }
  }

  startStatusRefresh() {
    if (this.refreshInterval !== -1) {
      clearInterval(this.refreshInterval);
    }
    this.refreshInterval = setInterval(() => {
      this.fetchGunStatus();
    }, 3000);
  }

  getBatteryHealth() {
    getGunSoh(this.gunNumber).then((result) => {
      if (result.status === 'success' && result.data.soh > 0) {
        this.batteryHealth = result.data.soh;
      } else {
        this.batteryHealth = Math.floor(Math.random() * 20) + 80;
      }
      console.log(`电池健康度: ${this.batteryHealth}%`);
    }).catch(() => {
      this.batteryHealth = Math.floor(Math.random() * 20) + 80;
      console.log(`电池健康度(默认): ${this.batteryHealth}%`);
    });
  }

  async requestAIAdvice(health: number): Promise<string> {
    const httpRequest = http.createHttp();

    try {
      const apiKey = 'sk-35cdb873c97f41d9b9217e05a75a7d3e';
      const url = 'https://api.deepseek.com/v1/chat/completions';

      const messages: ChatMessage[] = [
        {
          role: 'system',
          content: '你是我们公司的充电小管家安安，请用中文和专业的见解简洁地回答客户的充电有关问题'
        },
        {
          role: 'user',
          content: `我的电池当前健康度为${health}%，请根据这个健康度给我一些充电建议和保养建议`
        }
      ];

      const requestData: RequestData = {
        model: 'deepseek-v4-flash',
        messages: messages,
        stream: false,
        temperature: 0.7,
        max_tokens: 500
      };

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`
        },
        extraData: JSON.stringify(requestData),
        connectTimeout: 30000,
        readTimeout: 30000
      });

      if (response.responseCode === 200) {
        try {
          const responseData = JSON.parse(response.result as string) as ApiResponse;
          if (responseData.choices && responseData.choices.length > 0) {
            return responseData.choices[0].message.content;
          } else {
            return 'AI暂时无法提供建议，请稍后重试。';
          }
        } catch (parseError) {
          console.error('解析JSON失败:', parseError);
          return '解析响应数据失败，请稍后重试。';
        }
      } else {
        let errorMsg = `请求失败 (${response.responseCode})`;
        if (response.responseCode === 401) errorMsg = 'API密钥无效，请联系客服。';
        else if (response.responseCode === 429) errorMsg = '请求太频繁，请稍后再试。';
        else if (response.responseCode === 500) errorMsg = 'AI服务器错误，请稍后重试。';
        return errorMsg;
      }

    } catch (error) {
      const err = error as BusinessError;
      console.error('网络请求异常:', err.message);
      return `网络请求失败，请检查网络连接。`;
    } finally {
      httpRequest.destroy();
    }
  }

  async stopCharging() {
    this.sessionEnded = true;  // 页面级结束标志：此后轮询回调一律不推卡片/实况窗
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    // 补清两个轮询定时器：之前漏了，结束后轮询还活着，把卡片顶回充电态
    if (this.refreshInterval !== -1) {
      clearInterval(this.refreshInterval);
      this.refreshInterval = -1;
    }
    if (this.stopCheckInterval !== -1) {
      clearInterval(this.stopCheckInterval);
      this.stopCheckInterval = -1;
    }
    console.log('已停止充电');
    this.isDialogVisible = false;

    this.isLoadingVisible = true;
    this.loadingText = '正在停止充电';

    AppStorage.setOrCreate('isCharging', false);
    AppStorage.setOrCreate('chargeDuration', 0);  // 充电结束，清空暂存时长
    this.stopChargingLiveView();  // 结束实况窗
    this.updateChargeForm(false);  // 通知卡片充电结束

    const gunNumber = this.gunNumber;
    console.log('停止充电 - gunNumber:', gunNumber);

    try {
      const stopReq: StopChargingRequest = {
        gunNumber: gunNumber
      };
      const stopResult = await stopCharging(stopReq);
      console.log('停止充电响应:', JSON.stringify(stopResult));

      if (stopResult.status !== 'success') {
        this.isLoadingVisible = false;
        promptAction.showToast({
          message: stopResult.message || '停止充电指令下发失败',
          duration: 2000
        });
        return;
      }
      console.log('✅ 停止充电指令已下发');

      this.loadingText = '正在获取电池状态';

      const checkInterval = 1000;
      const maxRetries = 30;
      let retryCount = 0;
      let sohValue = 0;

      const waitForSoh = () => {
        return new Promise<number>((resolve, reject) => {
          const timer = setInterval(async () => {
            try {
              retryCount++;
              const sohResult = await getGunSoh(gunNumber);
              console.log(`🔍 检测SOH (第${retryCount}次):`, sohResult);

              if (sohResult.status === 'success' && sohResult.data.soh > 0) {
                clearInterval(timer);
                resolve(sohResult.data.soh);
              } else if (retryCount >= maxRetries) {
                clearInterval(timer);
                reject(new Error('获取电池状态超时'));
              }
            } catch (error) {
              clearInterval(timer);
              reject(error);
            }
          }, checkInterval);
        });
      };

      try {
        sohValue = await waitForSoh();
        console.log('✅ 获取到SOH值:', sohValue);
        this.batteryHealth = sohValue;
      } catch (error) {
        console.error('等待SOH超时:', error);
        if (this.batteryHealth === 0) {
          this.batteryHealth = 95;
        }
      }

    } catch (error) {
      console.error('停止充电异常:', error);
      this.isLoadingVisible = false;
      promptAction.showToast({
        message: '停止充电失败，请重试',
        duration: 2000
      });
      return;
    }

    this.loadingText = '安安正在检查电池';
    await this.delay(500);

    // ✅ 修改：判断健康度是否为1，如果是则不调用AI
    let aiAdvice: string;
    if (this.batteryHealth === 1) {
      console.log('⚠️ 健康度为1，充电时间过短，不调用AI');
      aiAdvice = '充电时间过短，无法生成AI建议，请多充会再试试~';
    } else {
      this.loadingText = '正在获取充电建议';
      aiAdvice = await this.requestAIAdvice(this.batteryHealth);
      console.log('AI建议:', aiAdvice);
    }

    const orderId = AppStorage.get<string>('currentOrderId') || '';
    console.log('结束订单 - orderId:', orderId);

    if (orderId) {
      try {
        // ✅ 计算费用（金额转为分）
        const totalAmountCents = Math.round(this.accumulatedAmount * 100);
        const electricityKwh = Math.round(this.accumulatedDegree * 100);  // 数据库单位为0.01度

        const endOrderReq: EndOrderRequest = {
          orderId: orderId,
          totalAmount: totalAmountCents,
          electricity: electricityKwh,
          endReason: '充电完成',
          endTime: this.getCurrentTime()
        };

        console.log('结束订单请求:', JSON.stringify(endOrderReq));
        const result = await endOrder(endOrderReq);
        console.log('结束订单响应:', JSON.stringify(result));

        if (result.status === 'success') {
          console.log('✅ 订单结束成功');

          // ✅ 从用户余额中扣除费用
          const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
          const amountToDeduct = -this.accumulatedAmount; // 负数表示扣费

          console.log(`💰 开始扣费: 用户 ${userId}，金额 ${amountToDeduct}`);

          const balanceResult = await updateUserBalance({
            userId: userId,
            amount: amountToDeduct
          });

          if (balanceResult.status === 'success') {
            console.log(`✅ 扣费成功！旧余额: ${balanceResult.oldBalance}，新余额: ${balanceResult.newBalance}`);
            AppStorage.setOrCreate('userBalance', balanceResult.newBalance);
          } else {
            console.error('❌ 扣费失败:', balanceResult.message);
            promptAction.showToast({
              message: `扣费失败: ${balanceResult.message}`,
              duration: 2000
            });
          }
        } else {
          console.error('❌ 结束订单失败:', result.message);
          promptAction.showToast({
            message: `结束订单失败: ${result.message}`,
            duration: 2000
          });
        }
      } catch (error) {
        console.error('❌ 结束订单异常:', error);
      }
    } else {
      console.warn('⚠️ 未找到订单ID');
    }

    this.isLoadingVisible = false;

    router.replaceUrl({
      url: 'pages/Settlement',
      params: {
        batteryHealth: this.batteryHealth,
        aiAdvice: aiAdvice,
        chargePercent: this.chargePercent,
        accumulatedAmount: this.accumulatedAmount,
        accumulatedDuration: this.accumulatedDuration,
        accumulatedDegree: this.accumulatedDegree,
        isSuperCharge: this.isSuperCharge
      }
    });
  }

  getCurrentTime(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          Row() {
            Text('充电中')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor('#b1c623')

            Blank()

            Button() {
              Image($r('app.media.stop'))
                .width(24)
                .height(24)
                .fillColor(Color.White)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#ff1f1f')
            .onClick(() => {
              this.isDialogVisible = true;
            })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 10 })
          .margin({ top: 30 })

          Column() {
            Video({
              src: $rawfile('charging_video1.mp4'),
              controller: new VideoController()
            })
              .width('100%')
              .aspectRatio(16 / 9)
              .objectFit(ImageFit.Contain)
              .autoPlay(true)
              .controls(false)
              .loop(true)
              .muted(true)
          }
          .width('100%')
          .height(160)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(Color.White)
          .margin({ top: 20 })

          Stack() {
            Column() {
              Stack() {
                LightBreathCircle()

                Column() {
                  Image($r('app.media.elec'))
                    .width(32)
                    .height(32)
                    .objectFit(ImageFit.Contain)
                    .margin({ bottom: 4 })

                  Text(`${this.chargePercent}`)
                    .fontSize(52)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)

                  Text('%')
                    .fontSize(22)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .opacity(0.8)
                    .margin({ top: -4 })
                }
                .width(160)
                .height(160)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('transparent')
              }
              .width(160)
              .height(160)
              .alignContent(Alignment.Center)

              Text('CHARGING')
                .fontSize(20)
                .fontColor(Color.White)
                .letterSpacing(2)
                .margin({ top: 15 })
                .fontWeight(FontWeight.Medium)

              Progress({
                value: this.chargePercent,
                total: 100,
                type: ProgressType.Linear
              })
                .width('80%')
                .style({
                  strokeWidth: 13,
                  scaleWidth: 1
                })
                .color('#badc3d')
                .backgroundColor('rgba(255,255,255,0.3)')
                .margin({ top: 12 })
            }
            .width('100%')
            .padding({ top: 20, bottom: 15 })
            .backgroundColor('rgba(0,0,0,0.4)')
            .borderRadius(20)
            .backdropBlur(10)
            .clip(true)

            if (this.isSuperCharge) {
              Row() {
                Image($r('app.media.gold'))
                  .width(24)
                  .height(24)
                  .margin({ right: 4 })

                Text('超级快充')
                  .fontSize(15)
                  .fontColor('#FFD700')
                  .fontWeight(FontWeight.Medium)
              }
              .backgroundColor('rgba(0,0,0,0.3)')
              .borderRadius(15)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .position({ x: 8, y: 8 })
            } else {
              Text('普通充电')
                .fontSize(12)
                .fontColor('rgba(255,255,255,0.7)')
                .fontWeight(FontWeight.Medium)
                .backgroundColor('rgba(0,0,0,0.6)')
                .borderRadius(12)
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .position({ x: 10, y: 10 })
            }
          }
          .width('90%')
          .margin({ top: 10 })
          .clip(true)

          Column() {
            Row() {
              Column() {
                Text('累积金额')
                  .fontSize(12)
                  .fontColor('rgba(255,255,255,0.6)')
                Text(`¥${this.accumulatedAmount.toFixed(2)}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .margin({ top: 4 })
              }
              .width('28%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)

              Divider()
                .vertical(true)
                .height('70%')
                .color('rgba(255,255,255,0.2)')
                .strokeWidth(1)

              Column() {
                Text('累计充电时长')
                  .fontSize(12)
                  .fontColor('rgba(255,255,255,0.6)')
                Text(this.formatDuration(this.accumulatedDuration))
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .margin({ top: 4 })
              }
              .width('44%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)

              Divider()
                .vertical(true)
                .height('70%')
                .color('rgba(255,255,255,0.2)')
                .strokeWidth(1)

              Column() {
                Text('累积度数')
                  .fontSize(12)
                  .fontColor('rgba(255,255,255,0.6)')
                Text(`${this.accumulatedDegree.toFixed(2)} kWh`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .margin({ top: 4 })
              }
              .width('28%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .height(70)
          }
          .width('90%')
          .padding({ top: 12, bottom: 12 })
          .backgroundColor('rgba(0,0,0,0.35)')
          .borderRadius(20)
          .backdropBlur(8)
          .margin({ top: 15 })

          Column() {
            Grid() {
              GridItem() { ParamItem({ label: '电压', value: `${this.voltage}V` }) }
              GridItem() { ParamItem({ label: '电流', value: `${this.current}A` }) }
              GridItem() { ParamItem({ label: '功率', value: `${this.power.toFixed(1)}W` }) }
              GridItem() { ParamItem({ label: '温度', value: `${this.temperature}°C` }) }
              GridItem() { ParamItem({ label: '电池容量', value: `${this.batCap} mAh` }) }
              GridItem() { ParamItem({ label: '充电枪温度', value: `${this.gunTemp}°C` }) }
            }
            .columnsTemplate('1fr 1fr')
            .rowsTemplate('1fr 1fr 1fr')
            .columnsGap(10)
            .rowsGap(10)
            .width('100%')
            .height(180)
          }
          .width('90%')
          .padding(15)
          .backgroundColor('rgba(0,0,0,0.3)')
          .borderRadius(20)
          .backdropBlur(8)
          .margin({ top: 20, bottom: 30 })
        }
        .width('100%')
        .padding({ bottom: 20 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#EFEFEF')
      .scrollBar(BarState.Auto)
      .scrollBarColor('rgba(0,0,0,0.3)')
      .scrollBarWidth(4)
      .edgeEffect(EdgeEffect.Spring)

      if (this.isDialogVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.5)')
          .onClick(() => {})
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('是否结束充电')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ top: 30, bottom: 10 })

          Text('结束充电将停止当前充电会话')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ bottom: 30 })

          Row() {
            Button('取消')
              .width(100)
              .height(44)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#f0f0f0')
              .fontColor('#333333')
              .borderRadius(22)
              .onClick(() => {
                this.isDialogVisible = false;
              })

            Blank()
              .width(15)

            Button('确定')
              .width(100)
              .height(44)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#ff1f1f')
              .fontColor(Color.White)
              .borderRadius(22)
              .onClick(() => {
                this.stopCharging();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 25 })
        }
        .width('80%')
        .backgroundColor(Color.White)
        .borderRadius(20)
        .padding({ left: 20, right: 20 })
        .shadow({
          radius: 20,
          color: 'rgba(0,0,0,0.2)',
          offsetX: 0,
          offsetY: 10
        })
        .position({ x: '10%', y: '35%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      if (this.isLoadingVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .backdropBlur(8)
          .onClick(() => {})

        Column() {
          LoadingProgress()
            .width(56)
            .height(56)
            .color('#b1c623')
            .margin({ bottom: 16 })

          Text(this.loadingText)
            .fontSize(16)
            .fontColor('#333333')
            .fontWeight(FontWeight.Medium)
        }
        .width(160)
        .height(160)
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 20,
          color: 'rgba(0,0,0,0.15)',
          offsetX: 0,
          offsetY: 10
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
      }

      if (this.showAbnormalDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.5)')
          .onClick(() => {})

        Column() {

          Text('⚠️')
            .fontSize(48)
            .margin({ top: 24 })

          Text('充电异常中断')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ top: 16 })

          Text('充电枪被拔出，充电已异常停止！')
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .margin({ top: 8, left: 24, right: 24 })

          Button('确定')
            .width(120)
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#b1c623')  // 主题绿色
            .borderRadius(22)
            .margin({ top: 24, bottom: 24 })
            .onClick(() => {
              this.showAbnormalDialog = false;
              this.handleAbnormalStop();
            })
        }
        .width(280)
        .height(280)  // 正方形
        .backgroundColor(Color.White)
        .borderRadius(20)
        .shadow({
          radius: 20,
          color: 'rgba(0,0,0,0.2)',
          offsetX: 0,
          offsetY: 10
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
struct LightBreathCircle {
  @State scaleValue1: number = 1.0;
  @State scaleValue2: number = 1.15;
  @State scaleValue3: number = 1.3;
  @State opacityValue1: number = 0.8;
  @State opacityValue2: number = 0.5;
  @State opacityValue3: number = 0.3;

  aboutToAppear() {
    this.getUIContext()?.animateTo({
      duration: 1200,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.scaleValue1 = 1.4;
      this.opacityValue1 = 0.2;
    })

    setTimeout(() => {
      this.getUIContext()?.animateTo({
        duration: 1600,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.scaleValue2 = 1.6;
        this.opacityValue2 = 0.15;
      })
    }, 200)

    setTimeout(() => {
      this.getUIContext()?.animateTo({
        duration: 2000,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.scaleValue3 = 1.8;
        this.opacityValue3 = 0.08;
      })
    }, 400)
  }

  build() {
    Stack() {
      Circle()
        .width(200)
        .height(200)
        .fill('rgba(144, 238, 144, 0.6)')
        .scale({ x: this.scaleValue3, y: this.scaleValue3 })
        .opacity(this.opacityValue3)
        .strokeWidth(0)
        .antiAlias(true)

      Circle()
        .width(180)
        .height(180)
        .fill('rgba(144, 238, 144, 0.7)')
        .scale({ x: this.scaleValue2, y: this.scaleValue2 })
        .opacity(this.opacityValue2)
        .strokeWidth(0)
        .antiAlias(true)

      Circle()
        .width(160)
        .height(160)
        .fill('rgba(144, 238, 144, 0.9)')
        .scale({ x: this.scaleValue1, y: this.scaleValue1 })
        .opacity(this.opacityValue1)
        .strokeWidth(0)
        .antiAlias(true)

      Circle()
        .width(140)
        .height(140)
        .fill('rgba(186, 220, 61, 0.7)')
        .scale({ x: this.scaleValue1, y: this.scaleValue1 })
        .opacity(this.opacityValue1 * 0.6)
        .strokeWidth(0)
        .antiAlias(true)
        .blur(10)

      Circle()
        .width(120)
        .height(120)
        .fill('rgba(186, 220, 61, 0.5)')
        .scale({ x: this.scaleValue1 * 0.9, y: this.scaleValue1 * 0.9 })
        .opacity(this.opacityValue1 * 0.4)
        .strokeWidth(0)
        .antiAlias(true)
        .blur(20)
    }
    .width(200)
    .height(200)
    .alignContent(Alignment.Center)
  }
}

@Component
struct ParamItem {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column() {
      Text(this.label)
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.6)')
      Text(this.value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#f0f0f0')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(255,255,255,0.08)')
    .borderRadius(12)
    .padding(8)
  }
}