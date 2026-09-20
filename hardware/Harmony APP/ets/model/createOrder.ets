import axios, { AxiosResponse, AxiosError } from '@ohos/axios'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { AppIPConfig } from '../model/IP';
import json from '@ohos.util.json';

// ==================== 创建订单 ====================
export interface CreateOrderRequest {
  stationName: string
  stationAddress: string
  gunNumber: number
  startTime: string
  unitPrice: number
  userId?: string
  totalAmount?: number
  electricity?: number
  duration?: string
  statusColor?: string
}

export interface CreateOrderResponse {
  status: string
  message?: string
  orderId?: string
}

// ==================== 获取用户余额 ====================
export class BalanceData {
  userId: string = ''
  userName: string = ''
  balance: number = 0
}

export class GetBalanceResponse {
  status: string = ''
  data: BalanceData = new BalanceData()
}

export async function getUserBalance(userId: string): Promise<number> {
  try {
    const response: AxiosResponse<GetBalanceResponse> = await axios.get<GetBalanceResponse>(
      AppIPConfig.BASE_URL + '/api/nexus/users/' + userId + '/balance',
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    if (response.data.status === 'success') {
      hilog.info(0x0000, 'GetBalance', '获取余额成功，用户: %{public}s，余额: %{public}d',
        response.data.data.userId, response.data.data.balance)
      return response.data.data.balance
    } else {
      return 0
    }

  } catch (error) {
    hilog.error(0x0000, 'GetBalance', '获取余额失败: %{public}s', error.message || '未知错误')
    return 0
  }
}

export async function createOrder(req: CreateOrderRequest): Promise<CreateOrderResponse> {
  try {
    const response: AxiosResponse<CreateOrderResponse> = await axios.post<CreateOrderResponse,
    AxiosResponse<CreateOrderResponse>,
    CreateOrderRequest>(
      AppIPConfig.BASE_URL + '/api/createOrder',
      req,
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'CreateOrder', '订单创建成功，订单ID: %{public}s', response.data.orderId || '')
    return response.data

  } catch (error) {
    let errorMsg: CreateOrderResponse = {
      status: '失败',
      message: error.message || '未知错误'
    }
    hilog.error(0x0000, 'CreateOrder', '创建失败: %{public}s', errorMsg.message)
    return errorMsg
  }
}

// ==================== 结束订单 ====================
export interface EndOrderRequest {
  orderId: string
  endTime?: string
  endReason?: string
  totalAmount?: number
  electricity?: number
  duration?: string
}

export interface EndOrderResponse {
  status: string
  message?: string
  orderId?: string
}

// ==================== 查询枪全部实时状态 ====================
export interface GunStatusData {
  gunNumber: number
  soc: number        // 电池SOC（%）
  charSoc: number    // 充电SOC（%）
  vol: number        // 电压（mV）
  cur: number        // 电流（mA）
  charTemp: number   // 充电温度（°C）
  temp: number       // 电池温度（°C）
  batCap: number     // 电池容量（mAh）
  agt: number        // 充电协议: 1-普通充电, 2-超级快充
}

export interface GunStatusResponse {
  status: string
  data: GunStatusData
  message?: string
}

export async function getGunStatus(gunNumber: number): Promise<GunStatusResponse> {
  try {
    const response: AxiosResponse<GunStatusResponse> = await axios.get<GunStatusResponse>(
      AppIPConfig.BASE_URL + '/api/nexus/gun-status',
      {
        params: {
          gunNumber: gunNumber
        },
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'GetGunStatus', '获取枪状态成功，枪号: %{public}d，SOC: %{public}d%%，电压: %{public}d mV',
      response.data.data.gunNumber, response.data.data.soc, response.data.data.vol)
    return response.data

  } catch (error) {
    let errorMsg: GunStatusResponse = {
      status: '失败',
      data: {
        gunNumber: gunNumber,
        soc: 0,
        charSoc: 0,
        vol: 0,
        cur: 0,
        charTemp: 0,
        temp: 0,
        batCap: 0,
        agt: 0
      },
      message: error.message || '未知错误'
    }
    hilog.error(0x0000, 'GetGunStatus', '获取枪状态失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}

// ==================== 辅助函数：获取充电协议名称 ====================
export function getAgtText(agt: number): string {
  switch (agt) {
    case 1:
      return '普通充电'
    case 2:
      return '超级快充'
    default:
      return '未知'
  }
}

export async function endOrder(req: EndOrderRequest): Promise<EndOrderResponse> {
  try {
    const response: AxiosResponse<EndOrderResponse> = await axios.post<EndOrderResponse,
    AxiosResponse<EndOrderResponse>,
    EndOrderRequest>(
      AppIPConfig.BASE_URL + '/api/endOrder',
      req,
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'EndOrder', '订单结束成功，订单ID: %{public}s', response.data.orderId || '')
    return response.data

  } catch (error) {
    let errorMsg: EndOrderResponse = {
      status: '失败',
      message: error.message || '未知错误'
    }
    hilog.error(0x0000, 'EndOrder', '结束订单失败: %{public}s', errorMsg.message)
    return errorMsg
  }
}

// ==================== 检查充电中订单 ====================
export interface ChargingOrderData {
  id: string
  userId: string
  stationName: string
  stationAddress: string
  gunNumber: number
  startTime: string
  endTime: string | null
  endReason: string | null
  duration: string
  totalAmount: number
  unitPrice: number
  electricity: number
  status: string
  statusColor: string
}

export interface CheckChargingOrderResponse {
  status: string
  hasChargingOrder: boolean
  data?: ChargingOrderData | null
}

export async function checkChargingOrder(userId: string): Promise<CheckChargingOrderResponse> {
  try {
    const response: AxiosResponse<CheckChargingOrderResponse> = await axios.get<CheckChargingOrderResponse>(
      AppIPConfig.BASE_URL + '/api/nexus/orders/charging/check',
      {
        params: {
          userId: userId
        },
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'CheckOrder', '检查充电中订单成功，hasChargingOrder: %{public}s', String(response.data.hasChargingOrder))
    return response.data

  } catch (error) {
    let errorMsg: CheckChargingOrderResponse = {
      status: '失败',
      hasChargingOrder: false,
      data: null
    }
    hilog.error(0x0000, 'CheckOrder', '检查充电中订单失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}

// ==================== 修改用户余额 ====================
export interface UpdateBalanceRequest {
  userId: string
  amount: number  // 正数=充值，负数=扣费
}

export interface UpdateBalanceResponse {
  status: string
  userId: string
  oldBalance: number
  newBalance: number
  message: string
}

export async function updateUserBalance(req: UpdateBalanceRequest): Promise<UpdateBalanceResponse> {
  try {
    const response: AxiosResponse<UpdateBalanceResponse> = await axios.post<UpdateBalanceResponse,
    AxiosResponse<UpdateBalanceResponse>,
    UpdateBalanceRequest>(
      AppIPConfig.BASE_URL + '/api/nexus/users/balance',
      req,
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'UpdateBalance', '余额修改成功，用户: %{public}s，旧余额: %{public}d，新余额: %{public}d',
      response.data.userId, response.data.oldBalance, response.data.newBalance)
    return response.data

  } catch (error) {
    let errorMsg: UpdateBalanceResponse = {
      status: '失败',
      userId: '',
      oldBalance: 0,
      newBalance: 0,
      message: error.message || '未知错误'
    }
    hilog.error(0x0000, 'UpdateBalance', '修改余额失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}

export interface GunStateResponse {
  gun1State: number; // 0-空闲, 1-插枪, 2-占用
  gun2State: number; // 0-空闲, 1-插枪, 2-占用
}

export interface GunStateApiResponse {
  code: number;
  data: GunStateResponse;
  message: string;
}

// ==================== 下发充电指令 ====================
export interface StartChargingRequest {
  userId: string
  gunNumber: number // 1 或 2
}

export interface StartChargingPayload {
  Gun1CtrSta?: number
  Gun1UserName?: string
  Gun1UserBal?: number
  Gun2CtrSta?: number
  Gun2UserName?: string
  Gun2UserBal?: number
}

export interface StartChargingData {
  userId: string
  userName: string
  balance: number
  gunNumber: number
  topic: string
  payload: StartChargingPayload
}

export interface StartChargingResponse {
  status: string
  message: string
  data: StartChargingData
}

export async function startCharging(req: StartChargingRequest): Promise<StartChargingResponse> {
  try {
    const response: AxiosResponse<StartChargingResponse> = await axios.post<StartChargingResponse,
    AxiosResponse<StartChargingResponse>,
    StartChargingRequest>(
      AppIPConfig.BASE_URL + '/api/nexus/start-charging',
      req,
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'StartCharging', '充电指令下发成功，枪号: %{public}d，用户: %{public}s',
      response.data.data.gunNumber, response.data.data.userName)
    return response.data

  } catch (error) {
    let errorMsg: StartChargingResponse = {
      status: '失败',
      message: error.message || '未知错误',
      data: {
        userId: '',
        userName: '',
        balance: 0,
        gunNumber: 0,
        topic: '',
        payload: {}
      }
    }
    hilog.error(0x0000, 'StartCharging', '下发充电指令失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}

// ==================== 停止充电指令 ====================
export interface StopChargingRequest {
  gunNumber: number // 1 或 2
}

export interface StopChargingPayload {
  Gun1CtrSta?: number
  Gun2CtrSta?: number
}

export interface StopChargingData {
  gunNumber: number
  topic: string
  payload: StopChargingPayload
}

export interface StopChargingResponse {
  status: string
  message: string
  data: StopChargingData
}

export async function stopCharging(req: StopChargingRequest): Promise<StopChargingResponse> {
  try {
    const response: AxiosResponse<StopChargingResponse> = await axios.post<StopChargingResponse,
    AxiosResponse<StopChargingResponse>,
    StopChargingRequest>(
      AppIPConfig.BASE_URL + '/api/nexus/stop-charging',
      req,
      {
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'StopCharging', '停止充电指令下发成功，枪号: %{public}d',
      response.data.data.gunNumber)
    return response.data

  } catch (error) {
    let errorMsg: StopChargingResponse = {
      status: '失败',
      message: error.message || '未知错误',
      data: {
        gunNumber: 0,
        topic: '',
        payload: {}
      }
    }
    hilog.error(0x0000, 'StopCharging', '停止充电指令下发失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}


// ==================== 查询枪SOH ====================
export interface GunSohData {
  gunNumber: number
  soh: number
}

export interface GunSohResponse {
  status: string
  data: GunSohData
  message?: string
}

export async function getGunSoh(gunNumber: number): Promise<GunSohResponse> {
  try {
    const response: AxiosResponse<GunSohResponse> = await axios.get<GunSohResponse>(
      AppIPConfig.BASE_URL + '/api/nexus/gun-soh',
      {
        params: {
          gunNumber: gunNumber
        },
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'GetGunSoh', '获取SOH成功，枪号: %{public}d，SOH: %{public}d',
      response.data.data.gunNumber, response.data.data.soh)
    return response.data

  } catch (error) {
    let errorMsg: GunSohResponse = {
      status: '失败',
      data: {
        gunNumber: gunNumber,
        soh: 0
      },
      message: error.message || '未知错误'
    }
    hilog.error(0x0000, 'GetGunSoh', '获取SOH失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}

// ==================== 查询订单是否异常停止 ====================
export interface AbnormalStopData {
  orderId: string
  isAbnormalStop: number  // 1=拔枪停止, 0=正常结束
  endReason: string
}

export interface AbnormalStopResponse {
  status: string
  data: AbnormalStopData
}

export async function checkAbnormalStop(orderId: string): Promise<AbnormalStopResponse> {
  try {
    const response: AxiosResponse<AbnormalStopResponse> = await axios.get<AbnormalStopResponse>(
      AppIPConfig.BASE_URL + '/api/nexus/order/abnormal-check',
      {
        params: {
          orderId: orderId
        },
        headers: {
          'Content-Type': 'application/json'
        }
      }
    )

    hilog.info(0x0000, 'CheckAbnormalStop', '查询订单异常停止成功，订单: %{public}s，isAbnormalStop: %{public}d',
      response.data.data.orderId, response.data.data.isAbnormalStop)
    return response.data

  } catch (error) {
    let errorMsg: AbnormalStopResponse = {
      status: '失败',
      data: {
        orderId: orderId,
        isAbnormalStop: 0,
        endReason: ''
      }
    }
    hilog.error(0x0000, 'CheckAbnormalStop', '查询订单异常停止失败: %{public}s', error.message || '未知错误')
    return errorMsg
  }
}