//充电

export interface NexusStatusStatusApiResponse {
  status: string
  data:  NexusStatus
}
// 定义 data 内部的具体字段
export interface NexusStatus {
  id: number
  topic: string
  timestamp: string
  Gun1UserName: string
  Gun2UserName: string
  Gun1UserBal: number
  Gun2UserBal: number
  Gun1Stop: string | null
  Gun2Stop: string | null
  Gun1BatCap: number | null
  Gun2BatCap: number | null
  Gun1Agt: string | null
  Gun2Agt: string | null
  Gun1State: string | null
  Gun2State: string | null
  Gun1Temp: number | null
  Gun2Temp: number | null
  SysTemp: number | null
  SysHumi: number | null
  Gun1Vol: number | null
  Gun2Vol: number | null
  Gun1Cur: number | null
  Gun2Cur: number | null
  Gun1CharSoc: number | null
  Gun2CharSoc: number | null
  Gun1Soc: number | null
  Gun2Soc: number | null
  Gun1CharTemp: number | null
  Gun2CharTemp: number | null
  Gun1Soh: number | null
  Gun2Soh: number | null
  SysPowSup: number | null
  CharPowSup: number | null
  EssSoc: number | null
  EssVol: number | null
  EssCur: number | null
  EssTemp: number | null
  PvVol: number | null
  PvCur: number | null
}