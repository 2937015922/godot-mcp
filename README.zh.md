# Godot MCP — 协作增强分支 0.2.0

**语言 / Language:** [English](README.md) | **简体中文**

开源 Godot MCP 服务，让 AI 助手（Claude Code、Cursor、Codex 等）通过 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) 直接操控 Godot 4 编辑器。

本 [fork](https://github.com/2937015922/godot-mcp) 基于 [mkdevkit/godot-mcp](https://github.com/mkdevkit/godot-mcp)，增加编辑活动记录、场景快照与差异、修改前检查以及 3D 空间查询。保留原有 173 个工具，新增 10 个，合计 **183 个**，方便人在 Godot 中调整场景后，由 AI 读取当前状态继续工作。

```
AI 客户端  ←—stdio/MCP—→  Node.js 服务  ←—WebSocket:6505—→  Godot 编辑器插件
```

## 实现概览

| 组件 | 职责 |
|------|------|
| **Godot 插件** | WebSocket 客户端，接收 JSON-RPC 请求，调用编辑器 API 执行命令 |
| **Node.js MCP 服务** | stdio 与 AI 客户端通信，WebSocket 服务端（默认端口 6505）转发工具调用 |
| **命令路由** | `command_router.gd` 聚合 26 个 command 模块，共 **182** 个 handler；服务端另提供 `get_bridge_status` |
| **编辑器协作** | 当前会话的活动记录、最多八份场景基线、选择节点、撤销/重做，以及可选的修改前快照检查 |
| **运行时服务** | 3 个 autoload（`MCPRuntimeBridge` / `MCPInputBridge` / `MCPScreenshotBridge`），通过 `user://` IPC 支持游戏内检视、输入模拟与截图 |

### 核心特性

- **编辑当前场景**：节点操作作用于编辑器中的场景树，包含尚未保存的修改；支持的节点及批量操作进入编辑器撤销栈
- **衔接人工修改**：读取选择和近期活动，对比场景基线；支持的修改操作可以在场景已变化时拒绝执行
- **3D 空间查询**：世界变换、几何包围盒及空间关系，明确返回遍历限制和无法取得的数据
- **原生截图结果**：编辑器及游戏截图通过 MCP 图片内容返回，尺寸与路径元数据单独提供
- **项目握手**：服务端检查插件所连接的项目，设置 `GODOT_MCP_PROJECT` 可限定目标项目
- **智能类型解析**：`Vector2(100, 200)`、`#ff0000`、`Color(1,0,0)` 等字符串自动转换
- **断线重连**：插件侧指数退避重连（1s → 60s）
- **心跳保活**：双向 ping/pong，保持 WebSocket 长连接
- **JSON-RPC 2.0**：Godot 插件与 Node.js 服务之间的标准协议

## 工具分类

**183 个 MCP 工具**，覆盖 **27 个类别**：

| 类别 | 工具数 | 代表能力 |
|------|--------|----------|
| Collaboration | 7 | 编辑活动与选择、场景快照/差异、撤销/重做 |
| Spatial inspection | 2 | 世界包围盒、变换、距离与 AABB 重叠 |
| Bridge | 1 | 连接状态及编辑器项目身份 |
| Project | 7 | 项目信息、文件搜索、UID 转换、项目设置读写 |
| Scene | 10 | 场景树、创建/删除/实例化场景、运行/停止、@export 变量 |
| Node | 14 | 增删改移、属性读写、信号连接、分组、资源挂载 |
| Script | 8 | 脚本 CRUD、挂载、语法校验、全文搜索 |
| Editor | 13 | 编辑器/游戏截图、相机控制、错误日志、截图对比、自动关闭弹窗 |
| Input | 7 | 键鼠/动作模拟、输入映射配置（含 deadzone） |
| Runtime | 19 | 游戏内场景树、属性读写、信号监听、录制回放、UI 点击、导航 |
| Animation | 6 | 动画轨道、关键帧、AnimationPlayer CRUD |
| TileMap | 6 | 单元格读写、区域填充、已用格子查询 |
| Theme/UI | 7 | 主题创建、Control 布局、颜色/字体/StyleBox 覆盖 |
| Profiling | 2 | FPS、内存、Draw Call、物理等性能监视器 |
| Batch/Refactor | 9 | 批量添加节点、按类型批量改属性、跨场景更新、依赖/循环检测 |
| Shader | 6 | 着色器 CRUD、材质分配、参数读写 |
| Export | 3 | 导出预设列表、导出命令生成 |
| Resource | 6 | `.tres` 读写、Autoload 注册/移除 |
| Physics | 6 | 碰撞体配置、物理层（含 layer 名称解析）、RayCast |
| 3D Scene | 6 | 网格实例、相机、灯光、环境、GridMap |
| Particle | 5 | GPU 粒子创建、材质、渐变、预设（火焰/烟雾/火花） |
| Navigation | 6 | 导航区域/代理、网格烘焙、路径计算 |
| Audio | 6 | 音频播放器、总线、效果器 |
| AnimationTree | 8 | 状态机、过渡、混合树、参数设置 |
| Analysis | 4 | 场景复杂度、信号流、未使用资源、项目统计 |
| Testing/QA | 5 | 测试场景、断言、压力测试 |
| Android | 4 | adb 设备列表、APK 导出部署、预设详情 |

<details>
<summary>展开查看全部 183 个工具名称</summary>

**Collaboration:** `get_editor_activity` · `get_editor_selection` · `set_editor_selection` · `scene_snapshot` · `scene_diff` · `undo_last` · `redo_last`

**Spatial inspection:** `get_scene_spatial_info` · `get_spatial_relationship`

**Bridge:** `get_bridge_status`

**Project:** `get_project_info` · `get_filesystem_tree` · `search_files` · `get_project_settings` · `set_project_setting` · `uid_to_project_path` · `project_path_to_uid`

**Scene:** `get_scene_tree` · `get_scene_file_content` · `create_scene` · `open_scene` · `delete_scene` · `add_scene_instance` · `play_scene` · `stop_scene` · `save_scene` · `get_scene_exports`

**Node:** `add_node` · `delete_node` · `duplicate_node` · `move_node` · `update_property` · `get_node_properties` · `add_resource` · `set_anchor_preset` · `rename_node` · `connect_signal` · `disconnect_signal` · `get_node_groups` · `set_node_groups` · `find_nodes_in_group`

**Script:** `list_scripts` · `read_script` · `create_script` · `edit_script` · `attach_script` · `get_open_scripts` · `validate_script` · `search_in_files`

**Editor:** `get_editor_errors` · `get_editor_screenshot` · `get_game_screenshot` · `execute_editor_script` · `clear_output` · `get_signals` · `reload_plugin` · `reload_project` · `get_output_log` · `get_editor_camera` · `set_editor_camera` · `set_auto_dismiss` · `compare_screenshots`

**Input:** `simulate_key` · `simulate_mouse_click` · `simulate_mouse_move` · `simulate_action` · `simulate_sequence` · `get_input_actions` · `set_input_action`

**Runtime:** `get_game_scene_tree` · `get_game_node_properties` · `set_game_node_property` · `execute_game_script` · `capture_frames` · `monitor_properties` · `start_recording` · `stop_recording` · `replay_recording` · `find_nodes_by_script` · `get_autoload` · `batch_get_properties` · `find_ui_elements` · `click_button_by_text` · `wait_for_node` · `find_nearby_nodes` · `navigate_to` · `move_to` · `watch_signals`

**Animation:** `list_animations` · `create_animation` · `add_animation_track` · `set_animation_keyframe` · `get_animation_info` · `remove_animation`

**TileMap:** `tilemap_set_cell` · `tilemap_fill_rect` · `tilemap_get_cell` · `tilemap_clear` · `tilemap_get_info` · `tilemap_get_used_cells`

**Theme/UI:** `create_theme` · `set_theme_color` · `set_theme_constant` · `set_theme_font_size` · `set_theme_stylebox` · `get_theme_info` · `setup_control`

**Profiling:** `get_performance_monitors` · `get_editor_performance`

**Batch/Refactor:** `find_nodes_by_type` · `find_signal_connections` · `batch_set_property` · `find_node_references` · `get_scene_dependencies` · `cross_scene_set_property` · `find_script_references` · `detect_circular_dependencies` · `batch_add_nodes`

**Shader:** `create_shader` · `read_shader` · `edit_shader` · `assign_shader_material` · `set_shader_param` · `get_shader_params`

**Export:** `list_export_presets` · `export_project` · `get_export_info`

**Resource:** `read_resource` · `edit_resource` · `create_resource` · `get_resource_preview` · `add_autoload` · `remove_autoload`

**Physics:** `setup_physics_body` · `setup_collision` · `set_physics_layers` · `get_physics_layers` · `get_collision_info` · `add_raycast`

**3D Scene:** `add_mesh_instance` · `setup_camera_3d` · `setup_lighting` · `setup_environment` · `add_gridmap` · `set_material_3d`

**Particle:** `create_particles` · `set_particle_material` · `set_particle_color_gradient` · `apply_particle_preset` · `get_particle_info`

**Navigation:** `setup_navigation_region` · `setup_navigation_agent` · `bake_navigation_mesh` · `set_navigation_layers` · `get_navigation_info` · `get_navigation_path`

**Audio:** `add_audio_player` · `add_audio_bus` · `add_audio_bus_effect` · `set_audio_bus` · `get_audio_bus_layout` · `get_audio_info`

**AnimationTree:** `create_animation_tree` · `get_animation_tree_structure` · `set_tree_parameter` · `add_state_machine_state` · `remove_state_machine_state` · `add_state_machine_transition` · `remove_state_machine_transition` · `set_blend_tree_node`

**Analysis:** `analyze_scene_complexity` · `analyze_signal_flow` · `find_unused_resources` · `get_project_statistics`

**Testing/QA:** `run_test_scenario` · `assert_node_state` · `assert_screen_text` · `run_stress_test` · `get_test_report`

**Android:** `list_android_devices` · `deploy_to_android` · `get_android_build_info` · `get_android_preset_info`

</details>

## 人与 AI 如何接续编辑

1. 调用 `get_bridge_status` 确认项目，再用 `get_editor_selection` 和 `get_editor_activity` 了解编辑上下文。
2. 用 `scene_snapshot` 为整个场景或指定子树建立基线，保留返回的 `snapshot_id`，然后在 Godot 中人工调整。
3. 用 `scene_diff` 对比该基线。读取差异不会推进基线；节点路径用于识别条目，因此改名和移动会显示为删除与新增。
4. 在 AI 修改前取得新的整场景快照（`root_path: "."`），将 ID 作为 `expected_scene_snapshot` 传给支持该参数的操作。需要保存时调用 `save_scene`；普通节点工具修改当前场景树，不自动保存。

可选快照检查支持：`add_node`、`delete_node`、`duplicate_node`、`move_node`、`rename_node`、`update_property`、`add_resource`、`connect_signal`、`disconnect_signal`、`set_node_groups`、`batch_add_nodes`、`batch_set_property`、`add_scene_instance` 和 `save_scene`，且必须使用完整的**整场景快照**。捕获内容或编辑器历史版本已变化、基线已过期、场景已重新加载、快照不完整，或传入的是子树基线时，操作会被拒绝。子树快照仅用于通过 `scene_diff` 比较指定范围。这项检查在操作前执行，不会锁住编辑器，也不覆盖所有工具。每次修改后应重新取得基线。

活动记录最多保留 **512 条事件**，读取时会报告游标缺口。`source: editor` 表示 MCP 命令窗口以外观察到的事件；`mcp_window` 表示命令执行期间观察到的事件，其中可能混有同时发生的人工操作；只有明确的命令事件标为 `mcp`。这些标签不能证明某项修改一定由谁完成。活动记录及最多 **八份快照**属于当前编辑器会话，关闭插件后不保留。

快照受节点数、深度、属性、集合大小和总字节数限制，捕获节点存储属性、资源摘要、分组名称及持久化信号连接，包括目标、方法、标志和绑定参数。脚本源码、外部文件字节、临时信号连接及分组的持久化标志不在比较范围内，快照也不是完整场景备份。应检查 `truncated`、`property_capture_complete`，以及差异中的 `complete`、`uncompared_paths`；完整性仅针对上述捕获范围。不完整的快照不能用于允许修改。

`undo_last`、`redo_last` 操作当前场景最近的一步历史，其中可能是人工修改；传入已观察到的 `expected_version`，可在历史变化后拒绝执行。操作保留 Godot 历史管理器的记录机制。Godot 4.7.2 未向 GDScript 开放指定场景的管理器撤销接口，因此本版本通过经过结构检查的原生 History 面板适配执行；所需面板结构或回调不存在时会返回错误，不直接操作底层 UndoRedo。其他 Godot 版本需要验证兼容性，返回结果中的 `backend` 会说明实际使用的方式。

## 3D 空间查询

`get_scene_spatial_info` 返回编辑器场景的变换、可见性标志、几何与碰撞形状包围盒，并可按限制展开 MultiMesh 实例。`get_spatial_relationship` 对比两棵子树的包围盒。使用结果前应检查 `bounds_complete` 及无法读取、遍历被截断等字段。

包围盒包含隐藏几何与禁用的碰撞形状；AABB 重叠不代表实际物理碰撞、相机可见或路线可通行。原生图形界面的 Godot 可以提供 MultiMesh 实例变换；无头渲染器返回的是占位变换，因此该模式会明确报告无法查询逐实例数据。这些新工具检查编辑器中编排好的场景，运行中的游戏仍使用原有 Runtime 工具。

`get_editor_screenshot`、`get_game_screenshot` 返回原生 MCP `image/png` 图片块和单独的文本元数据，不再把图片字节塞进 JSON 文本。截图需要图形界面的编辑器或游戏进程，游戏截图还要求游戏正在运行；空图片会返回错误。原生图形模式的集成测试会取得两种截图，保存到 `tests/results/` 并验证 PNG 文件头。

## 项目结构

```
godot-mcp/
├── addons/godot_mcp/              # Godot 编辑器插件（复制到你的项目）
│   ├── plugin.gd                  # 插件入口，注入 autoload
│   ├── plugin.cfg
│   ├── websocket_client.gd        # WebSocket 客户端 + JSON-RPC 分发
│   ├── command_router.gd          # 命令路由，注册全部 handler
│   ├── commands/                  # 26 个命令模块（182 个工具实现）
│   │   ├── base_commands.gd       # 基类：Undo、运行时 IPC、截图等
│   │   ├── collaboration_commands.gd
│   │   ├── spatial_commands.gd
│   │   ├── project_commands.gd
│   │   ├── scene_commands.gd
│   │   ├── node_commands.gd
│   │   ├── script_commands.gd
│   │   ├── editor_commands.gd
│   │   ├── input_commands.gd
│   │   ├── runtime_commands.gd
│   │   ├── animation_commands.gd
│   │   ├── tilemap_commands.gd
│   │   ├── theme_commands.gd
│   │   ├── profiling_commands.gd
│   │   ├── batch_commands.gd
│   │   ├── shader_commands.gd
│   │   ├── export_commands.gd
│   │   ├── resource_commands.gd
│   │   ├── physics_commands.gd
│   │   ├── scene_3d_commands.gd
│   │   ├── particle_commands.gd
│   │   ├── navigation_commands.gd
│   │   ├── audio_commands.gd
│   │   ├── animation_tree_commands.gd
│   │   ├── analysis_commands.gd
│   │   ├── test_commands.gd
│   │   └── android_commands.gd
│   ├── services/                  # 编辑器观察及运行时 autoload 服务
│   │   ├── editor_activity.gd     # 活动记录、快照/差异及历史检查
│   │   ├── mcp_runtime_bridge.gd  # 游戏内场景树 / 属性 / 脚本执行
│   │   ├── mcp_input_bridge.gd    # 输入事件队列
│   │   └── mcp_screenshot_bridge.gd
│   └── utils/
│       ├── type_parser.gd         # Vector2 / Color 等类型解析
│       ├── node_utils.gd
│       ├── scene_safety.gd        # 属性验证及子树 owner 恢复
│       └── resource_utils.gd
├── server/                        # Node.js MCP 服务
│   ├── src/
│   │   ├── index.ts               # MCP stdio 入口
│   │   ├── godot-bridge.ts        # WebSocket 服务端 + JSON-RPC
│   │   ├── tools.ts               # 工具注册逻辑
│   │   └── tool-manifest.ts       # 182 个定义；tools.ts 另注册连接状态工具
│   └── build/index.js             # 构建产物（MCP 启动入口）
├── scripts/install-local.ps1      # Windows 本地安装助手
├── tests/                         # 原生 Godot 检查及编辑器测试项目
├── .mcp.json.example              # MCP 客户端配置示例
├── README.md                      # 英文文档（默认）
└── README.zh.md                   # 中文文档
```

## 环境要求

- 当前开发目标为 **Godot 4.7.2**；更早的 Godot 4 版本需要另行验证兼容性
- **Node.js** 18+
- 任意支持 MCP 的客户端：Claude Code、Cursor、Codex CLI、Cline、Windsurf 等

## 使用方式

### Windows 本地安装

在本仓库目录中通过 PowerShell 指定项目目录与端口：

```powershell
.\scripts\install-local.ps1 -ProjectPath "D:\Games\MyGame" -Port 6505
```

需要指定本地引擎时增加 `-GodotPath "C:\Tools\Godot\Godot.exe"`；增加 `-ConfigureCodex` 可选择配置本地 Codex MCP 条目。下面的手动步骤解释相同的插件与服务端组件，也适用于其他客户端。

### 1. 安装 Godot 插件

将 `addons/godot_mcp/` 复制到你的 Godot 项目的 `addons/` 目录：

```bash
cp -r addons/godot_mcp /path/to/your-game/addons/
```

在 Godot 中启用：**项目 → 项目设置 → 插件 → Godot MCP → 启用**

> 插件启用时会自动注入 3 个 autoload（`MCPRuntimeBridge` 等），停用插件后会自动移除。

### 2. 构建 MCP 服务

```bash
cd server
npm install
npm run build
```

构建完成后入口为 `server/build/index.js`。

### 3. 配置 AI 客户端

将以下配置加入 MCP 配置文件（**请把路径改成你的实际路径**）：

| 客户端 | 配置文件位置 |
|--------|-------------|
| Claude Code | 项目根目录 `.mcp.json` |
| Cursor | Settings → MCP，或 `~/.cursor/mcp.json` |
| Codex CLI | `~/.codex/config.toml` 中的 MCP 段 |
| Cline / Roo Code | 对应扩展的 MCP 设置 |

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "node",
      "args": ["D:/godot-mcp/server/build/index.js"],
      "env": {
        "GODOT_MCP_PORT": "6505",
        "GODOT_MCP_PROJECT": "D:/Games/MyGame"
      }
    }
  }
}
```

也可直接参考仓库内的 [`.mcp.json.example`](.mcp.json.example)。

`GODOT_MCP_PROJECT` 应为绝对**项目目录**，不是 `project.godot` 文件。请搭配使用 0.2.0 插件和服务端：服务端在握手完成后才转发命令，拒绝连接到不同的指定项目，也不允许第二个编辑器接管已有连接。不设置项目目录时，状态查询仍会显示连接项目，但不会限定它。

插件与服务端必须使用相同端口。插件优先读取启动环境中的 `GODOT_MCP_PORT`，其次读取项目设置 `godot_mcp/network/port`，默认使用 6505。安装脚本会设置项目端口；手动安装时可在 Project Settings 中设置，或通过带环境变量的命令启动 Godot。只在 MCP 客户端中设置环境变量，不会改变已运行编辑器的环境。不同项目应使用不同端口。

### 4. 开始使用

1. **先**用 Godot 打开你的项目（确保插件已启用）
2. 启动 AI 客户端，确认 MCP 服务 `godot-mcp` 已连接
3. 在对话中让 AI 操作编辑器，例如：
   - 「获取当前场景树」
   - 「在根节点下添加 CharacterBody2D，命名为 Player」
   - 「创建 GDScript 并挂载到 Player」
   - 「运行当前场景，然后截取游戏画面」
   - 「给 TileMap 填充一片草地」

### 5. 测试

在仓库根目录通过 PowerShell 执行：

```powershell
npm --prefix server test
$env:GODOT_BIN = "C:\Tools\Godot\Godot.exe"
node server/tests/editor-integration.mjs
```

集成测试在 `.local/editor-fixture` 创建独立测试项目，默认使用端口 6517，可通过 `GODOT_TEST_PORT` 修改。21 项检查覆盖实际 MCP/服务端/编辑器调用链、场景差异及修改前检查、owner、撤销/重做、持久化、打开场景保护，以及游戏启动与停止。使用图形模式还会取得编辑器和游戏截图：

```powershell
$env:GODOT_TEST_NATIVE = "1"
node server/tests/editor-integration.mjs
Remove-Item Env:GODOT_TEST_NATIVE
```

集成测试准备好项目后，独立 Godot 检查可以复用其中的插件：

```powershell
$repoPath = (Get-Location).Path
foreach ($testName in @("test_collaboration", "test_scene_safety", "test_spatial")) {
    & $env:GODOT_BIN --headless --path "$repoPath/.local/editor-fixture" --script "$repoPath/tests/$testName.gd"
}
```

当前原生开发目标为 Godot 4.7.2。无头和图形模式覆盖的渲染行为有所不同，尤其是 MultiMesh 实例。上述检查覆盖列出的流程，不代表全部 183 个工具均已穷尽验证，也不等同于游戏的人工试玩。集成测试结果与本地日志写入 `tests/results/editor-integration.json`。

## 工作原理

1. AI 客户端通过 **stdio** 调用 MCP 工具（如 `add_node`）
2. Node.js 服务将请求转为 **JSON-RPC**，经 **WebSocket** 发往 Godot 插件
3. Godot 插件的 `command_router` 分发到对应 handler，调用 **EditorInterface** 等 API 执行
4. 结果沿原路返回给 AI 客户端

**运行时工具**（如 `get_game_scene_tree`）额外依赖：

- 编辑器处于 **播放** 状态
- `MCPRuntimeBridge` autoload 在游戏进程中轮询 `user://mcp_runtime_req.json` 并写回响应

