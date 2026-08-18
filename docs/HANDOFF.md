# 项目交接

## 当前项目状态

寻简 0.1.4（build 5）已正式发布。源码提交 `b349479`、annotated tag `v0.1.4` 与 GitHub Release“寻简 0.1.4”均已上线；Sparkle 使用 Universal DMG，旧版本更新项保留。

## 已完成内容

- 将过期索引 ID 写入临时主键表，再一次性清理 FTS 与文件记录，消除逐条全表扫描。
- 5 万条真实规模副本批量清理约 0.26 秒；数据库测试 24 项执行、2 项跳过、0 失败。
- 三架构均通过公证、staple、Gatekeeper、DMG、版本、架构及深层签名验收；Sparkle 为 Team `76V7CQ4T45` 且带时间戳，OpenAI/xAI Runtime 保持官方签名。

## 发布文件

- Universal：`67334ce62c79df004364d793ff305e8e3bb5756fa88f46e7ac79425cc7d4415d`
- Apple Silicon：`3dfcbf02dd9a9ff130f61e8c4420ad710bdfdc9dbbbf619274701e502fba1467`
- Intel：`d824a381901ddd1a3408f8263582eb1811643baaa18bdb9ec93851f10a01aa65`

## 边界与下一步

- 公证任务分别为 `6d87ec2f-d3e4-4364-bd3b-8bebddd44c4b`、`205d96af-6783-4048-88ed-06e0c68d5695`、`4bd7f121-065e-4085-b5fc-75aa024c690d`。
- 未运行真实 OAuth、AI 或付费模型请求。
