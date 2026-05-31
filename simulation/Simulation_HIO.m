clear; clc; close all;

%% ===================== 0. 可调参数 =====================
% 只需要根据实验情况修改本节参数；后续代码一般不需要改动。

% ---------- 输入与输出 ----------
cfg.input_image_path = 'D:\毕业设计\noise mnist\training_10506_5.jpg';  % 输入物体图像路径
cfg.output_dir       = '';                                               % 结果保存路径；为空则保存到当前工作目录
cfg.output_prefix    = 'OME_HIO_Result';                                  % 输出文件夹名前缀
cfg.show_figures     = true;                                             % 是否显示中间结果图
cfg.save_results     = true;                                             % 是否保存图像和 .mat 数据

% ---------- 光学系统参数 ----------
cfg.lambda = 532e-9;       % 波长，单位：m
cfg.NA     = 0.13;         % 物镜数值孔径
cfg.f_obj  = 45e-3;        % 物镜等效焦距，单位：m
cfg.f_tube = 180e-3;       % 筒镜焦距，单位：m
cfg.dx_cam = 2.4e-6;       % 相机像元尺寸，单位：m
cfg.N      = 256;          % 计算图像尺寸，单位：pixel
cfg.K      = 30;           % 生成散斑帧数

% ---------- 物体图像预处理参数 ----------
cfg.core_size          = 128;   % 物体缩放后的中心区域尺寸
cfg.object_threshold   = 0.05;  % 判定为有效发光点的强度阈值
cfg.binarize_threshold = 0.25;  % 物体图像二值/去弱背景阈值
cfg.gaussian_sigma     = 1;     % 物体图像高斯平滑标准差；设为 0 表示不平滑

% ---------- 光学记忆效应参数 ----------
cfg.z0          = 6e-3;     % 物体到散射介质/成像面的等效距离，单位：m
cfg.L_thickness = 0.5e-6;   % 散射层等效厚度，单位：m

% ---------- 频谱和自相关处理参数 ----------
cfg.hpf_block_radius = 1;     % 高频通滤波中心遮挡半径，单位：pixel
cfg.apply_pupil_limit = true; % 是否用 NA 对频谱进行截止限制

% ---------- HIO/ER 相位恢复参数 ----------
cfg.num_reconstructions = 10;    % 盲重建次数
cfg.recon_iterations    = 1500;  % 每次重建迭代次数
cfg.beta                = 0.8;   % HIO 反馈系数
cfg.er_iterations       = 50;    % 末尾 ER 收敛迭代次数
cfg.init_center_ratio   = 0.5;   % 初始随机物体所在中心区域比例，0.5 表示中心 1/2 区域

% ---------- Shrink-Wrap 支撑域参数 ----------
cfg.use_shrink_wrap        = true; % 是否动态更新支撑域
cfg.shrink_start_iter      = 200;  % 从第几次迭代后开始更新支撑域
cfg.shrink_update_interval = 50;   % 支撑域更新间隔
cfg.shrink_sigma           = 3;    % 支撑域更新前的高斯平滑标准差
cfg.shrink_threshold       = 0.1;  % 支撑域阈值，相对最大值

% ---------- 计算控制参数 ----------
cfg.enable_gpu        = true; % 是否尝试使用 GPU
cfg.progress_interval = 5;    % 每生成多少帧散斑输出一次进度
cfg.random_seed       = [];   % 随机种子；[] 表示不固定随机性


%% ===================== 1. 初始化光学系统 =====================
if ~isempty(cfg.random_seed)
    rng(cfg.random_seed);
end

[Pupil, opt] = build_pupil(cfg);

fprintf('NA = %.2f，散斑帧数 K = %d，物面像素尺寸 = %.3f μm\n', ...
    cfg.NA, cfg.K, opt.dx_obj * 1e6);


%% ===================== 2. 读取并预处理物体图像 =====================
obj = load_and_pad_object(cfg);

if cfg.show_figures
    figure('Name', '物体图像', 'Position', [150, 200, 400, 400]);
    imshow(obj, []);
    title(sprintf('Ground Truth：%d × %d padded to %d × %d', ...
        cfg.core_size, cfg.core_size, cfg.N, cfg.N));
end


%% ===================== 3. 生成有限记忆效应散斑 =====================
[speckle_stack, ome_info] = generate_speckle_stack(obj, Pupil, cfg, opt);

fprintf('OME 等效视场半径约 %.1f pixel，有效发光点数量：%d\n', ...
    ome_info.r_fov_pixel, ome_info.num_points);


%% ===================== 4. 提取频谱与空间自相关 =====================
[Obj_Fourier_Mag, Obj_Autocorr] = extract_spectrum_and_autocorr( ...
    speckle_stack, Pupil, cfg);

