clear; clc; close all;

%% =========================================================
%  真实散斑自相关 + HIO 重建流程
%  功能：暗背景扣除 -> 裁剪 -> 涨落自相关 -> 平均自相关处理 -> Hamming 加窗 -> HIO/ER 多次重建 -> 自动保存
%% =========================================================

%% ===================== 0. 可调参数区 =====================
% ---------- 路径参数 ----------
speckleFolder = "C:\Users\Public\MicroSnap\20260528\speckle4";  % 原始散斑图文件夹
darkFolder    = "C:\Users\Public\MicroSnap\20260528\black4";    % 暗背景图文件夹
resultRoot    = "E:\Users\86199\Matlab\Simulation-Speckle\real28-4"; % 结果保存根目录

imgExts = {'*.tif','*.tiff','*.png','*.bmp','*.jpg','*.jpeg'};      % 支持读取的图像格式

% ---------- 暗背景与裁剪参数 ----------
useDarkBackground = true;  % 是否进行暗背景扣除；false 表示不扣背景
crop_size = 256;           % 裁剪图像尺寸，最终用于自相关和 HIO 重建
x0 = 3904;                 % 裁剪区域左上角列坐标
y0 = 2184;                % 裁剪区域左上角行坐标

% ---------- 自相关前预处理参数 ----------
normalizeEachFrame = true;          % 是否将每帧散斑除以自身均值，减小帧间亮度差异
useSlowBackgroundBeforeAC = false;  % 是否在自相关前去除慢变化照明背景
slowBgSigma = 30;                   % 慢变化背景高斯滤波尺度，常用 20~40
useFluctuationAC = true;            % 是否计算涨落自相关，即 I - mean(I)

% ---------- 平均自相关处理参数 ----------
useAvgACBackgroundRemoval = true;   % 是否对平均自相关做保守背景压制
avgACBgSigma = 40;                  % 平均自相关背景估计的高斯滤波尺度，常用 30~50
avgACBgStrength = 0.3;              % 背景扣除强度，HIO 建议 0.3~0.6，过大可能损失弱信息
avgACFloorRatio = 0.001;            % 弱阈值比例，HIO 建议 0~0.005
useHammingWindow = true;            % 是否对平均自相关加 Hamming 窗

% ---------- HIO/ER 重建参数 ----------
hioOpt.num_reconstructions = 20;    % HIO 重建次数
hioOpt.total_iter = 5000;           % 每次 HIO 总迭代次数
hioOpt.er_iter = 200;               % 末尾 ER 迭代次数
hioOpt.beta = 0.8;                  % HIO 反馈系数
hioOpt.init_center_ratio = 0.5;     % 初始随机图像保留的中心区域比例
hioOpt.low_freq_protect_radius = 4; % 低频零值保护半径，避免中心频谱不稳定
hioOpt.support_update_interval = 50;% Shrink-Wrap 支撑域更新间隔
hioOpt.support_update_start = 200;  % 从第多少次迭代后开始更新支撑域
hioOpt.support_blur_sigma = 3;      % 支撑域更新时的高斯平滑尺度
hioOpt.support_threshold = 0.05;    % 支撑域阈值，越大支撑域越紧
hioOpt.align_threshold_ratio = 0.1; % 重建结果质心对齐时使用的强度阈值比例

% ---------- 保存与显示参数 ----------
saveAllBgCorrected = true;          % 是否保存所有暗背景扣除后的图像
saveAllCropped = true;              % 是否保存所有裁剪后的图像
saveMatFile = true;                 % 是否保存 .mat 数据文件

fprintf('HIO 参数：重建次数 = %d，总迭代次数 = %d，ER 迭代次数 = %d\n', ...
    hioOpt.num_reconstructions, hioOpt.total_iter, hioOpt.er_iter);

%% ===================== 1. 创建结果文件夹 =====================
run_stamp = datestr(now, 'yyyymmdd_HHMMSS');
resultFolder = fullfile(resultRoot, ...
    sprintf('Real_Speckle_HIO_%s_R%d_Iter%d', run_stamp, ...
    hioOpt.num_reconstructions, hioOpt.total_iter));

bgCorrFolder = fullfile(resultFolder, '01_Background_Corrected_All');
cropFolder   = fullfile(resultFolder, '02_Cropped_All');
preACFolder  = fullfile(resultFolder, '03_Preprocessed_For_AC_Examples');
allReconFolder = fullfile(resultFolder, 'HIO_All_Reconstructions');

