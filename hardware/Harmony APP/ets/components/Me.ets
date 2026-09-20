import { promptAction, router, curves } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { getUserBalance, updateUserBalance } from '../model/createOrder';
import axios, { AxiosResponse } from '@ohos/axios';
import { AppIPConfig } from '../model/IP';

// 用户信息接口响应（复用 balance 接口，返回里带 userName）
interface UserInfoData {
  userId: string;
  userName: string;
  balance: number;
}
interface UserInfoResp {
  status: string;
  data: UserInfoData;
}

@Component
export struct Me {
  @State avatarUrl: string = 'app.media.default_avatar';
  @State userName: string = '';
  // 编辑名称弹窗
  @State showEditNameDialog: boolean = false;
  @State editNameInput: string = '';
  @State isSavingName: boolean = false;
  @State userAccount: string = '138****8888';
  @State balance: string = '0.00';
  @State showRechargeDialog: boolean = false;

  // 与 Details 页一致的拨号功能
  makePhoneCall(phoneNumber: string) {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      let want: Want = { uri: `tel:${phoneNumber}` };
      context.startAbility(want, (err: BusinessError) => {
        if (err) {
          console.error('拨号失败：' + JSON.stringify(err));
          promptAction.showToast({ message: '拨号失败，请检查是否安装拨号应用', duration: 2000 });
        }
      });
    } catch (error) {
      console.error('拨号异常：' + JSON.stringify(error));
      promptAction.showToast({ message: '拨号失败，请稍后重试', duration: 2000 });
    }
  }
  @State selectedAmount: number = 0;
  @State customAmount: string = '';
  @State isLoading: boolean = true;
  @State private lastBalance: string = '';

  @State showLoadingDialog: boolean = false;
  @State loadingText: string = '正在拉起支付';
  @State loadingIcon: string = 'app.media.loading';
  @State isSuccess: boolean = false;

  @StorageLink('refreshMe') @Watch('onRefreshMeChange') refreshSignal: number = 0;

  private amounts: number[] = [10, 30, 50, 100, 200, 500];

  aboutToAppear() {
    this.loadBalance();
    this.loadUserInfo();
  }

  // 从服务器用户表拉取真实用户名（复用 balance 接口，响应里带 userName）
  async loadUserInfo() {
    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
    try {
      const resp: AxiosResponse<UserInfoResp> = await axios.get<UserInfoResp>(
        AppIPConfig.BASE_URL + '/api/nexus/users/' + userId + '/balance');
      if (resp.data.status === 'success' && resp.data.data.userName) {
        this.userName = resp.data.data.userName;
      }
    } catch (error) {
      console.error('获取用户信息失败:' + JSON.stringify(error));
    }
  }

  // 保存新名称到服务器用户表
  async saveUserName() {
    const newName = this.editNameInput.trim();
    if (!newName) {
      promptAction.showToast({ message: '名称不能为空', duration: 2000 });
      return;
    }
    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
    this.isSavingName = true;
    try {
      const resp: AxiosResponse<UserInfoResp> = await axios.put<UserInfoResp>(
        AppIPConfig.BASE_URL + '/api/nexus/users/' + userId,
        { userName: newName },
        { headers: { 'Content-Type': 'application/json' } });
      if (resp.data.status === 'success') {
        this.userName = newName;
        this.showEditNameDialog = false;
        promptAction.showToast({ message: '名称已更新', duration: 2000 });
      } else {
        promptAction.showToast({ message: '保存失败，请稍后重试', duration: 2000 });
      }
    } catch (error) {
      console.error('保存名称失败:' + JSON.stringify(error));
      promptAction.showToast({ message: '保存失败，请检查网络', duration: 2000 });
    } finally {
      this.isSavingName = false;
    }
  }

  onRefreshMeChange() {
    if (this.refreshSignal > 0) {
      this.loadBalance();
    }
  }

  async loadBalance() {
    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';
    const balance = await getUserBalance(userId);
    const newBalance = balance.toFixed(2);

    // ✅ 余额没变，直接返回，不显示加载动画
    if (this.lastBalance === newBalance && this.lastBalance !== '') {
      return;
    }

    // ✅ 余额变了，显示加载动画并更新
    this.isLoading = true;
    this.lastBalance = newBalance;

    setTimeout(() => {
      this.balance = newBalance;
      this.isLoading = false;
    }, 300);
  }

  private simulatePayment() {
    this.showLoadingDialog = true;
    this.loadingText = '正在拉起支付';
    this.isSuccess = false;

    const amount = this.selectedAmount || parseFloat(this.customAmount) || 0;
    const userId = AppStorage.get<string>('userId') || 'VOLT06300001';

    setTimeout(() => {
      this.loadingText = '等待支付结果';

      setTimeout(async () => {
        const result = await updateUserBalance({
          userId: userId,
          amount: amount
        });

        if (result.status === 'success') {
          this.isSuccess = true;
          this.loadingText = '充值成功';
          this.balance = result.newBalance.toFixed(2);
        } else {
          this.isSuccess = false;
          this.loadingText = '充值失败';
        }

        setTimeout(() => {
          this.showLoadingDialog = false;
          this.showRechargeDialog = false;

          this.selectedAmount = 0;
          this.customAmount = '';
          this.isSuccess = false;
          this.loadingText = '';

          if (result.status !== 'success') {
            promptAction.showToast({
              message: result.message || '充值失败，请重试',
              duration: 2000
            });
          }
        }, 1500);
      }, 1500);
    }, 1500);
  }

  build() {
    Stack() {
      Image($r('app.media.green'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      Text("VOLT")
        .fontSize(90)
        .fontColor('#e4eb4f')
        .fontWeight(FontWeight.Bolder)
        .offset({ x: 90, y: -330 })

      Text("伏安超充")
        .fontSize(96)
        .fontColor('#e4eb4f')
        .fontWeight(FontWeight.Bolder)
        .offset({ x: 145, y: -20 })
        .rotate({ angle: 90 })
        .maxLines(1)

      Column() {
        Scroll() {
          Column() {
            Text("我的")
              .fontSize(32)
              .fontColor('#b1c623')
              .fontWeight(FontWeight.Bolder)
              .textAlign(TextAlign.Start)
              .width('75%')
              .margin({ top: 45, left: -60 })
              .offset({ x: -8 })

            Column() {
              Row() {
                Image($r('app.media.wangchan'))
                  .width(70)
                  .height(70)
                  .borderRadius(35)
                  .borderWidth(2)
                  .borderColor(Color.White)
                  .objectFit(ImageFit.Cover)

                Column() {
                  Text(this.userName)
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#1A1A1A')
                    .width('100%')
                    .textAlign(TextAlign.Start)

                  Text(this.userAccount)
                    .fontSize(14)
                    .fontColor('#4A4A4A')
                    .width('100%')
                    .textAlign(TextAlign.Start)
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 16 })
                .layoutWeight(1)

                Button('编辑名称')
                  .fontSize(13)
                  .fontColor('#1A1A1A')
                  .backgroundColor('rgba(0,0,0,0.08)')
                  .borderRadius(18)
                  .height(32)
                  .padding({ left: 16, right: 16 })
                  .onClick(() => {
                    this.editNameInput = this.userName;
                    this.showEditNameDialog = true;
                  })
              }
              .width('100%')
              .padding(20)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor('rgba(255,255,255,0.5)')
            .backdropBlur(20)
            .margin({ top: 15 })
            .shadow({
              radius: 8,
              color: 'rgba(0,0,0,0.08)',
              offsetX: 0,
              offsetY: 2
            })

            Column() {
              Row() {
                Column() {
                  Text('账户余额（元）')
                    .fontSize(14)
                    .fontColor('#4A4A4A')
                    .textAlign(TextAlign.Start)
                    .width('100%')

                  if (this.isLoading) {
                    LoadingProgress()
                      .width(28)
                      .height(28)
                      .color('#b1c623')
                      .margin({ top: 8 })
                      .animation({
                        duration: 300,
                        curve: Curve.EaseInOut
                      })
                  } else {
                    Text(`¥ ${this.balance}`)
                      .fontSize(32)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#1A1A1A')
                      .textAlign(TextAlign.Start)
                      .width('100%')
                      .margin({ top: 8 })
                      .animation({
                        duration: 300,
                        curve: Curve.EaseInOut
                      })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button('去充值')
                  .fontSize(15)
                  .fontColor(Color.White)
                  .backgroundColor('#b1c623')
                  .borderRadius(22)
                  .height(44)
                  .padding({ left: 24, right: 24 })
                  .onClick(() => {
                    this.showRechargeDialog = true
                  })
              }
              .width('100%')
              .padding(20)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor('rgba(255,255,255,0.5)')
            .backdropBlur(20)
            .margin({ top: 12 })
            .shadow({
              radius: 8,
              color: 'rgba(0,0,0,0.08)',
              offsetX: 0,
              offsetY: 2
            })

            Column() {
              Row() {
                Row() {
                  Image($r('app.media.about'))
                    .width(24)
                    .height(24)
                    .margin({ right: 12 })
                  Text('关于我们')
                    .fontSize(16)
                    .fontColor('#1A1A1A')
                }
                Text('›')
                  .fontSize(20)
                  .fontColor('#999999')
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .borderRadius(12)
              .stateStyles({
                normal: { .backgroundColor('rgba(0,0,0,0)') },
                pressed: { .backgroundColor('rgba(0,0,0,0.12)') }
              })
              .onClick(() => {
                promptAction.showToast({ message: '功能正在开发中', duration: 2000 });
              })

              Divider()
                .color('rgba(0,0,0,0.06)')
                .margin({ left: 16, right: 16 })

              Row() {
                Row() {
                  Image($r('app.media.exit'))
                    .width(24)
                    .height(24)
                    .margin({ right: 12 })
                  Text('退出登陆')
                    .fontSize(16)
                    .fontColor('#1A1A1A')
                }
                Text('›')
                  .fontSize(20)
                  .fontColor('#999999')
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .borderRadius(12)
              .stateStyles({
                normal: { .backgroundColor('rgba(0,0,0,0)') },
                pressed: { .backgroundColor('rgba(0,0,0,0.12)') }
              })
              .onClick(() => {
                promptAction.showToast({ message: '功能正在开发中', duration: 2000 });
              })

              Divider()
                .color('rgba(0,0,0,0.06)')
                .margin({ left: 16, right: 16 })

              Row() {
                Row() {
                  Image($r('app.media.call'))
                    .width(24)
                    .height(24)
                    .margin({ right: 12 })
                  Text('联系我们')
                    .fontSize(16)
                    .fontColor('#1A1A1A')
                }
                Text('›')
                  .fontSize(20)
                  .fontColor('#999999')
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .borderRadius(12)
              .stateStyles({
                normal: { .backgroundColor('rgba(0,0,0,0)') },
                pressed: { .backgroundColor('rgba(0,0,0,0.12)') }
              })
              .onClick(() => {
                this.makePhoneCall('400-888-9999');
              })

              Divider()
                .color('rgba(0,0,0,0.06)')
                .margin({ left: 16, right: 16 })

              Row() {
                Row() {
                  Image($r('app.media.set'))
                    .width(28)
                    .height(28)
                    .margin({ right: 12 })
                    .offset({x:-2})
                  Text('管理后台')
                    .fontSize(16)
                    .fontColor('#1A1A1A')
                    .offset({x:-3})
                }
                Text('›')
                  .fontSize(20)
                  .fontColor('#999999')
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .borderRadius(12)
              .stateStyles({
                normal: { .backgroundColor('rgba(0,0,0,0)') },
                pressed: { .backgroundColor('rgba(0,0,0,0.12)') }
              })
              .onClick(() => {
                // ✅ 点击"管理后台"跳转到 Manage 页面
                router.pushUrl({
                  url: 'pages/Manage'
                }).catch((err: BusinessError) => {
                  console.error('跳转管理后台失败：' + JSON.stringify(err));
                });
              })

              Divider()
                .color('rgba(0,0,0,0.06)')
                .margin({ left: 16, right: 16 })

              Row() {
                Row() {
                  Image($r('app.media.updata'))
                    .width(29)
                    .height(29)
                    .margin({ right: 12 })
                    .offset({x:-2})
                  Text('检查更新')
                    .fontSize(16)
                    .fontColor('#1A1A1A')
                    .offset({ x: -4 })
                }
                Row() {
                  Text('v2.3.1')
                    .fontSize(13)
                    .fontColor('#999999')
                    .margin({ right: 8 })
                  Text('›')
                    .fontSize(20)
                    .fontColor('#999999')
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .borderRadius(12)
              .stateStyles({
                normal: { .backgroundColor('rgba(0,0,0,0)') },
                pressed: { .backgroundColor('rgba(0,0,0,0.12)') }
              })
              .onClick(() => {
                promptAction.showToast({ message: '当前已是最新版本', duration: 2000 });
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor('rgba(255,255,255,0.5)')
            .backdropBlur(20)
            .margin({ top: 12 })
            .shadow({
              radius: 8,
              color: 'rgba(0,0,0,0.08)',
              offsetX: 0,
              offsetY: 2
            })

            Row()
              .height(60)
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)

        Row()
          .height('30vp')
          .width('100%')
      }
      .width('100%')
      .height('100%')

      // 充值弹窗
      if (this.showRechargeDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .backdropBlur(8)
          .onClick(() => {
            this.showRechargeDialog = false
          })
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('余额充值')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 20, bottom: 16 })

          Row() {
            Column() {
              Text('当前余额')
                .fontSize(13)
                .fontColor('#999999')
                .textAlign(TextAlign.Start)
                .width('100%')

              if (this.isLoading) {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color('#b1c623')
                  .margin({ top: 4 })
              } else {
                Text(`¥ ${this.balance}`)
                  .fontSize(36)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .textAlign(TextAlign.Start)
                  .width('100%')
                  .margin({ top: 4 })
                  .animation({
                    duration: 300,
                    curve: Curve.EaseInOut
                  })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ bottom: 16 })

          Column() {
            Row() {
              ForEach(this.amounts.slice(0, 3), (amount: number) => {
                Button(`${amount}元`)
                  .fontSize(14)
                  .fontColor(this.selectedAmount === amount ? Color.White : '#1A1A1A')
                  .backgroundColor(this.selectedAmount === amount ? '#4CAF50' : 'rgba(0,0,0,0.05)')
                  .borderRadius(12)
                  .height(52)
                  .width('30%')
                  .onClick(() => {
                    this.selectedAmount = amount
                    this.customAmount = ''
                  })
              }, (amount: number) => `row1_${amount}`)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ bottom: 10 })

            Row() {
              ForEach(this.amounts.slice(3, 6), (amount: number) => {
                Button(`${amount}元`)
                  .fontSize(14)
                  .fontColor(this.selectedAmount === amount ? Color.White : '#1A1A1A')
                  .backgroundColor(this.selectedAmount === amount ? '#4CAF50' : 'rgba(0,0,0,0.05)')
                  .borderRadius(12)
                  .height(52)
                  .width('30%')
                  .onClick(() => {
                    this.selectedAmount = amount
                    this.customAmount = ''
                  })
              }, (amount: number) => `row2_${amount}`)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ bottom: 12 })

          Row() {
            Text('自定义')
              .fontSize(14)
              .fontColor('#4A4A4A')
              .width(60)

            TextInput({ placeholder: '请输入金额', text: this.customAmount })
              .width('65%')
              .height(44)
              .borderRadius(12)
              .backgroundColor('rgba(0,0,0,0.04)')
              .borderWidth(1)
              .borderColor('rgba(0,0,0,0.08)')
              .fontSize(14)
              .textAlign(TextAlign.Center)
              .onChange((value: string) => {
                this.customAmount = value
                this.selectedAmount = 0
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ bottom: 20 })

          Button('去支付')
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor('#4CAF50')
            .borderRadius(22)
            .height(48)
            .width('100%')
            .onClick(() => {
              const amount = this.selectedAmount || parseFloat(this.customAmount) || 0;
              if (amount > 0) {
                this.simulatePayment();
              } else {
                promptAction.showToast({
                  message: '请选择或输入充值金额',
                  duration: 2000
                });
              }
            })
        }
        .width('88%')
        .borderRadius(20)
        .backgroundColor('rgba(255,255,255,0.95)')
        .backdropBlur(20)
        .padding({ left: 16, right: 16, bottom: 20 })
        .shadow({
          radius: 24,
          color: 'rgba(0,0,0,0.15)',
          offsetX: 0,
          offsetY: 8
        })
        .position({ x: '6%', y: '25%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      // 加载弹窗
      // 编辑名称弹窗
      if (this.showEditNameDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .backdropBlur(8)
          .onClick(() => {
            this.showEditNameDialog = false
          })
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 180, curve: Curve.EaseOut }))

        Column() {
          Text('编辑名称')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 20, bottom: 16 })

          TextInput({ placeholder: '请输入新名称', text: this.editNameInput })
            .width('100%')
            .height(44)
            .backgroundColor('rgba(0,0,0,0.05)')
            .borderRadius(10)
            .onChange((value: string) => {
              this.editNameInput = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .fontColor('#666666')
              .backgroundColor('rgba(0,0,0,0.06)')
              .borderRadius(12)
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showEditNameDialog = false;
              })
            Button(this.isSavingName ? '保存中' : '保存')
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#b1c623')
              .borderRadius(12)
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .enabled(!this.isSavingName)
              .onClick(() => {
                this.saveUserName();
              })
          }
          .width('100%')
          .margin({ top: 20, bottom: 20 })
        }
        .width('80%')
        .padding({ left: 20, right: 20 })
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .position({ x: '10%', y: '35%' })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 300, curve: curves.springMotion(0.45, 0.75) }))
      }

      if (this.showLoadingDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.4)')
          .backdropBlur(8)
          .onClick(() => {})

        Column() {
          if (this.isSuccess) {
            Image($r('app.media.okk'))
              .width(64)
              .height(64)
              .objectFit(ImageFit.Contain)
              .margin({ top: 30, bottom: 16 })
          } else {
            LoadingProgress()
              .width(56)
              .height(56)
              .color('#4CAF50')
              .margin({ top: 30, bottom: 16 })
          }

          Text(this.loadingText)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 30 })
        }
        .width(160)
        .height(160)
        .borderRadius(20)
        .backgroundColor('rgba(255,255,255,0.95)')
        .backdropBlur(20)
        .padding({ left: 24, right: 24 })
        .shadow({
          radius: 24,
          color: 'rgba(0,0,0,0.15)',
          offsetX: 0,
          offsetY: 8
        })
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}