## 扩展工具

新增一个 MCP 工具需要三步：

1. 在 `addons/godot_mcp/commands/` 新建或修改命令类，在 `get_commands()` 中注册 handler
2. 在 `command_router.gd` 的 `COMMAND_MODULES` 数组中添加该脚本路径
3. 在 `server/src/tool-manifest.ts` 的 `TOOL_DEFINITIONS` 中添加工具名称、描述和参数 schema

然后重新构建服务：

```bash
cd server && npm run build
```

## 已知限制

- **Android 工具**：`list_android_devices` 通过 `adb devices` 列出设备；`deploy_to_android` 调用 Godot 无头导出并通过 adb 安装（需配置 Android 导出预设且 adb 在 PATH 中）
- **运行时工具**：需先 `play_scene`，且游戏进程需加载 `MCPRuntimeBridge` autoload；`watch_signals` 在游戏运行期间监听指定节点的信号发射
- **跨场景批量修改**（`cross_scene_set_property`）：预先验证请求目录内的 `.tscn` 文件，然后直接保存关闭的场景。任何目标场景已打开时，整次请求都会在写入前被拒绝；可以改用当前场景编辑，或先关闭场景。这些磁盘写入没有编辑器撤销。如果后续文件保存失败，先前已成功保存的文件仍然保留，错误结果会通过 `updated_scenes` 列出它们。
- **功能范围**：新增协作工具不会自动把运行时生成的关卡转换为可编辑的 `.tscn`，不会自动合并冲突，也不保证所有原有工具都支持撤销及快照检查。场景转换和重新生成时如何保留人工修改，仍需在项目中实现。
- **兼容性**：编辑器 API 可能随 Godot 小版本变化。本 fork 未从其他 bridge 引入 DAP 调试器、GDScript LSP 或通用的游戏暂停/单步运行功能。

## 来源与致谢

基础代码及原有工具来自 MIT 授权的 [mkdevkit/godot-mcp](https://github.com/mkdevkit/godot-mcp)。协作与空间查询功能在设计上参考了 [TomasLucasUTN/godot-mcp-bridge](https://github.com/TomasLucasUTN/godot-mcp-bridge)、[satelliteoflove/godot-mcp](https://github.com/satelliteoflove/godot-mcp) 和 [NPGameDev/godot-mcp-toolkit](https://github.com/NPGameDev/godot-mcp-toolkit)。本版本未复制后三个项目的源码，也未包含它们的全部功能。本分支的具体改动见 [CHANGELOG.md](CHANGELOG.md)。

## License

MIT