make_folder(resultFolder);
make_folder(preACFolder);
make_folder(allReconFolder);
if saveAllBgCorrected, make_folder(bgCorrFolder); end
if saveAllCropped, make_folder(cropFolder); end

fprintf('结果将保存到：%s\n', resultFolder);

%% ===================== 2. 读取散斑图像列表 =====================
speckleFiles = collect_image_files(speckleFolder, imgExts);

if isempty(speckleFiles)
    error('原始散斑文件夹中没有找到图像，请检查 speckleFolder 或图像格式。');
end

% 若暗背景文件夹误放在散斑文件夹内，排除暗背景文件
if useDarkBackground
    validMask = true(numel(speckleFiles), 1);
    darkFolderStr = char(darkFolder);

    for i = 1:numel(speckleFiles)
        fullp = fullfile(speckleFiles(i).folder, speckleFiles(i).name);
        if startsWith(fullp, darkFolderStr)
            validMask(i) = false;
        end
    end

    speckleFiles = speckleFiles(validMask);
end

[~, idx] = sort({speckleFiles.name});
speckleFiles = speckleFiles(idx);
numSpeckles = numel(speckleFiles);

fprintf('检测到 %d 张原始散斑图。\n', numSpeckles);

%% ===================== 3. 计算平均暗背景 =====================
if useDarkBackground
    darkFiles = collect_image_files(darkFolder, imgExts);

    if isempty(darkFiles)
        error('暗背景文件夹中没有找到图像，请检查 darkFolder。');
    end

    [~, idx] = sort({darkFiles.name});
    darkFiles = darkFiles(idx);

    fprintf('检测到 %d 张暗背景图，开始求平均。\n', numel(darkFiles));
    darkAvg = average_image_stack(darkFiles);
    save_image_uint16(darkAvg, fullfile(resultFolder, '00_Average_Dark_Background.tif'));
else
    darkAvg = [];
end

%% ===================== 4. 暗背景扣除与裁剪 =====================
croppedStack = zeros(crop_size, crop_size, numSpeckles);
firstBgCorrected = [];
firstCropped = [];

for i = 1:numSpeckles
    raw = read_gray_double(fullfile(speckleFiles(i).folder, speckleFiles(i).name));

    if i == 1
        rawSize = size(raw);
    elseif ~isequal(size(raw), rawSize)
        error('原始散斑图尺寸不一致：%s', speckleFiles(i).name);
    end

    if useDarkBackground
        if ~isequal(size(raw), size(darkAvg))
            error('原始散斑图与暗背景图尺寸不一致。');
        end

        bgCorrected = raw - darkAvg;
        bgCorrected(bgCorrected < 0) = 0;
    else
        bgCorrected = raw;
    end

    if y0 + crop_size - 1 > size(bgCorrected, 1) || x0 + crop_size - 1 > size(bgCorrected, 2)
        error('裁剪区域超出图像范围，请检查 x0、y0 和 crop_size。');
    end

    cropped = bgCorrected(y0:y0+crop_size-1, x0:x0+crop_size-1);
    croppedStack(:, :, i) = cropped;

    [~, baseName, ~] = fileparts(speckleFiles(i).name);

    if saveAllBgCorrected
        save_image_uint16(bgCorrected, fullfile(bgCorrFolder, [baseName '_bg_corrected.tif']));
    end

    if saveAllCropped
        save_image_uint16(cropped, fullfile(cropFolder, [baseName '_crop.tif']));
    end

    if i == 1
        firstBgCorrected = bgCorrected;
        firstCropped = cropped;
        save_image_uint16(firstBgCorrected, fullfile(resultFolder, '01_Background_Corrected_Example.tif'));
        save_image_uint16(firstCropped, fullfile(resultFolder, '02_Cropped_Example.tif'));
    end

    if mod(i, 10) == 0 || i == numSpeckles
        fprintf('已完成暗背景扣除与裁剪：%d/%d\n', i, numSpeckles);
    end
end

%% ===================== 5. 计算单张自相关与平均自相关 =====================
avgACsum = zeros(crop_size, crop_size);
singleAC = [];
firstPreAC = [];

