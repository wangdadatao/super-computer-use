# 验证产物

本目录存放**证据**，不属于 Project Doc 文档库（`docs/`）。
文档库描述当前结论，本目录存放得出结论所依据的样本与记录。

## 目录结构

```
verification/
  samples/                    原始样本（无障碍树导出、截图元数据等）
  YYYY-MM-DD-<假设编号>.md    单次验证的结论
```

## 为什么与文档库分开

样本是数据，工程知识是结论。两者的更新周期和读者都不同：

- 样本体积大、随采集时间累积、多数时候只被引用不被阅读
- 结论应当被阅读、被引用、随代码演进维护

混在一起会让文档库充满无法维护的二进制与数据集。

## 内容

| 文件 | 内容 |
| --- | --- |
| `external-sources.md` | 外部实现观察的来源清单：工件标识、采集方法、结论到证据的映射、复核步骤 |
| `samples/` | 采集到的原始样本 |
| `YYYY-MM-DD-<假设编号>.md` | 单次验证的结论 |
| `2026-10-16-baseline-identity.md` | 元素身份各档位分布的**基线记录**（不是验证结论） |
| `2026-10-17-read-latency.md` | 读树耗时：逐属性读取与批量读取的对比（性能测量，不是验证结论） |
| `2026-10-18-identity-k4.md` | 元素身份 K4 比例的正式验证（3 个判定样本，结论不成立，限定见文内） |
| `2026-10-18-fixture-validation.md` | 夹具应用上的令牌、动作效果、收敛、策略验证：哪些成立、哪些是缺口 |

## 结论文件格式

见 [docs/operations/testing.md](../docs/operations/testing.md) 的
「验证产物与标记约定」一节。

## 当前状态

**尚无任何假设被整体验证通过。** 有一份元素身份的基线记录
（[2026-10-16-baseline-identity.md](2026-10-16-baseline-identity.md)，不是验证结论），
和一份夹具上的验证记录（[2026-10-18-fixture-validation.md](2026-10-18-fixture-validation.md)，
令牌语义成立、收敛有缺口）。元素身份的 K4 正式验证已执行（[2026-10-18-identity-k4.md](2026-10-18-identity-k4.md)），冻结规则下不成立。
门槛见 [ADR-0013](../docs/decisions/adr_0013_p0_vertical_slice.md)；
权限状态见 [docs/operations/permissions.md](../docs/operations/permissions.md)。