if cfg.show_figures
    show_spectrum_diagnostics(obj, Pupil, Obj_Fourier_Mag, Obj_Autocorr, cfg);
end


%% ===================== 5. 多次 HIO/ER 盲重建 =====================
rec_all = run_multi_reconstruction(Obj_Fourier_Mag, cfg);


%% ===================== 6. 保存结果 =====================
if cfg.save_results
    save_all_results(obj, speckle_stack, rec_all, Obj_Fourier_Mag, ...
        Obj_Autocorr, cfg, opt, ome_info);
end


%% ===================== 局部函数：光学系统初始化 =====================
function [Pupil, opt] = build_pupil(cfg)
    opt.M      = cfg.f_tube / cfg.f_obj;   % 系统放大率
    opt.dx_obj = cfg.dx_cam / opt.M;       % 物面等效像素尺寸
    opt.L_obj  = cfg.N * opt.dx_obj;       % 物面视场长度
    opt.df     = 1 / opt.L_obj;            % 频域采样间隔
    opt.f_c    = cfg.NA / cfg.lambda;      % NA 截止频率

    [fx, fy] = meshgrid((-cfg.N/2:cfg.N/2-1) * opt.df, ...
                        (-cfg.N/2:cfg.N/2-1) * opt.df);
    f_r = sqrt(fx.^2 + fy.^2);

    Pupil = double(f_r <= opt.f_c);
    Pupil = fftshift(Pupil);
end


%% ===================== 局部函数：物体读取与补零 =====================
function obj = load_and_pad_object(cfg)
    img_raw = imread(cfg.input_image_path);

    if size(img_raw, 3) == 3
        img_raw = rgb2gray(img_raw);
    end

    img_small = imresize(double(img_raw), [cfg.core_size, cfg.core_size]);
    img_small = normalize_to_unit(img_small);

    img_small(img_small < cfg.binarize_threshold) = 0;

    if cfg.gaussian_sigma > 0
        img_small = imgaussfilt(img_small, cfg.gaussian_sigma);
    end

    obj = zeros(cfg.N, cfg.N);
    start_idx = floor((cfg.N - cfg.core_size) / 2) + 1;
    end_idx = start_idx + cfg.core_size - 1;
    obj(start_idx:end_idx, start_idx:end_idx) = img_small;
end


%% ===================== 局部函数：有限 OME 散斑生成 =====================
function [speckle_stack, ome_info] = generate_speckle_stack(obj, Pupil, cfg, opt)
    [row, col, vals] = find(obj > cfg.object_threshold);
    num_points = length(row);

    if num_points == 0
        error('有效发光点数量为 0，请降低 cfg.object_threshold 或检查输入图像。');
    end

    theta_c = cfg.lambda / (2 * pi * cfg.L_thickness);
    r_fov_phys = cfg.z0 * theta_c;
    r_fov_pixel = r_fov_phys / opt.dx_obj;

    x_idx_array = col - cfg.N / 2;
    y_idx_array = row - cfg.N / 2;

    x_phys = x_idx_array * opt.dx_obj;
    y_phys = y_idx_array * opt.dx_obj;
    r_phys = sqrt(x_phys.^2 + y_phys.^2);
    theta_pixel = r_phys / cfg.z0;

    corr_array = exp(-(theta_pixel.^2) / (theta_c^2));

    speckle_stack = zeros(cfg.N, cfg.N, cfg.K);
    use_gpu = false;

    if cfg.enable_gpu
        try
            gpuDevice;
            Pupil_gpu = gpuArray(Pupil);
            use_gpu = true;
            fprintf('已启用 GPU 加速。\n');
        catch
            Pupil_gpu = Pupil;
            fprintf('未检测到可用 GPU，使用 CPU 计算。\n');
        end
    else
        Pupil_gpu = Pupil;
    end

    tic;
    for k = 1:cfg.K
        if use_gpu
            I_camera_gpu = gpuArray.zeros(cfg.N, cfg.N);
            phi_center_gpu = gpuArray(randn(cfg.N));

            for p = 1:num_points
                corr = corr_array(p);
                phi_pixel = corr * phi_center_gpu + ...
                    sqrt(1 - corr^2) * gpuArray(randn(cfg.N));

                PSF_amp = fftshift(ifft2(Pupil_gpu .* exp(1i * 2 * pi * phi_pixel)));
                PSF_pixel = abs(PSF_amp).^2;
                PSF_shifted = circshift(PSF_pixel, ...
                    [round(y_idx_array(p)), round(x_idx_array(p))]);

                I_camera_gpu = I_camera_gpu + vals(p) * PSF_shifted;
            end

            speckle_stack(:, :, k) = gather(I_camera_gpu);
        else
            I_camera = zeros(cfg.N, cfg.N);
            phi_center = randn(cfg.N);

            for p = 1:num_points
                corr = corr_array(p);
                phi_pixel = corr * phi_center + sqrt(1 - corr^2) * randn(cfg.N);

                PSF_amp = fftshift(ifft2(Pupil .* exp(1i * 2 * pi * phi_pixel)));
                PSF_pixel = abs(PSF_amp).^2;
                PSF_shifted = circshift(PSF_pixel, ...
                    [round(y_idx_array(p)), round(x_idx_array(p))]);

                I_camera = I_camera + vals(p) * PSF_shifted;
            end

            speckle_stack(:, :, k) = I_camera;
        end

        if mod(k, cfg.progress_interval) == 0 || k == cfg.K
            fprintf('已生成 %d / %d 帧散斑，用时 %.1f s\n', k, cfg.K, toc);
        end
    end

    ome_info.theta_c = theta_c;
    ome_info.r_fov_phys = r_fov_phys;
    ome_info.r_fov_pixel = r_fov_pixel;
    ome_info.num_points = num_points;
