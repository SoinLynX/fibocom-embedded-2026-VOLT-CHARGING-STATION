import { router } from '@kit.ArkUI';
import promptAction from '@ohos.promptAction';
@Entry
@Component
struct Index {
  @State ID:string = '';
  @State passWord:string = '';

  build() {
    Scroll(){
      Column(){
        Column(){
          Image($r('app.media.health'))
            .width('50%')
            .height('50%')
            .objectFit(ImageFit.Contain)
        }
        .width(60)
        .height(60)
        .backgroundColor("#0066FF")
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(30)

        Text("鸿蒙健康管理\n")
          .fontSize(22)
          .fontWeight(FontWeight.Bolder)
          .fontColor(Color.Black)
          .textAlign(TextAlign.Center)
          .margin({top:20})

        Text("专业体脂检测·AI建康助手")
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})

        Text("账号")
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')
          .margin({top:40})
          .offset({x:10})

        TextInput({placeholder:"请输入账号"})
          .offset({y:6})
          .onChange((value:string)=>{
            this.ID = value
          })

        Text("密码")
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')
          .margin({top:20})
          .offset({x:10})

        TextInput({placeholder:"请输入密码"})
          .offset({y:6})
          .onChange((value:string)=>{
            this.passWord = value
          })

        Button("登录")
          .onClick(() => {
            if(!this.passWord && !this.ID){
              promptAction.showToast({
                message: '账号或密码不能为空',
                duration: 3000,
                bottom: 50
              });
            }else{
              router.pushUrl({
                url: 'pages/Home'
              })
            }
          })
          .backgroundColor(
            this.ID && this.passWord ? '#007fff' : '#9ca1a4'
          )
          .width('100%')
          .offset({y:20})
          .margin({top:15})

        Row(){
          Text("没有账号？")
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.Gray)

          Text("立即注册")
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor("#0066FF")
            .onClick(() => {
              router.pushUrl({
                url: 'pages/Register'
              })
            })
        }
        .margin({top:35})
      }
      .padding(30)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}