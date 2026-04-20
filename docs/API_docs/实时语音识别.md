实时语音识别服务可将音频流实时转换为带标点的文本，实现“边说边出文字”的效果。无论是麦克风语音、会议录音还是本地音频文件，都能轻松转录。服务广泛应用于会议实时记录、直播字幕、语音聊天、智能客服等场景。

## **核心功能**

-   支持多语种实时语音识别，覆盖中英文及多种方言
    
-   支持热词定制，可提升特定词汇的识别准确率
    
-   支持时间戳输出，生成结构化识别结果
    
-   灵活采样率与多种音频格式，适配不同录音环境
    
-   可选VAD（Voice Activity Detection），自动过滤静音片段，提升长音频处理效率
    
-   SDK + WebSocket 接入，低延迟稳定服务
    

## **适用范围**

**支持的模型：**

## 中国内地

服务部署范围为[中国内地](https://help.aliyun.com/zh/model-studio/regions/#080da663a75xh)时，数据存储位于**北京接入地域**，模型推理计算资源仅限于中国内地。

调用以下模型时，请选择北京地域的[API Key](https://bailian.console.aliyun.com/?tab=model#/api-key)：

-   **Fun-ASR**：
    
    -   fun-asr-realtime（稳定版，当前等同fun-asr-realtime-2025-11-07）、fun-asr-realtime-2026-02-28（最新快照版）、fun-asr-realtime-2025-11-07（快照版）、fun-asr-realtime-2025-09-15（快照版）
        
    -   fun-asr-flash-8k-realtime（稳定版，当前等同fun-asr-flash-8k-realtime-2026-01-28）、fun-asr-flash-8k-realtime-2026-01-28
        
-   **Gummy：**gummy-realtime-v1、gummy-chat-v1
    
-   **Paraformer**：paraformer-realtime-v2、paraformer-realtime-v1、paraformer-realtime-8k-v2、paraformer-realtime-8k-v1
    

## 国际

服务部署范围为[国际](https://help.aliyun.com/zh/model-studio/regions/#080da663a75xh)时，数据存储位于**新加坡接入地域**，模型推理计算资源在全球范围内动态调度（不含中国内地）。

调用以下模型时，请选择新加坡地域的[API Key](https://modelstudio.console.aliyun.com/?tab=dashboard#/api-key)：

-   **Fun-ASR**：fun-asr-realtime（稳定版，当前等同fun-asr-realtime-2025-11-07）、fun-asr-realtime-2025-11-07（快照版）
    

更多信息请参见模型列表

## **模型选型**

| **场景** | **推荐模型** | **理由** |
| --- | --- | --- |
| **中文普通话识别（会议/直播）** | fun-asr-realtime、fun-asr-realtime-2026-02-28、paraformer-realtime-v2 | 多格式兼容，高采样率支持，稳定延迟 |
| **多语种识别（跨境客服、国际会议）** | gummy-realtime-v1、paraformer-realtime-v2 | 支持跨境场景与多语种自由切换 |
| **中文方言识别（客服/政务）** | fun-asr-realtime-2026-02-28、paraformer-realtime-v2 | 覆盖多地方言 |
| **中英日混合识别（课堂/演讲）** | fun-asr-realtime、fun-asr-realtime-2025-11-07 | 中英日识别优化 |
| **短音频快速交互（智能客服）** | gummy-chat-v1 | 1分钟内音频，低成本，支持多语种 |
| **低带宽电话录音转写** | fun-asr-flash-8k-realtime | 专为中文电话客服场景设计 |
| **热词定制场景（品牌名/专有术语）** | Fun-ASR、Gummy、Paraformer最新版本模型 | 热词可开关，易于迭代配置 |

更多说明请参见[模型功能特性对比](#ea5edc7ae4cq7)。

## **快速开始**

下面是调用API的示例代码。更多常用场景的代码示例，请参见[GitHub](https://github.com/aliyun/alibabacloud-bailian-speech-demo)。

您需要已[获取API Key](https://help.aliyun.com/zh/model-studio/get-api-key)并[配置API Key到环境变量](https://help.aliyun.com/zh/model-studio/configure-api-key-through-environment-variables)。如果通过SDK调用，还需要[安装DashScope SDK](https://help.aliyun.com/zh/model-studio/install-sdk)。

## Fun-ASR

## 识别传入麦克风的语音

实时语音识别可以识别麦克风中传入的语音并输出识别结果，达到“边说边出文字”的效果。

## Java

```
import com.alibaba.dashscope.audio.asr.recognition.Recognition;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionParam;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionResult;
import com.alibaba.dashscope.common.ResultCallback;
import com.alibaba.dashscope.utils.Constants;

import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.TargetDataLine;

import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class Main {
    public static void main(String[] args) throws InterruptedException {
        // 以下为北京地域url，若使用新加坡地域的模型，需将url替换为：wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference
        Constants.baseWebsocketApiUrl = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";
        ExecutorService executorService = Executors.newSingleThreadExecutor();
        executorService.submit(new RealtimeRecognitionTask());
        executorService.shutdown();
        executorService.awaitTermination(1, TimeUnit.MINUTES);
        System.exit(0);
    }
}

class RealtimeRecognitionTask implements Runnable {
    @Override
    public void run() {
        RecognitionParam param = RecognitionParam.builder()
                .model("fun-asr-realtime")
                // 新加坡和北京地域的API Key不同。获取API Key：https://help.aliyun.com/zh/model-studio/get-api-key
                // 若没有配置环境变量，请用百炼API Key将下行替换为：.apiKey("sk-xxx")
                .apiKey(System.getenv("DASHSCOPE_API_KEY"))
                .format("pcm")
                .sampleRate(16000)
                .build();
        Recognition recognizer = new Recognition();

        ResultCallback<RecognitionResult> callback = new ResultCallback<RecognitionResult>() {
            @Override
            public void onEvent(RecognitionResult result) {
                if (result.isSentenceEnd()) {
                    System.out.println("Final Result: " + result.getSentence().getText());
                } else {
                    System.out.println("Intermediate Result: " + result.getSentence().getText());
                }
            }

            @Override
            public void onComplete() {
                System.out.println("Recognition complete");
            }

            @Override
            public void onError(Exception e) {
                System.out.println("RecognitionCallback error: " + e.getMessage());
            }
        };
        try {
            recognizer.call(param, callback);
            // 创建音频格式
            AudioFormat audioFormat = new AudioFormat(16000, 16, 1, true, false);
            // 根据格式匹配默认录音设备
            TargetDataLine targetDataLine =
                    AudioSystem.getTargetDataLine(audioFormat);
            targetDataLine.open(audioFormat);
            // 开始录音
            targetDataLine.start();
            ByteBuffer buffer = ByteBuffer.allocate(1024);
            long start = System.currentTimeMillis();
            // 录音50s并进行实时转写
            while (System.currentTimeMillis() - start < 50000) {
                int read = targetDataLine.read(buffer.array(), 0, buffer.capacity());
                if (read > 0) {
                    buffer.limit(read);
                    // 将录音音频数据发送给流式识别服务
                    recognizer.sendAudioFrame(buffer);
                    buffer = ByteBuffer.allocate(1024);
                    // 录音速率有限，防止cpu占用过高，休眠一小会儿
                    Thread.sleep(20);
                }
            }
            recognizer.stop();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            // 任务结束后关闭 Websocket 连接
            recognizer.getDuplexApi().close(1000, "bye");
        }

        System.out.println(
                "[Metric] requestId: "
                        + recognizer.getLastRequestId()
                        + ", first package delay ms: "
                        + recognizer.getFirstPackageDelay()
                        + ", last package delay ms: "
                        + recognizer.getLastPackageDelay());
    }
}
```

## Python

运行Python示例前，需要通过`pip install pyaudio`命令安装第三方音频播放与采集套件。

```
import os
import signal  # for keyboard events handling (press "Ctrl+C" to terminate recording)
import sys

import dashscope
import pyaudio
from dashscope.audio.asr import *

mic = None
stream = None

# Set recording parameters
sample_rate = 16000  # sampling rate (Hz)
channels = 1  # mono channel
dtype = 'int16'  # data type
format_pcm = 'pcm'  # the format of the audio data
block_size = 3200  # number of frames per buffer


# Real-time speech recognition callback
class Callback(RecognitionCallback):
    def on_open(self) -> None:
        global mic
        global stream
        print('RecognitionCallback open.')
        mic = pyaudio.PyAudio()
        stream = mic.open(format=pyaudio.paInt16,
                          channels=1,
                          rate=16000,
                          input=True)

    def on_close(self) -> None:
        global mic
        global stream
        print('RecognitionCallback close.')
        stream.stop_stream()
        stream.close()
        mic.terminate()
        stream = None
        mic = None

    def on_complete(self) -> None:
        print('RecognitionCallback completed.')  # recognition completed

    def on_error(self, message) -> None:
        print('RecognitionCallback task_id: ', message.request_id)
        print('RecognitionCallback error: ', message.message)
        # Stop and close the audio stream if it is running
        if 'stream' in globals() and stream.active:
            stream.stop()
            stream.close()
        # Forcefully exit the program
        sys.exit(1)

    def on_event(self, result: RecognitionResult) -> None:
        sentence = result.get_sentence()
        if 'text' in sentence:
            print('RecognitionCallback text: ', sentence['text'])
            if RecognitionResult.is_sentence_end(sentence):
                print(
                    'RecognitionCallback sentence end, request_id:%s, usage:%s'
                    % (result.get_request_id(), result.get_usage(sentence)))


def signal_handler(sig, frame):
    print('Ctrl+C pressed, stop recognition ...')
    # Stop recognition
    recognition.stop()
    print('Recognition stopped.')
    print(
        '[Metric] requestId: {}, first package delay ms: {}, last package delay ms: {}'
        .format(
            recognition.get_last_request_id(),
            recognition.get_first_package_delay(),
            recognition.get_last_package_delay(),
        ))
    # Forcefully exit the program
    sys.exit(0)


# main function
if __name__ == '__main__':
    # 新加坡和北京地域的API Key不同。获取API Key：https://help.aliyun.com/zh/model-studio/get-api-key
    # 若没有配置环境变量，请用百炼API Key将下行替换为：dashscope.api_key = "sk-xxx"
    dashscope.api_key = os.environ.get('DASHSCOPE_API_KEY')

    # 以下为北京地域url，若使用新加坡地域的模型，需将url替换为：wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference
    dashscope.base_websocket_api_url='wss://dashscope.aliyuncs.com/api-ws/v1/inference'

    # Create the recognition callback
    callback = Callback()

    # Call recognition service by async mode, you can customize the recognition parameters, like model, format,
    # sample_rate
    recognition = Recognition(
        model='fun-asr-realtime',
        format=format_pcm,
        # 'pcm'、'wav'、'opus'、'speex'、'aac'、'amr', you can check the supported formats in the document
        sample_rate=sample_rate,
        # support 8000, 16000
        semantic_punctuation_enabled=False,
        callback=callback)

    # Start recognition
    recognition.start()

    signal.signal(signal.SIGINT, signal_handler)
    print("Press 'Ctrl+C' to stop recording and recognition...")
    # Create a keyboard listener until "Ctrl+C" is pressed

    while True:
        if stream:
            data = stream.read(3200, exception_on_overflow=False)
            recognition.send_audio_frame(data)
        else:
            break

    recognition.stop()
```

## 识别本地音频文件

实时语音识别可以识别本地音频文件并输出识别结果。对于对话聊天、控制口令、语音输入法、语音搜索等较短的准实时语音识别场景可考虑采用该接口进行语音识别。

## Java

示例中用到的音频为：[asr\_example.wav](https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20250210/oiydrd/asr_example.wav)。

```
import com.alibaba.dashscope.api.GeneralApi;
import com.alibaba.dashscope.audio.asr.recognition.Recognition;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionParam;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionResult;
import com.alibaba.dashscope.base.HalfDuplexParamBase;
import com.alibaba.dashscope.common.GeneralListParam;
import com.alibaba.dashscope.common.ResultCallback;
import com.alibaba.dashscope.protocol.GeneralServiceOption;
import com.alibaba.dashscope.protocol.HttpMethod;
import com.alibaba.dashscope.protocol.Protocol;
import com.alibaba.dashscope.protocol.StreamingMode;
import com.alibaba.dashscope.utils.Constants;

import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

class TimeUtils {
    private static final DateTimeFormatter formatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS");

    public static String getTimestamp() {
        return LocalDateTime.now().format(formatter);
    }
}

public class Main {
    public static void main(String[] args) throws InterruptedException {
        // 以下为北京地域url，若使用新加坡地域的模型，需将url替换为：wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference
        Constants.baseWebsocketApiUrl = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";
        // 实际应用中，该方法仅在程序最开始执行一次即可，不必多次执行该方法。
        warmUp();

        ExecutorService executorService = Executors.newSingleThreadExecutor();
        executorService.submit(new RealtimeRecognitionTask(Paths.get(System.getProperty("user.dir"), "asr_example.wav")));
        executorService.shutdown();

        // wait for all tasks to complete
        executorService.awaitTermination(1, TimeUnit.MINUTES);
        System.exit(0);
    }

    public static void warmUp() {
        try {
            // Lightweight GET request to establish connection
            GeneralServiceOption warmupOption = GeneralServiceOption.builder()
                    .protocol(Protocol.HTTP)
                    .httpMethod(HttpMethod.GET)
                    .streamingMode(StreamingMode.OUT)
                    .path("assistants")
                    .build();

            warmupOption.setBaseHttpUrl(Constants.baseHttpApiUrl);
            GeneralApi<HalfDuplexParamBase> api = new GeneralApi<>();
            api.get(GeneralListParam.builder().limit(1L).build(), warmupOption);
        } catch (Exception e) {
            // Reset flag to allow retry if pre-warming failed
        }
    }
}

class RealtimeRecognitionTask implements Runnable {
    private Path filepath;

    public RealtimeRecognitionTask(Path filepath) {
        this.filepath = filepath;
    }

    @Override
    public void run() {
        RecognitionParam param = RecognitionParam.builder()
                .model("fun-asr-realtime")
                // 新加坡和北京地域的API Key不同。获取API Key：https://help.aliyun.com/zh/model-studio/get-api-key
                // 若没有配置环境变量，请用百炼API Key将下行替换为：.apiKey("sk-xxx")
                .apiKey(System.getenv("DASHSCOPE_API_KEY"))
                .format("wav")
                .sampleRate(16000)
                .build();
        Recognition recognizer = new Recognition();

        String threadName = Thread.currentThread().getName();

        ResultCallback<RecognitionResult> callback = new ResultCallback<RecognitionResult>() {
            @Override
            public void onEvent(RecognitionResult message) {
                if (message.isSentenceEnd()) {

                    System.out.println(TimeUtils.getTimestamp()+" "+
                            "[process " + threadName + "] Final Result:" + message.getSentence().getText());
                } else {
                    System.out.println(TimeUtils.getTimestamp()+" "+
                            "[process " + threadName + "] Intermediate Result: " + message.getSentence().getText());
                }
            }

            @Override
            public void onComplete() {
                System.out.println(TimeUtils.getTimestamp()+" "+"[" + threadName + "] Recognition complete");
            }

            @Override
            public void onError(Exception e) {
                System.out.println(TimeUtils.getTimestamp()+" "+
                        "[" + threadName + "] RecognitionCallback error: " + e.getMessage());
            }
        };

        try {
            recognizer.call(param, callback);
            // Please replace the path with your audio file path
            System.out.println(TimeUtils.getTimestamp()+" "+"[" + threadName + "] Input file_path is: " + this.filepath);
            // Read file and send audio by chunks
            FileInputStream fis = new FileInputStream(this.filepath.toFile());
            byte[] allData = new byte[fis.available()];
            int ret = fis.read(allData);
            fis.close();

            int sendFrameLength = 3200;
            for (int i = 0; i * sendFrameLength < allData.length; i ++) {
                int start = i * sendFrameLength;
                int end = Math.min(start + sendFrameLength, allData.length);
                ByteBuffer byteBuffer = ByteBuffer.wrap(allData, start, end - start);
                recognizer.sendAudioFrame(byteBuffer);
                Thread.sleep(100);
            }

            System.out.println(TimeUtils.getTimestamp()+" "+LocalDateTime.now());
            recognizer.stop();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            // 任务结束后关闭 Websocket 连接
            recognizer.getDuplexApi().close(1000, "bye");
        }

        System.out.println(
                "["
                        + threadName
                        + "][Metric] requestId: "
                        + recognizer.getLastRequestId()
                        + ", first package delay ms: "
                        + recognizer.getFirstPackageDelay()
                        + ", last package delay ms: "
                        + recognizer.getLastPackageDelay());
    }
}
```

## Python

示例中用到的音频为：[asr\_example.wav](https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20250210/acoict/asr_example.wav)。

```
import os
import time
import dashscope
from dashscope.audio.asr import *

# 新加坡和北京地域的API Key不同。获取API Key：https://help.aliyun.com/zh/model-studio/get-api-key
# 若没有配置环境变量，请用百炼API Key将下行替换为：dashscope.api_key = "sk-xxx"
dashscope.api_key = os.environ.get('DASHSCOPE_API_KEY')

# 以下为北京地域url，若使用新加坡地域的模型，需将url替换为：wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference
dashscope.base_websocket_api_url = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference'

from datetime import datetime


def get_timestamp():
    now = datetime.now()
    formatted_timestamp = now.strftime("[%Y-%m-%d %H:%M:%S.%f]")
    return formatted_timestamp


class Callback(RecognitionCallback):
    def on_complete(self) -> None:
        print(get_timestamp() + ' Recognition completed')  # recognition complete

    def on_error(self, result: RecognitionResult) -> None:
        print('Recognition task_id: ', result.request_id)
        print('Recognition error: ', result.message)
        exit(0)

    def on_event(self, result: RecognitionResult) -> None:
        sentence = result.get_sentence()
        if 'text' in sentence:
            print(get_timestamp() + ' RecognitionCallback text: ', sentence['text'])
        if RecognitionResult.is_sentence_end(sentence):
            print(get_timestamp() +
                  'RecognitionCallback sentence end, request_id:%s, usage:%s'
                  % (result.get_request_id(), result.get_usage(sentence)))


callback = Callback()

recognition = Recognition(model='fun-asr-realtime',
                          format='wav',
                          sample_rate=16000,
                          callback=callback)

try:
    audio_data: bytes = None
    f = open("asr_example.wav", 'rb')
    if os.path.getsize("asr_example.wav"):
        # 一次性将文件数据全部读入buffer
        file_buffer = f.read()
        f.close()
        print("Start Recognition")
        recognition.start()

        # 从buffer中间隔3200字节发送一次
        buffer_size = len(file_buffer)
        offset = 0
        chunk_size = 3200

        while offset < buffer_size:
            # 计算本次要发送的数据块大小
            remaining_bytes = buffer_size - offset
            current_chunk_size = min(chunk_size, remaining_bytes)

            # 从buffer中提取当前数据块
            audio_data = file_buffer[offset:offset + current_chunk_size]

            # 发送音频数据帧
            recognition.send_audio_frame(audio_data)
            # 更新偏移量
            offset += current_chunk_size

            # 添加延迟模拟实时传输
            time.sleep(0.1)

        recognition.stop()
    else:
        raise Exception(
            'The supplied file was empty (zero bytes long)')
except Exception as e:
    raise e

print(
    '[Metric] requestId: {}, first package delay ms: {}, last package delay ms: {}'
    .format(
        recognition.get_last_request_id(),
        recognition.get_first_package_delay(),
        recognition.get_last_package_delay(),
    ))
```

## Gummy

**实时语音识别**：适用于会议演讲、视频直播等长时间不间断识别的场景。

**一句话识别**：对停顿更加敏感，支持对一分钟内的短语音进行精准识别，适用于对话聊天、指令控制、语音输入法、语音搜索等短时语音交互场景。

## 实时语音识别

实时语音识别支持对长时间的语音数据流（无论是从外部设备如麦克风获取的音频流，还是从本地文件读取的音频流）进行识别并流式返回结果。

## 识别传入麦克风的语音

## Java

```
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerParam;
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerRealtime;
import com.alibaba.dashscope.audio.asr.translation.results.TranslationRecognizerResult;
import com.alibaba.dashscope.common.ResultCallback;

import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.TargetDataLine;

import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class Main {
    public static void main(String[] args) throws InterruptedException {
        ExecutorService executorService = Executors.newSingleThreadExecutor();
        executorService.submit(new RealtimeRecognitionTask());
        executorService.shutdown();
        executorService.awaitTermination(1, TimeUnit.MINUTES);
        System.exit(0);
    }
}

class RealtimeRecognitionTask implements Runnable {
    @Override
    public void run() {
        String targetLanguage = "en";
        // 初始化请求参数
        TranslationRecognizerParam param =
                TranslationRecognizerParam.builder()
                        // 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
                        // .apiKey("your-api-key")
                        .model("gummy-realtime-v1") // 设置模型名
                        .format("pcm") // 设置待识别音频格式，支持的音频格式：pcm、wav、mp3、opus、speex、aac、amr
                        .sampleRate(16000) // 设置待识别音频采样率（单位Hz）。支持16000Hz及以上采样率。
                        .transcriptionEnabled(true) // 设置是否开启实时识别
                        .sourceLanguage("auto") // 设置源语言（待识别/翻译语言）代码
                        .translationEnabled(true) // 设置是否开启实时翻译
                        .translationLanguages(new String[] {targetLanguage}) // 设置翻译目标语言
                        .build();

        // 初始化回调接口
        ResultCallback<TranslationRecognizerResult> callback =
                new ResultCallback<TranslationRecognizerResult>() {
                    @Override
                    public void onEvent(TranslationRecognizerResult result) {
                        System.out.println("RequestId: " + result.getRequestId());
                        // 打印最终结果
                        if (result.getTranscriptionResult() != null) {
                            System.out.println("Transcription Result:"+result);
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranscriptionResult().getText());
                            } else {
                                System.out.println("\tTemp Result:" + result.getTranscriptionResult().getText());
                            }
                        }
                        if (result.getTranslationResult() != null) {
                            System.out.println("English Translation Result:");
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranslationResult().getTranslation(targetLanguage).getText());
                            } else {
                                System.out.println("\tTemp Result:" + result.getTranslationResult().getTranslation(targetLanguage).getText());
                            }
                        }
                    }

                    @Override
                    public void onComplete() {
                        System.out.println("Translation complete");
                    }

                    @Override
                    public void onError(Exception e) {
                        e.printStackTrace();
                        System.out.println("TranslationCallback error: " + e.getMessage());
                    }
                };

        // 初始化流式识别服务
        TranslationRecognizerRealtime translator = new TranslationRecognizerRealtime();

        try {
            // 启动流式语音识别/翻译，绑定请求参数和回调接口
            translator.call(param, callback);
            // 创建音频格式
            AudioFormat audioFormat = new AudioFormat(16000, 16, 1, true, false);
            // 根据格式匹配默认录音设备
            TargetDataLine targetDataLine =
                    AudioSystem.getTargetDataLine(audioFormat);
            targetDataLine.open(audioFormat);
            // 开始录音
            targetDataLine.start();
            System.out.println("请您通过麦克风讲话体验实时语音识别和翻译功能");
            ByteBuffer buffer = ByteBuffer.allocate(1024);
            long start = System.currentTimeMillis();
            // 录音50s并进行实时识别
            while (System.currentTimeMillis() - start < 50000) {
                int read = targetDataLine.read(buffer.array(), 0, buffer.capacity());
                if (read > 0) {
                    buffer.limit(read);
                    // 将录音音频数据发送给流式识别服务
                    translator.sendAudioFrame(buffer);
                    buffer = ByteBuffer.allocate(1024);
                    // 录音速率有限，防止cpu占用过高，休眠一小会儿
                    Thread.sleep(20);
                }
            }
            // 通知结束
            translator.stop();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            // 任务结束关闭 websocket 连接
            translator.getDuplexApi().close(1000, "bye");
        }

        System.out.println(
                "[Metric] requestId: "
                        + translator.getLastRequestId()
                        + ", first package delay ms: "
                        + translator.getFirstPackageDelay()
                        + ", last package delay ms: "
                        + translator.getLastPackageDelay());
    }
}
```

## Python

运行Python示例前，需要通过`pip install pyaudio`命令安装第三方音频播放与采集套件。

```
import pyaudio
import dashscope
from dashscope.audio.asr import *


# 若没有将API Key配置到环境变量中，需将下面这行代码注释放开， 并将your-api-key替换为自己的API Key
# dashscope.api_key = "your-api-key"

mic = None
stream = None

class Callback(TranslationRecognizerCallback):
    def on_open(self) -> None:
        global mic
        global stream
        print("TranslationRecognizerCallback open.")
        mic = pyaudio.PyAudio()
        stream = mic.open(
            format=pyaudio.paInt16, channels=1, rate=16000, input=True
        )

    def on_close(self) -> None:
        global mic
        global stream
        print("TranslationRecognizerCallback close.")
        stream.stop_stream()
        stream.close()
        mic.terminate()
        stream = None
        mic = None

    def on_event(
        self,
        request_id,
        transcription_result: TranscriptionResult,
        translation_result: TranslationResult,
        usage,
    ) -> None:
        print("request id: ", request_id)
        print("usage: ", usage)
        if translation_result is not None:
            print(
                "translation_languages: ",
                translation_result.get_language_list(),
            )
            english_translation = translation_result.get_translation("en")
            print("sentence id: ", english_translation.sentence_id)
            print("translate to english: ", english_translation.text)
        if transcription_result is not None:
            print("sentence id: ", transcription_result.sentence_id)
            print("transcription: ", transcription_result.text)


callback = Callback()


translator = TranslationRecognizerRealtime(
    model="gummy-realtime-v1",
    format="pcm",
    sample_rate=16000,
    transcription_enabled=True,
    translation_enabled=True,
    translation_target_languages=["en"],
    callback=callback,
)
translator.start()
print("请您通过麦克风讲话体验实时语音识别和翻译功能")
while True:
    if stream:
        data = stream.read(3200, exception_on_overflow=False)
        translator.send_audio_frame(data)
    else:
        break

translator.stop()
```

## 识别本地文件

## Java

示例中用到的音频为：[hello\_world.wav](https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20250415/ngevnu/hello_world.wav)。

```
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerParam;
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerRealtime;
import com.alibaba.dashscope.audio.asr.translation.results.TranslationRecognizerResult;
import com.alibaba.dashscope.common.ResultCallback;
import com.alibaba.dashscope.exception.NoApiKeyException;

import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

class RealtimeTranslateTask implements Runnable {
    private Path filepath;

    public RealtimeTranslateTask(Path filepath) {
        this.filepath = filepath;
    }

    @Override
    public void run() {
        String targetLanguage = "en";
        // Create translation params
        // you can customize the translation parameters, like model, format,
        // sample_rate for more information, please refer to
        // https://help.aliyun.com/document_detail/2712536.html
        TranslationRecognizerParam param =
                TranslationRecognizerParam.builder()
                        // 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
                        // .apiKey("your-api-key")
                        .model("gummy-realtime-v1")
                        .format("wav") // 'pcm'、'wav'、'mp3'、'opus'、'speex'、'aac'、'amr', you
                        // can check the supported formats in the document
                        .sampleRate(16000)
                        .transcriptionEnabled(true)
                        .sourceLanguage("auto")
                        .translationEnabled(true)
                        .translationLanguages(new String[] {targetLanguage})
                        .build();
        TranslationRecognizerRealtime translator = new TranslationRecognizerRealtime();
        CountDownLatch latch = new CountDownLatch(1);

        String threadName = Thread.currentThread().getName();

        ResultCallback<TranslationRecognizerResult> callback =
                new ResultCallback<TranslationRecognizerResult>() {
                    @Override
                    public void onEvent(TranslationRecognizerResult result) {
                        System.out.println("RequestId: " + result.getRequestId());
                        // 打印最终结果
                        if (result.getTranscriptionResult() != null) {
                            System.out.println("Transcription Result:"+result);
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranscriptionResult().getText());
                            } else {
                                System.out.println("\tTemp Result:" + result.getTranscriptionResult().getText());
                            }
                        }
                        if (result.getTranslationResult() != null) {
                            System.out.println("English Translation Result:");
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranslationResult().getTranslation(targetLanguage).getText());
                            } else {
                                System.out.println("\tTemp Result:" + result.getTranslationResult().getTranslation(targetLanguage).getText());
                            }
                        }
                    }

                    @Override
                    public void onComplete() {
                        System.out.println("[" + threadName + "] Translation complete");
                        latch.countDown();
                    }

                    @Override
                    public void onError(Exception e) {
                        e.printStackTrace();
                        System.out.println("[" + threadName + "] TranslationCallback error: " + e.getMessage());
                    }
                };
        // set param & callback
        try {
            translator.call(param, callback);
            // Please replace the path with your audio file path
            System.out.println("[" + threadName + "] Input file_path is: " + this.filepath);
            // Read file and send audio by chunks
            FileInputStream fis = new FileInputStream(this.filepath.toFile());
            // chunk size set to 1 seconds for 16KHz sample rate
            byte[] buffer = new byte[3200];
            int bytesRead;
            // Loop to read chunks of the file
            while ((bytesRead = fis.read(buffer)) != -1) {
                ByteBuffer byteBuffer;
                // Handle the last chunk which might be smaller than the buffer size
                System.out.println("[" + threadName + "] bytesRead: " + bytesRead);
                if (bytesRead < buffer.length) {
                    byteBuffer = ByteBuffer.wrap(buffer, 0, bytesRead);
                } else {
                    byteBuffer = ByteBuffer.wrap(buffer);
                }
                // Send the ByteBuffer to the translation instance
                translator.sendAudioFrame(byteBuffer);
                buffer = new byte[3200];
                Thread.sleep(100);
            }
            System.out.println(LocalDateTime.now());
            translator.stop();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            // 任务结束关闭 websocket 连接
            translator.getDuplexApi().close(1000, "bye");
        }

        // wait for the translation to complete
        try {
            latch.await();
        } catch (InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

}

public class Main {
    public static void main(String[] args)
            throws NoApiKeyException, InterruptedException {

        String currentDir = System.getProperty("user.dir");
        // Please replace the path with your audio source
        Path[] filePaths = {
                Paths.get(currentDir, "hello_world.wav"),
//                Paths.get(currentDir, "hello_world_male_16k_16bit_mono.wav"),
        };
        // Use ThreadPool to run recognition tasks
        ExecutorService executorService = Executors.newFixedThreadPool(10);
        for (Path filepath:filePaths) {
            executorService.submit(new RealtimeTranslateTask(filepath));
        }
        executorService.shutdown();
        // wait for all tasks to complete
        executorService.awaitTermination(1, TimeUnit.MINUTES);
        System.exit(0);
    }
}
```

## Python

```
import os
import requests
from http import HTTPStatus

import dashscope
from dashscope.audio.asr import *

# 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
# dashscope.api_key = "your-api-key"

r = requests.get(
    "https://dashscope.oss-cn-beijing.aliyuncs.com/samples/audio/paraformer/hello_world_female2.wav"
)
with open("asr_example.wav", "wb") as f:
    f.write(r.content)


class Callback(TranslationRecognizerCallback):
    def on_open(self) -> None:
        print("TranslationRecognizerCallback open.")

    def on_close(self) -> None:
        print("TranslationRecognizerCallback close.")

    def on_event(
        self,
        request_id,
        transcription_result: TranscriptionResult,
        translation_result: TranslationResult,
        usage,
    ) -> None:
        print("request id: ", request_id)
        print("usage: ", usage)
        if translation_result is not None:
            print(
                "translation_languages: ",
                translation_result.get_language_list(),
            )
            english_translation = translation_result.get_translation("en")
            print("sentence id: ", english_translation.sentence_id)
            print("translate to english: ", english_translation.text)
        if transcription_result is not None:
            print("sentence id: ", transcription_result.sentence_id)
            print("transcription: ", transcription_result.text)
    
    def on_error(self, message) -> None:
        print('error: {}'.format(message))
    
    def on_complete(self) -> None:
        print('TranslationRecognizerCallback complete')


callback = Callback()


translator = TranslationRecognizerRealtime(
    model="gummy-realtime-v1",
    format="wav",
    sample_rate=16000,
    callback=callback,
)

translator.start()

try:
    audio_data: bytes = None
    f = open("asr_example.wav", 'rb')
    if os.path.getsize("asr_example.wav"):
        while True:
            audio_data = f.read(12800)
            if not audio_data:
                break
            else:
                translator.send_audio_frame(audio_data)
    else:
        raise Exception(
            'The supplied file was empty (zero bytes long)')
    f.close()
except Exception as e:
    raise e

translator.stop()
```

## 一句话识别

一句话识别能够对一分钟内的语音数据流（无论是从外部设备如麦克风获取的音频流，还是从本地文件读取的音频流）进行识别并流式返回结果。

## 识别传入麦克风的语音

## Java

```
package org.alibaba.bailian.example.examples;

import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerChat;
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerParam;
import com.alibaba.dashscope.audio.asr.translation.results.TranscriptionResult;
import com.alibaba.dashscope.audio.asr.translation.results.TranslationRecognizerResult;
import com.alibaba.dashscope.common.ResultCallback;
import com.alibaba.dashscope.exception.NoApiKeyException;

import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.TargetDataLine;
import java.nio.ByteBuffer;

public class Main {

    public static void main(String[] args) throws NoApiKeyException, InterruptedException, LineUnavailableException {

        // 创建Recognizer
        TranslationRecognizerChat translator = new TranslationRecognizerChat();
        // 初始化请求参数
        TranslationRecognizerParam param =
                TranslationRecognizerParam.builder()
                        // 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
                        // .apiKey("your-api-key")
                        .model("gummy-chat-v1") // 设置模型名
                        .format("pcm") // 设置待识别音频格式，支持的音频格式：pcm、pcm编码的wav、mp3、ogg封装的opus、ogg封装的speex、aac、amr
                        .sampleRate(16000) // 设置待识别音频采样率（单位Hz）。仅支持16000Hz采样率。
                        .transcriptionEnabled(true) // 设置是否开启实时识别
                        .translationEnabled(true) // 设置是否开启实时翻译
                        .translationLanguages(new String[] {"en"}) // 设置翻译目标语言
                        .build();

        try {

            translator.call(param, new ResultCallback<TranslationRecognizerResult>() {
                @Override
                public void onEvent(TranslationRecognizerResult result) {
                    if (result.getTranscriptionResult() == null) {
                        return;
                    }
                    try {
                        System.out.println("RequestId: " + result.getRequestId());
                        // 打印最终结果
                        if (result.getTranscriptionResult() != null) {
                            System.out.println("Transcription Result:");
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranscriptionResult().getText());
                            } else {
                                TranscriptionResult transcriptionResult = result.getTranscriptionResult();
                                System.out.println("\tTemp Result:" + transcriptionResult.getText());
                                if (result.getTranscriptionResult().isVadPreEnd()) {
                                    System.out.printf("VadPreEnd: start:%d, end:%d, time:%d\n", transcriptionResult.getPreEndStartTime(), transcriptionResult.getPreEndEndTime(), transcriptionResult.getPreEndTimemillis());
                                }
                            }
                        }
                        if (result.getTranslationResult() != null) {
                            System.out.println("English Translation Result:");
                            if (result.isSentenceEnd()) {
                                System.out.println("\tFix:" + result.getTranslationResult().getTranslation("en").getText());
                            } else {
                                System.out.println("\tTemp Result:" + result.getTranslationResult().getTranslation("en").getText());
                            }
                        }
                    } catch (Exception e) {
                        e.printStackTrace();
                    }

                }

                @Override
                public void onComplete() {
                    System.out.println("Translation complete");
                }

                @Override
                public void onError(Exception e) {

                }
            });

            // 创建音频格式
            AudioFormat audioFormat = new AudioFormat(16000, 16, 1, true, false);
            // 根据格式匹配默认录音设备
            TargetDataLine targetDataLine =
                    AudioSystem.getTargetDataLine(audioFormat);
            targetDataLine.open(audioFormat);
            // 开始录音
            targetDataLine.start();
            System.out.println("请您通过麦克风讲话体验一句话语音识别和翻译功能");
            ByteBuffer buffer = ByteBuffer.allocate(1024);
            long start = System.currentTimeMillis();
            // 录音5s并进行实时识别
            while (System.currentTimeMillis() - start < 50000) {
                int read = targetDataLine.read(buffer.array(), 0, buffer.capacity());
                if (read > 0) {
                    buffer.limit(read);
                    // 将录音音频数据发送给流式识别服务
                    if (!translator.sendAudioFrame(buffer)) {
                        System.out.println("sentence end, stop sending");
                        break;
                    }
                    buffer = ByteBuffer.allocate(1024);
                    // 录音速率有限，防止cpu占用过高，休眠一小会儿
                    Thread.sleep(20);
                }
            }
            translator.stop();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            // 任务结束关闭 websocket 连接
            translator.getDuplexApi().close(1000, "bye");
        }
        System.exit(0);
    }
}
```

## Python

运行Python示例前，需要通过`pip install pyaudio`命令安装第三方音频播放与采集套件。

```
import pyaudio
import dashscope
from dashscope.audio.asr import *


# 若没有将API Key配置到环境变量中，需将下面这行代码注释放开， 并将your-api-key替换为自己的API Key
# dashscope.api_key = "your-api-key"

mic = None
stream = None

class Callback(TranslationRecognizerCallback):
    def on_open(self) -> None:
        global mic
        global stream
        print("TranslationRecognizerCallback open.")
        mic = pyaudio.PyAudio()
        stream = mic.open(
            format=pyaudio.paInt16, channels=1, rate=16000, input=True
        )

    def on_close(self) -> None:
        global mic
        global stream
        print("TranslationRecognizerCallback close.")
        stream.stop_stream()
        stream.close()
        mic.terminate()
        stream = None
        mic = None

    def on_event(
        self,
        request_id,
        transcription_result: TranscriptionResult,
        translation_result: TranslationResult,
        usage,
    ) -> None:
        print("request id: ", request_id)
        print("usage: ", usage)
        if translation_result is not None:
            print(
                "translation_languages: ",
                translation_result.get_language_list(),
            )
            english_translation = translation_result.get_translation("en")
            print("sentence id: ", english_translation.sentence_id)
            print("translate to english: ", english_translation.text)
            if english_translation.vad_pre_end:
                print("vad pre end {}, {}, {}".format(transcription_result.pre_end_start_time, transcription_result.pre_end_end_time, transcription_result.pre_end_timemillis))
        if transcription_result is not None:
            print("sentence id: ", transcription_result.sentence_id)
            print("transcription: ", transcription_result.text)


callback = Callback()


translator = TranslationRecognizerChat(
    model="gummy-chat-v1",
    format="pcm",
    sample_rate=16000,
    transcription_enabled=True,
    translation_enabled=True,
    translation_target_languages=["en"],
    callback=callback,
)
translator.start()
print("请您通过麦克风讲话体验一句话语音识别和翻译功能")
while True:
    if stream:
        data = stream.read(3200, exception_on_overflow=False)
        if not translator.send_audio_frame(data):
            print("sentence end, stop sending")
            break
    else:
        break

translator.stop()
```

## 识别本地文件

## Java

示例中用到的音频为：[hello\_world.wav](https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20250415/ojoixp/hello_world.wav)。

```
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerChat;
import com.alibaba.dashscope.audio.asr.translation.TranslationRecognizerParam;
import com.alibaba.dashscope.audio.asr.translation.results.TranslationRecognizerResult;
import com.alibaba.dashscope.common.ResultCallback;
import com.alibaba.dashscope.exception.NoApiKeyException;

import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

class RealtimeTranslateChatTask implements Runnable {
    private Path filepath;
    private TranslationRecognizerChat translator = null;

    public RealtimeTranslateChatTask(Path filepath) {
        this.filepath = filepath;
    }

    @Override
    public void run() {
        for (int i=0; i<1; i++) {
            // 初始化请求参数
            TranslationRecognizerParam param =
                    TranslationRecognizerParam.builder()
                            // 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
                            // .apiKey("your-api-key")
                            .model("gummy-chat-v1") // 设置模型名
                            .format("wav") // 设置待识别音频格式，支持的音频格式：pcm、pcm编码的wav、mp3、ogg封装的opus、ogg封装的speex、aac、amr
                            .sampleRate(16000) // 设置待识别音频采样率（单位Hz）。只支持16000Hz的采样率。
                            .transcriptionEnabled(true) // 设置是否开启实时识别
                            .translationEnabled(true) // 设置是否开启实时翻译
                            .translationLanguages(new String[] {"en"}) // 设置翻译目标语言
                            .build();
            if (translator == null) {
                // 初始化流式识别服务
                translator = new TranslationRecognizerChat();
            }

            String threadName = Thread.currentThread().getName();

            // 初始化回调接口
            ResultCallback<TranslationRecognizerResult> callback =
                    new ResultCallback<TranslationRecognizerResult>() {
                        @Override
                        public void onEvent(TranslationRecognizerResult result) {
                            System.out.println("RequestId: " + result.getRequestId());
                            // 打印最终结果
                            if (result.getTranscriptionResult() != null) {
                                System.out.println("Transcription Result:"+result);
                                if (result.isSentenceEnd()) {
                                    System.out.println("\tFix:" + result.getTranscriptionResult().getText());
                                } else {
                                    System.out.println("\tTemp Result:" + result.getTranscriptionResult().getText());
                                }
                            }
                            if (result.getTranslationResult() != null) {
                                System.out.println("English Translation Result:");
                                if (result.isSentenceEnd()) {
                                    System.out.println("\tFix:" + result.getTranslationResult().getTranslation("en").getText());
                                } else {
                                    System.out.println("\tTemp Result:" + result.getTranslationResult().getTranslation("en").getText());
                                }
                            }
                        }

                        @Override
                        public void onComplete() {
                            System.out.println("[" + threadName + "] Translation complete");
                        }

                        @Override
                        public void onError(Exception e) {
                            e.printStackTrace();
                            System.out.println("[" + threadName + "] TranslationCallback error: " + e.getMessage());
                        }
                    };
            try {
                // 启动流式语音识别/翻译，绑定请求参数和回调接口
                translator.call(param, callback);
                // 替换成您自己的文件路径
                System.out.println("[" + threadName + "] Input file_path is: " + this.filepath);
                // Read file and send audio by chunks
                try (FileInputStream fis = new FileInputStream(this.filepath.toFile())) {
                    // chunk size set to 1 seconds for 16KHz sample rate
                    byte[] buffer = new byte[3200];
                    int bytesRead;
                    // Loop to read chunks of the file
                    while ((bytesRead = fis.read(buffer)) != -1) {
                        ByteBuffer byteBuffer;
                        // Handle the last chunk which might be smaller than the buffer size
                        System.out.println("[" + threadName + "] bytesRead: " + bytesRead);
                        if (bytesRead < buffer.length) {
                            byteBuffer = ByteBuffer.wrap(buffer, 0, bytesRead);
                        } else {
                            byteBuffer = ByteBuffer.wrap(buffer);
                        }
                        // Send the ByteBuffer to the translation instance
                        if (!translator.sendAudioFrame(byteBuffer)) {
                            System.out.println("sentence end, stop sending");
                            break;
                        }
                        buffer = new byte[3200];
                        Thread.sleep(100);
                    }
                    fis.close();
                    System.out.println(LocalDateTime.now());
                } catch (Exception e) {
                    e.printStackTrace();
                }

                // 通知结束
                translator.stop();
            } catch (Exception e) {
                e.printStackTrace();
            } finally {
                // 任务结束关闭 websocket 连接
                if (translator != null) {
                    translator.getDuplexApi().close(1000, "bye");
                }
            }
        }
    }

}


public class Main {
    public static void main(String[] args)
            throws NoApiKeyException, InterruptedException {
        String currentDir = System.getProperty("user.dir");
        // Please replace the path with your audio source
        Path[] filePaths = {
                Paths.get(currentDir, "hello_world.wav"),
//                Paths.get(currentDir, "hello_world_male_16k_16bit_mono.wav"),
        };
        // Use ThreadPool to run recognition tasks
        ExecutorService executorService = Executors.newFixedThreadPool(10);
        for (Path filepath:filePaths) {
            executorService.submit(new RealtimeTranslateChatTask(filepath));
        }
        executorService.shutdown();
        // wait for all tasks to complete
        executorService.awaitTermination(1, TimeUnit.MINUTES);
//        System.exit(0);
    }
}
```

## Python

```
import os
import requests
from http import HTTPStatus

import dashscope
from dashscope.audio.asr import *

# 若没有将API Key配置到环境变量中，需将your-api-key替换为自己的API Key
# dashscope.api_key = "your-api-key"

r = requests.get(
    "https://dashscope.oss-cn-beijing.aliyuncs.com/samples/audio/paraformer/hello_world_female2.wav"
)
with open("asr_example.wav", "wb") as f:
    f.write(r.content)


class Callback(TranslationRecognizerCallback):
    def on_open(self) -> None:
        print("TranslationRecognizerCallback open.")

    def on_close(self) -> None:
        print("TranslationRecognizerCallback close.")

    def on_event(
            self,
            request_id,
            transcription_result: TranscriptionResult,
            translation_result: TranslationResult,
            usage,
    ) -> None:
        print("request id: ", request_id)
        print("usage: ", usage)
        if translation_result is not None:
            print(
                "translation_languages: ",
                translation_result.get_language_list(),
            )
            english_translation = translation_result.get_translation("en")
            print("sentence id: ", english_translation.sentence_id)
            print("translate to english: ", english_translation.text)
        if transcription_result is not None:
            print("sentence id: ", transcription_result.sentence_id)
            print("transcription: ", transcription_result.text)

    def on_error(self, message) -> None:
        print('error: {}'.format(message))

    def on_complete(self) -> None:
        print('TranslationRecognizerCallback complete')


callback = Callback()

translator = TranslationRecognizerChat(
    model="gummy-chat-v1",
    format="wav",
    sample_rate=16000,
    callback=callback,
)

translator.start()

try:
    audio_data: bytes = None
    f = open("asr_example.wav", 'rb')
    if os.path.getsize("asr_example.wav"):
        while True:
            audio_data = f.read(12800)
            if not audio_data:
                break
            else:
                if translator.send_audio_frame(audio_data):
                    print("send audio frame success")
                else:
                    print("sentence end, stop sending")
                    break
    else:
        raise Exception(
            'The supplied file was empty (zero bytes long)')
    f.close()
except Exception as e:
    raise e

translator.stop()
```

## Paraformer

## 识别传入麦克风的语音

实时语音识别可以识别麦克风中传入的语音并输出识别结果，达到“边说边出文字”的效果。

## Java

```
import com.alibaba.dashscope.audio.asr.recognition.Recognition;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionParam;
import com.alibaba.dashscope.exception.NoApiKeyException;
import io.reactivex.BackpressureStrategy;
import io.reactivex.Flowable;

import java.nio.ByteBuffer;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.TargetDataLine;

public class Main {

    public static void main(String[] args) throws NoApiKeyException {
        // 创建一个Flowable<ByteBuffer>
        Flowable<ByteBuffer> audioSource = Flowable.create(emitter -> {
            new Thread(() -> {
                try {
                    // 创建音频格式
                    AudioFormat audioFormat = new AudioFormat(16000, 16, 1, true, false);
                    // 根据格式匹配默认录音设备
                    TargetDataLine targetDataLine =
                            AudioSystem.getTargetDataLine(audioFormat);
                    targetDataLine.open(audioFormat);
                    // 开始录音
                    targetDataLine.start();
                    ByteBuffer buffer = ByteBuffer.allocate(1024);
                    long start = System.currentTimeMillis();
                    // 录音300s并进行实时转写
                    while (System.currentTimeMillis() - start < 300000) {
                        int read = targetDataLine.read(buffer.array(), 0, buffer.capacity());
                        if (read > 0) {
                            buffer.limit(read);
                            // 将录音音频数据发送给流式识别服务
                            emitter.onNext(buffer);
                            buffer = ByteBuffer.allocate(1024);
                            // 录音速率有限，防止cpu占用过高，休眠一小会儿
                            Thread.sleep(20);
                        }
                    }
                    // 通知结束转写
                    emitter.onComplete();
                } catch (Exception e) {
                    emitter.onError(e);
                }
            }).start();
        },
        BackpressureStrategy.BUFFER);

        // 创建Recognizer
        Recognition recognizer = new Recognition();
        // 创建RecognitionParam，audioFrames参数中传入上面创建的Flowable<ByteBuffer>
        RecognitionParam param = RecognitionParam.builder()
            .model("paraformer-realtime-v2")
            .format("pcm")
            .sampleRate(16000)
            // 若没有将API Key配置到环境变量中，需将下面这行代码注释放开，并将apiKey替换为自己的API Key
            // .apiKey("apikey")
            .build();

        // 流式调用接口
        recognizer.streamCall(param, audioSource)
            // 调用Flowable的subscribe方法订阅结果
            .blockingForEach(
                result -> {
                    // 打印最终结果
                    if (result.isSentenceEnd()) {
                        System.out.println("Fix:" + result.getSentence().getText());
                    } else {
                        System.out.println("Result:" + result.getSentence().getText());
                    }
                });
        System.exit(0);
    }
}
```

## Python

运行Python示例前，需要通过`pip install pyaudio`命令安装第三方音频播放与采集套件。

```
import pyaudio
from dashscope.audio.asr import (Recognition, RecognitionCallback,
                                 RecognitionResult)

# 若没有将API Key配置到环境变量中，需将下面这行代码注释放开，并将apiKey替换为自己的API Key
# import dashscope
# dashscope.api_key = "apiKey"

mic = None
stream = None


class Callback(RecognitionCallback):
    def on_open(self) -> None:
        global mic
        global stream
        print('RecognitionCallback open.')
        mic = pyaudio.PyAudio()
        stream = mic.open(format=pyaudio.paInt16,
                          channels=1,
                          rate=16000,
                          input=True)

    def on_close(self) -> None:
        global mic
        global stream
        print('RecognitionCallback close.')
        stream.stop_stream()
        stream.close()
        mic.terminate()
        stream = None
        mic = None

    def on_event(self, result: RecognitionResult) -> None:
        print('RecognitionCallback sentence: ', result.get_sentence())


callback = Callback()
recognition = Recognition(model='paraformer-realtime-v2',
                          format='pcm',
                          sample_rate=16000,
                          callback=callback)
recognition.start()

while True:
    if stream:
        data = stream.read(3200, exception_on_overflow=False)
        recognition.send_audio_frame(data)
    else:
        break

recognition.stop()
```

## 识别本地音频文件

实时语音识别可以识别本地音频文件并输出识别结果。对于对话聊天、控制口令、语音输入法、语音搜索等较短的准实时语音识别场景可考虑采用该接口进行语音识别。

## Java

```
import com.alibaba.dashscope.audio.asr.recognition.Recognition;
import com.alibaba.dashscope.audio.asr.recognition.RecognitionParam;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;

public class Main {
    public static void main(String[] args) {
        // 用户可忽略url下载文件部分，可以直接使用本地文件进行相关api调用进行识别
        String exampleWavUrl =
                "https://dashscope.oss-cn-beijing.aliyuncs.com/samples/audio/paraformer/hello_world_female2.wav";
        try {
            InputStream in = new URL(exampleWavUrl).openStream();
            Files.copy(in, Paths.get("asr_example.wav"), StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            System.out.println("error: " + e);
            System.exit(1);
        }

        // 创建Recognition实例
        Recognition recognizer = new Recognition();
        // 创建RecognitionParam
        RecognitionParam param =
                RecognitionParam.builder()
                        // 若没有将API Key配置到环境变量中，需将下面这行代码注释放开，并将apiKey替换为自己的API Key
                        // .apiKey("apikey")
                        .model("paraformer-realtime-v2")
                        .format("wav")
                        .sampleRate(16000)
                        // “language_hints”只支持paraformer-v2和paraformer-realtime-v2模型
                        .parameter("language_hints", new String[]{"zh", "en"})
                        .build();

        try {
            System.out.println("识别结果：" + recognizer.call(param, new File("asr_example.wav")));
        } catch (Exception e) {
            e.printStackTrace();
        }
        System.exit(0);
    }
}
```

## Python

```
import requests
from http import HTTPStatus
from dashscope.audio.asr import Recognition

# 若没有将API Key配置到环境变量中，需将下面这行代码注释放开，并将apiKey替换为自己的API Key
# import dashscope
# dashscope.api_key = "apiKey"

# 用户可忽略从url下载文件这部分代码，直接使用本地文件进行识别
r = requests.get(
    'https://dashscope.oss-cn-beijing.aliyuncs.com/samples/audio/paraformer/hello_world_female2.wav'
)
with open('asr_example.wav', 'wb') as f:
    f.write(r.content)

recognition = Recognition(model='paraformer-realtime-v2',
                          format='wav',
                          sample_rate=16000,
                          # “language_hints”只支持paraformer-v2和paraformer-realtime-v2模型
                          language_hints=['zh', 'en'],
                          callback=None)
result = recognition.call('asr_example.wav')
if result.status_code == HTTPStatus.OK:
    print('识别结果：')
    print(result.get_sentence())
else:
    print('Error: ', result.message)
```

## 应用于生产环境

### 提升识别效果

-   **选择正确采样率的模型**：8kHz 的电话音频应直接使用 8kHz 模型，而不是升采样到 16kHz 再识别，这样可以避免信息失真，获得更佳效果。
    
-   **使用热词功能**：针对业务中的专有名词、人名、品牌名等，配置热词可以显著提升识别准确率，详情请参见[定制热词](https://help.aliyun.com/zh/model-studio/custom-hot-words/)。
    
-   **优化输入音频质量**：尽量使用高质量的麦克风，并确保录音环境信噪比高、无回声。在应用层面，可以集成降噪（如RNNoise）、回声消除（AEC）等算法对音频进行预处理，以获得更纯净的音频。
    
-   **明确指定识别语种**：对于Paraformer-v2等支持多语种的模型，如果在调用时能预先确定音频的语种（如使用[Language\_hints](https://help.aliyun.com/zh/model-studio/paraformer-real-time-speech-recognition-python-sdk#1f66c2882by8w)参数指定语种为［'zh','en'］），可以帮助模型收敛，避免在相似发音的语种间混淆，提升准确性。
    
-   **语气词过滤**：对于Paraformer模型，可以通过设置参数[disfluency\_removal\_enabled](https://help.aliyun.com/zh/model-studio/paraformer-real-time-speech-recognition-python-sdk#1f66c2882by8w)开启语气词过滤功能，获得更书面、更易读的文本结果。
    

### 设置容错策略

-   **客户端重连**：客户端应实现断线自动重连机制，以应对网络抖动。以Python SDK为例，您可以参考如下建议：
    
    1.  捕获异常：在`Callback`类中实现`on_error`方法。当`dashscope` SDK遇到网络错误或其他问题时，会调用该方法。
        
    2.  状态通知：当`on_error`被触发时，设置重连信号。在Python中可以使用`threading.Event`，它是一种线程安全的信号标志。
        
    3.  重连循环：将主逻辑包裹在一个`for`循环中（例如重试3次）。当检测到重连信号后，当前轮次的识别会中断，清理资源，然后等待几秒钟，再次进入循环，创建一个全新的连接。
        
-   **设置心跳防止连接断开：**当需要与服务端保持长连接时，可将参数[heartbeat](https://help.aliyun.com/zh/model-studio/paraformer-real-time-speech-recognition-python-sdk)设置为`true`，即使音频中长时间没有声音，与服务端的连接也不会中断。
    
-   **模型限流**：在调用模型接口时请注意模型的[限流](https://help.aliyun.com/zh/model-studio/rate-limit)规则。
    

## **API参考**

-   [Fun-ASR实时语音识别API参考](https://help.aliyun.com/zh/model-studio/fun-asr-real-time-speech-recognition-api-reference/)
    
-   [Gummy实时长语音识别API参考](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-and-translation-api-reference/)
    
-   [Gummy实时短语音（一句话）识别API参考](https://help.aliyun.com/zh/model-studio/sentence-recognition-and-translation-api-reference/)
    
-   [Paraformer实时语音识别API参考](https://help.aliyun.com/zh/model-studio/paraformer-real-time-speech-recognition-api-reference/)
    

## **模型功能特性对比**

| **功能/特性** | **Fun-ASR** | **Gummy** | **Paraformer** |
| --- | --- | --- | --- |
| **支持语言** | 因模型而异： - fun-asr-realtime、fun-asr-realtime-2026-02-28、fun-asr-realtime-2025-11-07：中文（普通话、粤语、吴语、闽南语、客家话、赣语、湘语、晋语；并支持中原、西南、冀鲁、江淮、兰银、胶辽、东北、北京、港台等，包括河南、陕西、湖北、四川、重庆、云南、贵州、广东、广西、河北、天津、山东、安徽、南京、江苏、杭州、甘肃、宁夏等地区官话口音）、英文、日语 - fun-asr-realtime-2025-09-15：中文（普通话）、英文 - fun-asr-flash-8k-realtime、fun-asr-flash-8k-realtime-2026-01-28：中文 | 中文、英文、日语、韩语、法语、德语、西班牙语、意大利语、俄语、粤语、葡萄牙语、印尼语、阿拉伯语、泰语、印地语、丹麦语、乌尔都语、土耳其语、荷兰语、马来语、越南语 | 因模型而异： - paraformer-realtime-v2：中文（普通话、粤语、吴语、闽南语、东北话、甘肃话、贵州话、河南话、湖北话、湖南话、宁夏话、山西话、陕西话、山东话、四川话、天津话、江西话、云南话、上海话）、英文、日语、韩语、德语、法语、俄语 - paraformer-realtime-v1、paraformer-realtime-8k-v2、paraformer-realtime-8k-v1：中文（普通话） |
| **支持的音频格式** | pcm、wav、mp3、opus、speex、aac、amr |   |   |
| **采样率** | 因模型而异： - fun-asr-realtime、fun-asr-realtime-2026-02-28、fun-asr-realtime-2025-11-07、fun-asr-realtime-2025-09-15：16kHz - fun-asr-flash-8k-realtime、fun-asr-flash-8k-realtime-2026-01-28：8kHz | 因模型而异： - gummy-realtime-v1：≥ 16kHz - gummy-chat-v1：16kHz | 因模型而异： - paraformer-realtime-v2：任意采样率 - paraformer-realtime-v1：16kHz - paraformer-realtime-8k-v2、paraformer-realtime-8k-v1：8kHz |
| **声道** | 单声道 |   |   |
| **输入形式** | 二进制音频流 |   |   |
| **音频大小/时长** | 不限  | 因模型而异： - gummy-realtime-v1：不限 - gummy-chat-v1：1分钟以内 | 不限  |
| **情感识别** | 不支持 |   | 因模型而异： - paraformer-realtime-v2、paraformer-realtime-v1、paraformer-realtime-8k-v1：不支持 - paraformer-realtime-8k-v2：支持 默认开启，可关闭 |
| **敏感词过滤** | 不支持 |   |   |
| **说话人分离** | 不支持 |   |   |
| **语气词过滤** | 不支持 |   | 支持 默认关闭，可开启 |
| **时间戳** | 支持 固定开启 |   |   |
| **标点符号预测** | 支持 固定开启 |   | 因模型而异： - paraformer-realtime-v2、paraformer-realtime-8k-v2：支持 默认开启，可关闭 - paraformer-realtime-v1、paraformer-realtime-8k-v1：支持 固定开启 |
| **热词** | 支持 **重要** 新加坡地域的子业务空间暂不支持热词功能。 |   |   |
| **ITN** | 支持 固定开启 |   |   |
| **VAD** | 支持 固定开启 |   |   |
| **限流（RPS）** | 20  | 10  | 20  |
| **接入方式** | Java/Python/Android/iOS SDK、WebSocket API |   |   |
| **价格** | 因模型而异： - fun-asr-realtime、fun-asr-realtime-2026-02-28、fun-asr-realtime-2025-11-07： - 中国内地：0.00033元/秒 - 国际：0.00066元/秒 - fun-asr-realtime-2025-09-15： - 中国内地：0.00033元/秒 - fun-asr-flash-8k-realtime、fun-asr-flash-8k-realtime-2026-01-28： - 中国内地：0.00022元/秒 | 中国内地：0.00015元/秒 | 中国内地：0.00024元/秒 |

/\* 让引用上下间距调小，避免内容显示过于稀疏 \*/ .unionContainer .markdown-body blockquote { margin: 4px 0; } .aliyun-docs-content table.qwen blockquote { border-left: none; /\* 添加这一行来移除表格里的引用文字的左侧边框 \*/ padding-left: 5px; /\* 左侧内边距 \*/ margin: 4px 0; }

 span.aliyun-docs-icon { color: transparent !important; font-size: 0 !important; } span.aliyun-docs-icon:before { color: black; font-size: 16px; } span.aliyun-docs-icon.icon-size-20:before { font-size: 20px; } span.aliyun-docs-icon.icon-size-22:before { font-size: 22px; } span.aliyun-docs-icon.icon-size-24:before { font-size: 24px; } span.aliyun-docs-icon.icon-size-26:before { font-size: 26px; } span.aliyun-docs-icon.icon-size-28:before { font-size: 28px; }