# 对应源码说明（AGPL-3.0 §6 / §13）

## 一、结论

**本仓库就是对应源码（Corresponding Source）。**

AGPL-3.0 意义上的对应源码，指"生成、安装、（对可执行作品）运行目标代码，以及修改该作品所需的全部源码"。
本项目对 AGPL 部分的全部依赖是 Bambu Studio 的切片内核 `libslic3r`，它**完整地在仓库里**：

```
entry/src/main/cpp/libslic3r/          内核源码树（2420 个文件）
├─ libslic3r/                          libslic3r 本体（含我们新增的 ohos_slicer_api.*）
├─ boost/ eigen/ clipper/ clipper2/ libnest2d/ mcut/ qhull/ …
│                                      vendored 第三方头文件与源码
├─ cmake/                              补写的 PCH 模块
└─ CMakeLists.txt                      OpenHarmony arm64 交叉编译脚本
```

所以使用者拿到本仓库后，可以：修改内核 → 重新交叉编译出 `liblibslic3r.a` → 重新构建应用。
**不需要向我们索取任何额外的内核源码。**

## 二、构建可复现性的边界（据实说明）

以下内容**不随仓库分发**，需要使用者自行准备。它们不影响"对应源码已提供"这一结论：

| 缺失项 | 原因 | 如何获得 |
| --- | --- | --- |
| `liblibslic3r.a`（预编译静态库） | 二进制产物，可由仓库内源码重新生成 | 用 OpenHarmony NDK 交叉编译 `entry/src/main/cpp/libslic3r/` |
| FFmpeg 6.1.2（OHOS 静态库） | 体积大、含本地编译选项 | 自行交叉编译 FFmpeg |
| OpenCASCADE 7.6（OHOS 静态库） | 同上 | 自行交叉编译 OCCT |
| TBB / CGAL / GMP / MPFR / nlopt / expat / OpenSSL | 第三方预编译依赖 | 各自上游 |
| 签名材料（`.p12` / `.p7b` / `.cer`）与口令 | **含个人信息**，不得公开 | 用你自己的开发者证书 |

`entry/src/main/cpp/CMakeLists.txt` 里保留了原开发机的绝对路径（`C:/HMBambulabStudio/...`），
这是"我们怎么构建的"的如实记录；复现时请改成你自己的路径（见 `README.md` 第二节）。

## 三、网络交互（§13）

AGPL §13 要求：若修改版通过计算机网络向用户提供交互，须向这些用户提供获取对应源码的机会。

本应用是**本地客户端**，不运营任何对外网络服务，也不会让远程用户通过网络使用本程序的修改版功能
（它只作为客户端连接用户自己的打印机）。因此 §13 的"远程交互"义务在本项目中无触发场景。
若你把它改成服务端形态或托管给别人使用，请自行补上源码获取入口。

## 四、如何获取与再分发

1. 获取：本仓库（GitHub 公开地址由发布者填写）。
2. 再分发：你可以原样或修改后再分发，但必须
   - 附上 `LICENSE`（AGPL-3.0 全文）与本目录下的 `NOTICE.md`、`MODIFICATIONS.md`；
   - 继续以 AGPL-3.0 授权整个作品（§5(c)）；
   - 保留上游版权与许可声明（`entry/src/main/cpp/libslic3r/` 内各文件头部的版权行）；
   - 说明你对上游做过哪些修改（见 `MODIFICATIONS.md`，如有新增改动请追加）。
3. 分发**可安装包（.hap）**时：除内核源码外，还需一并满足 `NOTICE.md` 第二节列出的
   FFmpeg / OCCT / TBB / CGAL 等依赖的许可证（例如 FFmpeg 若以 GPL 选项构建，需提供其源码）。

## 五、联系

开源包由仓库维护者发布；如发现许可证或归属信息有误，请提 issue，我们会修正。
