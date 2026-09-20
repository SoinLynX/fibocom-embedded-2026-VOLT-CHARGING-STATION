import { router } from '@kit.ArkUI';
import promptAction from '@ohos.promptAction';
@Entry
@Component
struct Register {
  @State ID: string = '';
  @State userName: string = '';
  @State passWord: string = '';


  build() {
    Scroll(){
      Column(){
        Text("创建账号\n")
          .fontSize(22)
          .fontWeight(FontWeight.Bolder)
          .fontColor(Color.Black)
          .textAlign(TextAlign.Start)
          .margin({top:20})
          .width('100%')

        Text("注册使用完整健康管理功能")
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')

        Text("账号")
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')
          .margin({top:40})
          .offset({x:10})

        TextInput({placeholder:"自定义登录账号"})
          .offset({y:6})
          .onChange((value:string)=>{
            this.ID = value
          })

        Text("昵称")
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')
          .margin({top:40})
          .offset({x:10})

        TextInput({placeholder:"你的昵称"})
          .offset({y:6})
          .onChange((value:string)=>{
            this.userName = value
          })

        Text("密码")
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.Gray)
          .offset({y:-15})
          .textAlign(TextAlign.Start)
          .width('100%')
          .margin({top:40})
          .offset({x:10})

        TextInput({placeholder:"设置6位以上密码"})
          .offset({y:6})
          .onChange((value:string)=>{
            this.passWord = value
          })

        Button("完成注册")
          .onClick(() => {
            if(!this.passWord && !this.ID){
              promptAction.showToast({
                message: '还有未填写的信息',
                duration: 3000,
                bottom: 50
              });
            }else{
              router.pushUrl({
                url: 'pages/Index'
              })
              promptAction.showToast({
                message: '注册成功',
                duration: 3000,
                bottom: 50
              });
            }
          })
          .backgroundColor(
            this.ID && this.passWord && this.userName ? '#007fff' : '#9ca1a4'
          )
          .width('100%')
          .offset({y:20})
          .margin({top:25})

      }
      .padding(30)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}