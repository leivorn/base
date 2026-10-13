// create-base 从 base 基底创建一个新项目。
//
//	go run github.com/leivorn/base/tools/create-base@latest myproject
//
// 它做的就是 CLAUDE.md 里那套手工步骤：保留共同 git 历史地 clone（之后才能
// make sync-base）、按项目名填好本地配置、生成随机密钥、装依赖、提交首个 commit。
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const defaultBaseURL = "https://github.com/leivorn/base.git"

type options struct {
	Name        string // 项目名，同时用作 PROJECT_NAME / 前端 namespace / 目录名
	Dir         string // 目标目录，默认 ./<name>
	Title       string // 前端显示标题，默认与 Name 相同
	BaseURL     string // 基底仓库地址，测试和本地开发时指向本地路径
	Origin      string // 新项目自己的远端地址，留空则不添加
	Version     string // vX.Y.Z 或 main，留空表示取基底最新标签
	Chuanyun    bool   // 是否生成 chuanyun.toml
	SkipInstall bool   // 跳过 go mod download / pnpm install
	KeepOnError bool   // 失败时保留目录，便于排查
	Verbose     bool   // 打印执行的每条命令
}

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n\n", err)
		usage(os.Stderr)
		os.Exit(2)
	}
	if err := run(opts, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "\n失败: %v\n", err)
		os.Exit(1)
	}
}

func parseArgs(args []string) (options, error) {
	var opts options
	fs := flag.NewFlagSet("create-base", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { usage(os.Stderr) }

	fs.StringVar(&opts.Dir, "dir", "", "目标目录（默认 ./<项目名>）")
	fs.StringVar(&opts.Title, "title", "", "前端显示标题（默认与项目名相同）")
	fs.StringVar(&opts.BaseURL, "base", defaultBaseURL, "基底仓库地址")
	fs.StringVar(&opts.Origin, "origin", "", "新项目自己的仓库地址（会添加为 origin，但不会 push）")
	fs.StringVar(&opts.Version, "version", "", "基底版本 vX.Y.Z 或 main（默认最新标签）")
	fs.BoolVar(&opts.Chuanyun, "chuanyun", false, "生成 chuanyun.toml（穿云隧道项目配置）")
	fs.BoolVar(&opts.SkipInstall, "skip-install", false, "跳过 go mod download 与 pnpm install")
	fs.BoolVar(&opts.KeepOnError, "keep-on-error", false, "失败时保留已创建的目录")
	fs.BoolVar(&opts.Verbose, "v", false, "打印执行的每条命令")

	// flag 包在第一个位置参数处就停止解析，而 `create-base demo --skip-install`
	// 是最自然的写法（帮助里的示例也是这么写的），先把选项挪到前面。
	if err := fs.Parse(reorderArgs(fs, args)); err != nil {
		return opts, err
	}

	rest := fs.Args()
	if len(rest) == 0 {
		return opts, fmt.Errorf("缺少项目名")
	}
	if len(rest) > 1 {
		return opts, fmt.Errorf("只能指定一个项目名，收到 %v", rest)
	}
	opts.Name = rest[0]

	if err := validateName(opts.Name); err != nil {
		return opts, err
	}
	if opts.Version != "" && opts.Version != "main" {
		if _, ok := parseTag(opts.Version); !ok {
			return opts, fmt.Errorf("--version 须为 vX.Y.Z 或 main，收到 %q", opts.Version)
		}
	}
	if opts.Dir == "" {
		opts.Dir = opts.Name
	}
	abs, err := filepath.Abs(opts.Dir)
	if err != nil {
		return opts, fmt.Errorf("解析目标目录: %w", err)
	}
	opts.Dir = abs
	if opts.Title == "" {
		opts.Title = opts.Name
	}
	if opts.BaseURL == "" {
		opts.BaseURL = defaultBaseURL
	}
	return opts, nil
}

// reorderArgs 把选项排到位置参数前面，让 `<项目名> --flag` 和 `--flag <项目名>` 都能用。
// 布尔选项后面不跟值，其余选项要把紧随其后的值一起带走；`--` 之后一律当位置参数。
func reorderArgs(fs *flag.FlagSet, args []string) []string {
	var flags, positional []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if len(arg) < 2 || arg[0] != '-' {
			positional = append(positional, arg)
			continue
		}
		flags = append(flags, arg)
		name := strings.TrimLeft(arg, "-")
		if strings.Contains(name, "=") {
			continue // --key=value 自带值
		}
		f := fs.Lookup(name)
		if f == nil {
			continue // 未知选项交给 flag.Parse 报错
		}
		if bf, ok := f.Value.(interface{ IsBoolFlag() bool }); ok && bf.IsBoolFlag() {
			continue // 布尔选项不吃后面的值
		}
		if i+1 < len(args) {
			i++
			flags = append(flags, args[i])
		}
	}
	return append(flags, positional...)
}

func usage(w *os.File) {
	fmt.Fprint(w, `用法: create-base <项目名> [选项]

从 base 基底创建一个新项目（保留共同 git 历史，之后可用 make sync-base 合入基底更新）。

项目名要求: 小写字母开头，只含小写字母/数字/连字符，2-40 位。
            它会作为 systemd 服务名、穿云隧道子域名和部署目录名，所以限制较严。

选项:
  --dir path        目标目录（默认 ./<项目名>）
  --title 标题      前端显示标题（默认与项目名相同）
  --origin url      新项目自己的仓库地址（添加为 origin，不会自动 push）
  --version v1.2.3  基底版本，或 main 取开发中的最新代码（默认最新标签）
  --base url        基底仓库地址（默认 `+defaultBaseURL+`）
  --chuanyun        生成 chuanyun.toml（穿云隧道项目配置）
  --skip-install    跳过 go mod download 与 pnpm install
  --keep-on-error   失败时保留已创建的目录
  -v                打印执行的每条命令

示例:
  create-base myshop
  create-base myshop --origin git@github.com:me/myshop.git --title 商城后台
  create-base myshop --version main --skip-install
`)
}
