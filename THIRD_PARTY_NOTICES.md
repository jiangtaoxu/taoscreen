# 第三方声明

- macOS 客户端使用 [WebRTC XCFramework](https://github.com/stasel/WebRTC) 154.0.0。许可证随应用打包，也收录在 [WebRTC-LICENSE.txt](macos/WebRTC-LICENSE.txt)。
- macOS 客户端使用 [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0。构建应用时从固定版本的依赖复制许可证到应用资源中。
- Go 服务端的标准库和已编译依赖许可见 [服务端许可清单](server/licenses/README.md)。容器镜像将这些文件放在 `/licenses`。
- Compose 独立启动 [PostgreSQL](https://www.postgresql.org/about/licence/) 和 [Redis](https://redis.io/legal/licenses/) 官方镜像，各组件适用各自的许可条款。
