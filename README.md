# Memory-effect-Simulation

基于光学记忆效应（Optical Memory Effect, OME）与 HIO/ER 相位恢复算法的荧光散斑成像仿真和真实数据重建项目。

本项目包含两条主要流程：

- `simulation/Simulation_HIO.m`：从已知物体图像出发，仿真生成有限记忆效应散斑，提取频谱和自相关信息，并使用 HIO/ER 进行多次盲重建。
- `HIO-Fluorescent speckle/HIOforReal.m`：处理实验采集的真实荧光散斑图像，完成暗背景扣除、裁剪、自相关平均、频谱幅值估计、HIO/ER 重建和最佳结果筛选。

## 项目结构

```text
Memory-effect-Simulation/
|-- README.md
|-- simulation/
|   `-- Simulation_HIO.m
`-- HIO-Fluorescent speckle/
    `-- HIOforReal.m
```

## 环境要求

建议使用 MATLAB R2020b 或更新版本。脚本主要依赖以下能力：

- MATLAB 基础函数：`fft2`、`ifft2`、`fftshift`、`circshift`、`imshow`、`imwrite` 等
- Image Processing Toolbox：`imread`、`rgb2gray`、`imresize`、`imgaussfilt`、`imgradientxy`、`hamming` 等
- Parallel Computing Toolbox：可选，仅当启用 GPU 加速时使用

如果没有可用 GPU，仿真脚本会自动回退到 CPU 计算。

## 快速开始

### 1. 运行仿真流程

打开 MATLAB，将当前工作目录切换到项目根目录：

```matlab
cd('E:\Users\86199\Documents\GitHub\Memory-effect-Simulation')
run('simulation/Simulation_HIO.m')
```

运行前请先修改 `simulation/Simulation_HIO.m` 顶部 `0. 可调参数` 区域中的输入路径：

```matlab
cfg.input_image_path = 'path\to\your\object_image.jpg';
cfg.output_dir = '';
```

其中 `cfg.output_dir = ''` 表示结果保存到 MATLAB 当前工作目录。

### 2. 运行真实散斑重建流程

```matlab
cd('E:\Users\86199\Documents\GitHub\Memory-effect-Simulation')
run('HIO-Fluorescent speckle/HIOforReal.m')
```

运行前请先修改 `HIOforReal.m` 顶部的路径参数：

```matlab
speckleFolder = "path\to\speckle_images";
darkFolder    = "path\to\dark_background_images";
resultRoot    = "path\to\save_results";
```

如果不需要暗背景扣除，可设置：

```matlab
useDarkBackground = false;
```

## 仿真脚本说明

`simulation/Simulation_HIO.m` 的主要步骤如下：

1. 初始化光学系统参数，包括波长、NA、物镜焦距、筒镜焦距、相机像元尺寸和计算网格大小。
2. 读取输入物体图像，灰度化、缩放、归一化、阈值处理，并补零到指定尺寸。
3. 根据有限光学记忆效应模型生成多帧散斑图像。
4. 对散斑强度涨落进行频域统计，估计物体频谱幅值和自相关。
5. 多次执行 HIO/ER 相位恢复，并对重建结果进行居中对齐。
6. 保存 ground truth、平均散斑、频谱、自相关、各次重建结果和 `.mat` 原始数据。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `cfg.N` | 计算图像尺寸，单位为 pixel |
| `cfg.K` | 生成散斑帧数 |
| `cfg.NA` | 物镜数值孔径 |
| `cfg.lambda` | 波长，单位为 m |
| `cfg.L_thickness` | 散射层等效厚度，单位为 m |
| `cfg.num_reconstructions` | HIO/ER 重建次数 |
| `cfg.recon_iterations` | 每次重建的总迭代次数 |
| `cfg.er_iterations` | 末尾 ER 迭代次数 |
| `cfg.beta` | HIO 反馈系数 |
| `cfg.use_shrink_wrap` | 是否启用 Shrink-Wrap 动态支撑域 |
| `cfg.enable_gpu` | 是否尝试使用 GPU 加速 |

## 真实数据脚本说明

`HIO-Fluorescent speckle/HIOforReal.m` 面向实验采集图像，主要步骤如下：

1. 收集散斑图像和暗背景图像。
2. 计算平均暗背景，并对每张散斑图像进行背景扣除。
3. 按指定坐标裁剪出用于重建的区域。
4. 对每帧散斑做归一化和可选慢变化背景去除。
5. 计算单帧涨落自相关并累加平均。
6. 对平均自相关进行背景压制、弱阈值处理和 Hamming 加窗。
7. 从自相关估计物体频谱幅值。
8. 多次执行 HIO/ER 重建，并使用清晰度评分选择最佳结果。
9. 保存重建图像、汇总图、参数文件、评分表和 `.mat` 数据。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `speckleFolder` | 原始散斑图像文件夹 |
| `darkFolder` | 暗背景图像文件夹 |
| `resultRoot` | 结果保存根目录 |
| `crop_size` | 裁剪尺寸，也是 HIO 重建尺寸 |
| `x0`, `y0` | 裁剪区域左上角坐标 |
| `normalizeEachFrame` | 是否对每帧按均值归一化 |
| `useFluctuationAC` | 是否使用涨落自相关，即 `I - mean(I)` |
| `useAvgACBackgroundRemoval` | 是否对平均自相关做背景压制 |
| `useHammingWindow` | 是否对 HIO 输入自相关加 Hamming 窗 |
| `hioOpt.num_reconstructions` | HIO 重建次数 |
| `hioOpt.total_iter` | 每次重建总迭代次数 |
| `hioOpt.er_iter` | 末尾 ER 迭代次数 |
| `hioOpt.beta` | HIO 反馈系数 |

## 输出结果

仿真流程默认生成类似下面的结果文件夹：

```text
OME_HIO_Result_NA_0.13_K_30_L_5.00e-07/
|-- 00_Ground_Truth.png
|-- 01_Reconstruction_Run01.png
|-- ...
|-- 02_Average_Speckle.png
|-- 03_Spectrum_No_STF.png
|-- 04_Autocorrelation.png
`-- RawData.mat
```

