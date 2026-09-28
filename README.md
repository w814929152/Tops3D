# 陀螺对战 / Tops Arena 3D · 真 3D 独立项目

> 从《物候 / Seasons of Things》工程里的 `tops/` 子项目**拆分独立**，并把原来的
> 「2D 物理 + 手搓 2.5D 椭圆投影」改造成**真正的 3D**。
> 引擎 Godot **4.7.2** / GDScript / **真 3D 物理** / 全程序化绘制，零外部美术资源。

---

## 1. 怎么打开 / 怎么跑

```bash
# 编辑器（把下面两个占位换成你本机的实际路径）
set GODOT="C:/path/to/Godot_v4.7.2-stable_win64.exe"
set PROJECT="C:/path/to/Tops3D"

%GODOT% --editor --path %PROJECT%

# 直接跑（不打开编辑器）
%GODOT% --path %PROJECT%
```

主场景：`res://tops/tops_main.tscn`（已在 `project.godot` 里设为 `run/main_scene`）。

### 操作

| 键 | 作用 |
|---|---|
| 鼠标移动 | 发射阶段调方向（把屏幕点投射到水平面） |
| `←` / `→` | 发射阶段微调方向 |
| `空格` / `Shift` / 鼠标左键 | 蓄力（按住），松手即放陀螺进场 |
| `Enter` / `空格` | 开始界面：开始游戏；结算界面：再来一局 |
| `R` | 结算界面：重开一局 |

### 一局的三步骤（UI 显式呈现）

1. **① 开始游戏** —— 标题卡片上的主按钮（或 `Enter` / `空格`）。
2. **② 蓄力** —— 底部蓄力槽充能，来回摆动，松手时机就是玩法；踩中右侧金色
   「完美区间」（≥85%）松手 → 初速 +8%（`PERFECT_SPEED_BONUS`）。
3. **③ 放陀螺** —— 松手发射，屏幕弹「放陀螺！」横幅（完美发射是金色横幅），
   进入战斗：进场后无法操控，靠初速 + 进动漂移 + 碰撞运动，最后还在转的赢。

> **玩法核心**：发射进场后**完全无法操控**，陀螺只靠发射初速 + 自转进动漂移 +
> 物理碰撞运动。全部策略压缩进「发射」这一次决策（角度 × 力度）。5 人混战，
> 最后一个还在转的赢；60 s 起缩圈，单局目标 3–5 min。

---

## 2. UI 设计系统

| 文件 | 职责 |
|---|---|
| `src/ui_theme.gd`（`UiTheme`） | 设计令牌：色板 / 字号（12→40）/ 4px 间距系 / 圆角 / 阴影 / Theme 工厂 + 主按钮样式 |
| `src/ui_font.gd`（`UiFont`） | 系统字体渲染中文（零文件依赖） |
| `tops/tops_ui.gd`（`TopsUi`） | 界面层（CanvasLayer，全代码搭建）：三步流程条、蓄力槽（自绘 `Gauge`）、顶部状态芯片、转速条、Toast、标题/结算卡片 |

色板（深色主题，对比度达 WCAG AA，正文 ≥ 4.5:1）：底 `#0B0E14` / 面板 `#151A24` /
主色 `#5DCAA5`（= 玩家陀螺色）/ 强调 `#EFB54B` / 危险 `#E2564F`。
按钮最小热区 52px；键盘 focus 有 2px 描边；`TopsUi` 通过
`start_requested` / `restart_requested` 信号与 `TopsMain` 解耦。

实机截图：`docs/ui_01_title.png`（开始）· `ui_02_charge.png`（蓄力）·
`ui_03_battle.png`（战斗 HUD）· `ui_04_result.png`（结算），
由 `tests/tops_ui_shot.gd` 生成（需真窗口，勿加 `--headless`）。

---

## 2. 从 2D 版到 3D 版做了什么

原 `tops/` 是「纯 2D 物理 + 绘制时手搓椭圆压扁成伪 3D」。本项目改成真 3D：

| 层 | 2D 原版 | 3D 新版 |
|---|---|---|
| 场景根 | `TopsMain extends Node2D` | `TopsMain extends Node3D` |
| 陀螺刚体 | `RigidBody2D` + `CircleShape2D` | `RigidBody3D` + `SphereShape3D` |
| 边界墙 | 24 段 `StaticBody2D`（矩形） | 24 段 `StaticBody3D`（薄盒，沿切线旋转拼圆环） |
| 逻辑坐标 | `Vector2`（就是平面坐标） | 逻辑仍用 `Vector2(x, z)`，经 `plane_pos()/plane_vel()` 与 `RigidBody3D` 互转；高度 y 固定 `TOP_Y=0` |
| 渲染 | `TopsArt` 手搓椭圆投影 + y 排序 | 真 3D：`MeshInstance3D` 圆柱本体 + `Camera3D` 斜俯视跟随 + `DirectionalLight3D` + `WorldEnvironment` |
| HUD | 画在 `_draw()` 里 | `CanvasLayer` 上不需要——改用 `Control` 标签，保证中文可靠渲染 |
| CCD | `continuous_cd = CCD_MODE_CAST_RAY`（2D 枚举） | `continuous_cd = true`（Godot 4 布尔属性） |