for i = 1:numSpeckles
    speckle = preprocess_speckle_for_ac(croppedStack(:, :, i), ...
        normalizeEachFrame, useSlowBackgroundBeforeAC, slowBgSigma);

    if i == 1
        firstPreAC = speckle;
        save_image_uint16(firstPreAC, fullfile(resultFolder, '03_Preprocessed_Before_AC_Example.tif'));
        save_image_uint16(firstPreAC, fullfile(preACFolder, 'Preprocessed_Before_AC_Example.tif'));
    end

    if useFluctuationAC
        acInput = speckle - mean(speckle(:));
    else
        acInput = speckle;
    end

    AC = calc_autocorrelation(acInput);

    if i == 1
        singleAC = AC;
    end

    avgACsum = avgACsum + AC;
end

avgAC_raw = normalize_to_unit(avgACsum / numSpeckles);

if useAvgACBackgroundRemoval
    avgAC_bg = imgaussfilt(avgAC_raw, avgACBgSigma);
    avgAC = avgAC_raw - avgACBgStrength * avgAC_bg;
    avgAC(avgAC < 0) = 0;

    if avgACFloorRatio > 0 && max(avgAC(:)) > 0
        avgAC(avgAC < avgACFloorRatio * max(avgAC(:))) = 0;
    end

    avgAC = normalize_to_unit(avgAC);
else
    avgAC_bg = zeros(size(avgAC_raw));
    avgAC = avgAC_raw;
end

save_image_uint16(singleAC, fullfile(resultFolder, '04_Single_Speckle_Fluctuation_Autocorrelation.tif'));
save_image_uint16(avgAC_raw, fullfile(resultFolder, '05_Average_Fluctuation_Autocorrelation_Raw.tif'));
save_image_uint16(avgAC_bg, fullfile(resultFolder, '06_Average_Autocorrelation_Estimated_Background.tif'));
save_image_uint16(avgAC, fullfile(resultFolder, '07_Average_Fluctuation_Autocorrelation_Clean.tif'));

%% ===================== 6. 平均自相关加窗 =====================
if useHammingWindow
    W_hamming = hamming(crop_size) * hamming(crop_size)';
    avgAC_forHIO = normalize_to_unit(avgAC .* W_hamming);
else
    W_hamming = ones(crop_size, crop_size);
    avgAC_forHIO = avgAC;
end

save_image_uint16(avgAC_forHIO, fullfile(resultFolder, '08_Average_Autocorrelation_For_HIO.tif'));

%% ===================== 7. 由自相关计算频谱幅值 =====================
Obj_Fourier_Mag = sqrt(abs(fft2(ifftshift(avgAC_forHIO))));
Obj_Fourier_Mag = normalize_to_unit(Obj_Fourier_Mag);
Obj_Fourier_Mag_display = fftshift(Obj_Fourier_Mag);

save_image_uint16(Obj_Fourier_Mag_display, fullfile(resultFolder, '09_Object_Fourier_Magnitude.tif'));

%% ===================== 8. HIO/ER 多次重建 =====================
rec_all = zeros(crop_size, crop_size, hioOpt.num_reconstructions);
sharpness_scores = zeros(hioOpt.num_reconstructions, 1);

show_cols = min(5, hioOpt.num_reconstructions);
show_rows = ceil(hioOpt.num_reconstructions / show_cols);
fig_w = min(1800, 300 * show_cols);
fig_h = min(1000, 260 * show_rows);

h_recon_all = figure('Name', 'HIO 多次重建结果', 'Position', [100, 100, fig_w, fig_h]);

for run_idx = 1:hioOpt.num_reconstructions
    fprintf('正在进行第 %d/%d 次 HIO 重建，迭代次数 = %d...\n', ...
        run_idx, hioOpt.num_reconstructions, hioOpt.total_iter);

    rec_temp = blind_fienup_HIO_no_support(Obj_Fourier_Mag, hioOpt);
    rec_final = align_reconstruction(rec_temp, hioOpt.align_threshold_ratio);

    rec_all(:, :, run_idx) = rec_final;
    sharpness_scores(run_idx) = calc_sharpness_score(rec_final);

    subplot(show_rows, show_cols, run_idx);
    imshow(rec_final, []);
    title(sprintf('Run %d, %.1e', run_idx, sharpness_scores(run_idx)));
end

[~, best_idx] = max(sharpness_scores);
best_reconstruction = rec_all(:, :, best_idx);

fprintf('\nHIO 重建完成。最佳结果为第 %d 次。\n', best_idx);

save_figure(h_recon_all, fullfile(resultFolder, ...
    sprintf('HIO_All_Reconstructions_R%d_Iter%d', hioOpt.num_reconstructions, hioOpt.total_iter)));

