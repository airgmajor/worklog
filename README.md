# 工作日志

搭环境、复现项目过程中踩过的坑和做出的决策。主要是机器人仿真（Isaac Sim / ROS）
和容器化相关，重点记「为什么这么做」而不是「怎么做」—— 怎么做搜得到，为什么往往搜不到。

## 笔记

| 日期 | 主题 |
|---|---|
| 2026-08-26 | [DifferentialRobotics 无人机项目的 ROS1 Noetic 复现环境](notes/2026-08-26-diffrobot-noetic.md) |
| 2026-08-25 | [Isaac Lab 3.0.0 跑在 rootless Docker 上](notes/2026-08-25-isaac-sim-lab.md) |
| 2026-08-25 | [用 rootless Docker 与同机另一位用户隔离](notes/2026-08-25-rootless-docker.md) |

## 相关仓库

- [diffrobot-noetic-env](https://github.com/airgmajor/diffrobot-noetic-env) —— 上面第一篇对应的环境定义

## 约定

- 一篇笔记一个文件，放 `notes/`，命名 `YYYY-MM-DD-主题.md`
- 开头写日期和环境（硬件 / 系统 / 版本），日后翻回来才知道结论还成不成立
- 有版本时效性的结论标注出来（比如「Noetic 已 EOL，源哪天下架就得换」）
- 笔记之间用相对链接互指
- 新增笔记后在上面表格里加一行

写完记得更新目录。模板见 [`templates/note.md`](templates/note.md)。
