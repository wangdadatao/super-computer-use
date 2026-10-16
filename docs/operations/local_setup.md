# 本地环境

开发环境依赖与首次运行步骤。当前仓库处于设计阶段，**尚无实现代码**，
本文描述的是计划中的开发环境。

## 阶段与形态

计划分两个阶段，使用不同技术栈：

| 阶段 | 目的 | 形态 | 语言 |
| --- | --- | --- | --- |
| 验证阶段 | 验证元素身份与快照语义的可行性 | 单进程脚本 | Python + pyobjc |
| 实现阶段 | 可发布的服务 | 服务进程 + sidecar | 待定（见下） |

**先用 Python 验证的理由**：核心风险在协议语义（元素身份是否稳定、
令牌失效能否正确检测），这些用 Python 调用同一套系统 API 就能验证。
在协议未定型前投入原生工程的成本不划算。

## 验证阶段环境

已验证可用的本机环境：

```
Python      3.14.3
Swift       6.4（Apple Swift 6.4）
Xcode       27.1
macOS       arm64, macOS 26.x
```

Python 侧需要 pyobjc 的应用服务与 Quartz 绑定（**尚未安装**）：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install pyobjc-framework-ApplicationServices pyobjc-framework-Quartz
```

验证可访问性：

```bash
python3 -c "import Quartz, ApplicationServices; print('ok')"
```

## 首次运行的顺序

1. **授予权限。** 按[macOS 权限](permissions.md)给宿主可执行文件授予
   辅助功能与屏幕录制权限。跳过这一步后面全部无法进行。
2. **建立虚拟环境**并安装 pyobjc 绑定。
3. **导出第一份无障碍树样本。** 选一个原生应用（建议系统自带的
   音乐或访达），导出完整树并人工确认结构合理。
4. **导出第二个应用**，优先选一个 Electron 应用，用于对比两种
   技术栈暴露的字段差异。
5. **在样本上验证指纹稳定性**，见[测试策略](testing.md)。

第 3、4 步的产出是所有后续设计的依据。在拿到真实样本前，
[元素身份](../architecture/element_identity.md) 的字段选择属于假设。

## 实现阶段待定

以下在验证阶段结束前不做决定：

- **原生层语言**：Swift 是自然选择（系统 API 原生、无绑定开销）。
  若验证阶段证明 Python 的性能足够，也可考虑保留 Python。
- **服务进程语言**：协议层与语言弱相关，取决于接入层选择。
- **分发方式**：签名与公证的要求取决于是否对外发布二进制。