save_image_uint16(best_reconstruction, fullfile(resultFolder, '10_HIO_Best_Reconstruction.tif'));

for i = 1:hioOpt.num_reconstructions
    if i == best_idx
        tag = sprintf('HIO_run_%02d_BEST_R%d_Iter%d', i, hioOpt.num_reconstructions, hioOpt.total_iter);
    else
        tag = sprintf('HIO_run_%02d_R%d_Iter%d', i, hioOpt.num_reconstructions, hioOpt.total_iter);
    end

    save_image_uint16(rec_all(:, :, i), fullfile(allReconFolder, [tag '.tif']));
end

%% ===================== 9. 生成结果汇总图 =====================
h_summary = figure('Name', '结果汇总', 'Position', [100, 100, 1700, 900]);

subplot(2, 5, 1);  imshow(firstBgCorrected, []);      title('暗背景扣除后');
subplot(2, 5, 2);  imshow(firstCropped, []);          title('裁剪后散斑');
subplot(2, 5, 3);  imshow(firstPreAC, []);            title('自相关前预处理');
subplot(2, 5, 4);  imshow(singleAC, []);              title('单张涨落自相关');
subplot(2, 5, 5);  imshow(avgAC_raw, []);             title('原始平均涨落自相关');
subplot(2, 5, 6);  imshow(avgAC_bg, []);              title('估计自相关背景');
subplot(2, 5, 7);  imshow(avgAC, []);                 title('去背景平均自相关');
subplot(2, 5, 8);  imshow(avgAC_forHIO, []);          title('输入 HIO 的自相关');
subplot(2, 5, 9);  imshow(Obj_Fourier_Mag_display, []); title('频谱幅值');
subplot(2, 5, 10); imshow(best_reconstruction, []);   title(sprintf('HIO 最佳结果 Run %d', best_idx));

save_figure(h_summary, fullfile(resultFolder, '11_Result_Summary'));

h_score = figure('Name', 'HIO 清晰度评分', 'Position', [100, 100, 800, 500]);
bar(sharpness_scores);
hold on;
plot(best_idx, sharpness_scores(best_idx), 'r*', 'MarkerSize', 10);
title('各次 HIO 清晰度评分');
xlabel('Run');
ylabel('Score');
save_figure(h_score, fullfile(resultFolder, '12_HIO_Sharpness_Scores'));

%% ===================== 10. 保存运行参数与数据 =====================
write_run_parameters(fullfile(resultFolder, 'run_parameters.txt'), ...
    speckleFolder, darkFolder, resultRoot, useDarkBackground, crop_size, x0, y0, ...
    normalizeEachFrame, useSlowBackgroundBeforeAC, slowBgSigma, useFluctuationAC, ...
    useAvgACBackgroundRemoval, avgACBgSigma, avgACBgStrength, avgACFloorRatio, ...
    useHammingWindow, numSpeckles, hioOpt, run_stamp);

write_score_table(fullfile(resultFolder, 'reconstruction_scores.csv'), sharpness_scores, best_idx);

if saveMatFile
    save(fullfile(resultFolder, 'real_speckle_hio_results.mat'), ...
        'darkAvg', 'firstBgCorrected', 'firstCropped', 'firstPreAC', ...
        'singleAC', 'avgAC_raw', 'avgAC_bg', 'avgAC', 'W_hamming', 'avgAC_forHIO', ...
        'Obj_Fourier_Mag', 'Obj_Fourier_Mag_display', ...
        'rec_all', 'best_reconstruction', 'best_idx', 'sharpness_scores', ...
        'crop_size', 'x0', 'y0', 'numSpeckles', 'hioOpt', ...
        'normalizeEachFrame', 'useSlowBackgroundBeforeAC', 'slowBgSigma', ...
        'useFluctuationAC', 'useAvgACBackgroundRemoval', ...
        'avgACBgSigma', 'avgACBgStrength', 'avgACFloorRatio', 'useHammingWindow', ...
        '-v7.3');
end

%% ===================== 11. 输出完成信息 =====================
fprintf('\n全部处理完成。\n');
fprintf('结果总文件夹：%s\n', resultFolder);
fprintf('HIO 最佳结果：%s\n', fullfile(resultFolder, '10_HIO_Best_Reconstruction.tif'));
fprintf('HIO 全部结果文件夹：%s\n', allReconFolder);

%% =========================================================
%                         本地函数区
%% =========================================================

