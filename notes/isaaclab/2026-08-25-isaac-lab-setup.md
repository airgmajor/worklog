# Isaac Lab 3.0.0 跑在 rootless Docker 上

**日期**：2026-08-25
**环境**：Ubuntu 26.04 / RTX PRO 6000 Blackwell 96GB / 驱动 595.84 / CUDA 13.2 / Ryzen 9 9950X3D / 89GB 内存

Isaac Lab 3.0.0，基础镜像 Isaac Sim 6.0.1-rc.7。容器内实测 torch 2.10.0+cu128，
`torch.cuda.is_available()` 为 True。首次构建 21 分钟，镜像 48.6GB。

前提是 [rootless Docker 那一套](../infra/2026-08-25-rootless-docker.md)。

## 位置

- 仓库在宿主 `~/IsaacLab`（115MB 纯源码），bind mount 到容器 `/workspace/isaaclab`，宿主改代码容器实时生效
- 镜像 `isaac-lab-base:latest`，容器名 `isaac-lab-base`

## 常用命令

都在宿主 `~/IsaacLab` 下执行：

```bash
./docker/container.py start
./docker/container.py enter base
```

容器内跑 Python 必须用包装脚本，直接 `python` 不在 PATH 里：

```bash
./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/train.py --task Isaac-Cartpole-v0 --headless
```

## 坑一：别用 `container.py stop`

它底层是 `docker compose down --volumes`，会连 13 个卷一起删，
包括 shader 缓存（`isaac-cache-kit` / `-gl` / `-ov` / `-compute`）和 pip 缓存。
下次启动要重编 shader，**黑屏十几分钟**。

日常关机用 `docker stop isaac-lab-base`，恢复用 `docker start isaac-lab-base` 再 `enter base`。
只有换版本 / 缓存损坏 / 腾磁盘才用 `container.py stop`。
（代码在 bind mount 上，任何情况都不会丢。）

## 坑二：GPU 直通要用「用户级」配置

网上教程普遍让改系统级 `/etc/nvidia-container-runtime/config.toml` 的 `no-cgroups`，
**那会破坏同机另一位用户的 rootful GPU 容器**。用户级配置 + CDI 达到同样效果且零影响：

- `/etc/cdi/nvidia.yaml` 由 `nvidia-ctk cdi generate` 生成
- `~/.config/nvidia-container-runtime/config.toml` 设 `no-cgroups = true`
- `~/.config/systemd/user/docker.service.d/nvidia-rootless.conf` 设 `XDG_CONFIG_HOME=/home/major/.config`

最后那条最容易漏：少了它，nvidia 运行时会回退去读 `/etc` 那份，
`--gpus all` 报 `bpf_prog_query` 权限错误。

`--gpus all` 和 `--device nvidia.com/gpu=all` 两种写法都可用。

## 坑三：开 GUI 要过三关

容器每次重启、X server 每次重启都要重做前两步。

**1. cookie 会过期。** `docker/.container.cfg` 的 x11 转发把 cookie 写进宿主
`/tmp/tmp.XXXX/*.xauth` 再 bind mount 进容器，但 XWayland 重启会换 cookie，
容器里那份就失效。症状是 `Invalid MIT-MAGIC-COOKIE-1 key`。重新生成：

```bash
xauth nlist :0 | sed -e 's/^..../ffff/' | xauth -f <挂载的 xauth 文件> nmerge -
```

**2. 容器用户既读不到 cookie，也连不上 socket。** 两个独立原因叠在一起：

- 容器默认用户是 uid 1000（`/etc/passwd` 里叫 ubuntu，compose 里叫 isaaclab），
  rootless 下它是宿主的 subuid；而 cookie 文件属于宿主 major（= 容器 root），模式 0600
- XWayland 建的 `/tmp/.X11-unix/X0` 是 **0775**（标准 Xorg 是 0777），
  uid 1000 落在 other 位没有写权限，`XOpenDisplay` 直接返回 NULL 且**不报任何错**

修复：

```bash
# 宿主：cookie 鉴权仍在，另一位用户拿不到 cookie，安全性不变
chmod 0777 /tmp/.X11-unix/X0
# 容器内以 root 把 cookie 复制成 uid 1000 可读的容器本地文件
install -m600 -o1000 -g1000 "$XAUTHORITY" /tmp/isaaclab.xauth
# 然后用 -e XAUTHORITY=/tmp/isaaclab.xauth 跑
```

**3. 不要用 root 跑 kit。** Kit 会拒绝（要 `--allow-root`），
而且镜像已把 `/root`（即 `DOCKER_USER_HOME`）chown 给 uid 1000，
用 root 跑会在挂载的 cache volume 里留下 root 文件，反过来弄坏正常用户的运行。

启动 UI：

```bash
docker exec -d -e XAUTHORITY=/tmp/isaaclab.xauth isaac-lab-base /isaac-sim/isaac-sim.sh
```

带 Isaac Lab 场景的 GUI 则是去掉 `--headless` 跑
`./isaaclab.sh -p scripts/tutorials/00_sim/create_empty.py`。

验证 X 是否通（不用装 xdpyinfo）：用 `/isaac-sim/kit/python/bin/python3` 加 ctypes 调
`XOpenDisplay(b":0")`，返回 0 就是没通。

## 其他

compose 里的 `network_mode: host` 在 rootless 下是 rootlesskit 的 netns 而非真宿主网络，
TensorBoard / WebRTC 串流的端口访问需要另行处理。

## 相关

- [rootless Docker 配置](../infra/2026-08-25-rootless-docker.md)
- [DifferentialRobotics ROS1 复现环境](../diffrobot/2026-08-26-noetic-container.md) —— 那边用 root 跑容器，
  正好避开了这里的三关权限地狱，对比着看很说明问题