end


%% ===================== 局部函数：频谱与自相关提取 =====================
function [Obj_Fourier_Mag, Obj_Autocorr] = extract_spectrum_and_autocorr(speckle_stack, Pupil, cfg)
    PS_sum = zeros(cfg.N, cfg.N);

    for k = 1:cfg.K
        I = speckle_stack(:, :, k);
        I_zero_mean = I - mean(I(:));
        F_I = fft2(I_zero_mean);
        PS_sum = PS_sum + abs(F_I).^2;
    end

    Obj_Fourier_Mag = sqrt(PS_sum / cfg.K);

    [X_grid, Y_grid] = meshgrid(-cfg.N/2:cfg.N/2-1, -cfg.N/2:cfg.N/2-1);
    R_grid_px = sqrt(X_grid.^2 + Y_grid.^2);

    HPF = double(R_grid_px > cfg.hpf_block_radius);
    HPF = fftshift(HPF);
    Obj_Fourier_Mag = Obj_Fourier_Mag .* HPF;

    if cfg.apply_pupil_limit
        Obj_Fourier_Mag = Obj_Fourier_Mag .* Pupil;
    end

    Obj_Autocorr = fftshift(real(ifft2(Obj_Fourier_Mag.^2)));
    Obj_Autocorr = max(Obj_Autocorr, 0);
    Obj_Autocorr = normalize_to_unit(Obj_Autocorr);
end


%% ===================== 局部函数：频谱诊断图 =====================
function show_spectrum_diagnostics(obj, Pupil, Obj_Fourier_Mag, Obj_Autocorr, cfg)
    True_Fourier_Mag = abs(fft2(obj));

    if cfg.apply_pupil_limit
        True_Fourier_Mag = True_Fourier_Mag .* Pupil;
    end

    figure('Name', '频谱与自相关', 'Position', [100, 100, 1200, 400]);

    subplot(1, 3, 1);
    imshow(log(fftshift(True_Fourier_Mag) + 1), []);
    title('真实物体频谱');

    subplot(1, 3, 2);
    imshow(log(fftshift(Obj_Fourier_Mag) + 1), []);
    title('散斑自相关提取频谱');

    subplot(1, 3, 3);
    imshow(Obj_Autocorr, []);
    title('输入相位恢复的自相关');
end


%% ===================== 局部函数：多次盲重建 =====================
function rec_all = run_multi_reconstruction(Obj_Fourier_Mag, cfg)
    rec_all = zeros(cfg.N, cfg.N, cfg.num_reconstructions);

    if cfg.show_figures
        figure('Name', '多次盲重建结果', 'Position', [100, 100, 1500, 600]);
        n_col = ceil(sqrt(cfg.num_reconstructions));
        n_row = ceil(cfg.num_reconstructions / n_col);
    end

    for run_idx = 1:cfg.num_reconstructions
        fprintf('正在进行第 %d / %d 次盲重建...\n', ...
            run_idx, cfg.num_reconstructions);

        rec_temp = blind_fienup_HIO_ER(Obj_Fourier_Mag, cfg);
        rec_final = align_reconstruction(rec_temp);

        rec_all(:, :, run_idx) = rec_final;

        if cfg.show_figures
            subplot(n_row, n_col, run_idx);
            imshow(rec_final, []);
            title(sprintf('Run %d', run_idx));
        end
    end

    fprintf('盲重建完成。\n');
end


