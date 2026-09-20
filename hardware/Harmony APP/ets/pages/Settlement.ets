import { router } from '@kit.ArkUI';
import { textToSpeech } from '@kit.CoreSpeechKit';

interface BatteryRating {
  level: string;
  color: string;
  suggestion: string;
}

@Entry
@Component
struct Settlement {
  @State totalTime: string = '2小时18分钟';
  @State totalFee: string = '18.50';
  @State unitPrice: string = '1.20';
  @State startTime: string = '2026-07-05 14:30:00';
  @State endTime: string = '2026-07-05 16:48:00';
  @State orderNo: string = 'CP202607051430001';
  @State stationName: string = '科技园1号桩';
  @State totalElectricity: string = '12.1度';
  @State batteryHealth: number = 89;
  @State aiAdvice: string = '';
  @State maxTemp: number = 38.5;
  @State minTemp: number = 22.3;

  private scroller: Scroller = new Scroller();

  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;

  // 初始化语音合成引擎
  async initTts() {
    try {
      this.ttsEngine = await textToSpeech.createEngine({
        language: 'zh-CN',
        person: 0,
        online: 1
      });
      console.info('TTS引擎初始化成功');
    } catch (e) {
      console.error('TTS引擎初始化失败:', JSON.stringify(e));
    }
  }

  aboutToDisappear() {
    try {
      this.ttsEngine?.stop();
      this.ttsEngine?.shutdown();
    } catch (e) {
      console.error('TTS释放失败:', JSON.stringify(e));
    }
    this.ttsEngine = null;
  }

