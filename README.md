# dsh-thinking-guard

纯思考空转熔断器。挂在 `agent/assistant-stream` 事件上，对「只思考、零产出」的退化回合实施三重熔断。

## 安装

**方式一：从 npm 安装（推荐）**

```sh
dsh plugin add @ethanwong-hk/dsh-thinking-guard
```

**方式二：从 GitHub 安装**

```sh
dsh plugin add github:ethanwong-hk/dsh-thinking-guard
```

**方式三：手工挂载**

把本仓库放到 `~/.dsh/plugins/dsh-thinking-guard/`，然后在 `~/.dsh/cordis.patch.yml` 中加入 `cordis.patch.yml` 里的 `insert` 片段（见下方「配置」）。

安装后**重启 DSH** 生效。验证是否加载：

```sh
grep -n "thinking-guard" ~/.dsh/cordis.patch.yml
```

## 为什么需要它

`dsh-agent-loop` 的 `step()` 只在**流结束后**才做终止判定（`lib/index.js:1115-1119`）。流不结束，`turn/end` 就永不写入。

`dsh-llm-deepseek` 的 `idleWatchdog`（`lib/index.js:1627`）测的是**连接活性**而非任务进展 —— 它在每个 SSE 事件上 `pulse()` 重置 5 分钟计时器（`:1816` 经 `parseSse` 喂食）。模型持续吐 `reasoning-delta` 时，看门狗每 chunk 重置，**永不触发**。

结果是：模型以比 5 分钟更密的节奏输出 thinking token 时，回合可以无限持续，只能由用户手动中止。默认 `max_tokens = 256000`（`DEFAULT_MAX_TOKENS`）量级过大，不构成实际兜底。

## 三重熔断

| 熔断 | 默认值 | 触发条件 |
|---|---|---|
| `thinking-only-timeout` | 45000 ms | 零 text、零 tool-call，且距**最后一次进展**已超时 |
| `thinking-volume` | 80000 字符 | 单次尝试 reasoning 总量超限，**不依赖**是否有 text 产出 |
| `degenerate-loop` | 3 次重复 | 尾部窗口命中：精确重复单元 / 句子级模板重复 / 稀疏复读 / N-gram 高密度 |

命中即 `agent.cancel({ kind:'thinking-guard', reason, detail })`，并尽力用 `agent.followup()` 注入一条可见说明。

「停滞时长」锚定**最后一次进展**（text 或 tool-call 到达的时刻），而非 attempt 起点 —— 避免慢启动的正常回合被误判。

## 配置

在 `~/.dsh/cordis.patch.yml` 的 `thinking-guard` 条目 `config` 下调整，重启 DSH 生效：

```yaml
- insert:
    - id: thinking-guard
      name: "dsh-thinking-guard"
      config:
        enabled: true
        # 只思考、零 text/tool-call 的持续时长上限（毫秒）
        thinkingOnlyMs: 45000
        # 单次尝试 reasoning 字符总量上限
        maxThinkingChars: 80000
        # 退化循环：重复次数阈值
        repeatThreshold: 3
        # 熔断后自动注入「继续当前任务」指令
        autoContinue: true
        notify: true
        verbose: false
```

环境变量可临时覆盖（无需改配置）：

| 变量 | 作用 |
|---|---|
| `DSH_THINKING_GUARD_DISABLED=1` | 停用 |
| `DSH_THINKING_ONLY_MS` | 纯思考停滞阈值 |
| `DSH_MAX_THINKING_CHARS` | 思考容量阈值 |
| `DSH_THINKING_REPEAT_THRESHOLD` | 重复次数阈值 |
| `DSH_THINKING_GUARD_VERBOSE=1` | 打日志 |

## 误报调优

| 现象 | 调整 |
|---|---|
| 正常长文本被误熔断 | 调高 `sentenceRepeatRatio`（默认 0.6）、`gramDensity`（默认 0.22） |
| 退化循环漏检 | 调低 `repeatThreshold`（默认 8） |
| 慢模型被误判停滞 | 调高 `thinkingOnlyMs` |

## 验证

```bash
node ~/.dsh/plugins/dsh-thinking-guard/test/guard.test.mjs
```

11 个场景覆盖：纯思考超时、退化复读、容量上限、有产出仍限容量、文本复读、稀疏复读（回归用例）、正常回合放行、工具调用放行、正常结束放行、长正常文本放行。

## 已修缺陷：熔断器自身的静默失效

`formatNotice` 是**模块级函数**，却在 `sparse-repeat` 分支引用了 `apply()` 内的局部 `cfg`（`cfg.sparseWindow`）。该分支一旦命中即抛 `ReferenceError: cfg is not defined`。

危害不是「少一条提示」，而是**熔断完全失效**：

1. `trip()` 中 `formatNotice(...)` 位于 `agent.cancel(...)` **之前**，异常直接中断 `trip()`，`cancel` 永不执行；
2. `st.fired = true` 已在异常前置位，本 attempt 的后续检测被 `if (st.fired) return` 全部跳过。

线上日志实证：`dsh-2026-09-26.log` 记录 472 次、`dsh-2026-09-27.log` 记录 39 次 `agent/assistant-stream listener threw: ReferenceError: cfg is not defined` —— 全部来自本插件唯一的事件监听器。修复前，该档熔断在所有命中回合上都是空转的。

修复两处：

```js
// 1) 根因：显式传参，消除模块级作用域泄漏
function formatNotice(reason, detail, st, cfg) { ... }

// 2) 防御：cancel 前置，且通知文本生成失败时降级而非中断
console.warn(...);
try { agent.cancel({ ... }); } catch (error) { ... }
let text;
try { text = formatNotice(reason, detail, st, cfg); }
catch (error) { text = `...（说明文本生成失败：${error?.message}）`; }
```

原则：**熔断这一关键动作不得依赖通知环节的成功**。回归用例见 `test/guard.test.mjs` 场景 11。

## 语义边界

`thinkingOnlyMs` **只在零 text、零 tool-call 时生效**。已产出文本的回合不会被它熔断 —— 那类回合至少有可见产出，不属于「纯思考空转」。`maxThinkingChars` 与退化检测对已产出文本的回合同样生效，用以兜住「先吐一小段文本再无限思考」。

## 依赖

无。仅用 harness 的 `agent/assistant-stream` / `agent/disposed` 事件与 `agent.cancel` / `agent.followup` 接口。消息工厂按候选路径显式解析 `@deepseek-ai/dsh-llm`，解析失败时降级为仅日志，不影响熔断本身。
