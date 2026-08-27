# 工作日志

搭环境、复现项目过程中踩过的坑和做出的决策。
重点记「为什么这么做」而不是「怎么做」—— 怎么做搜得到，为什么往往搜不到。

目前两条主线：**Isaac Lab 机器人仿真**、**Diff-Planner 无人机仿真**。

## Diff-Planner 无人机仿真

`notes/diffrobot/`

| 日期 | 主题 |
|---|---|
| 2026-08-26 | [仿真三模式：单机指点 / 单机预设航点 / 集群](notes/diffrobot/2026-08-26-sim-single-swarm.md) |
| 2026-08-26 | [ROS1 Noetic 复现环境搭建](notes/diffrobot/2026-08-26-noetic-container.md) |

环境定义在单独的仓库：[diffrobot-noetic-env](https://github.com/airgmajor/diffrobot-noetic-env)

## Isaac Lab 机器人仿真

`notes/isaaclab/`

| 日期 | 主题 |
|---|---|
| 2026-08-27 | [unitree_rl_lab 装进 Isaac Lab 容器：从搭建到验证](notes/isaaclab/2026-08-27-unitree-rl-lab.md) |
| 2026-08-25 | [Isaac Lab 3.0.0 跑在 rootless Docker 上](notes/isaaclab/2026-08-25-isaac-lab-setup.md) |

## 基础设施

`notes/infra/` —— 两条主线共用的底座

| 日期 | 主题 |
|---|---|
| 2026-08-25 | [用 rootless Docker 与同机另一位用户隔离](notes/infra/2026-08-25-rootless-docker.md) |

## 约定

- 一篇笔记一个文件，按项目放进 `notes/<项目>/`，命名 `YYYY-MM-DD-主题.md`
- 开头写日期和环境（硬件 / 系统 / 版本），日后翻回来才知道结论还成不成立
- 有版本时效性的结论标注出来（比如「Noetic 已 EOL，源哪天下架就得换」）
- 引用源码时带上**文件路径和行号**，方便日后对照上游改动
- 笔记之间用相对链接互指
- 新增笔记后在上面对应表格里加一行
- 补丁、脚本等配套文件放 `notes/<项目>/files/<笔记名>/`，笔记里链过去

模板见 [`templates/note.md`](templates/note.md)。
