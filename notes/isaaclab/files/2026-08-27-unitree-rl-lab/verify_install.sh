#!/usr/bin/env bash
# Verify the unitree_rl_lab install inside the Isaac Lab container. Run ON THE HOST.
#   ./docker/verify_install.sh          # checks 1-5 (fast, ~2 min)
#   ./docker/verify_install.sh --full   # + trains every task and exports a policy (~10 min)
CONTAINER=${CONTAINER:-isaac-lab-base}
REPO_CTR=/workspace/unitree_rl_lab
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
pass=0; fail=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }
inctr() { docker exec -w "$REPO_CTR" "$CONTAINER" bash -lc "$1"; }

step 1 "container and mounts"
[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ] \
    && ok "container $CONTAINER is running" || { bad "container not running"; exit 1; }
inctr "test -f $REPO_CTR/unitree_rl_lab.sh" >/dev/null 2>&1 && ok "repo mounted at $REPO_CTR" || bad "repo not mounted"
inctr "test -d /workspace/unitree_model/G1" >/dev/null 2>&1 && ok "assets mounted at /workspace/unitree_model" || bad "assets not mounted"
inctr "touch $REPO_CTR/.vtest && rm -f $REPO_CTR/.vtest" >/dev/null 2>&1 \
    && ok "container can write the bind mount (ACL ok)" || bad "container cannot write the bind mount"

step 2 "robot assets"
missing=$(inctr 'for f in Go2/usd/go2.usd Go2W/usd/go2w.usd B2/usd/b2.usd H1/h1/usd/h1.usd \
    G1/23dof/usd/g1_23dof_rev_1_0/g1_23dof_rev_1_0.usd G1/29dof/usd/g1_29dof_rev_1_0/g1_29dof_rev_1_0.usd; do
    [ -s "/workspace/unitree_model/$f" ] || echo "$f"; done' 2>/dev/null)
[ -z "$missing" ] && ok "all 6 robot USD entry files present" || bad "missing USD: $missing"

step 3 "python package"
inctr '/isaac-sim/python.sh -m pip show unitree_rl_lab' >/dev/null 2>&1 \
    && ok "unitree_rl_lab installed ($(inctr '/isaac-sim/python.sh -m pip show unitree_rl_lab 2>/dev/null | grep ^Version' | tr -d '\r'))" \
    || bad "unitree_rl_lab NOT installed -- run docker/setup_container.sh"
ver=$(inctr '/isaac-sim/python.sh -c "import importlib.metadata as m; print(m.version(\"rsl-rl-lib\"))"' 2>/dev/null | tr -d '\r')
[ -n "$ver" ] && ok "rsl-rl-lib $ver" || bad "rsl-rl-lib not importable"

step 4 "task registration"
n=$(inctr '/isaac-sim/python.sh scripts/list_envs.py 2>/dev/null' | grep -c "| Unitree-")
[ "$n" = 5 ] && ok "5 tasks registered" || bad "expected 5 tasks, got $n"

step 5 "smoke train (G1 velocity, 2 iterations)"
log=$(mktemp)
inctr '/isaac-sim/python.sh scripts/rsl_rl/train.py --headless --task Unitree-G1-29dof-Velocity --num_envs 16 --max_iterations 2' >"$log" 2>&1
grep -q Traceback "$log" && { bad "training raised"; sed -n '/Traceback/,$p' "$log" | tail -12; } \
    || ok "training ran, $(grep -c 'Learning iteration' "$log") iterations"
rm -f "$log"

if [ "$FULL" = 1 ]; then
  step 6 "every task trains"
  for t in Unitree-Go2-Velocity Unitree-H1-Velocity \
           Unitree-G1-29dof-Mimic-Dance-102 Unitree-G1-29dof-Mimic-Gangnanm-Style; do
      log=$(mktemp)
      inctr "/isaac-sim/python.sh scripts/rsl_rl/train.py --headless --task $t --num_envs 16 --max_iterations 2" >"$log" 2>&1
      grep -q Traceback "$log" && { bad "$t"; sed -n '/Traceback/,$p' "$log" | tail -8; } || ok "$t"
      rm -f "$log"
  done

  step 7 "play + policy export"
  log=$(mktemp)
  # play.py loops until the sim app closes; kill it once the export has happened.
  # note: killing the `docker exec` client does NOT kill the process inside the container.
  timeout 240 docker exec -w "$REPO_CTR" "$CONTAINER" bash -lc \
      '/isaac-sim/python.sh scripts/rsl_rl/play.py --headless --task Unitree-G1-29dof-Velocity --num_envs 8' >"$log" 2>&1
  docker exec "$CONTAINER" pkill -9 -f "rsl_rl/play.py" >/dev/null 2>&1
  grep -q Traceback "$log" && { bad "play raised"; sed -n '/Traceback/,$p' "$log" | tail -12; } || ok "play ran"
  inctr 'ls logs/rsl_rl/*/*/exported/policy.onnx' >/dev/null 2>&1 \
      && ok "policy.onnx exported" || bad "no exported policy.onnx"
  rm -f "$log"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" = 0 ]
