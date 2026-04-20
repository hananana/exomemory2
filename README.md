<h1 align="center">exomemory2</h1>

<p align="center">
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/hananana/exomemory2?color=blue"></a>
    <a href="https://github.com/hananana/exomemory2/releases"><img alt="Version" src="https://img.shields.io/github/v/tag/hananana/exomemory2"></a>
    <a href="https://docs.claude.com/en/docs/claude-code"><img alt="Claude Code Plugin" src="https://img.shields.io/badge/Claude_Code-Plugin-D97757"></a>
</p>

<h4 align="center">
    <p>
        <b>日本語</b> |
        <a href="./README.en.md">English</a>
    </p>
</h4>

<h3 align="center">
    <p>Claude Code 向け外部記憶 wiki — Karpathy の LLM Wiki パターンをプラグイン化</p>
</h3>

[Andrej Karpathy の LLM Wiki パターン](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)を Claude Code プラグインとして実装した、Claude 向け外部記憶システム。

ソース文書を `raw/` に投入して `/wiki-ingest` を実行すると、Claude が永続的で相互リンクされた Markdown wiki にコンパイルする。蓄積された知識は `/wiki-query` で問い合わせ可能。`/compact` やセッション終了時に会話は自動でキャプチャされる。

## Requirements

| 項目 | 用途 |
|---|---|
| `jq` | capture hook が transcript JSON の抽出に使用（必須） |
| `python3` | `/wiki-init` のパス展開で使用（macOS / 主要 Linux には標準同梱） |
| [Obsidian](https://obsidian.md) | **強く推奨**。技術的には optional（vault は純 Markdown なのでどのエディタでも開ける）だが、Karpathy の原典 gist が想定する UX（Graph View / Backlinks / Web Clipper / Dataview）は Obsidian でしか成立しない。入れずに使うのは「LLM wiki パターンの半分を捨てる」ことに近い |

## Install

Claude Code 内で以下を実行：

```
/plugin marketplace add hananana/exomemory2
/plugin install exomemory2@exomemory2
```

## Obsidian (recommended frontend)

exomemory2 の vault は純粋な Markdown なのでどのエディタでも閲覧・編集できるが、[Karpathy の原典](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)が想定する体験（Graph View、Backlinks、Web Clipper、Dataview）を得るには **Obsidian が最短経路**。

### Install

- macOS: `brew install --cask obsidian`
- Linux / Windows: https://obsidian.md/download

### Open the vault

Obsidian 起動 → "Open folder as vault" → `/wiki-init` で作成した vault パスを指定。

### What the bundled preset enables

`/wiki-init` で作成される vault には `.obsidian/` が同梱されており、以下が初期設定済み:

- **コアプラグイン enable**: Graph view、Backlinks、Outgoing links、Tag pane、Properties、Page preview など
- **Graph View の色分け**:
  - `wiki/sources/` → 青
  - `wiki/entities/` → 緑
  - `wiki/concepts/` → 橙

### Recommended community plugins

Obsidian 側で別途インストールが必要（本プラグインの管轄外）:

- **Dataview** — `type: entity` や `tags:` などの YAML frontmatter を SQL 的にクエリ
- **Obsidian Web Clipper** — ブラウザ拡張。web 記事を vault の `raw/web/` 配下に保存するよう設定すれば、後で `/wiki-ingest raw/web/` で一括取り込み可能

## Quick start

### 1. Create a vault

```
/wiki-init              # デフォルト ~/vault に作成
/wiki-init ~/vault-personal   # 任意パスを指定する場合
```

指定パス（省略時は `~/vault`）に `WIKI.md`、`raw/`、`wiki/`、`.obsidian/`（推奨プリセット）を含む vault スケルトンが生成される。Obsidian が未インストールならコマンド完了時にインストール案内が出る。作成後は Obsidian で "Open folder as vault" からこのパスを開くのが推奨。

### 2. Set the active vault

`EXOMEMORY_VAULT` の設定は必須。auto-capture hook は環境変数しか見ないので、これを設定しないと会話ログの自動保存が動かない。`~/.zshrc` 等に追記して永続化する:

```bash
export EXOMEMORY_VAULT=~/vault
```

### 3. Ingest sources

`raw/` に Markdown を置いたら、引数なしで `raw/` 全体をスキャン：

```
/wiki-ingest
```

これで新規/変更されたファイルだけが取り込まれる（未変更ファイルは `source_hash` 一致で `SKIP`）。特定のファイルやディレクトリだけ狙い撃ちしたい場合は引数を渡す：

```
/wiki-ingest raw/papers/attention.md
/wiki-ingest raw/papers/
```

### 4. Query

```
/wiki-query "attention mechanisms について wiki は何を記述しているか？"
```

### 5. Ingest conversation logs

セッションを重ねると `raw/handovers/` に `.md` が蓄積する（下記「自動 capture」セクション参照）。引数なしの `/wiki-ingest` で一緒に取り込まれる：

```
/wiki-ingest
```

handover だけを対象にしたい場合は従来通り `/wiki-ingest raw/handovers/`。

## Auto-capture

プラグイン hook が Claude との会話を自動的に `<vault>/raw/handovers/` に書き出す。詳細：

### Trigger timing

| イベント | hook | 説明 |
|---|---|---|
| `/compact` コマンド実行 | PreCompact | コンテキスト圧縮の**直前**に発火（圧縮で失われる情報を保存するタイミング） |
| セッション終了 | SessionEnd | `/exit`、ターミナル close、Claude Code 終了で発火 |

### When it doesn't fire

- **`/clear` コマンド**: 対応 hook が存在しない（Claude Code の既知制約）。clear 前に手動で `/compact` を走らせれば capture される
- **Ctrl+C による強制中断**: hook は走らない
- **Claude Code のクラッシュ**: hook は走らない
- **`$EXOMEMORY_VAULT` 未設定**: hook は silent skip（stderr に警告のみ）
- **vault に `WIKI.md` が無い**: 同じく silent skip

### File naming

```
<vault>/raw/handovers/<session-id>.md
```

- **session_id を主キーとする**。タイムスタンプは含めない
- 同一セッション内で複数回 hook が発火（複数 `/compact` + `/exit` など）しても、**毎回同じファイルに上書き**される
- 結果として「1 セッション = 1 ファイル」。最新の状態のみが保存される

### Captured content

各ファイルは YAML frontmatter + 会話本文の Markdown：

```markdown
---
title: "Session abc123-..."
session_id: "abc123-..."
last_trigger: "PreCompact"
last_captured_at: "2026-04-19T04:12:34Z"
---

## User

ここ1週間のgit logを調べて…

## Assistant

ここ1週間のcommitを確認した結果…

## User

あー、ちょっとこの機能を…

（以下続く）
```

### What isn't captured

- **tool_use**（ツール呼び出し）とその内容
- **tool_result**（ツール実行結果）
- **thinking** / 内部推論ブロック

これらは handover の目的（会話要約）にとってノイズなので `jq` で意図的に除外している。tool の出力を残したい場合は `raw/` に手動で別ファイルとして投入する運用を推奨。

### Requirements

| 条件 | 必須 |
|---|---|
| `$EXOMEMORY_VAULT` が設定されている | Yes |
| 指定 vault に `WIKI.md` が存在する | Yes |
| `jq` が PATH にある | Yes |

いずれか満たされない場合、hook は stderr に警告を出して `exit 0` する（セッション終了はブロックしない）。

## Auto-ingest (v0.2+)

PreCompact / SessionEnd hook 後に、未 ingest の handover が一定数溜まっていれば、`claude -p` をバックグラウンドで spawn して自動的に wiki に取り込む。**デフォルトで有効**。

### Flow

```
ユーザーが /compact または /exit
  ↓
capture.sh が handover を raw/handovers/<session-id>.md に書き出す
  ↓
gate を評価:
  - <vault>/.exomemory-config の AUTO_INGEST=1 か？
  - dirty 件数 ≥ AUTO_INGEST_THRESHOLD か？
  - 前回 ingest から AUTO_INGEST_INTERVAL_SEC 以上経過しているか？
  ↓ all yes
nohup claude -p ... & disown でバックグラウンド spawn
  ↓
hook 即終了（数ms）→ ユーザーセッション完全クローズ
  ↓ （別 Claude プロセスが裏で 2-3 分 ingest）
wiki/ 更新、log.md 追記、.last-ingest 更新
  ↓
プロセス終了、lock 解放
```

`/exit` 直後にターミナルが返る点は変わらない。LLM 呼び出しはバックグラウンドジョブとして launchd 養子プロセスで進行するので、tmux kill-server や Terminal.app 終了でも生き残る（macOS シャットダウンでは止まる）。

### Configuration: `<vault>/.exomemory-config`

`/wiki-init` で作る vault に同梱されるファイル。`KEY=INT` 形式の **厳密パース**（`source` はしない、悪意あるシェル content 実行を防ぐため）。

```
# Automatic ingest of handover files
# 1 = enabled (default), 0 = disabled
AUTO_INGEST=1

# Number of dirty (un-ingested or changed) handovers required to trigger
AUTO_INGEST_THRESHOLD=3

# Minimum seconds between auto-ingest runs
AUTO_INGEST_INTERVAL_SEC=1800
```

設定ファイルがない or キー未指定なら上記デフォルト値が使われる。**自動 ingest を完全に止めたい場合**は `AUTO_INGEST=0` を書く。

### Concurrency control

`<vault>/.ingest.lock` に subshell の PID を書き、PID 生存確認（`kill -0`）で stale 判定する。プロセスが死ねば次回起動時に自動的に lock を奪取できる（時刻リースは使わない、長時間 ingest にも安全）。

`/wiki-query` も同じ lock を見て、ingest 中なら最大 5 分待機してから読み取りを始める（読み取り整合性確保）。

### Scope

- **handover のみ**: `raw/handovers/*.md` だけが自動 ingest 対象
- `raw/papers/`、`raw/web/` 等は手動で `/wiki-ingest raw/papers/` を叩く運用

意図しない LLM 起動とコスト暴走を避けるため、配置範囲を意図的に絞っている。

### Logs and debugging

- `<vault>/.ingest.log` にすべての stream-json 出力が append される（debug 用）
- `<vault>/.last-ingest` に前回 ingest 完了時刻（epoch 秒）
- `<vault>/.ingest.lock` 実行中のロック（PID 入り）

これら 3 ファイルは template の `.gitignore` に含まれている。`.exomemory-config` は git に commit してOK。

### SessionStart notification

新セッション開始時、`.last-ingest` のタイムスタンプを `additionalContext` で Claude に注入する（hidden context、ユーザー非表示）:

```
exomemory2: last auto-ingest at 2026-04-19 11:35:42 (12m ago).
```

これにより Claude は wiki の鮮度を認識でき、auto ingest が止まっている場合（最終 ingest が古すぎるなど）も検知できる。

### Cost / runtime (measured)

handover 1件の ingest で約 **160秒 / 31 turns**。Claude Max プランの認証経由 (`apiKeySource: none`) なら追加の課金は発生しないが、利用枠を消費する。`AUTO_INGEST_INTERVAL_SEC=1800`（30分）と `AUTO_INGEST_THRESHOLD=3` のデフォルトは「日次1〜2回」程度の頻度に収める意図。

### Prerequisites

- `claude` コマンドが PATH にある（hook が `command -v claude` でチェック、無ければ silent skip）
- vault に `WIKI.md` が存在する
- `jq` が PATH にある（capture 機能と共有）

## Commands

| コマンド | 用途 |
|---|---|
| `/wiki-init [<vault-path>]` | 新規 vault のスケルトン作成（省略時は `~/vault`） |
| `/wiki-ingest [<file-or-dir>] [--vault <path>]` | raw ソースを wiki ページへコンパイル（引数省略で `raw/` 全体をスキャン） |
| `/wiki-query <question> [--vault <path>] [--save]` | wiki から合成回答を生成 |

## Vault layout

```
<vault>/
├── WIKI.md                 # スキーマとワークフロー（Claude が参照する正本）
├── .obsidian/              # Obsidian 推奨プリセット（graph 色分け、core plugin 有効化）
├── raw/                    # イミュータブルなソース文書（ユーザーがここに投入）
│   └── handovers/          # 自動キャプチャされた会話ログ
└── wiki/                   # LLM が保守する知識レイヤー
    ├── index.md            # ページカタログ
    ├── log.md              # append-only 操作履歴
    ├── overview.md         # 生きた統合サマリ
    ├── sources/            # raw ソース1つに対し1ページ
    ├── entities/           # 人物、組織、プロジェクト、製品
    └── concepts/           # 概念、フレームワーク、手法、理論
```

各ページは YAML frontmatter 付きのプレーン Markdown で、`[[wikilink]]` による相互参照を持つ。Obsidian、VS Code、その他任意の Markdown ビューワで閲覧可能。`.obsidian/` は Obsidian を使わない場合はそのまま無視して問題ない（削除も可）。

## Design notes

- **Claude Code 専用** — コマンドとフックは Claude Code ネイティブで構成。Python 等の外部ツール不要。
- **File over app** — wiki の実体は Markdown ファイルのみ。特定アプリへのロックインなし。Obsidian を推奨フロントエンドとするが、データは純 Markdown なので VS Code や他の Markdown ビューワでも動く。
- **Compounds over time** — entity / concept ページは新規ソース取り込み時に **上書きせず MERGE** する。情報が累積して濃くなる。
- **Local by default** — クラウド接続・アカウント不要。vault はあなたの手元にある。

## Troubleshooting

### `/wiki-init` returns `Target already exists and is not empty`

デフォルトパス `~/vault` または指定したパスにすでにファイルが入っている。別のパスを指定するか、既存ディレクトリを別名に退避してから再実行する。

### `/wiki-ingest` returns `Vault not found`

次のいずれかが必要：
- `export EXOMEMORY_VAULT=<path>` で vault 指定
- コマンドに `--vault <path>` を追加
- vault ディレクトリ配下に `cd` する（ancestor search が効く）

### `/compact` produces no file in `raw/handovers/`

以下を順に確認：

1. `$EXOMEMORY_VAULT` が設定されているか:
   ```bash
   echo "$EXOMEMORY_VAULT"
   ```
2. その vault に `WIKI.md` があるか:
   ```bash
   test -f "$EXOMEMORY_VAULT/WIKI.md" && echo OK
   ```
3. `jq` がインストールされているか:
   ```bash
   which jq
   ```
4. Claude Code を起動した terminal で環境変数が見えていたか（`.zshrc` に追記した場合、既存の terminal は `source ~/.zshrc` 必要）

### Graph colors don't show after opening the vault in Obsidian

以下を確認：

- vault 直下に `.obsidian/graph.json` が存在するか（`/wiki-init` で作成した新規 vault なら自動で入る）
- Obsidian の Graph View を開いた状態で、左上の "Groups" メニューに3エントリ（sources / entities / concepts）が見えるか
- 見えない場合、Obsidian を一度再起動してから再度 Graph View を開く（設定ファイル読み込みは起動時に走る）

既存 vault の場合は Obsidian セクションの「既存 vault に後から `.obsidian/` プリセットを適用する」を参照。

### Plugin update doesn't take effect

`plugin.json` のバージョンが上がっていないとキャッシュが無効化されない場合がある：

```
/plugin marketplace update exomemory2
/plugin install exomemory2@exomemory2
```

それでも効かない場合は手動でキャッシュ削除：

```bash
rm -rf ~/.claude/plugins/cache/exomemory2/
```

## Roadmap

- [x] v0.2: `SessionStart` での自動 ingest（環境変数で opt-in）
- [ ] v0.3: capture 時のプライバシーフィルタ（機密トピック除外）
- [ ] v0.4: graph-aware lint（孤立ページ、リンク切れ、矛盾検出）
- [ ] 将来: Obsidian Bases / Canvas テンプレート、Quartz 経由の HTML 公開

## License

MIT.
