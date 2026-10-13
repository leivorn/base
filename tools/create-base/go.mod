// 独立 module：go run github.com/leivorn/base/tools/create-base@latest 需要一个
// 可下载的 module 路径，而 server/go.mod 的 module 名必须保持 base（基底硬性禁令）。
// 纯标准库实现，没有 go.sum，下载和构建都很快。
module github.com/leivorn/base/tools/create-base

go 1.24
