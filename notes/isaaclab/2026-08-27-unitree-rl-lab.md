# unitree_rl_lab 装进 Isaac Lab 容器：从搭建到验证

**日期**：2026-08-27
**上游**：[unitree_rl_lab](https://github.com/unitreerobotics/unitree_rl_lab) @ `4960b84`
**上游标称环境**：Isaac Sim 5.1 / Isaac Lab 2.3.0 / conda
**本机实际环境**：Isaac Sim 6.0.1-rc.7 / **Isaac Lab 3.0.0** / rootless Docker，**没有 conda**
**前置**：[Isaac Sim + Isaac Lab 容器环境](2026-08-25-isaac-lab-setup.md)

上游锁在 2.3.0，本机是 3.0.0，**不打补丁必然跑不起来**——会在 6 个不同位置依次报错。
本篇记录从零装到跑通、再到自动化验证的完整过程，以及所有踩过的坑。

配套文件都在 [`files/2026-08-27-unitree-rl-lab/`](files/2026-08-27-unitree-rl-lab/)：
四个脚本 + compose 覆盖文件 + 一份 `isaaclab-3.0-port.patch`（438 行，12 个文件）。

---

## 0. 每次开始工作，就跑这三条

> 这一节是给「明天的自己」看的。环境已经装好之后，日常复现只需要这些。

```bash
# ── 宿主机（major@ASUS）──────────────────────────────────────
cd ~/unitree_rl_lab
./docker/start.sh                       # ① 起容器 + 补挂载 + 装包 + 修 X11（幂等，可反复跑）

docker exec -it \
    -e XAUTHORITY=/tmp/isaaclab.xauth \
    -w /workspace/unitree_rl_lab \
    isaac-lab-base bash                 # ② 进容器

# ── 容器内（ubuntu@ASUS）────────────────────────────────────
./unitree_rl_lab.sh -l                                        # ③ 列出 5 个任务，确认环境活着
./unitree_rl_lab.sh -t --task Unitree-G1-29dof-Velocity --headless   # 开始训练
```

三条命令各自的作用：

| 命令 | 干什么 | 为什么不能省 |
|---|---|---|
| `./docker/start.sh` | `container.py start --files <覆盖文件>` + `setup_container.sh` | **绝对不要直接 `container.py start`**，见 §6.1 |
| `docker exec -it ... bash` | 进容器 | `-e XAUTHORITY=/tmp/isaaclab.xauth` 是开 GUI 的前提，见 §6.3 |
| `./unitree_rl_lab.sh -l` | 列任务 | 五个任务都列出来 = 包装好了、资源找得到、注册没问题 |

**怎么判断自己在宿主还是容器里**：`network_mode: host` 让容器继承了宿主的 hostname，
两边提示符都是 `ASUS`。**看用户名**——`major@ASUS` 是宿主，`ubuntu@ASUS` 是容器。
另一个判据：容器里没装 docker CLI，敲 `docker ps` 报 `command not found` 就说明你已经在容器里了。

想看训练曲线（**必须在宿主跑**，原因见 §6.5）：

```bash
~/unitree_rl_lab/docker/tensorboard.sh      # → http://localhost:6006
```

想确认环境没坏：

```bash
~/unitree_rl_lab/docker/verify_install.sh           # 9 项快检，约 2 分钟
~/unitree_rl_lab/docker/verify_install.sh --full    # 15 项全检，约 10 分钟
```

---

## 1. 总体思路：宿主是唯一真源，容器只提供运行时

```
宿主 ~/unitree_rl_lab   ──bind mount──→  容器 /workspace/unitree_rl_lab   (读写)
宿主 ~/unitree_model    ──bind mount──→  容器 /workspace/unitree_model    (只读)
宿主 ~/IsaacLab         ──bind mount──→  容器 /workspace/isaaclab         (已有)
```

代码、USD 资源、训练日志全在宿主上，容器可以随时删了重建。
这条原则决定了后面几乎所有设计：为什么用 compose 覆盖文件而不是 `docker cp`、
为什么日志能被宿主的 TensorBoard 直接读、为什么容器一重建就要重跑 `pip install -e`。

---

## 2. 环境搭建

### 2.1 拉代码和资源

```bash
cd ~
git clone https://github.com/unitreerobotics/unitree_rl_lab.git

# USD 资源在 HuggingFace，不是 GitHub
git clone https://huggingface.co/datasets/unitreerobotics/unitree_model
```

`~/unitree_model` 263MB，38 个 `.usd`，目录结构必须保持原样：

```
unitree_model/
├── B2/usd/b2.usd
├── Go2/usd/go2.usd
├── Go2W/usd/go2w.usd
├── H1/h1/usd/h1.usd
├── H1-2/, H2/                      # 本仓库暂时没用到
└── G1/
    ├── 23dof/usd/g1_23dof_rev_1_0/g1_23dof_rev_1_0.usd
    └── 29dof/usd/g1_29dof_rev_1_0/g1_29dof_rev_1_0.usd
```

> `deploy/` 里签入的 `.onnx` 是**普通二进制 blob 不是 LFS 指针**，所以宿主没装 git-lfs 也没关系。
> 上游 `unitree_rl_lab.sh -i` 里硬跑 `git lfs install`，我改成了有才跑（见 §4.7）。

### 2.2 告诉代码资源在哪

上游把路径写死成占位符，必须改：

```python
# source/unitree_rl_lab/unitree_rl_lab/assets/robots/unitree.py:20
- UNITREE_MODEL_DIR = "path/to/unitree_model"
- UNITREE_ROS_DIR = "path/to/unitree_ros"
+ # 用环境变量兜底，这样同一份 checkout 在容器里(/workspace)和宿主上(~)都能用
+ UNITREE_MODEL_DIR = os.environ.get("UNITREE_MODEL_DIR", "/workspace/unitree_model")
+ UNITREE_ROS_DIR = os.environ.get("UNITREE_ROS_DIR", "/workspace/unitree_ros")
```

写成 `os.environ.get(默认值)` 而不是写死 `/workspace/...`，是为了这份代码离开容器也能用。

### 2.3 把两个目录挂进已有的容器

不新建容器，而是给 IsaacLab 自己的 compose 加一个**覆盖文件**：

```yaml
# ~/unitree_rl_lab/docker/docker-compose.isaaclab.yaml
services:
  isaac-lab-base:
    volumes:
      - type: bind
        source: /home/major/unitree_rl_lab      # ← 绝对路径，见下方警告
        target: /workspace/unitree_rl_lab
      - type: bind
        source: /home/major/unitree_model
        target: /workspace/unitree_model
        read_only: true
```

> ⚠️ **source 必须写绝对路径**。compose 解析相对 bind source 时，基准是 **project 目录**
> （这里是 `~/IsaacLab/docker`），**不是覆盖文件自己所在的目录**。写成 `../..` 会挂到完全错误的地方，
> 而且不报错——它会当成不存在的目录直接建一个空的给你。

启动：

```bash
cd ~/IsaacLab/docker
./container.py start base --files ~/unitree_rl_lab/docker/docker-compose.isaaclab.yaml
```

### 2.4 ACL：让宿主和容器都能写这个目录

rootless Docker 下 `/proc/self/uid_map` 是 `0→1001` 和 `1→165536(+65536)`，
所以**容器 uid 1000 == 宿主 uid 166535**。宿主目录（`major:major` 0775）在容器里看是 `root:root`，
uid 1000 落在 other 位不可写 ⇒ `pip install -e` 写 egg-info 直接失败。

```bash
setfacl -R -m u:1001:rwX,u:166535:rwX ~/unitree_rl_lab
find ~/unitree_rl_lab -type d -exec setfacl -d -m u:1001:rwX,u:166535:rwX {} +
```

两个坑：

1. **ACL 只有文件属主能改**。如果容器已经建了一些文件（属主 166535），宿主 `setfacl` 会对它们报错。
   要先从容器里把那些文件删掉，再在宿主设 default ACL 让新文件继承。
2. **不要写成 `setfacl -R -m ... && setfacl -R -d ...`**。前一条一报错就短路，
   第二条根本不执行，而你还以为设好了。两条要分开跑（脚本里我用了 `|| true`）。

### 2.5 装 Python 包

容器里没有 conda，也没有裸 `python`，要用 Isaac Sim 自带的解释器：

```bash
docker exec isaac-lab-base /isaac-sim/python.sh -m pip install -e /workspace/unitree_rl_lab/source/unitree_rl_lab/
```

> ⚠️ `pip install -e` 装到 `/root/.local/`，**那不是 volume** ⇒ 容器一重建就没了，要重跑。
> `docker stop` / `docker start` 不受影响。这就是 `setup_container.sh` 存在的理由。

---

## 3. 把这些步骤固化成脚本

手动敲一遍能跑，但容器一重建就全废。所以写了四个脚本（都在宿主执行）：

| 脚本 | 作用 | 什么时候跑 |
|---|---|---|
| `docker/start.sh` | `container.py start --files 覆盖文件` + 调用下面那个 | **日常唯一入口** |
| `docker/setup_container.sh` | 补 ACL + `pip install -e` + X11 cookie，**幂等** | 容器重建后 / start.sh 自动调 |
| `docker/verify_install.sh` | 15 项自检 | 改完东西想确认没坏 |
| `docker/tensorboard.sh` | 起一个独立容器读日志 | 想看曲线时 |

`start.sh` 的核心只有两行，但开头那段守卫很重要：

```bash
if [ -n "${WORKSPACE:-}" ] || [ -d /workspace/isaaclab ]; then
    echo "!! You appear to be INSIDE the container (no docker CLI here). Exit first."
    exit 1
fi
cd "$ISAACLAB_DOCKER"
./container.py start base --files "${REPO}/docker/docker-compose.isaaclab.yaml"
exec "${REPO}/docker/setup_container.sh"
```

因为容器和宿主的提示符长得一样（§0），在容器里误跑宿主脚本是很容易发生的事。

---

## 4. Isaac Lab 3.0 移植：6 处 API 改动

**只有逐个跑 `train.py` 才能暴露这些错。** `list_envs.py` 能过说明不了任何问题——
env cfg 是**字符串 entry point，延迟导入**，列任务的时候根本没 import 到出错的模块。

### 4.1 噪声类改名

```python
# 3 个 velocity_env_cfg.py + 2 个 tracking_env_cfg.py
- from isaaclab.utils.noise import AdditiveUniformNoiseCfg as Unoise
+ from isaaclab.utils.noise import UniformNoiseCfg as Unoise
```

3.0 里 `UniformNoiseCfg.operation` 默认就是 `"add"`，所以语义完全等价，不用改调用点。

### 4.2 PhysX 配置搬家

3.0 把物理后端拆成了 physx / ovphysx / newton 三套，`sim.physx` 这个直通属性没了：

```python
+ from isaaclab_physx.physics import PhysxCfg
...
- self.sim.physx.gpu_max_rigid_patch_count = 10 * 2**15
+ self.sim.physics = PhysxCfg(gpu_max_rigid_patch_count=10 * 2**15)
```

### 4.3 `pretrained_checkpoint` 换包

```python
# scripts/rsl_rl/play.py
- from isaaclab.utils.pretrained_checkpoint import get_published_pretrained_checkpoint
+ from isaaclab_rl.utils.pretrained_checkpoint import get_published_pretrained_checkpoint
```

### 4.4 rsl-rl 5.0.1 不再吃旧的 `policy` 配置

rsl-rl ≥ 4.0 把单个 `policy`（`RslRlPpoActorCriticCfg`）拆成了 `actor` / `critic`。
Isaac Lab 提供了迁移函数，**必须在建 runner 之前调**：

```python
# scripts/rsl_rl/train.py:107,125
- from isaaclab_rl.rsl_rl import RslRlOnPolicyRunnerCfg, RslRlVecEnvWrapper
+ from isaaclab_rl.rsl_rl import RslRlOnPolicyRunnerCfg, RslRlVecEnvWrapper, handle_deprecated_rsl_rl_cfg
...
  agent_cfg = cli_args.update_rsl_rl_cfg(agent_cfg, args_cli)
+ agent_cfg = handle_deprecated_rsl_rl_cfg(agent_cfg, installed_version)
```

`play.py` 里同样要加一次（用 `version("rsl-rl-lib")` 取版本）。

### 4.5 策略导出：`runner.alg.policy` 没了

rsl-rl ≥ 4.0 自己接管了导出，`alg.policy` / `alg.actor_critic` 两个属性都不存在了。
我保留了旧分支做版本兼容：

```python
# scripts/rsl_rl/play.py:141
rsl_rl_version = pkg_version.parse(version("rsl-rl-lib"))
if rsl_rl_version >= pkg_version.parse("4.0.0"):
    policy_nn = None
    runner.export_policy_to_jit(path=export_model_dir, filename="policy.pt")
    runner.export_policy_to_onnx(path=export_model_dir, filename="policy.onnx")
else:
    ... # 原来那套 policy_nn + normalizer 手动导出
```

顺带修了播放循环里的 recurrent state 重置（旧代码把 `dones` 丢掉了）：

```python
- obs, _, _, _ = env.step(actions)
+ obs, _, dones, _ = env.step(actions)
+ if rsl_rl_version >= pkg_version.parse("4.0.0"):
+     policy.reset(dones)
+ else:
+     policy_nn.reset(dones)
```

### 4.6 删掉自带的 `randomize_rigid_body_com`

`tasks/mimic/mdp/events.py` 里那份是 Isaac Lab 2.x 的**逐字拷贝**，
它调 `asset.root_physx_view.get_coms()`，而 3.0 里这个不再返回 torch tensor。

**修法是直接删掉整个函数**（-46 行）。3.0 自带一个同签名、且感知物理后端的版本，
本包 `__init__` 里的 `from isaaclab.envs.mdp import *` 会自动提供它。删了就好了，不用改调用点。

### 4.7 入口脚本解绑 conda

`unitree_rl_lab.sh` 原本硬依赖 `CONDA_PREFIX`，容器里没有 conda 就直接报错退出：

```bash
 if ! [[ -z "${CONDA_PREFIX}" ]]; then
     python_exe=${CONDA_PREFIX}/bin/python
+elif [[ -x "/isaac-sim/python.sh" ]]; then
+    python_exe=/isaac-sim/python.sh          # ← 容器里走这条
+elif [[ -n "${ISAACLAB_PATH}" && -x "${ISAACLAB_PATH}/isaaclab.sh" ]]; then
+    python_exe="${ISAACLAB_PATH}/isaaclab.sh -p"
 else
-    echo "[Error] No conda environment activated..."
+    echo "[Error] No Isaac Lab python found. Activate the conda env, or run inside the container."
 fi
```

`-i|--install` 分支里的 `git lfs install` 和 `activate-global-python-argcomplete`
也改成了「有才跑」，conda 专属的 `_ut_setup_conda_env` 加了条件包住。

---

## 5. ProxyArray：3.0 最隐蔽的一个坑

Isaac Lab 3.0 里所有 `asset.data.*` 都不再是 `torch.Tensor`，而是
`isaaclab.utils.warp.proxy_array.ProxyArray`。

它支持索引和算术运算（**结果会退化成 `torch.Tensor`**），所以绝大部分代码完全无感。
**只有把整个未索引的 ProxyArray 直接传进 TorchScript 函数时才会炸**：

```
Expected a value of type 'Tensor' for argument 'quat' but instead found type 'ProxyArray'.
```

判据很简单：`quat_apply_inverse(Tensor, Tensor)` 才 OK，任一参数是 ProxyArray 就报错。
修法是加 `.torch`。全仓库只有 **4 处**：

```python
# tasks/mimic/mdp/terminations.py:38,40
- motion_projected_gravity_b = quat_apply_inverse(command.anchor_quat_w, asset.data.GRAVITY_VEC_W)
+ motion_projected_gravity_b = quat_apply_inverse(command.anchor_quat_w, asset.data.GRAVITY_VEC_W.torch)
- robot_projected_gravity_b = quat_apply_inverse(command.robot_anchor_quat_w, asset.data.GRAVITY_VEC_W)
+ robot_projected_gravity_b = quat_apply_inverse(command.robot_anchor_quat_w, asset.data.GRAVITY_VEC_W.torch)
```

```python
# tasks/locomotion/mdp/rewards.py:109  —— 在循环外取一次，顺便省了每次迭代的转换
+ root_quat_w = asset.data.root_quat_w.torch
  for i in range(len(asset_cfg.body_ids)):
-     footpos_in_body_frame[:, i, :] = quat_apply_inverse(asset.data.root_quat_w, cur_footpos_translated[:, i, :])
-     footvel_in_body_frame[:, i, :] = quat_apply_inverse(asset.data.root_quat_w, cur_footvel_translated[:, i, :])
+     footpos_in_body_frame[:, i, :] = quat_apply_inverse(root_quat_w, cur_footpos_translated[:, i, :])
+     footvel_in_body_frame[:, i, :] = quat_apply_inverse(root_quat_w, cur_footvel_translated[:, i, :])
```

第二个参数 `cur_footpos_translated[:, i, :]` 是**索引过的**，已经退化成 Tensor，所以只有第一个参数要改。

---

## 6. 日常操作与踩过的坑

### 6.1 不要直接 `container.py start`

裸的 `container.py start` 会**只按 IsaacLab 自己的 compose 重建容器**，
**静默丢掉** `/workspace/unitree_rl_lab` 和 `/workspace/unitree_model` 两个挂载，
连带 `pip install -e` 的包和 `/tmp/isaaclab.xauth` 一起没（可写层被清空）。

**症状**：进容器后 `/workspace` 下只剩 `isaaclab` 一个目录。
**修法**：`./docker/start.sh`（= `container.py start --files ...` + `setup_container.sh`）。

### 6.2 不要用 `container.py stop`

它底层是 `docker compose down --volumes`，会连 13 个卷一起删，
包括 shader 缓存（`isaac-cache-kit/-gl/-ov/-compute`），下次启动要重编 shader，黑屏十几分钟。

- 日常关机：`docker stop isaac-lab-base`
- 恢复：`docker start isaac-lab-base`，然后 `./docker/setup_container.sh`
- 只有换版本 / 缓存损坏 / 腾磁盘才用 `container.py stop`

代码在 bind mount 上，任何情况都不会丢。

### 6.3 GUI 要过三关

（详见 [Isaac Lab 环境笔记](2026-08-25-isaac-lab-setup.md)，这里只列 `setup_container.sh` 自动做的两件事）

1. **X socket 权限**：XWayland 建的 `/tmp/.X11-unix/X0` 是 **0775**（标准 Xorg 是 0777），
   容器 uid 1000 落在 other 位没权限，`XOpenDisplay` **直接返回 NULL 且不报错**。
   → 宿主 `chmod 0777 /tmp/.X11-unix/X0`（cookie 鉴权还在，安全性不变）
2. **cookie 权限**：cookie 文件是 0600 root-owned，容器 uid 1000 读不到。
   → 容器内以 root 复制一份：`install -m600 -o1000 -g1000 "$XAUTHORITY" /tmp/isaaclab.xauth`，
   然后用 `-e XAUTHORITY=/tmp/isaaclab.xauth` 跑

脚本里解析 `DISPLAY` 那段有个细节值得记：`DISPLAY` 可能是 `:0` 也可能是 `:0.0`，
必须只取显示号，不能拿整个字符串去拼路径。

```bash
disp="${DISPLAY#*:}"    # "0" 或 "0.0"
disp="${disp%%.*}"      # "0"
sock="/tmp/.X11-unix/X${disp}"
```

3. **不要用 root 跑 kit**。Kit 会拒绝（要 `--allow-root`），而且会在挂载的 cache volume 里留下
   root 文件，反过来弄坏正常用户的运行。

**IsaacLab 3.0 改了 GUI 模型**：光去掉 `--headless` 不再开窗口，默认就是 headless，
**必须显式加 `--viz kit`**（`--headless` 已标记 deprecated）。

### 6.4 mimic 任务：先生成 npz

mimic 任务读的是 `.npz`，仓库里签入的是 `.csv`。两个动作的 npz 我已经生成好了：

```
source/unitree_rl_lab/.../dance_102/G1_Take_102.bvh_60hz.npz
source/unitree_rl_lab/.../gangnanm_style/G1_gangnam_style_V01.bvh_60hz.npz
```

要重新生成：

```bash
/isaac-sim/python.sh scripts/mimic/csv_to_npz.py \
    -f source/unitree_rl_lab/unitree_rl_lab/tasks/mimic/robots/g1_29dof/dance_102/G1_Take_102.bvh_60hz.csv \
    --input_fps 60 --headless
```

> ⚠️ **这个脚本存完 npz 之后会无限空转，不会自己退出。**
> 看到文件出现就手动 Ctrl-C / kill，别傻等。（默认 `--output_fps 50`，会做插值重采样。）

### 6.5 TensorBoard 不能在训练容器里起

`network_mode: host` 在 rootless 下是 **rootlesskit 自己的 netns**，不是真宿主网络。
容器里开的端口，宿主 `curl localhost:PORT` 连不上（实测）。

日志本来就在 bind mount 上，所以用一个**走 bridge + `-p`** 的临时容器读它：

```bash
docker run --rm -p 6006:6006 -v ~/unitree_rl_lab/logs:/logs:ro \
    -e ACCEPT_EULA=Y \
    --entrypoint /isaac-sim/python.sh \
    isaac-lab-base -m tensorboard.main --logdir /logs --host 0.0.0.0 --port 6006
```

> ⚠️ `--entrypoint` 是必须的。`isaac-lab-base` 的 ENTRYPOINT 是 `/isaac-sim/runheadless.sh`，
> 不覆盖的话参数会被 Kit 吞掉，然后段错误。`-e ACCEPT_EULA=Y` 也不能少。

封装成了 `docker/tensorboard.sh`。

### 6.6 `docker exec` 被 timeout 杀掉，容器里的进程还活着

排查时常用 `timeout 240 docker exec ...`，但**杀掉的只是 exec 客户端，容器内的进程会一直跑**，
继续占着 GPU。下一轮跑之前先看看有没有残留：

```bash
docker exec isaac-lab-base pgrep -af "train.py|play.py"
docker exec isaac-lab-base pkill -9 -f "rsl_rl/play.py"
```

`play.py` 会一直循环到 sim app 关闭，所以在自动化脚本里必须 timeout + pkill 收尾。

---

## 7. 验证

把上面所有东西编码成一个自检脚本 `docker/verify_install.sh`，分两档。

### 7.1 快检（9 项，约 2 分钟）

```bash
~/unitree_rl_lab/docker/verify_install.sh
```

| 步骤 | 检什么 | 检不过说明 |
|---|---|---|
| **[1] 容器和挂载** | 容器在跑；`/workspace/unitree_rl_lab` 挂上了；`/workspace/unitree_model` 挂上了；容器能往 bind mount 写文件 | 前三条 → 用了裸 `container.py start`（§6.1）；第四条 → ACL 没设（§2.4） |
| **[2] 机器人资源** | 6 个 USD 入口文件都非空 | HuggingFace 仓库没拉全，或目录结构被改过 |
| **[3] Python 包** | `pip show unitree_rl_lab` 有输出；`rsl-rl-lib` 可导入 | 容器重建后没重跑 `setup_container.sh`（§2.5） |
| **[4] 任务注册** | `list_envs.py` 数出 **5** 个 `Unitree-` 任务 | 包没装上，或 `tasks/__init__.py` 导入失败 |
| **[5] 冒烟训练** | G1 velocity 跑 2 个 iteration 不抛 Traceback | 移植改动有遗漏（§4、§5） |

第 4 步这个「数 5 个」的设计有意思：它**只能证明注册表是对的，证明不了 env cfg 能实例化**——
因为 entry point 是延迟导入的。所以第 5 步的冒烟训练不能省，它才是真正把代码路径跑通的那一步。

实际输出：

```
[1] container and mounts
  PASS  container isaac-lab-base is running
  PASS  repo mounted at /workspace/unitree_rl_lab
  PASS  assets mounted at /workspace/unitree_model
  PASS  container can write the bind mount (ACL ok)
[2] robot assets
  PASS  all 6 robot USD entry files present
[3] python package
  PASS  unitree_rl_lab installed (Version: 0.2.1)
  PASS  rsl-rl-lib 5.0.1
[4] task registration
  PASS  5 tasks registered
[5] smoke train (G1 velocity, 2 iterations)
  PASS  training ran, 2 iterations

9 passed, 0 failed
```

### 7.2 全检（15 项，约 10 分钟）

```bash
~/unitree_rl_lab/docker/verify_install.sh --full
```

在快检基础上加：

- **[6] 每个任务都能训**：剩下 4 个任务各跑 2 个 iteration
  （`Unitree-Go2-Velocity`、`Unitree-H1-Velocity`、两个 Mimic）。
  这一步是必要的——6 处移植改动散落在不同任务里，只跑 G1 覆盖不到 mimic 那两处。
- **[7] play + 策略导出**：跑 `play.py` 并确认 `logs/rsl_rl/*/*/exported/policy.onnx` 真的生成了。
  这一条直接验证 §4.5 那个改动。

### 7.3 当前环境实测值

| 项 | 值 |
|---|---|
| Isaac Lab | **3.0.0**（`/workspace/isaaclab/VERSION`；pip 包 `isaaclab` 版本号是 6.1.17，别混淆） |
| `isaaclab_rl` | 0.5.7 |
| `rsl-rl-lib` | **5.0.1** |
| torch | 2.10.0+cu128 |
| `unitree_rl_lab` | 0.2.1 |
| 注册任务 | 5 个 |

五个任务：

| # | Task | Config |
|---|---|---|
| 1 | `Unitree-G1-29dof-Velocity` | `locomotion.robots.g1.29dof.velocity_env_cfg:RobotEnvCfg` |
| 2 | `Unitree-Go2-Velocity` | `locomotion.robots.go2.velocity_env_cfg:RobotEnvCfg` |
| 3 | `Unitree-H1-Velocity` | `locomotion.robots.h1.velocity_env_cfg:RobotEnvCfg` |
| 4 | `Unitree-G1-29dof-Mimic-Dance-102` | `mimic.robots.g1_29dof.dance_102.tracking_env_cfg:RobotEnvCfg` |
| 5 | `Unitree-G1-29dof-Mimic-Gangnanm-Style` | `mimic.robots.g1_29dof.gangnanm_style.tracking_env_cfg:RobotEnvCfg` |

> `Gangnanm` 是上游的错拼（应为 Gangnam），任务名和目录名都是它，**别改**。
> 和 Diff-Planner 里的 `fligt_type` 一个性质。

---

## 8. 换台机器怎么复现

```bash
# 1. 先把 Isaac Lab 容器装好（前置笔记）
# 2. 拉代码和资源
git clone https://github.com/unitreerobotics/unitree_rl_lab.git ~/unitree_rl_lab
git clone https://huggingface.co/datasets/unitreerobotics/unitree_model ~/unitree_model
cd ~/unitree_rl_lab && git checkout 4960b84

# 3. 打移植补丁
git apply /path/to/isaaclab-3.0-port.patch

# 4. 放脚本（注意改 docker-compose.isaaclab.yaml 里的绝对路径和 setup_container.sh 里的 uid）
cp /path/to/files/*.sh /path/to/files/docker-compose.isaaclab.yaml docker/
chmod +x docker/*.sh

# 5. 起环境 + 验证
./docker/start.sh
./docker/verify_install.sh --full
```

要改的两个机器相关值：
- `docker-compose.isaaclab.yaml` 里两处 `/home/major/...`
- `setup_container.sh` 里的 `CTR_UID=166535`（用 `cat /proc/self/uid_map` 算：容器 uid 1000 → 宿主 subuid 起点 + 1000 - 1）

---

## 相关

- [Isaac Sim + Isaac Lab 容器环境](2026-08-25-isaac-lab-setup.md)
- [rootless Docker 配置](../infra/2026-08-25-rootless-docker.md)
- 配套文件：[`files/2026-08-27-unitree-rl-lab/`](files/2026-08-27-unitree-rl-lab/)