%% ===================== 局部函数：重建结果对齐 =====================
function rec_final = align_reconstruction(rec_temp)
    sum_rows = sum(rec_temp, 2);
    sum_cols = sum(rec_temp, 1);

    [~, min_row] = min(sum_rows);
    [~, min_col] = min(sum_cols);

    rec_unwrapped = circshift(rec_temp, [1 - min_row, 1 - min_col]);

    [N_y, N_x] = size(rec_unwrapped);
    [X, Y] = meshgrid(1:N_x, 1:N_y);

    thresh = 0.1 * max(rec_unwrapped(:));
    weight = rec_unwrapped .* double(rec_unwrapped > thresh);
    total_weight = sum(weight(:));

    if total_weight > 0
        x_c = sum(X(:) .* weight(:)) / total_weight;
        y_c = sum(Y(:) .* weight(:)) / total_weight;

        shift_x = round(N_x / 2 - x_c);
        shift_y = round(N_y / 2 - y_c);

        rec_final = circshift(rec_unwrapped, [shift_y, shift_x]);
    else
        rec_final = rec_unwrapped;
    end
end


%% ===================== 局部函数：保存结果 =====================
function save_all_results(obj, speckle_stack, rec_all, Obj_Fourier_Mag, Obj_Autocorr, cfg, opt, ome_info)
    if isempty(cfg.output_dir)
        output_base_dir = pwd;
    else
        output_base_dir = cfg.output_dir;
    end

    folder_name = sprintf('%s_NA_%.2f_K_%d_L_%.2e', ...
        cfg.output_prefix, cfg.NA, cfg.K, cfg.L_thickness);
    result_dir = fullfile(output_base_dir, folder_name);

    if ~exist(result_dir, 'dir')
        mkdir(result_dir);
    end

    imwrite(obj, fullfile(result_dir, '00_Ground_Truth.png'));

    for run_idx = 1:cfg.num_reconstructions
        filename = sprintf('01_Reconstruction_Run%02d.png', run_idx);
        imwrite(rec_all(:, :, run_idx), fullfile(result_dir, filename));
    end

    speckle_mean = mean(speckle_stack, 3);
    imwrite(mat2gray(speckle_mean), fullfile(result_dir, '02_Average_Speckle.png'));
    imwrite(mat2gray(log(fftshift(Obj_Fourier_Mag) + 1)), ...
        fullfile(result_dir, '03_Spectrum_No_STF.png'));
    imwrite(mat2gray(Obj_Autocorr), fullfile(result_dir, '04_Autocorrelation.png'));

    save(fullfile(result_dir, 'RawData.mat'), ...
        'obj', 'speckle_stack', 'rec_all', 'Obj_Fourier_Mag', ...
        'Obj_Autocorr', 'cfg', 'opt', 'ome_info');

    fprintf('结果已保存至：%s\n', result_dir);
end


%% ===================== 局部函数：HIO + ER 相位恢复 =====================
function rec = blind_fienup_HIO_ER(Fourier_Mag, cfg)
    [N, ~] = size(Fourier_Mag);

    [X_grid, Y_grid] = meshgrid(-N/2:N/2-1, -N/2:N/2-1);
    R_grid = fftshift(sqrt(X_grid.^2 + Y_grid.^2));

    x = rand(N);

    center_mask = zeros(N);
    center_size = round(N * cfg.init_center_ratio);
    start_idx = floor((N - center_size) / 2) + 1;
    end_idx = start_idx + center_size - 1;
    center_mask(start_idx:end_idx, start_idx:end_idx) = 1;
    x = x .* center_mask;

    support = ones(N);
    hio_iterations = max(cfg.recon_iterations - cfg.er_iterations, 0);

    for t = 1:cfg.recon_iterations
        U = fft2(x);
        U_new = Fourier_Mag .* exp(1i * angle(U));

        zero_mask = (Fourier_Mag == 0) & (R_grid <= 4);
        U_new(zero_mask) = U(zero_mask);

        x_prime = real(ifft2(U_new));
        valid_mask = (x_prime >= 0) & (support == 1);

        if t <= hio_iterations
            x(valid_mask) = x_prime(valid_mask);
            x(~valid_mask) = x(~valid_mask) - cfg.beta * x_prime(~valid_mask);

            if cfg.use_shrink_wrap && ...
                    mod(t, cfg.shrink_update_interval) == 0 && ...
                    t > cfg.shrink_start_iter

                blurred = imgaussfilt(max(x, 0), cfg.shrink_sigma);

                if max(blurred(:)) > 0
                    support = double(blurred > cfg.shrink_threshold * max(blurred(:)));
                end
            end
        else
            x(valid_mask) = x_prime(valid_mask);
            x(~valid_mask) = 0;
        end
    end

    rec = normalize_to_unit(x);
end


%% ===================== 局部函数：归一化到 0-1 =====================
function img = normalize_to_unit(img)
    img = img - min(img(:));

    max_val = max(img(:));
    if max_val > 0
        img = img / max_val;
    end
end
