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

## 结论文件格式

见 [docs/operations/testing.md](../docs/operations/testing.md) 的
「验证产物与标记约定」一节。

## 当前状态

**空。** 尚无任何假设验证被执行，全部处于未验证状态。
验证内嵌在 P0 中，门槛见
[ADR-0013](../docs/decisions/adr_0013_p0_vertical_slice.md)。
元素身份与令牌尚未实现，相关验证还不能开始；权限状态见
[docs/operations/permissions.md](../docs/operations/permissions.md)。
