# Diff-Planner 仿真：单机指点 / 单机预设航点 / 集群

**日期**：2026-08-26
**环境**：Ubuntu 26.04 宿主 + `diffrobot:noetic` 容器（ROS1 Noetic）
**前置**：[ROS1 Noetic 复现环境搭建](2026-08-26-noetic-container.md)
**代码**：[Diff-Planner](https://github.com/DifferentialRobotics/Diff-Planner)（基于 ZJU EGO-Planner-v2）

今天跑通三种仿真模式。三者的差别**不在于启动哪个 launch，而在于目标点从哪个话题进入规划器**，
搞清楚这条链路，三种模式就是一回事的三种接法。

---

## 0. 进入容器

```bash
cd ~/diffrobot && ./run.sh
```

幂等 —— 容器不存在就创建，存在就 `docker exec` 进去。**每开一个新终端都执行这一条**，
它们会进入同一个容器、共享同一个 roscore。

进去之后提示符是绿色的 `[diffrobot容器] /ws/Diff-Planner #`，看到这个才说明在容器里。
退出用 `exit`，容器继续在后台跑；关机前 `docker stop diffrobot`。

```bash
cd /ws/Diff-Planner
```

---

## 0.1 每次 roslaunch 之前必须 `source devel/setup.bash`

```bash
cd /ws/Diff-Planner
source devel/setup.bash     # ← 每开一个新终端、每次 roslaunch 之前都要执行
roslaunch diff_planner run_sim_single.launch
```

**这不是可选步骤**，漏了就会看到：

```
[diff_planner] is not a package nor is it in the ROS_PACKAGE_PATH
RLException: [run_sim_single.launch] is neither a launch file in package [diff_planner] nor is [diff_planner] a launch file name
```

下面把「为什么」拆开讲清楚。

### 一、`devel/setup.bash` 到底改了什么

catkin 编译完会在 `devel/` 下生成一个环境脚本。它不产出任何二进制，唯一作用是**改当前 shell 的环境变量**。
在容器里实测对比：

```bash
# 没 source 时
root@diffrobot:/ws/Diff-Planner# echo $ROS_PACKAGE_PATH
/opt/ros/noetic/share

# source 之后
root@diffrobot:/ws/Diff-Planner# source devel/setup.bash
root@diffrobot:/ws/Diff-Planner# echo $ROS_PACKAGE_PATH
/ws/Diff-Planner/src:/opt/ros/noetic/share      # ← 多出来的这一段就是关键
```

被改写的主要有这几个：

| 变量 | 作用 | 不 source 的后果 |
|---|---|---|
| `ROS_PACKAGE_PATH` | `rospack` / `roslaunch` 搜包的根目录列表 | 找不到 `diff_planner`、`map_generator`、`multipoint` 等本地包 |
| `CMAKE_PREFIX_PATH` | catkin 查找依赖包的 CMake 配置 | 增量编译时找不到本工作空间已编译的包 |
| `LD_LIBRARY_PATH` | 动态链接库搜索路径 | 节点启动瞬间 `error while loading shared libraries` |
| `PATH` | 可执行文件搜索路径 | `rosrun` 起不来本工作空间的节点 |
| `PYTHONPATH` | Python 模块搜索路径 | 自定义 msg/srv 的 Python 绑定 `ImportError` |
| `ROS_MASTER_URI` 等 | roscore 地址 | 连不上 master |

`roslaunch diff_planner run_sim_single.launch` 这条命令里，`diff_planner` 是**包名不是路径**。
roslaunch 拿到包名后走 `rospack find`，而 `rospack` 只会在 `ROS_PACKAGE_PATH` 列出的目录里递归找
`package.xml`。`/ws/Diff-Planner/src` 不在里面，包就等于不存在 —— 哪怕你此刻就站在这个目录下。
**ROS 找包靠的是环境变量，不是当前工作目录。**

### 二、为什么叫 overlay（覆盖层）

ROS 环境是层层叠加的：

```
/opt/ros/noetic/setup.bash          ← 底层(underlay)：系统装的 ROS 和 mavros、pcl_ros 等
        ↓ 被 devel/setup.bash 继承并追加
/ws/Diff-Planner/devel/setup.bash   ← 覆盖层(overlay)：本工作空间自己编的包
```

`devel/setup.bash` 内部会先 source 它编译时记录下来的 underlay，再把自己的 `src` 和 `devel` **前置**
到各个路径变量最前面。所以只 source overlay 这一条就够了，不用先 source `/opt/ros/noetic/setup.bash`。
前置的顺序也意味着：同名包以本工作空间的为准，这正是我们改上游代码后能生效的原因。

### 三、为什么必须用 `source`，不能直接执行

```bash
source devel/setup.bash    # ✅ 在当前 shell 里执行，环境变量留下来
. devel/setup.bash         # ✅ 同上，POSIX 写法
./devel/setup.bash         # ❌ 开一个子 shell 执行，子 shell 一退出环境全丢
bash devel/setup.bash      # ❌ 同上
```

环境变量只能由进程自己修改，且只向下传给子进程、**永远传不回父进程**。
`roslaunch` 是当前 shell 的子进程，所以变量必须先设在当前 shell 里。

### 四、作用范围：一个 shell 一次，退出即失效

这条命令的效果**只存在于执行它的那个 shell 进程**。因此：

- 开第二个终端跑 `pub_trigger.sh` / `pub_swarm_trigger.sh` → 那个终端要**再 source 一次**
- `exit` 退出容器再进来 → 要重新 source
- 用 `docker exec diffrobot bash -c '...'` 这种非交互方式跑命令 → 更要显式带上，实测：

  ```bash
  $ docker exec diffrobot bash -c 'echo "[$ROS_PACKAGE_PATH]"; which roslaunch'
  []
  # roslaunch 都不在 PATH 里
  ```

  非交互 shell 根本不读 `.bashrc`（Ubuntu 的 `.bashrc` 开头就是 `[ -z "$PS1" ] && return`），
  所以任何写在 `.bashrc` 里的自动 source 对它都无效。正确写法：

  ```bash
  docker exec diffrobot bash -lc 'cd /ws/Diff-Planner && source devel/setup.bash && roslaunch diff_planner run_sim_single.launch'
  ```

### 五、`catkin_make` 之后一定要重新 source

编译会重新生成 `devel/setup.bash`。尤其是**新增了包、新增了 msg/srv** 的时候，路径变量的内容会变。
已经开着的旧终端里是编译**之前**的环境快照，不会自动更新，典型症状是「明明编译成功了却还是找不到包」。
规矩很简单：**`catkin_make` 完，所有终端重新 source 一遍。**

### 六、本机踩到的坑：镜像里的自动 source 在这个容器里是失效的

Dockerfile 里本来是写了自动 source 的：

```dockerfile
RUN printf '%s\n' \
      'source /opt/ros/noetic/setup.bash' \
      '[ -f /ws/Diff-Planner/devel/setup.bash ] && source /ws/Diff-Planner/devel/setup.bash' \
      'export ROS_MASTER_URI=http://localhost:11311' \
      > /etc/profile.d/ros_ws.sh \
 && echo '. /etc/profile.d/ros_ws.sh' >> /root/.bashrc
```

但今天查了正在跑的容器，`/root/.bashrc` 结尾并不是 `. /etc/profile.d/ros_ws.sh`，而是被替换成了一份
**路径写错**的内联副本：

```bash
$ docker exec diffrobot tail -3 /root/.bashrc
source /opt/ros/noetic/setup.bash
[ -f /ws/devel/setup.bash ] && source /ws/devel/setup.bash     # ← 路径错了
export ROS_MASTER_URI=http://localhost:11311

$ docker exec diffrobot ls -d /ws/devel
ls: cannot access '/ws/devel': No such file or directory
```

真实路径是 `/ws/Diff-Planner/devel/setup.bash`（工作空间在 `/ws` 下面还嵌了一层）。
`[ -f ... ] && source ...` 这种写法在文件不存在时**静默跳过、不报任何错**，
于是进容器后只有底层 ROS 环境，工作空间那一层永远没加载 —— 表现就是「看着一切正常，一 roslaunch 就说找不到包」。

> 容器是长期存活的（`run.sh` 里存在就 `docker start`），这份改动落在容器的可写层里，
> 重启容器不会恢复成镜像里的版本。要么 `docker rm diffrobot` 让 `run.sh` 从镜像重建，
> 要么就按现在这样每次手动 source。**手动 source 是更保险的做法**：它不依赖任何隐式配置，
> 换一台机器、换一个镜像版本都照样对。

### 七、`sh_files/` 下的脚本是例外

`sh_files/*.sh` 自己会 source，但它们是 **zsh** 脚本，而且用的是**相对路径**：

```bash
#!/bin/zsh
source devel/setup.zsh      # ← 相对路径，所以必须在 /ws/Diff-Planner 下执行
```

所以跑这些脚本时不需要先 `source devel/setup.bash`，但**必须先 `cd /ws/Diff-Planner`**，
否则 `source devel/setup.zsh` 会失败。注意是 `setup.zsh` 不是 `setup.bash` —— catkin
给每种 shell 各生成一份，内容等价。


---

## 1. 关键：目标点的两条链路

RViz 配置（`sim.rviz`）里挂了**两个**目标点工具，指向**不同的话题**：

| RViz 工具 | 插件类 | 发布话题 | 谁在听 |
|---|---|---|---|
| **3D Nav Goal** | `rviz_plugins/Goal3DTool` | `/goal` | **规划器直接收** |
| **2D Nav Goal** | `rviz/SetGoal` | `/move_base_simple/goal` | **multipoint 节点**（当作「开始」按钮） |

规划器 `diff_replan_fsm.cpp` 按 `flight_type` 决定订阅哪个：

```cpp
// src/diff_planner/plan_manage/src/diff_replan_fsm.cpp:70
if (target_type_ == TARGET_TYPE::MANUAL_TARGET)        // flight_type = 1
{
  waypoint_sub_ = nh.subscribe("/goal", 1, &DiffReplanFSM::waypointCallback, this);
}
else if (target_type_ == TARGET_TYPE::PRESET_TARGET)   // flight_type = 2
{
  trigger_sub_ = nh.subscribe("/traj_start_trigger", 1, &DiffReplanFSM::triggerCallback, this);
}
```

于是三条链路：

```
① 手动指点   RViz 3D Nav Goal ──────────────────────────────→ /goal → 规划器(flight_type=1)

② 预设航点   pub_trigger.sh ─→ /move_base_simple/goal ─→ multipoint ─逐点─→ /goal → 规划器(flight_type=1)
                                                            ↑
                                                     points.yaml

③ 集群       pub_swarm_trigger.sh ─→ /traj_start_trigger ──→ 规划器(flight_type=2)
                                                                  ↑
                                                          目标点写在 launch 的 target0_* 里
```

**记住这张图，后面全是它的展开。**

---

## 2. 单机手动指点飞行

```bash
cd /ws/Diff-Planner
source devel/setup.bash
roslaunch diff_planner run_sim_single.launch
```

`run_sim_single.launch` 干了四件事：

```xml
<!-- src/diff_planner/plan_manage/launch/sim/run_sim_single.launch -->
<node pkg="map_generator" name="random_forest" .../>   <!-- ① 随机森林地图 26×20×3，100 根柱子 -->

<include file="$(find diff_planner)/launch/include/run_in_sim.xml">
    <arg name="drone_id"    value="0"/>
    <arg name="init_x"      value="-15.0"/>            <!-- ② 飞机起始位置 -->
    <arg name="init_y"      value="0.0"/>
    <arg name="init_z"      value="1.0"/>
    <arg name="flight_type" value="1"/>                <!--    1 = MANUAL_TARGET -->
</include>

<include file="$(find multipoint)/launch/multipointplan_sim.launch" />  <!-- ③ 多点节点也一起起来了 -->
<node name="rviz" pkg="rviz" type="rviz" args="-d .../sim.rviz" required="true" />  <!-- ④ -->
```

**注意 ③** —— multipoint 节点在单机模式下是**一直在跑**的，只是没被触发而已。
这就是为什么下一节的「预设航点」不需要换 launch。

### 操作

在 RViz 里选 **3D Nav Goal** 工具（不是 2D Nav Goal），然后：

- 左键**按住**，在地面上拖动 → 选 x-y
- **不松左键**，同时按下右键上下拖 → 调 z
- 两个键都松开 → 发送

飞机随即规划一条避开柱子的轨迹飞过去。实测 RViz 31fps。

> 如果误用了 2D Nav Goal，飞机不会动（那个话题喂给的是 multipoint，
> 而 multipoint 此时如果 yaml 没加载好只会打 `No pyt loaded!`）。

---

## 3. 单机预设航点

**同一个 launch，不用重启**。上一节已经把 multipoint 节点带起来了。

### 3.1 编辑航点

```bash
vim src/user_command/multipoint/config/points.yaml
```

四种模式，**读哪个 key 由 `fligt_type` 参数决定**（注意上游把 flight 拼成了 `fligt`，
参数名和 yaml 里都是这个错拼，别「顺手改对」，改了就读不到了）：

```cpp
// src/user_command/multipoint/src/multipointplan.cpp:57
enum FLIGT_TYPE{ PP = 1, PP_TIME = 2, PP_YAW = 3, PP_YAW_TIME = 4 };
```

| `fligt_type` | 读取的 key | 每行格式 | 元素个数 |
|---|---|---|---|
| 1 | `test1` | `[x, y, z]` | 3 |
| 2 | `test2` | `[x, y, z, time]` | 4 |
| 3 | `test3` | `[x, y, z, yaw]` | 4 |
| 4 | `test4` | `[x, y, z, yaw, time]` | 5 |
| —（返程固定） | `test_back` | `[x, y, z]` | 3 |

**元素个数不对会直接读取失败**，节点起来就报错。

```yaml
# 模式1  x y z
test1:
  - [10.0,  0.0,  0.8]   # Point 1
  - [ 1.0,  0.5,  0.8]   # Point 2
  - [ 8.0, -0.2,  0.8]   # Point 3

# 返程点（back.sh 用）
test_back:
  - [0,  0,  0.8]
```

`time` 是**到达该点后的悬停等待秒数**，`yaw` 是偏航角（弧度）。

### 3.2 确认模式参数

```xml
<!-- src/user_command/multipoint/launch/multipointplan_sim.launch -->
<arg name="odom_topic"    value="/visual_slam/odom" />
<arg name="next_distance" value="0.3" />   <!-- 到点判定阈值(米) -->
<arg name="fligt_type"    value="1" />     <!-- 1~4，对应上表 -->
<arg name="start_plan"    value="1" />     <!-- 1=订阅开始触发 -->
<arg name="back_plan"     value="1" />     <!-- 1=订阅返程触发 -->
<arg name="auto_planning" value="0" />     <!-- 本地补丁新增 -->
<arg name="auto_landing"  value="0" />     <!-- 本地补丁新增 -->
```

> `auto_planning` / `auto_landing` 这两个参数**上游 launch 文件里漏了**，
> 但 C++ 代码用 `getParam` 强制读取（读不到就报错退出）。
> 我打了个补丁补上，见 [diffrobot-noetic-env/patches](https://github.com/airgmajor/diffrobot-noetic-env/tree/main/patches)。

改完要重新 `roslaunch`（yaml 和 launch 参数都是启动时读的）。

### 3.3 触发

**另开一个终端**（记得先 `cd ~/diffrobot && ./run.sh` 进同一个容器）：

```bash
cd /ws/Diff-Planner        # 必须在这个目录，脚本里是相对路径 source devel/setup.zsh
./sh_files/pub_trigger.sh  # 开始任务
```

脚本本体就是往触发话题发一个空 Pose：

```bash
#!/bin/zsh
source devel/setup.zsh;
rostopic pub -1 /move_base_simple/goal geometry_msgs/PoseStamped "..."
```

**Pose 里的 x/y/z 全是 0，是无意义的** —— multipoint 只把这条消息当作「开始」信号，
真正的航点来自 yaml：

```cpp
// multipointplan.cpp  startplan_cb
pytVector.assign(start_pytVector.begin(), start_pytVector.end());
counts = 0;
trigger = true;
ROS_INFO("Get start trigger.");
```

**等价操作**：在 RViz 里点一下 **2D Nav Goal** 随便戳个点，效果完全一样
（`points.yaml` 头部注释说的「发送一次 2D Nav Goal 即可进行规划」就是这个意思）。

### 3.4 逐点推进的逻辑

multipoint 不是一次把所有点发出去，而是**到一个发一个**：

```cpp
// multipointplan.cpp:260
if (distance_ < next_distance && counts < pytVector.size())  // 到达当前点且还有下一个
{
    // 若是带 time 的模式，先悬停 pytVector[counts_pre].time 秒
    goal.pose.position.x = pytVector[counts].x;   // 再发下一个点到 /goal
    ...
    counts++;
}
```

所以 `next_distance = 0.3` 的含义是：**离当前目标点小于 0.3m 就算到达**，随即切下一个点。
点排得太密（间距 < 0.3m）会被直接跳过。

终端里能看到逐点日志：`Publish the next pyt: [x:.. y:.. z:..]`。

### 3.5 返程

```bash
./sh_files/back.sh
```

发 `/back_trigger`，加载 `test_back` 里的点。

> ⚠️ **有副作用**：`backplan_cb` 里会把模式**强制改回 1**：
> ```cpp
> fligt_type = FLIGT_TYPE::PP;   // multipointplan.cpp  backplan_cb
> ```
> 也就是说返程之后如果再按一次 `pub_trigger.sh`，**模式已经不是你原来设的 2/3/4 了**，
> 而是模式 1（只读 `test1`，忽略 time 和 yaw）。要恢复得重启 launch。
> 这个坑不看源码根本发现不了。

### 3.6 关于自动降落

`auto_landing=1` 时，到最后一个点会自动发降落指令：

```cpp
// multipointplan.cpp:303
if (counts_pre == pytVector.size() - 1 && distance_ < next_distance
    && auto_landing == 1 && px4_is_auto_hover)
{
    takeoff_msg.takeoff_land_cmd = 2;
    takeoff_land_pub.publish(takeoff_msg);
}
```

注意条件里有 `px4_is_auto_hover`，它来自 `/px4ctrl/state`。
**仿真里 `run_in_sim.xml` 并不启动 px4ctrl**（只有 `traj_server` 和 `monitor_node`），
这个话题没人发，标志位一直是 false —— 所以**仿真下 `auto_landing` 设成 1 也不会触发**。
纯仿真阶段保持 0 即可，这个参数是留给真机的。

手动降落是 `./sh_files/land.sh`（发 `/px4ctrl/takeoff_land`，`cmd=2`），同样只在真机链路有效。

---

## 4. 集群预设点

```bash
cd /ws/Diff-Planner
source devel/setup.bash
roslaunch diff_planner run_sim_swarm.launch
```

另开终端：

```bash
cd /ws/Diff-Planner
./sh_files/pub_swarm_trigger.sh
```

### 4.1 上游默认是 10 机，不是 4 机

`run_sim_swarm.launch` 里 `run_in_sim.xml` 被 include 了 **10 次**，drone_id 0–9：

| drone_id | 起点 (x, y, z) | 目标 (x, y, z) |
|---|---|---|
| 0 | (-15, **-9**, 0.1) | (15, **9**, 1) |
| 1 | (-15, **-7**, 0.1) | (15, **7**, 1) |
| 2 | (-15, **-5**, 0.1) | (15, **5**, 1) |
| 3 | (-15, **-3**, 0.1) | (15, **3**, 1) |
| 4 | (-15, **-1**, 0.1) | (15, **1**, 1) |
| 5 | (-15, **1**, 0.1) | (15, **-1**, 1) |
| 6 | (-15, **3**, 0.1) | (15, **-3**, 1) |
| 7 | (-15, **5**, 0.1) | (15, **-5**, 1) |
| 8 | (-15, **7**, 0.1) | (15, **-7**, 1) |
| 9 | (-15, **9**, 0.1) | (15, **-9**, 1) |

y 坐标**首尾镜像对调** —— 10 架飞机从左边一字排开飞到右边，同时上下对穿，
在中间形成一个 X 形交叉。这不是随便设的，是**专门用来压测多机避碰**的构型。

**想改成 4 机**：删掉 drone_id 4–9 那 6 个 `<include>` 块即可（或注释掉）。
剩 0–3 就是 4 机，起点 y = -9/-7/-5/-3，目标 y = 9/7/5/3。

### 4.2 为什么集群不用 multipoint

`run_sim_swarm.launch` **没有** include `multipointplan_sim.launch`（grep 计数为 0）。
集群走的是第 1 节里的链路 ③：

- `run_in_sim.xml` 的 `flight_type` **默认值就是 2**（PRESET_TARGET），swarm launch 没覆盖它
- 每架飞机的目标点直接写在 launch 的 `target0_x/y/z` 里，启动时就读进去了
- 规划器订阅 `/traj_start_trigger`，收到就出发

```xml
<!-- run_in_sim.xml:10 -->
<arg name="flight_type" default="2"/>
<!-- 1: use 2D Nav Goal to select goal -->
<!-- 2: use global waypoints below -->
```

所以集群模式下 `points.yaml` 完全不起作用，改它没有任何效果。

### 4.3 机间通信：swarm_bridge

```xml
<include file="$(find swarm_bridge)/launch/bridge_udp.launch">
    <arg name="drone_id"     value="999"/>
    <arg name="broadcast_ip" value="127.0.0.255"/>
</include>
```

飞机之间靠 UDP 广播交换各自的轨迹，用来相互避让。
`drone_id=999` 是地面站/桥接节点的保留 ID。
广播地址 `127.0.0.255` 是**本机回环广播** —— 仿真里 10 架飞机都是同一台机器上的进程，
所以走 loopback 就够了。

> 这也解释了为什么[真机联调在这台机器上做不了](2026-08-26-noetic-container.md#限制)：
> 真机要换成真实网段的广播地址，而 rootless Docker 的 `--network=host`
> 是 rootlesskit 的 netns，不是真宿主网络。

### 4.4 触发脚本的差别

```bash
# pub_swarm_trigger.sh —— 注意没有 -1
rostopic pub /traj_start_trigger geometry_msgs/PoseStamped "..."
```

对比单机的 `pub_trigger.sh` 是 `rostopic pub **-1** ...`：

- 带 `-1`：发一条就退出
- 不带：发布后**持续挂着不退出**，要手动 `Ctrl-C`

集群这个脚本跑完记得 Ctrl-C，否则那个终端一直被占着。

---

## 5. 话题速查

| 话题 | 类型 | 方向 | 作用 |
|---|---|---|---|
| `/goal` | `geometry_msgs/PoseStamped` | → 规划器 | 单个目标点（flight_type=1） |
| `/move_base_simple/goal` | `geometry_msgs/PoseStamped` | → multipoint | 「开始」触发（内容被忽略） |
| `/back_trigger` | `geometry_msgs/PoseStamped` | → multipoint | 「返程」触发（会把模式重置为 1） |
| `/traj_start_trigger` | `geometry_msgs/PoseStamped` | → 规划器 | 集群出发触发（flight_type=2） |
| `/visual_slam/odom` | `nav_msgs/Odometry` | 规划器 → multipoint | 里程计，用于到点判定 |
| `/planning/yaw` | `quadrotor_msgs/PositionCommand` | multipoint → | 偏航角指令（模式 3/4） |
| `/px4ctrl/takeoff_land` | `quadrotor_msgs/TakeoffLand` | → px4ctrl | 起飞/降落，`cmd=2` 为降落（仅真机） |
| `/px4ctrl/state` | — | → multipoint | 仿真中**无人发布** |

---

## 6. 踩过的坑小结

1. **每次 roslaunch 前都要 `source devel/setup.bash`** —— 这个容器里 `.bashrc` 的自动 source
   路径写错了（`/ws/devel` vs 实际的 `/ws/Diff-Planner/devel`），`[ -f ] &&` 静默失败，
   工作空间那层环境根本没加载。详见 0.1 节。
2. **`source` 的作用范围只有当前 shell** —— 新开终端、`exit` 后重进、`docker exec bash -c`
   非交互执行，都要各自再 source 一次。
3. **`catkin_make` 之后所有终端重新 source** —— 旧终端里是编译前的环境快照，
   典型症状是「编译明明成功了却还是找不到包」。
4. **`sh_files/*.sh` 必须在 `/ws/Diff-Planner` 下执行** —— 脚本里是相对路径 `source devel/setup.zsh`，
   在别的目录跑会 source 失败。
5. **脚本是 zsh 不是 bash**。镜像里装了 zsh，所以能跑；换个没装 zsh 的环境会直接 `bad interpreter`。
6. **`fligt_type` 是上游的错拼**，参数名和代码里全都是它，别改。
7. **`back.sh` 会把飞行模式重置成 1**，返程后想再跑模式 2/3/4 必须重启 launch。
8. **仿真下 `auto_landing` 不生效**，因为 px4ctrl 没启动，`px4_is_auto_hover` 恒为 false。
9. **`auto_planning` / `auto_landing` 上游 launch 里缺失**，而代码用 `getParam` 强制读，
   不补参数节点直接报错退出。
10. **集群模式改 `points.yaml` 无效** —— 它压根不加载 multipoint。
11. **`pub_swarm_trigger.sh` 不会自己退出**，记得 Ctrl-C。
12. **航点间距不能小于 `next_distance`（0.3m）**，否则会被判定为「已到达」直接跳过。

---

## 相关

- [ROS1 Noetic 复现环境搭建](2026-08-26-noetic-container.md)
- [rootless Docker 配置](../infra/2026-08-25-rootless-docker.md)
