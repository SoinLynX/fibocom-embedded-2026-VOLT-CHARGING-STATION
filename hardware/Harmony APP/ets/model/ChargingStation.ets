// ChargingStation.ts

export interface ChargingStation {
  id: string;
  name: string;
  address: string;
  distance: string;
  status: 'available' | 'occupied' | 'broken';
  price: string;
  latitude: number;
  longitude: number;
}
export interface ChargingStationStatusApiResponse {
  status: string
  data:  ChargingStation[]
}


export function getMockStations(): ChargingStation[] {

  return [
    {
      id: 'VOLT0001',
      name: '伏安超充1号桩',
      address: '科技园区A座地下停车场',
      distance: '300m',
      status: 'available',
      price: '1.2元/度',
      latitude: 24.3666,
      longitude: 118.0400
    },
    {
      id: 'VOLT0002',
      name: '伏安超充2号桩',
      address: '购物中心B2层',
      distance: '500m',
      status: 'occupied',
      price: '1.5元/度',
      latitude: 24.3555,
      longitude: 118.0477
    },
    {
      id: 'VOLT0003',
      name: '伏安超充3号桩',
      address: '产业园东门入口',
      distance: '800m',
      status: 'available',
      price: '0.9元/度',
      latitude: 24.3666,
      longitude: 118.0456
    },
    {
      id: 'VOLT0004',
      name: '伏安超充4号桩',
      address: '政务中心南侧',
      distance: '1.2km',
      status: 'broken',
      price: '1.0元/度',
      latitude: 24.3888,
      longitude: 118.0388
    },
    {
      id: 'VOLT0005',
      name: '伏安超充5号桩',
      address: '商业街地下车库',
      distance: '1.5km',
      status: 'available',
      price: '1.8元/度',
      latitude: 24.3000,
      longitude: 118.0299
    }
  ];
}

export interface GunStateResponse {
  gun1State: number; // 0-空闲, 1-占用, 2-故障
  gun2State: number; // 0-空闲, 1-占用, 2-故障
}

export interface GunStateApiResponse {
  code: number;
  data: GunStateResponse;
  message: string;
}