# Prompt：ScreenPresenter「电视端预补偿」实现方案

## 角色与背景

你是一个 **资深 macOS / Metal / 图形管线工程 Agent**，正在为 ScreenPresenter 增加一套 **显示终端预补偿系统**，用于对冲电视面板与电视端图像算法导致的颜色与亮度失真。

### 已知事实

- ScreenPresenter 本地预览颜色 **是正确的**
- 失真仅发生在 **电视面板 + 电视端图像处理**
- 不涉及视频链路、编码、色彩空间错误
- 目标是 **预补偿（pre-compensation）**，而非“色彩增强”

------

## 总体目标

实现一套 **基于 1D LUT 的实时颜色预补偿系统**，特点：

- **GPU（Metal）实时处理**
- 可调 Gamma / 黑位 / 高光 / 色温 / 饱和度
- 支持 **Profile（按电视/输出设备保存）**
- 可在任意时刻一键启用 / 禁用（AB 对比）
- 架构上为未来 3D LUT 扩展预留接口

------

## 一、系统结构设计（必须按模块拆分）

### 1. ColorPreCompensationPipeline

一个独立模块，负责在 **最终渲染到屏幕前** 做颜色处理。

职责：

- 接收输入纹理（屏幕捕获结果）
- 应用一组 **1D LUT + 参数化调整**
- 输出处理后的纹理供最终显示

要求：

- 完全运行在 GPU（Metal）
- 不允许 CPU per-pixel 处理

------

### 2. ColorProfile

用于描述一套电视对应的预补偿参数。

包含但不限于：

- `gamma: Float`
- `blackLift: Float`
- `whiteClip: Float`
- `highlightRollOff: Float`
- `temperature: Float`（冷/暖）
- `tint: Float`（绿↔紫）
- `saturation: Float`
- `lutR: [Float]`
- `lutG: [Float]`
- `lutB: [Float]`

要求：

- 可序列化（JSON / Codable）
- 可持久化（按显示设备保存）

------

### 3. DisplayProfileManager

负责管理多个显示终端配置。

能力：

- 根据当前输出显示器（名称 / 分辨率 / 刷新率）选择 Profile
- 支持切换 / 新建 / 删除
- 支持临时禁用（Bypass）

------

## 二、1D LUT 实现规范（核心）

### LUT 规格

- 默认长度：256
- 每个通道一条曲线（R/G/B）
- 数值范围：`0.0 ... 1.0`
- 使用 **线性空间** 计算（注意 sRGB ↔ Linear）

### LUT 生成逻辑

Agent 需要实现：

- 根据 Gamma / Black / White / Roll-off 参数生成三条曲线
- 保证：
  - 单调递增
  - 不产生 banding
  - 黑位与高光可控

------

## 三、Metal Shader 实现要求

### Shader Pipeline

1. 输入纹理（BGRA8Unorm / RGBA8Unorm）
2. sRGB → Linear（如输入是 sRGB）
3. 应用 1D LUT（R/G/B 分别采样）
4. 应用：
   - 色温 / Tint（矩阵或偏移）
   - 饱和度（在合适色彩空间）
5. Linear → 输出色彩空间
6. 输出到屏幕

### 技术约束

- 使用 `MTLBuffer` 或 `MTLTexture1D` 存 LUT
- 每帧可更新参数（支持滑杆实时拖动）
- 必须可整体 Bypass（零成本）

------

## 四、校准流程

实现一个 **Calibration Wizard（第一阶段）**：

### Step 1：灰阶测试

- 显示一组暗部灰阶（0–32 区间）
- 用户通过滑杆调整：
  - Black Lift
  - Gamma
- 目标：刚好能区分最低几级灰阶

### Step 2：中间调 & 高光

- 显示中灰 + 高光渐变
- 调整：
  - Gamma
  - Highlight Roll-off

### Step 3：色温 & 饱和度

- 显示肤色参考 + 基础色块
- 微调 Temperature / Tint / Saturation

> 注意：不引导用户理解“色域 / XYZ / Lab”，只给“看起来对不对”。

------

## 五、UI / UX 要求（工程工具，不要花哨）

- 一个浮层 Panel：
  - Gamma
  - Black Lift
  - Highlight Roll-off
  - Temperature
  - Tint
  - Saturation
- 预设按钮：
  - 偏冷电视
  - 发灰电视
  - 过饱和电视
- AB 对比开关（瞬时 Bypass）
- Profile 下拉选择

------

## 六、性能与稳定性要求

- 不得引入可感知延迟
- 不得降低帧率
- 参数变化必须平滑（避免闪变）
- LUT 更新必须线程安全

------

## 七、扩展性（为未来留钩子）

- ColorPreCompensationPipeline 抽象为 protocol
- 明确区分：
  - 1D LUT 模式
  - 未来 3D LUT 模式
- 禁止在本阶段引入 3D LUT 复杂度

------

## 八、交付物要求

Agent 必须交付：

1. 模块结构说明
2. Metal Shader 代码（含注释）
3. LUT 生成算法
4. Profile 存储方案
5. 校准流程伪代码
6. 性能评估说明

------

## ⚠️ 非目标（明确禁止）

- ❌ 不引入 ICC / ColorSync 依赖
- ❌ 不做“自动校色”
- ❌ 不宣称“色彩科学级准确”
- ❌ 不依赖电视型号数据库

------

## 结束语

这不是一个“调色滤镜”，这是一个 **工程级显示终端预补偿系统**。
**稳定、可控、可理解** 优先于“理论完美”。

