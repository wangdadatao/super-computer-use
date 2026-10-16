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

## 结论文件格式

见 [docs/operations/testing.md](../docs/operations/testing.md) 的
「验证产物与标记约定」一节。

## 当前状态

**空。** 尚无任何验证执行——全部假设处于未验证状态，
阻塞原因是辅助功能权限未授予，见
[docs/operations/permissions.md](../docs/operations/permissions.md)。
