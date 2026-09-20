import { http } from '@kit.NetworkKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

// ==================== 类型定义 ====================
interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ChoiceMessage {
  content: string;
}

interface Choice {
  message: ChoiceMessage;
}

interface ApiResponse {
  choices: Choice[];
}

interface RequestData {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  temperature: number;
  max_tokens: number;
}

// 定义本地聊天记录数据结构
interface ChatRecord {
  id: string;  // 添加唯一ID
  isUser: boolean;
  text: string;
  timestamp?: number; // 可选的时间戳
}

@Component
export struct AiServer {
  @State chatList: ChatRecord[] = [];
  @State userInput: string = '';
  @State isLoading: boolean = false;
  @State voiceEnabled: boolean = true;  // 朗读模式开关（false=静音）
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private scroller: Scroller = new Scroller();  // 使用Scroller控制滚动
  private messageId: number = 0;  // 消息ID计数器

  aboutToAppear() {
    this.addMessage(false, 'Hi，我是您的充电小管家安安~');
    this.initTts();
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

  // 添加消息的辅助方法
  addMessage(isUser: boolean, text: string) {
    this.chatList.push({
      id: `msg_${this.messageId++}`,
      isUser: isUser,
      text: text,
      timestamp: Date.now()
    });

    // 延迟滚动到底部（等待UI渲染完成）
    setTimeout(() => {
      this.scrollToBottom();
    }, 50);
  }

  // 滚动到底部
  scrollToBottom() {
    try {
      // 滚动到列表底部
      this.scroller.scrollEdge(Edge.Bottom);
    } catch (e) {
      console.error('滚动失败:', e);
    }
  }

  async requestAI() {
    if (this.isLoading) {
      return;
    }

    const question = this.userInput.trim();
    if (!question) {
      return;
    }

    // 1. 添加用户消息
    this.addMessage(true, question);
    this.userInput = '';

    // 2. 添加思考中的消息
    this.isLoading = true;
    const thinkingId = `msg_${this.messageId++}`;
    this.chatList.push({
      id: thinkingId,
      isUser: false,
      text: '🤔 思考中...'
    });
    this.scrollToBottom();

    const httpRequest = http.createHttp();

    try {
      const apiKey = 'sk-35cdb873c97f41d9b9217e05a75a7d3e';
      const url = 'https://api.deepseek.com/v1/chat/completions';

      const messages: ChatMessage[] = [
        { role: 'system', content: '你是我们公司的充电小管家安安，和你对话的是我们的客户,请用中文和专业的见解简洁回答客户的充电有关问题' },
        { role: 'user', content: question }
      ];

      const requestData: RequestData = {
        model: 'deepseek-v4-flash',
        messages: messages,
        stream: false,
        temperature: 0.7,
        max_tokens: 2000
      };

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`
        },
        extraData: JSON.stringify(requestData),
        connectTimeout: 60000,
        readTimeout: 60000
      });

      // 3. 移除"思考中..."消息
      const index = this.chatList.findIndex(item => item.id === thinkingId);
      if (index !== -1) {
        this.chatList.splice(index, 1);
      }

      if (response.responseCode === 200) {
        try {
          const responseData = JSON.parse(response.result as string) as ApiResponse;
          if (responseData.choices && responseData.choices.length > 0) {
            this.addMessage(false, responseData.choices[0].message.content);
            if (this.voiceEnabled) {
              this.speakText(responseData.choices[0].message.content);
            }
          } else {
            this.addMessage(false, '❌ AI没有返回有效回复');
          }
        } catch (parseError) {
          console.error('解析JSON失败:', parseError);
          this.addMessage(false, '❌ 解析响应数据失败');
        }
      } else {
        let errorMsg = `请求失败 (${response.responseCode})`;
        if (response.responseCode === 401) errorMsg = '❌ API密钥无效，请检查';
        else if (response.responseCode === 429) errorMsg = '❌ 请求太频繁，请稍后再试';
        else if (response.responseCode === 500) errorMsg = '❌ AI服务器错误，请稍后重试';
        this.addMessage(false, errorMsg);
      }

    } catch (error) {
      const err = error as BusinessError;
      console.error('网络请求异常:', err.message);

      // 移除"思考中..."
      const index = this.chatList.findIndex(item => item.id === thinkingId);
      if (index !== -1) {
        this.chatList.splice(index, 1);
      }

      let errorMsg = '❌ 网络请求失败';
      if (err.message.includes('timeout')) errorMsg = '❌ 请求超时，请检查网络';
      else if (err.message.includes('network')) errorMsg = '❌ 网络连接失败，请检查网络设置';
      else errorMsg = `❌ 请求异常: ${err.message || '未知错误'}`;
      this.addMessage(false, errorMsg);

    } finally {
      this.isLoading = false;
      httpRequest.destroy();
    }
  }

  // 构建单条聊天气泡
  @Builder
  ChatBubble(record: ChatRecord) {
    Row() {
      if (record.isUser) {
        // 用户消息：气泡靠右
        Blank()
          .layoutWeight(1)

        Column() {
          Text(record.text)
            .fontSize(16)
            .backgroundColor('#95ec69')
            .borderRadius(18)
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .maxLines(100)
            .wordBreak(WordBreak.BREAK_ALL)


          Text(this.formatTime(record.timestamp))
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4,right:8})
            .alignSelf(ItemAlign.End)
        }
        .alignItems(HorizontalAlign.End)
        .width('87%')

        Image($r('app.media.wangchan'))
          .width(44)
          .height(44)
          .borderRadius(22)
          .margin({ left: 10 })
          .flexShrink(0)
      } else {
        // AI消息：气泡靠左
        Image($r('app.media.hanli'))
          .width(44)
          .height(44)
          .borderRadius(22)
          .margin({ right: 10 })
          .flexShrink(0)

        Column() {
          Text() {
            Span(record.text)
            Span(' ')
            ImageSpan($r('app.media.shengyin'))
              .width(16)
              .height(16)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.CENTER)
              .onClick(() => {
                this.speakText(record.text);
              })
          }
          .fontSize(16)
          .fontColor('#1a1a1a')
          .maxLines(100)
          .wordBreak(WordBreak.BREAK_ALL)
          .backgroundColor('#ffffff')
          .borderRadius(18)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .shadow({
            radius: 2,
            color: 'rgba(0,0,0,0.08)',
            offsetX: 0,
            offsetY: 1
          })

          Text(this.formatTime(record.timestamp))
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 4 ,left:8})
            .alignSelf(ItemAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
        .width('85%')

        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }

  // 格式化时间
  formatTime(timestamp?: number): string {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${hours}:${minutes}`;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($r('app.media.songyu'))  // 你的背景图
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      // 聊天内容区域
      Scroll(this.scroller) {
        Column() {
          // 使用 ForEach 遍历所有聊天记录
          Blank()
            .height(50)  // 调整这个值来控制下移距离
          ForEach(
            this.chatList,
            (item: ChatRecord) => {
              this.ChatBubble(item)
            },
            (item: ChatRecord) => item.id  // 使用稳定的ID作为key
          )

          // 底部留白
          Blank()
            .height(80)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 60, bottom: 80 })
        .justifyContent(FlexAlign.Start)
      }
      .height('100%')
      .width('100%')
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Vertical)
      .onTouch(() => {
      })
      .align(Alignment.TopStart)
      // 顶部标题栏
      Column() {
        Row() {
          Text('安安')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor('#b1c623')
            .offset({x:22,y:10})

          Blank()
            .layoutWeight(1)

          // 朗读/静音切换按钮（样式与Home页右上角按钮一致）
          Button() {
            if (this.voiceEnabled) {
              Image($r('app.media.shengyin'))
                .width(22)
                .height(22)
                .objectFit(ImageFit.Contain)
            } else {
              Image($r('app.media.jingyin'))
                .width(22)
                .height(22)
                .objectFit(ImageFit.Contain)
            }
          }
          .width(42)
          .height(42)
          .backgroundColor('rgba(255, 255, 255, 0.85)')
          .borderRadius(25)
          .shadow({
            radius: 8,
            color: 'rgba(0,0,0,0.1)',
            offsetX: 0,
            offsetY: 2
          })
          .margin({ right: 22 })
          .offset({ y: 10 })
          .onClick(() => {
            this.voiceEnabled = !this.voiceEnabled;
            if (!this.voiceEnabled) {
              this.ttsEngine?.stop();
            }
          })
        }
        .width('100%')
        .height(110)
      }
      .width('100%')
      .height(110)
      .linearGradient({
        direction: GradientDirection.Top,
        colors: [
          ['rgba(255, 255, 255, 0)', 0],      // 顶部完全透明
          ['rgba(255, 255, 255, 0.15)', 0.3],    // 上半部分保持透明
          ['rgba(255, 255, 255, 0.4)', 0.6], // 开始出现模糊
          ['rgba(255, 255, 255, 0.5)', 0.85], // 底部半透明
          ['rgba(255, 255, 255, 0.6)', 1]    // 底部稍强
        ]
      })
      .backdropBlur(15)
      .position({ x: 0, y: 0 })
      .zIndex(10)

      // 底部镜像渐变栏（下边缘与输入栏上边框对齐）
      Column() {
      }
      .width('100%')
      .height(165)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          ['rgba(255, 255, 255, 0)', 0],      // 顶部完全透明
          ['rgba(255, 255, 255, 0.05)', 0.4],    // 上半部分保持透明
          ['rgba(255, 255, 255, 0.2)', 0.6], // 开始渐变
          ['rgba(255, 255, 255, 0.4)', 0.85], // 底部半透明
          ['rgba(255, 255, 255, 0.5)', 1]
        ]
      })
      .backdropBlur(10)
      .position({ x: 0, y: '100%' })
      .translate({ x: 0, y: '-100%' })
      .zIndex(9)

      // 底部输入框
      Column() {
        Row() {
          TextInput({ placeholder: "请输入您的问题..." , text: this.userInput })
            .onChange((value: string) => {
              this.userInput = value
            })
            .layoutWeight(1)
            .height(40)
            .backgroundColor('rgba(255, 255, 255, 0.85)')
            .backdropBlur(20)
            .padding({ left: 16, right: 16 })
            .fontSize(15)


          Button() {
            Image($r('app.media.send'))
              .width(22)
              .height(22)
              .fillColor(Color.White)
          }
          .backgroundColor(this.userInput && !this.isLoading ? '#badc3d' : '#c8c8c8')
          .onClick(() => {
            this.requestAI();
            this.userInput=''
            this.getUIContext().getFocusController().clearFocus();
          })
          .width(44)
          .height(44)
          .borderRadius(22)
          .margin({ left: 8 })
          .enabled(this.userInput.trim().length > 0 && !this.isLoading)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({top:-150})
      }
      .width('90%')
      .height(70)
      .backgroundColor('rgba(255, 255, 255, 0.85)')
      .backdropBlur(20)
      .position({x:'5%',y: '88%'})
      .zIndex(10)
      .justifyContent(FlexAlign.Center)
      .borderRadius(35)
      .borderWidth({ top: 0.5, bottom: 0.5 })  // 上下边框
      .borderColor('#d0d0d0')  // 边框颜色

    }
    .height('100%')
    .width('100%')
  }
}