function files = collect_image_files(folderPath, imgExts)
    files = [];

    for e = 1:numel(imgExts)
        files = [files; dir(fullfile(folderPath, imgExts{e}))]; %#ok<AGROW>
    end
end

function make_folder(folderPath)
    if ~exist(folderPath, 'dir')
        mkdir(folderPath);
    end
end

function img = read_gray_double(img_path)
    raw = imread(img_path);

    if ndims(raw) == 3
        raw = rgb2gray(raw);
    end

    img = double(raw);
end

function avgImg = average_image_stack(files)
    for i = 1:numel(files)
        img = read_gray_double(fullfile(files(i).folder, files(i).name));

        if i == 1
            imgSize = size(img);
            imgSum = zeros(imgSize);
        elseif ~isequal(size(img), imgSize)
            error('图像尺寸不一致：%s', files(i).name);
        end

        imgSum = imgSum + img;
    end

    avgImg = imgSum / numel(files);
end

function speckle = preprocess_speckle_for_ac(speckle, normalizeEachFrame, useSlowBackgroundBeforeAC, slowBgSigma)
    speckle = speckle - min(speckle(:));

    if useSlowBackgroundBeforeAC
        slowBg = imgaussfilt(speckle, slowBgSigma);
        speckle = speckle - slowBg;
        speckle(speckle < 0) = 0;
    end

    if normalizeEachFrame && mean(speckle(:)) > 0
        speckle = speckle / mean(speckle(:));
    end
end

function AC = calc_autocorrelation(img)
    AC = fftshift(real(ifft2(abs(fft2(img)).^2)));
    AC = normalize_to_unit(AC);
end

function out = normalize_to_unit(img)
    out = img - min(img(:));

    if max(out(:)) > 0
        out = out / max(out(:));
    end
end

function save_image_uint16(img, save_path)
    img = normalize_to_unit(img);
    imwrite(uint16(img * 65535), save_path);
end

function save_figure(figHandle, saveBasePath)
    try
        exportgraphics(figHandle, [saveBasePath '.png'], 'Resolution', 300);
    catch
        saveas(figHandle, [saveBasePath '.png']);
    end

    try
        savefig(figHandle, [saveBasePath '.fig']);
    catch
        saveas(figHandle, [saveBasePath '.fig']);
    end
end

function rec = blind_fienup_HIO_no_support(Fourier_Mag, hioOpt)
    [N, ~] = size(Fourier_Mag);

    [X_grid, Y_grid] = meshgrid(-N/2:N/2-1, -N/2:N/2-1);
    R_grid = fftshift(sqrt(X_grid.^2 + Y_grid.^2));

    x = rand(N);
    center_mask = make_center_mask(N, hioOpt.init_center_ratio);
    x = x .* center_mask;

    support = ones(N);
    phase_1_HIO = max(hioOpt.total_iter - hioOpt.er_iter, 0);

    for t = 1:hioOpt.total_iter
        U = fft2(x);
        U_new = Fourier_Mag .* exp(1i * angle(U));

        zero_mask = (Fourier_Mag == 0) & (R_grid <= hioOpt.low_freq_protect_radius);
        U_new(zero_mask) = U(zero_mask);

        x_prime = real(ifft2(U_new));
        mask = (x_prime >= 0) & (support == 1);

        if t <= phase_1_HIO
            x(mask) = x_prime(mask);
            x(~mask) = x(~mask) - hioOpt.beta * x_prime(~mask);

            if mod(t, hioOpt.support_update_interval) == 0 && t > hioOpt.support_update_start
                blurred = imgaussfilt(max(x, 0), hioOpt.support_blur_sigma);

                if max(blurred(:)) > 0
                    support = double(blurred > hioOpt.support_threshold * max(blurred(:)));
                end
            end
        else
            x(mask) = x_prime(mask);
            x(~mask) = 0;
        end
    end

    rec = normalize_to_unit(x);
end

function mask = make_center_mask(N, centerRatio)
    centerRatio = max(0, min(centerRatio, 1));
    mask = zeros(N);

    center = floor(N / 2) + 1;
    halfSize = max(1, round(N * centerRatio / 2));

    idx1 = max(1, center - halfSize);
    idx2 = min(N, center + halfSize - 1);

    mask(idx1:idx2, idx1:idx2) = 1;
end

