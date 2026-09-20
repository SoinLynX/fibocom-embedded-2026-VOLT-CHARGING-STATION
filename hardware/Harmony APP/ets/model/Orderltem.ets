// Orderltem.ts

// 订单数据接口
export interface OrderItem {
  id: string;
  stationName: string;
  stationAddress: string;
  gunNumber: number;
  startTime: string;
  endTime?: string;
  duration: string;
  totalAmount: number;
  unitPrice: number;
  electricity: number;
  status: OrderStatus | string;  // ✅ 支持字符串和枚举
  statusColor: string;
}

export interface OrderItemStatusApiResponse {
  status: string
  data: OrderItem[]
}

// 订单状态枚举
export enum OrderStatus {
  PENDING = '待支付',
  PAID = '已支付',
  CHARGING = '充电中',
  COMPLETED = '已完成',
  CANCELLED = '已取消'
}

export function OrderItemLoadMockData(): OrderItem[] {
  return [
    {
      id: '20260705001',
      stationName: '伏安超冲充电站（硬件园店）',
      stationAddress: '泉州',
      gunNumber: 1,
      startTime: '2026-07-05 14:30:00',
      endTime: '2026-07-05 15:45:00',
      duration: '1小时15分钟',
      totalAmount: 45.75,
      unitPrice: 1.2,
      electricity: 38.13,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    },
    {
      id: '20260705002',
      stationName: '伏安超冲充电站（TS广场店）',
      stationAddress: '厦门市湖里区SM城市广场',
      gunNumber: 2,
      startTime: '2026-07-05 09:20:00',
      duration: '充电中...',
      totalAmount: 23.50,
      unitPrice: 1.0,
      electricity: 23.50,
      status: OrderStatus.CHARGING,
      statusColor: '#FF9800'
    },
    {
      id: '20260704003',
      stationName: '伏安超冲充电站（火车站店）',
      stationAddress: '厦门市思明区火车站南广场',
      gunNumber: 1,
      startTime: '2026-07-04 18:00:00',
      endTime: '2026-07-04 19:30:00',
      duration: '1小时30分钟',
      totalAmount: 56.80,
      unitPrice: 1.2,
      electricity: 47.33,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    },
    {
      id: '20260704004',
      stationName: '伏安超冲充电站（机场店）',
      stationAddress: '厦门市湖里区高崎机场T4航站楼',
      gunNumber: 2,
      startTime: '2026-07-04 12:15:00',
      duration: '充电中...',
      totalAmount: 18.40,
      unitPrice: 0.8,
      electricity: 23.00,
      status: OrderStatus.PENDING,
      statusColor: '#9E9E9E'
    },
    {
      id: '20260703005',
      stationName: '伏安超冲充电站（集美万达店）',
      stationAddress: '厦门市集美区万达广场',
      gunNumber: 1,
      startTime: '2026-07-03 16:40:00',
      endTime: '2026-07-03 17:50:00',
      duration: '1小时10分钟',
      totalAmount: 38.20,
      unitPrice: 1.1,
      electricity: 34.73,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    },
    {
      id: '20260703006',
      stationName: '伏安超冲充电站（海沧店）',
      stationAddress: '厦门市海沧区阿罗海城市广场',
      gunNumber: 2,
      startTime: '2026-07-03 08:00:00',
      endTime: '2026-07-03 08:45:00',
      duration: '45分钟',
      totalAmount: 22.50,
      unitPrice: 1.0,
      electricity: 22.50,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    },
    {
      id: '20260702007',
      stationName: '伏安超冲充电站（同安店）',
      stationAddress: '厦门市同安区钟楼壹号',
      gunNumber: 1,
      startTime: '2026-07-02 20:30:00',
      endTime: '2026-07-02 21:15:00',
      duration: '45分钟',
      totalAmount: 25.60,
      unitPrice: 1.15,
      electricity: 22.26,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    },
    {
      id: '20260701008',
      stationName: '伏安超冲充电站（翔安店）',
      stationAddress: '厦门市翔安区汇景广场',
      gunNumber: 2,
      startTime: '2026-07-01 11:00:00',
      endTime: '2026-07-01 12:20:00',
      duration: '1小时20分钟',
      totalAmount: 42.30,
      unitPrice: 1.05,
      electricity: 40.29,
      status: OrderStatus.COMPLETED,
      statusColor: '#4CAF50'
    }
  ];
}