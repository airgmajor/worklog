# DifferentialRobotics 无人机项目的 ROS1 Noetic 复现环境

**日期**：2026-08-26
**环境**：Ubuntu 26.04 宿主 + ROS1 Noetic 容器
**代码**：https://github.com/airgmajor/diffrobot-noetic-env

## 背景

复现 [DifferentialRobotics](https://github.com/DifferentialRobotics)（微分智飞 / 非凸空间）的教育无人机项目。
核心仓库 Diff-Planner（基于 ZJU EGO-Planner-v2）、Diff-Navigation、px4ctrl、faster-lio、
Aerial_Autonomy_Challenge（IROS 2025 竞赛）。

项目要求 Ubuntu 16/18/20.04 + ROS1，宿主是 Ubuntu 26.04 —— 装不了 Noetic，所以全部容器化。
底座是 [rootless Docker](../infra/2026-08-25-rootless-docker.md)。

镜像 `diffrobot:noetic`（基于 `osrf/ros:noetic-desktop-full`），容器名 `diffrobot`，
`~/diffrobot/ws` bind mount 到 `/ws`。Diff-Planner 已编译通过，RViz 仿真实测 31fps。

## 日常

```bash
cd ~/diffrobot && ./run.sh    # 幂等，新终端重复执行会 exec 进同一容器
docker stop diffrobot          # 关机前停
```

容器内：`roslaunch diff_planner run_sim_single.launch`

## 关键决策与坑

### 1. 容器以 root 跑

rootless 下容器 root == 宿主 major（uid 1001），所以 bind mount 的源码、X11 socket、
xauth cookie **全部天然可读写** —— 完全避开了
[Isaac Lab 那边 uid 1000 的三关权限地狱](../isaaclab/2026-08-25-isaac-lab-setup.md)。

这条路走得通的前提是 ROS / RViz 不像 Isaac Kit 那样拒绝 root。同样是 rootless Docker + GUI，
两个项目的最优解完全相反，取决于容器里那个程序肯不肯用 root 跑。

### 2. 必须设 `__GLX_VENDOR_LIBRARY_NAME=nvidia`

否则 XWayland 的 GLX 默认报 mesa，RViz 落到 llvmpipe **软件渲染**。
设了之后容器内是 `OpenGL 4.6 NVIDIA 595.84`。

附带发现：宿主桌面本身跑在 AMD 核显（radeonsi）上，容器反而拿到了真正的 RTX PRO 6000。

### 3. CDI 只注入 `.so`，不注入 glvnd 的 vendor json

`/usr/share/glvnd/egl_vendor.d/10_nvidia.json` 得在 Dockerfile 里手动补，否则 EGL 找不到 nvidia vendor。

### 4. cookie 每次 XWayland 重启会失效

`run.sh` 每次执行都重新生成，所以直接跑 `run.sh` 就行，不用手动修：

```bash
xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f ~/diffrobot/.xauth nmerge -
```

### 5. `DOCKER_BUILDKIT=0` 必需

这台机器的 rootless docker 没装 buildx 组件，BuildKit 直接报
`buildx component is missing or broken`，只能用传统构建器。

### 6. 上游两个编译问题已在镜像里绕过

- `livox_ros_driver2` 需要 Livox-SDK2 → Dockerfile 里源码编译安装
- `user_command/multipoint` 的 CMakeLists 漏了 eigen3 include 路径 → 软链 `/usr/include/Eigen`

## 限制

**真机联调做不了。** rootless 的 `--network=host` 是 rootlesskit 的 netns 而非真宿主网络，
Mid360 雷达的 UDP、PX4 的串口都接不进来。
不过真机代码本来就跑在飞机的机载计算机上，不影响学习复现。

**Noetic 已于 2025-05 EOL。** `packages.ros.org` 的 focal 源目前（2026-08）还在，
哪天下架就得换 `snapshots.ros.org`，或者直接把镜像 `docker save` 存档。

**IROS 挑战赛仿真器**是 Unity 打包的 `.x86_64`，需手动从 Google Drive / 百度网盘下载解压。
同一个容器能跑（GL / Vulkan 已通）。

## 相关

- [rootless Docker 配置](../infra/2026-08-25-rootless-docker.md)
- [Isaac Sim / Isaac Lab 环境](../isaaclab/2026-08-25-isaac-lab-setup.md)