**关键设计**：竞技场铺在 y=0 的水平面（XZ 平面）。所有规则判定（转速经济、碰撞
伤害、AI 追击）都在二维水平面上运算，与 2D 版数学**完全等价**——只是把原来的 y 轴
换成了世界 Z 轴。高度只用于相机与光照，不参与任何规则判定。

**保留不变**（因为本就是零渲染依赖的纯逻辑）：
- `TopsRules`（规则层）—— 伤害只随 Δspin、摩擦转速交换、撞墙损耗、衰减、AI 决策
- `TopBody`（数据层）—— 双轴模型（spin 血量轴 / velocity 动量轴）
- §4.2 铁律：**伤害 ≠ 击飞**，伤害只看转速差、与速度无关

---

## 3. 工程结构

```
Tops3D/
├─ project.godot              # 3D 项目配置、输入映射、gl_compatibility、默认重力 0
├─ tops/
│  ├─ tops_main.gd            # TopsMain extends Node3D —— 主场景（TITLE/LAUNCH/BATTLE/RESULT 状态机 + 3D 世界搭建 + 相机 + HUD 数据）
│  ├─ tops_main.tscn
│  ├─ tops_ui.gd              # TopsUi extends CanvasLayer —— 界面层（三步流程条 + 蓄力槽 + Toast + 标题/结算卡片）
│  ├─ tops_top.gd             # TopTop extends RigidBody3D —— 陀螺实体（plane_pos/vel 桥接 + CCD + 进动漂移）
│  ├─ tops_rules.gd           # TopsRules —— 零渲染依赖规则层（XZ 平面运算，可 headless 断言）
│  ├─ tops_art.gd             # TopsArt —— 精简为纯颜色工具（本体改由真 3D 网格渲染）
│  ├─ tops_boot.gd            # 独立启动入口
│  └─ sim/top_body.gd         # TopBody —— 纯数据双轴模型
├─ src/
│  ├─ ui_font.gd              # UiFont —— 系统字体渲染中文（从物候迁移）
│  └─ ui_theme.gd             # UiTheme —— UI 设计令牌 + Godot Theme 工厂
├─ tests/
│  ├─ harness.gd              # TestHarness —— headless 断言器（去掉物候专属方法）
│  ├─ tops_smoke_main.gd      # 3D 冒烟测试（UI 流程 / 规则层 / 物理接线 / 整局跑通）
│  └─ tops_ui_shot.gd         # UI 实机截图脚本（真窗口，产出 docs/ui_*.png）
└─ docs/
```

**硬约束（沿用物候工程）**：`TopsRules` 与 `TopBody` **不得**引用任何渲染类型
（`Node3D`/`MeshInstance3D` 等）——这是 headless 可断言的前提。

---

## 4. 怎么跑测试

```bash
GD="C:/path/to/Godot_v4.7.2-stable_win64_console.exe"
PROJ="C:/path/to/Tops3D"

# 1) 资源导入 + 全量脚本编译检查（无 ERROR 即通过）
"$GD" --headless --path "$PROJ" --import

# 2) headless 冒烟测试（退出码 0 = 全绿）
"$GD" --headless --path "$PROJ" --script res://tests/tops_smoke_main.gd
```

冒烟测试覆盖：
- 规则层纯函数（伤害只随 Δspin、摩擦交换方向）
- 3D 物理接线（RigidBody3D、CCD、24 段 StaticBody3D 墙、水平 XZ 平面、plane_pos/vel 桥接）
- 整局跑通（加速物理时间跑完，确认碰撞发生、有人出局、缩圈生效、单局时长落在 3–5 min）

---

## 5. 与原《物候》工程的关系

- 本项目是**独立副本**，不共用任何逻辑，也不影响原工程（原工程保持不动）。
- 陀螺机制的权威设计仍在原工程 `design/tops/core_mechanic_design.md`；数值定稿见
  `docs/tops/numeric_sim_report.md`（如需可一并复制过来）。
- 3D 化的数值参数（发射初速、缩圈节奏、转速经济）沿用 2D 物理版定稿值，未重新扫参——
  真 3D 物理与 2D 物理在水平面上的数学等价，预期手感一致，但建议后续在真 3D 上复扫一次。
