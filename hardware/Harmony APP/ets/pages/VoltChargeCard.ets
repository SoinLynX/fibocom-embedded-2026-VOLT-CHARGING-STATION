// 伏安超充 桌面充电卡片 2x2
// 数据由应用进程通过 formProvider.updateForm 推送（LocalStorage 传递）

@Entry
@Component
struct VoltChargeCard {
  @LocalStorageProp('soc') soc: number = 0;
  @LocalStorageProp('power') power: string = '0.0';
  @LocalStorageProp('temp') temp: string = '0.0';
  @LocalStorageProp('duration') duration: string = '00:00';
  @LocalStorageProp('charging') charging: number = 0;

  build() {
    Column() {
      // 顶部：标题 + 状态（两种状态都显示）
      Row() {
        Text('伏安超充')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
        Blank()
        Text(this.charging === 1 ? '充电中' : '未充电')
          .fontSize(11)
          .fontColor(this.charging === 1 ? '#FFFFFF' : '#999999')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(this.charging === 1 ? '#b1c623' : '#EEEEEE')
          .borderRadius(8)
      }
      .width('100%')

      if (this.charging === 1) {
        // ===== 充电中：圆环 + 居中百分比 =====
        Stack() {
          Progress({ value: this.soc, total: 100, type: ProgressType.Ring })
            .width(88)
            .height(88)
            .color('#b1c623')
            .backgroundColor('#EEEEEE')
            .style({ strokeWidth: 8 })
          Text(`${this.soc}%`)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#b1c623')
        }
        .layoutWeight(1)

        // 底部：功率 / 枪温 / 时长
        Row() {
          Column() {
            Text(`${this.power}kW`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
            Text('功率')
              .fontSize(10)
              .fontColor('#999999')
          }
          .layoutWeight(1)

          Column() {
            Text(`${this.temp}℃`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
            Text('枪温')
              .fontSize(10)
              .fontColor('#999999')
          }
          .layoutWeight(1)

          Column() {
            Text(this.duration)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
            Text('时长')
              .fontSize(10)
              .fontColor('#999999')
          }
          .layoutWeight(1)
        }
        .width('100%')
      } else {
        // ===== 未充电：图标 + 提示语，底部单独一行长logo =====
        Row() {
          Image($r('app.media.Station'))
            .width(64)
            .height(64)
            .objectFit(ImageFit.Contain)
          Text('小安等待您来充电~^v^')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#b1c623')
            .maxLines(3)
            .layoutWeight(1)
            .margin({ left: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Image($r('app.media.logo2'))
          .width('100%')
          .height(24)
          .objectFit(ImageFit.Contain)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    // 点击卡片跳回应用
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        bundleName: 'com.example.volt',
        abilityName: 'EntryAbility'
      });
    })
  }
}