真实数据流程默认生成带时间戳的结果文件夹，包含：

- 背景扣除示例图和裁剪示例图
- 单帧与平均涨落自相关图
- HIO 输入频谱幅值图
- 所有 HIO 重建结果
- 最佳重建结果 `10_HIO_Best_Reconstruction.tif`
- 汇总图 `11_Result_Summary.png`
- 清晰度评分图和 `reconstruction_scores.csv`
- 运行参数 `run_parameters.txt`
- 完整数据 `real_speckle_hio_results.mat`

## 注意事项

- 两个脚本顶部都包含本地绝对路径，首次运行前必须根据自己的数据位置修改。
- 真实数据流程要求散斑图像尺寸一致；如果启用暗背景扣除，暗背景图像也必须与散斑图像尺寸一致。
- `x0`、`y0` 和 `crop_size` 必须保证裁剪区域不超出原始图像范围。
- HIO/ER 对随机初值敏感，建议保留多次重建并根据评分或人工观察选择最佳结果。
- 迭代次数、散斑帧数和图像尺寸会显著影响运行时间；大尺寸和多次重建建议使用 GPU。
- 如果需要复现实验结果，可以在脚本中固定随机种子。

## 后续改进方向

- 将脚本顶部参数整理为独立配置文件，减少直接修改源码的需求。
- 增加批处理入口，支持多组 NA、散斑帧数、裁剪区域或迭代次数的参数扫描。
- 增加结果评价指标，例如与 ground truth 的相关系数、SSIM 或频谱误差。
- 将核心函数拆分为独立 `.m` 文件，便于复用和单独测试。
