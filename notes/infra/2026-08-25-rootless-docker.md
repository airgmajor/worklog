# 用 rootless Docker 与同机另一位用户隔离

**日期**：2026-08-25
**环境**：Ubuntu 26.04

## 背景

这台机器是双人共用：另一位用户（下称 **用户 A**，uid 1000）已经在用系统 Docker，
我（major，uid 1001）需要自己的容器环境。最省事的做法是把自己加进 `docker` 组，
但那等于共用同一个 root 守护进程 —— 我能看到并删掉用户 A 的容器和镜像，
而且加入 docker 组本身就等价于拿到 root 权限。**那正是隔离的反面。**

所以走 rootless Docker：两个守护进程并存，互不可见。

## 结果

| | 我的 (rootless) | 用户 A 的 (系统) |
|---|---|---|
| 守护进程 | `systemctl --user status docker` | `systemctl status docker` |
| socket | `/run/user/1001/docker.sock` | `/var/run/docker.sock` |
| 数据目录 | `~/.local/share/docker` | `/var/lib/docker` |
| 访问方式 | 环境变量 `DOCKER_HOST` | `docker` 组 |

配置要点：

- `~/.bashrc` 里 `export DOCKER_HOST=unix:///run/user/1001/docker.sock`
- `~/.local/bin/` 下三个软链：`docker`、`dockerd-rootless.sh`、`dockerd-rootless-setuptool.sh`
  （后两个来自 Ubuntu `docker.io` 包，原始位置 `/usr/share/docker.io/contrib/`，不在 PATH 里，
  这一点官方文档没提，是排查了一阵才找到的）
- `loginctl enable-linger major` —— 否则注销后用户级 systemd 停掉，容器跟着死

## 已知限制

rootless 不是免费的，以下几条后来在别的项目里都实际撞上了：

- 默认绑不了 1024 以下端口
- 网络走 slirp4netns
- **`--network=host` 不是真正的宿主网络**，而是 rootlesskit 的 netns
  —— 这条后来直接导致 [无人机项目](../diffrobot/2026-08-26-noetic-container.md) 的真机联调做不了
- 只能挂载当前用户有权限的目录

## 相关

- [Isaac Sim / Isaac Lab 环境](../isaaclab/2026-08-25-isaac-lab-setup.md) —— GPU 直通建在这套 rootless 之上
- [DifferentialRobotics ROS1 复现环境](../diffrobot/2026-08-26-noetic-container.md)
