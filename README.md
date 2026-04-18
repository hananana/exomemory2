# exomemory2

[English](./README.en.md)

[Andrej Karpathy の LLM Wiki パターン](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)を Claude Code プラグインとして実装した、Claude 向け外部記憶システム。

ソース文書を `raw/` に投入して `/wiki-ingest` を実行すると、Claude が永続的で相互リンクされた Markdown wiki にコンパイルする。蓄積された知識は `/wiki-query` で問い合わせ可能。`/compact` やセッション終了時に会話は自動でキャプチャされる。

## ステータス

初期 MVP (v0.1)。コアの ingest / query / 自動capture は動作する。Obsidian 深統合、グラフ可視化、lint、複数 vault ルーティングは今後実装予定。

認知科学ベースの tiered memory を採用していた [hananana/exomemory](https://github.com/hananana/exomemory) (v1) の後継。v2 は Karpathy の wiki パターンを軸にゼロから再設計した。

## インストール

Claude Code 内で以下を実行：

```
/plugin marketplace add hananana/exomemory2
/plugin install exomemory2@exomemory2
```

hook スクリプトには `jq` が必要（通常は導入済み、無ければ `brew install jq`）。

## クイックスタート

### 1. Vault を作成

```
/wiki-init ~/vault-personal
```

指定パスに `WIKI.md`、`raw/`、`wiki/` を含む vault スケルトンが生成される。

### 2. アクティブ vault を指定

環境変数で恒久設定（推奨）：

```bash
export CLAUDE_MEMORY_VAULT=~/vault-personal
```

あるいは各コマンドに `--vault <path>` を渡す、または vault 配下に `cd`（ancestor search が効く）。

### 3. ソースを ingest

`raw/` に Markdown を置いてから：

```
/wiki-ingest raw/papers/attention.md
```

ディレクトリ単位の ingest も可：

```
/wiki-ingest raw/papers/
```

### 4. Query

```
/wiki-query "attention mechanisms について wiki は何を記述しているか？"
```

### 5. 自動 capture

`CLAUDE_MEMORY_VAULT` が設定されていれば、プラグインの hook が `/compact` とセッション終了のタイミングで `raw/handovers/<session-id>.md` に Markdown ハンドオーバーファイルを書き出す。後で `/wiki-ingest raw/handovers/` を実行して会話ログを wiki に取り込める。

## コマンド一覧

| コマンド | 用途 |
|---|---|
| `/wiki-init <vault-path>` | 新規 vault のスケルトン作成 |
| `/wiki-ingest <file-or-dir> [--vault <path>]` | raw ソースを wiki ページへコンパイル |
| `/wiki-query <question> [--vault <path>] [--save]` | wiki から合成回答を生成 |

## Vault 構造

```
<vault>/
├── WIKI.md                 # スキーマとワークフロー（Claude が参照する正本）
├── raw/                    # イミュータブルなソース文書（ユーザーがここに投入）
│   └── handovers/          # 自動キャプチャされた会話ログ
└── wiki/                   # LLM が保守する知識レイヤー
    ├── index.md
    ├── log.md
    ├── overview.md
    ├── sources/            # raw ソース1つに対し1ページ
    ├── entities/           # 人物、組織、プロジェクト、製品
    └── concepts/           # 概念、フレームワーク、手法、理論
```

各ページは YAML frontmatter 付きのプレーン Markdown で、`[[wikilink]]` による相互参照を持つ。Obsidian、VS Code、その他任意の Markdown ビューワで閲覧可能。

## 設計方針

- **Claude Code 専用** — コマンドとフックは Claude Code ネイティブで構成。Python 等の外部ツール不要。
- **File over app** — wiki の実体は Markdown ファイルのみ。特定アプリへのロックインなし。
- **Compounds over time** — entity / concept ページは新規ソース取り込み時に **上書きせず MERGE** する。情報が累積して濃くなる。
- **Local by default** — クラウド接続・アカウント不要。vault はあなたの手元にある。

## ロードマップ

- v0.2: `SessionStart` での自動 ingest（環境変数で opt-in）
- v0.3: capture 時のプライバシーフィルタ（機密トピック除外）
- v0.4: graph-aware lint（孤立ページ、リンク切れ、矛盾検出）
- 将来: Obsidian Bases / Canvas テンプレート、Quartz 経由の HTML 公開

## exomemory v1 からの移行

v1 プラグイン（`hananana/exomemory`）は v2 安定後に deprecate し archive される。移行手順：

1. Claude Code の `settings.json` から `exomemory` の参照を `exomemory2` に差し替える：
   - `extraKnownMarketplaces`
   - `enabledPlugins`
2. `/wiki-init <path>` で新しい vault を作成
3. 必要に応じて v1 の memory ファイルから有用な内容を `raw/` に移し、再 ingest

v1 の tier 式メモリ（episodic / semantic / procedural）は v2 の sources / entities / concepts に一対一で写像できない。まっさらから始めるのが推奨経路。

## ライセンス

MIT.
