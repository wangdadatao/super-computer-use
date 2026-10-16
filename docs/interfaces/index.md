# 接口 文档目录

> 上级目录：[工程文档](../index.md)

## 范围

本分类拥有 **对外契约**：agent 侧的工具面、元素寻址的字符串格式、动作效果回报的结构。

不在此分类：内部模块间的调用关系（属于[架构](../architecture/index.md)）、设计理由（属于[决策](../decisions/index.md)）。

## 文档

- [协议总览](protocol_overview.md)：agent 与 SCU 之间的完整交互面与调用约定。读取时机：写 agent 集成、MCP 客户端或测试夹具时。
- [元素寻址](element_addressing.md)：元素 ID 的字符串格式与解析规则。读取时机：实现或消费元素引用时。