function rec_aligned = align_reconstruction(rec, thresholdRatio)
    sum_rows = sum(rec, 2);
    sum_cols = sum(rec, 1);

    [~, min_row] = min(sum_rows);
    [~, min_col] = min(sum_cols);

    rec_unwrapped = circshift(rec, [1 - min_row, 1 - min_col]);

    [Ny, Nx] = size(rec_unwrapped);
    [X, Y] = meshgrid(1:Nx, 1:Ny);

    threshold = thresholdRatio * max(rec_unwrapped(:));
    weight = rec_unwrapped .* double(rec_unwrapped > threshold);
    total_weight = sum(weight(:));

    if total_weight > 0
        xc = sum(X(:) .* weight(:)) / total_weight;
        yc = sum(Y(:) .* weight(:)) / total_weight;
        rec_aligned = circshift(rec_unwrapped, [round(Ny/2 - yc), round(Nx/2 - xc)]);
    else
        rec_aligned = rec_unwrapped;
    end
end

function score = calc_sharpness_score(img)
    [Gx, Gy] = imgradientxy(img);
    score = sum(Gx(:).^2 + Gy(:).^2);
end

function write_run_parameters(savePath, speckleFolder, darkFolder, resultRoot, useDarkBackground, ...
    crop_size, x0, y0, normalizeEachFrame, useSlowBackgroundBeforeAC, slowBgSigma, ...
    useFluctuationAC, useAvgACBackgroundRemoval, avgACBgSigma, avgACBgStrength, ...
    avgACFloorRatio, useHammingWindow, numSpeckles, hioOpt, run_stamp)

    fid = fopen(savePath, 'w');

    fprintf(fid, 'speckleFolder = %s\n', char(speckleFolder));
    fprintf(fid, 'darkFolder = %s\n', char(darkFolder));
    fprintf(fid, 'resultRoot = %s\n', char(resultRoot));
    fprintf(fid, 'useDarkBackground = %d\n', useDarkBackground);
    fprintf(fid, 'crop_size = %d\n', crop_size);
    fprintf(fid, 'x0 = %d\n', x0);
    fprintf(fid, 'y0 = %d\n', y0);
    fprintf(fid, 'normalizeEachFrame = %d\n', normalizeEachFrame);
    fprintf(fid, 'useSlowBackgroundBeforeAC = %d\n', useSlowBackgroundBeforeAC);
    fprintf(fid, 'slowBgSigma = %.6g\n', slowBgSigma);
    fprintf(fid, 'useFluctuationAC = %d\n', useFluctuationAC);
    fprintf(fid, 'useAvgACBackgroundRemoval = %d\n', useAvgACBackgroundRemoval);
    fprintf(fid, 'avgACBgSigma = %.6g\n', avgACBgSigma);
    fprintf(fid, 'avgACBgStrength = %.6g\n', avgACBgStrength);
    fprintf(fid, 'avgACFloorRatio = %.6g\n', avgACFloorRatio);
    fprintf(fid, 'useHammingWindow = %d\n', useHammingWindow);
    fprintf(fid, 'numSpeckles = %d\n', numSpeckles);
    fprintf(fid, 'num_reconstructions = %d\n', hioOpt.num_reconstructions);
    fprintf(fid, 'total_iter = %d\n', hioOpt.total_iter);
    fprintf(fid, 'er_iter = %d\n', hioOpt.er_iter);
    fprintf(fid, 'beta = %.6g\n', hioOpt.beta);
    fprintf(fid, 'init_center_ratio = %.6g\n', hioOpt.init_center_ratio);
    fprintf(fid, 'low_freq_protect_radius = %.6g\n', hioOpt.low_freq_protect_radius);
    fprintf(fid, 'support_update_interval = %d\n', hioOpt.support_update_interval);
    fprintf(fid, 'support_update_start = %d\n', hioOpt.support_update_start);
    fprintf(fid, 'support_blur_sigma = %.6g\n', hioOpt.support_blur_sigma);
    fprintf(fid, 'support_threshold = %.6g\n', hioOpt.support_threshold);
    fprintf(fid, 'align_threshold_ratio = %.6g\n', hioOpt.align_threshold_ratio);
    fprintf(fid, 'run_stamp = %s\n', run_stamp);

    fclose(fid);
end

function write_score_table(savePath, sharpness_scores, best_idx)
    fid = fopen(savePath, 'w');
    fprintf(fid, 'run_index,sharpness_score,is_best\n');

    for i = 1:numel(sharpness_scores)
        fprintf(fid, '%d,%.12g,%d\n', i, sharpness_scores(i), i == best_idx);
    end

    fclose(fid);
end
