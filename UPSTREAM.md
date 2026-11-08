# 来源

本仓库给 singbox-zig 用，提交历史保留上游。

- 上游：<https://git.jcollie.dev/jeff/zig-yaml>
- 上游作者：Jeffrey C. Ollie（jeff@ocjtech.us）
- 许可证：MIT（各文件 SPDX）
- 迁入时上游 `main`：`7f1bf68f3f396a2d5030c8e038c85b71c3c5f029`（Give every public function a doctest and an accurate doc comment）
- 迁入日期：2026-11-09
- 本仓库在上游之上的改动：父工程构建时不自动拉取 yaml-test-suite。Windows 解不开套件里的符号链接。加上 `-Dyaml-suite` 才会拉取。分支是 `zig-0.17-singbox`。