  // 过滤emoji等非文字符号，避免被朗读出来
  stripEmoji(text: string): string {
    return text
      .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]/gu, '')
      .replace(/[0-9#*]\u{FE0F}?\u{20E3}/gu, '')
      .trim();
  }

  // 朗读指定文本
  speakText(text: string) {
    if (!this.ttsEngine) {
      console.error('TTS引擎未初始化');
      return;
    }
    const cleanText = this.stripEmoji(text);
    if (!cleanText) {
      return;
    }
    try {
      this.ttsEngine.stop();
      this.ttsEngine.speak(cleanText, { requestId: `tts_${Date.now()}` });
    } catch (e) {
      console.error('朗读失败:', JSON.stringify(e));
    }
  }

  aboutToAppear() {
    this.initTts();
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      if (params['batteryHealth'] !== undefined) {
        this.batteryHealth = params['batteryHealth'] as number;
      }
      if (params['aiAdvice'] !== undefined) {
        this.aiAdvice = params['aiAdvice'] as string;
      }
      if (params['accumulatedAmount'] !== undefined) {
        this.totalFee = (params['accumulatedAmount'] as number).toFixed(2);
      }
      if (params['accumulatedDuration'] !== undefined) {
        const duration = params['accumulatedDuration'] as number;
        this.totalTime = this.formatDuration(duration);
      }
      if (params['accumulatedDegree'] !== undefined) {
        this.totalElectricity = (params['accumulatedDegree'] as number).toFixed(1) + '度';
      }
    }
  }

  // 拦截返回事件，跳转到Home页面（包含底部导航栏的主页面）
  onBackPress(): boolean | void {
    // 使用replaceUrl跳转到Home页面，清除历史栈
    AppStorage.setOrCreate('closeHomeDrawer', true);
    router.clear();  // 清空栈，避免主页叠两层
    router.replaceUrl({
      url: 'pages/Home' // 跳转到包含底部导航栏的主页面
    });
    // 返回true表示拦截默认返回行为
    return true;
  }

  formatDuration(seconds: number): string {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (hours > 0) {
      return `${hours}小时${minutes}分钟`;
    } else {
      return `${minutes}分钟`;
    }
  }

  private getNumberArray(count: number): number[] {
    const arr: number[] = [];
    for (let i = 0; i < count; i++) {
      arr.push(i);
    }
    return arr;
  }

  private getBatteryRating(health: number): BatteryRating {
    if (health >= 90) {
      return {
        level: '极佳',
        color: '#4CAF50',
        suggestion: '您的电池状态非常健康，继续保持良好的充电习惯，避免过度放电。'
      };
    } else if (health >= 70) {
      return {
        level: '良好',
        color: '#2196F3',
        suggestion: '电池状态良好，建议定期进行完整充放电循环，维持电池活性。'
      };
    } else if (health >= 50) {
      return {
        level: '普通',
        color: '#FF9800',
        suggestion: '电池性能正常，建议避免高温环境充电，可考虑预约电池检测服务。'
      };
    } else if (health >= 30) {
      return {
        level: '较差',
        color: '#F44336',
        suggestion: '电池容量下降明显，建议尽快到专业维修点检测，避免影响续航。'
      };
    } else {
      return {
        level: '故障',
        color: '#D32F2F',
        suggestion: '电池可能存在故障风险，请立即停止使用并联系售后服务进行检测维修。'
      };
    }
  }

  private getCapacityText(health: number): string {
    const decline = 100 - health;
    if (decline === 0) {
      return '当前容量无下降';
    } else {
      return `容量下降 ${decline}%`;
    }
  }

  private getStrokeDashArray(health: number): number[] {
    const radius = 40;
    const circumference = 2 * Math.PI * radius;
    const progress = health / 100;
    const dashLength = circumference * progress;
    const gapLength = circumference - dashLength;
    return [dashLength, gapLength];
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll(this.scroller) {
        Column() {
          // 标题区域
          Row() {
            Column() {
              Text('充电已完成')
                .fontSize(31)
                .fontWeight(FontWeight.Bolder)
                .fontColor('#1A1A1A')
                .letterSpacing(1)
                .layoutWeight(1)
                .offset({ x: -10, y: 25 })

              Row() {
                Image($r('app.media.ok'))
                  .width(16)
                  .height(16)

                Text('感谢使用VOLT伏安超充~')
                  .fontSize(15)
                  .fontWeight(FontWeight.Regular)
                  .fontColor('#515151')
                  .margin({ left: 3, top: 2 })
              }
              .height(30)
              .offset({ y: -22 })
            }
            .width('70%')
            .height('20%')

            Image($r('app.media.Station'))
              .width(130)
              .height(130)
              .objectFit(ImageFit.Contain)
              .offset({ x: -20 })
          }
          .width('100%')
          .margin({ top: 20 })

          // 充电小票卡片
          Stack() {
            Row() {
              ForEach(
                this.getNumberArray(23),
                (item: number) => {
                  Circle()
                    .width(24)
                    .height(24)
                    .fill('#E0E0E0')
                    .margin({ left: -9 })
                }
              )
            }
            .width('100%')
            .height(6)
            .backgroundColor(Color.Transparent)
            .position({ x: 0, y: 0 })

            Column() {
              Column() {
                Text('充电小票')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#666666')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ bottom: 12 })

                Divider()
                  .color('#E8E8E8')
                  .strokeWidth(1)
                  .margin({ bottom: 14 })

                Row() {
                  Text('站点')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(this.stationName)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 10 })

                Row() {
                  Text('充电时长')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(this.totalTime)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 10 })

                Row() {
                  Text('消费电量')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(this.totalElectricity)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 10 })

                Row() {
                  Text('单价')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(`¥${this.unitPrice}/小时`)
                    .fontSize(14)
                    .fontColor('#333333')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 10 })

                Row() {
                  Text('开始时间')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(this.startTime)
                    .fontSize(13)
                    .fontColor('#666666')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 10 })

                Row() {
                  Text('结束时间')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width(70)
                  Text(this.endTime)
                    .fontSize(13)
                    .fontColor('#666666')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 14 })

                Divider()
                  .color('#E8E8E8')
                  .strokeWidth(1.5)
                  .margin({ bottom: 14 })

                Row() {
                  Text('总计')
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#1A1A1A')
                    .width(70)
                  Text(`¥${this.totalFee}`)
                    .fontSize(28)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FF6B35')
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ bottom: 12 })

                Text(`订单号：${this.orderNo}`)
                  .fontSize(11)
                  .fontColor('#CCCCCC')
                  .fontFamily('monospace')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 4 })
              }
              .padding({ left: 20, right: 20, top: 8, bottom: 20 })
              .width('100%')
            }
            .width('100%')
            .linearGradient({
              direction: GradientDirection.Top,
              colors: [
                ['rgba(255, 255, 255, 1)', 0],
                ['rgba(255, 255, 255, 0.7)', 0.8],
                ['rgba(255, 255, 255, 0.65)', 0.9],
                ['rgba(255, 255, 255, 0.55)', 1]
              ]
            })
            .backdropBlur(7)
            .borderRadius(4)
            .shadow({
              radius: 8,
              color: 'rgba(0, 0, 0, 0.06)',
              offsetX: 0,
              offsetY: 2
            })
          }
          .width('92%')

          // 电池健康报告卡片
          Column() {
            Row() {
              Text('电池健康报告')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .margin({ left: 6 })
            }
            .width('100%')
            .padding({ top: 16, bottom: 16 })

            Row() {
              Column() {
                Stack() {
                  Circle()
                    .width(80)
                    .height(80)
                    .fill('rgba(0,0,0,0.04)')

                  Circle()
                    .width(80)
                    .height(80)
                    .fill('transparent')
                    .stroke(this.getBatteryRating(this.batteryHealth).color)
                    .strokeWidth(6)
                    .strokeDashArray(this.getStrokeDashArray(this.batteryHealth))
                    .strokeDashOffset(0)
                    .rotate({ angle: -90 })
                    .strokeLineCap(LineCapStyle.Round)

                  Column() {
                    Text(`${this.batteryHealth}%`)
                      .fontSize(22)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#1A1A1A')
                  }
                  .alignItems(HorizontalAlign.Center)
                  .justifyContent(FlexAlign.Center)
                  .width('100%')
                  .height('100%')
                }
                .width(80)
                .height(80)
              }
              .width('30%')
              .alignItems(HorizontalAlign.Center)
              .margin({ left: 20 })

              Column() {
                Text('电池评级')
                  .fontSize(13)
                  .fontColor('#999999')
                  .margin({ bottom: 6 })

                Text(this.getBatteryRating(this.batteryHealth).level)
                  .fontSize(24)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.getBatteryRating(this.batteryHealth).color)

                Text(this.getCapacityText(this.batteryHealth))
                  .fontSize(12)
                  .fontColor(this.batteryHealth === 100 ? '#4CAF50' : '#666666')
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                  .borderRadius(12)
                  .backgroundColor(this.batteryHealth === 100 ? 'rgba(76, 175, 80, 0.1)' : 'rgba(0,0,0,0.06)')
                  .margin({ top: 8 })
              }
              .width('70%')
              .alignItems(HorizontalAlign.Center)
              .margin({ left: 10 })
            }
            .width('100%')
            .padding({ bottom: 16 })

            Row() {
              Column() {
                Text('最高温度')
                  .fontSize(12)
                  .fontColor('#999999')
                  .margin({ bottom: 4 })
                Text(`${this.maxTemp}°C`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FF6B35')
              }
              .width('50%')
              .alignItems(HorizontalAlign.Center)

              Divider()
                .color('#E8E8E8')
                .strokeWidth(1)
                .height(30)
                .vertical(true)

              Column() {
                Text('最低温度')
                  .fontSize(12)
                  .fontColor('#999999')
                  .margin({ bottom: 4 })
                Text(`${this.minTemp}°C`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#2196F3')
              }
              .width('50%')
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ bottom: 16 })
            .margin({ top: 10 })

            Divider()
              .color('#E8E8E8')
              .strokeWidth(1)
              .margin({ bottom: 14 })

            Column() {
              Row() {
                Image($r('app.media.hanli'))
                  .width(36)
                  .height(36)
                  .borderRadius(18)

                Column() {
                  Text('安安说')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#1A1A1A')

                  Text('AI智能建议')
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .margin({ left: 10 })
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ bottom: 10 })

              Text() {
                Span(this.aiAdvice || this.getBatteryRating(this.batteryHealth).suggestion)
                Span(' ')
                ImageSpan($r('app.media.shengyin'))
                  .width(14)
                  .height(14)
                  .objectFit(ImageFit.Contain)
                  .verticalAlign(ImageSpanAlignment.CENTER)
                  .onClick(() => {
                    this.speakText(this.aiAdvice || this.getBatteryRating(this.batteryHealth).suggestion);
                  })
              }
              .fontSize(14)
              .fontColor('#666666')
              .lineHeight(22)
              .width('100%')
              .margin({ bottom: 4 })
            }
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 0 })

            Text('安安说由AI生成，仅供参考注意甄别')
              .fontSize(10)
              .fontColor('#CCCCCC')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12 })
              .margin({ top: 0 })
          }
          .width('92%')
          .padding({ left: 20, right: 20, top: 0, bottom: 20 })
          .backgroundColor('rgba(255, 255, 255, 0.95)')
          .backdropBlur(7)
          .borderRadius(4)
          .shadow({
            radius: 8,
            color: 'rgba(0, 0, 0, 0.2)',
            offsetX: 0,
            offsetY: 2
          })
          .margin({ top: 16 })

          Blank()
            .height(100)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 80 })
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.TopStart)

      // 底部固定导航栏
      Row() {
        Text('投诉建议')
          .fontSize(14)
          .fontColor(Color.Black)
          .fontWeight(FontWeight.Medium)
          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
          .textAlign(TextAlign.Center)
          .borderRadius(22)
          .margin({ left: 65 })
          .backgroundColor('rgba(255,255,255,0.7)')
          .shadow({
            radius: 8,
            color: 'rgba(0,0,0,0.2)',
            offsetX: 0,
            offsetY: 2
          })
          .onClick(() => {})

        Blank()
          .width(12)

        Text('联系客服')
          .fontSize(14)
          .fontColor(Color.Black)
          .fontWeight(FontWeight.Medium)
          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
          .textAlign(TextAlign.Center)
          .backgroundColor('rgba(255,255,255,0.7)')
          .borderRadius(22)
          .shadow({
            radius: 8,
            color: 'rgba(0,0,0,0.2)',
            offsetX: 0,
            offsetY: 2
          })
          .onClick(() => {
            console.log('点击联系客服');
          })

        Blank()
          .width(12)

        // ✅ 修改：将"再来一单"改为"完成"，跳转到Home
        Text('完成充电')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
          .textAlign(TextAlign.Center)
          .backgroundColor('#badc3d')
          .borderRadius(22)
          .onClick(() => {
            console.log('点击完成');
            // 跳转到主页
            AppStorage.setOrCreate('closeHomeDrawer', true);
            router.clear();  // 清空栈，避免主页叠两层
            router.replaceUrl({
              url: 'pages/Home'
            });
          })
      }
      .width('100%')
      .height(64)
      .padding({ left: 20, right: 20, bottom: 5 })
      .backgroundColor('rgba(255, 255, 255, 0.7)')
      .backdropBlur(20)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .shadow({
        radius: 8,
        color: 'rgba(0, 0, 0, 0.06)',
        offsetX: 0,
        offsetY: -2
      })
      .margin({ top: 775 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F0')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}