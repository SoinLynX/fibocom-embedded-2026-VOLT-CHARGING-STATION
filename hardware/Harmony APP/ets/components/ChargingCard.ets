// ChargingCard.ets
import { router } from '@kit.ArkUI';

@Component
export struct ChargingCard {
  @Prop batteryLevel: number = 75; // 电量百分比
  @Prop chargeTime: string = '00:23:45'; // 已充电时间
  @Prop isCharging: boolean = true;
  @StorageLink('isCharging') globalChargingState: boolean = false;

  build() {
    if (this.isCharging) {
      Column() {
        // 上半部分：图标 + 文字
        Row() {
          // 左侧图标
          Stack() {
            Image($r('app.media.Station'))
              .width(60)
              .height(60)
              .objectFit(ImageFit.Contain)
          }
          .margin({ right: 12 })

          // 右侧文字
          Column() {
            Row() {
              Text('正在充电中')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor('#B1C623')
                .margin({ right: 8 })

              Text(`${this.batteryLevel}%`)
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor('#B1C623')
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)

            Text(`已充电时长 ${this.chargeTime}`)
              .fontSize(14)
              .fontColor('#999999')
              .margin({top:3})
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })

        // 下半部分：电量进度条
        Column() {
          Row() {
            // 背景条 - 加深颜色使其更明显
            Row() {
              // 填充部分
              Row()
                .width(`${this.batteryLevel}%`)
                .height('100%')
                .backgroundColor('#B1C623')
                .borderRadius(6)
            }
            .width('100%')
            .height(10)
            .backgroundColor('#E8E8E8') // 从半透明改为实色灰色，更明显
            .borderRadius(6)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })
        .margin({ top: 8 })
      }
      .width('90%')
      .backgroundColor('rgba(255, 255, 255, 0.85)')
      .backdropBlur(20)
      .borderRadius(12)
      .shadow({
        radius: 20,
        color: 'rgba(0, 0, 0, 0.25)',
        offsetX: 0,
        offsetY: 8
      })
      .margin({ left: 20, right: 20, top: 10, bottom: 10 })
      .onClick(() => {
        router.pushUrl({
          url: 'pages/Charge'
        }).catch((err: BusinessError) => {
          console.error('跳转充电页失败：' + JSON.stringify(err));
        });
      })
    } else {
      // 不显示任何内容
      Column()
        .height(0)
        .width(0)
    }
  }
}


