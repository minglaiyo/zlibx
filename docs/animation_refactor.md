# 动效系统 v2（整体重写）

> v1（2026-11-18）建了 token 文件和一批新组件，但组件零采用、与旧封装
> 双轨并存、shimmer 两套实现竞争。v2 推倒重来：**一套 token、三个组件、
> 全量迁移、旧代码删光**。本文取代 v1 文档。

## 文件地图

| 文件 | 内容 |
|------|------|
| `lib/theme/motion.dart` | `MotionCurves`（曲线 token）+ `MotionPress`（按压 token）+ `Motion.disabled/durationOf`（无障碍感知）+ `MotionContextX` / `MotionControllerX` 扩展 |
| `lib/widgets/motion/entrance.dart` | `MotionEntrance`——列表/网格条目错峰入场 |
| `lib/widgets/motion/switch.dart` | `MotionSwitch`——状态切换过渡（fade/scale/slide/size 四变体） |
| `lib/widgets/motion/skeleton.dart` | `MotionShimmer`（全 app 共享一个控制器的扫光）+ `SkeletonBox` / `SkeletonCircle` |
| `lib/widgets/motion/motion.dart` | barrel，UI 侧统一 import |
| `lib/theme/app_metrics.dart` | `AppMotion` 时长 token（150/180/200/250/300/400ms…），v1 已有，未动 |

**已删除**：`theme/app_animation.dart`（v1 token 文件）、`widgets/animated/`
整个目录（v1 组件，零调用点）、`widgets/entrance.dart`（EntranceSlideFade）、
`widgets/state_transition_switch.dart`。

## 规则

1. **时长**一律 `AppMotion.*`，**曲线**一律 `MotionCurves.*`（按用途命名：
   `enter`/`exit`/`emphasized`/`elastic`/`linear`/`loop`/`shimmer`），
   不写裸 `Curves.easeOutCubic` / `Duration(milliseconds: …)`。
2. **列表/网格条目入场**用 `MotionEntrance(index: i)`；网格按行错峰传
   `index ~/ columns`，不设专门的网格变体。
3. **状态切换**用 `MotionSwitch`（child 必须带稳定且互异的 Key）；
   `AnimatedSwitcher` + 手写 transitionBuilder 不再出现。
4. **骨架屏**用 `MotionShimmer`（共享控制器：同屏同相位、引用计数启停，
   系统动画关闭时自动静止）+ `SkeletonBox/Circle`。禁止再手写
   AnimationController shimmer。
5. **无障碍**：组件内部已自动尊重 `Motion.disabled`；自定义动画必须查
   `context.disableAnimations` 或用 `context.motionDuration(d)`。
   全库不允许裸 `MediaQuery…disableAnimations`。
6. **按压反馈**：自带手势的组件（书卡）用 `MotionPress.scale/duration/curve`
   配 `AnimatedScale`，不再有包装组件。

## 迁移落点（v2 全量）

- `MotionEntrance` 替换 `EntranceSlideFade`：11 文件 12 处（my_comments /
  view_history / user_profile / home_book_grid / popular / recent /
  search_results_view ×4 / local_downloads / trending_section）。
- `MotionSwitch` 替换 `StateTransitionSwitch`：6 处 + 收编 4 处手写
  AnimatedSwitcher（profile 计数徽标 slide、评论发送按钮 scale、
  书架选择徽章 scale、splash 状态行 slide）+ search_screen 的手搓
  Fade+SizeTransition（→ `MotionSwitchStyle.size`，top-anchored 的
  `axisAlignment` 兼容注释随组件入库）。
- 骨架屏收敛：cover_placeholder 的 `_SharedShimmer` 单例并入
  `MotionShimmer`；booklist_card 的呼吸骨架保留自有控制器（它是呼吸
  不是扫光）但 token 走新系统。
- 无障碍 bypass 收编：book_hero_section 的裸
  `MediaQuery.of(context).disableAnimations` → `context.disableAnimations`。
- 裸曲线清零：book_comments_screen 的 `Curves.easeOutCubic` →
  `MotionCurves.enter`。

## 测试契约

- `disableAnimations: true` 时三个组件全部退化为静态 child——既有测试
  （popular/recent/home_grid/app_layout/downloads 等）把它当通用前置，
  本契约是它们的地基。
- `SkeletonBox` 缺省色取 `colorScheme.surfaceContainerHighest`；
  search 骨架网格的列数契约不受影响。
- 回归：`test/widgets/motion_components_test.dart`（8 用例：入场自播/
  超档位直显/无障碍 bypass、fade 过渡中双 child/size 展开/零时长直切、
  骨架缺省色/shimmer builder 渲染）。
- 全量：`flutter analyze`（仅剩 download_path_section 的历史 deprecation）
  + `flutter test`（除基线既有的 5 个 rust_regex 用例外全绿）。

## splash / 3D 封面（未动结构，仅 token 换轨）

- `splash_screen.dart` 4 个控制器（logo elastic / content 三段 Interval /
  pulse 呼吸 / ring 旋转）结构保留，装配走 `withCurve`/`withInterval`。
- `book_3d_cover.dart` 的 idle sway + ValueNotifier 拖拽旋转是刻意的
  性能设计（指针事件只重建 AnimatedBuilder），保留。

---

**版本**: v2.0
**日期**: 2026-11-19
