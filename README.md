# exomemory2

[English](./README.en.md)

[Andrej Karpathy の LLM Wiki パターン](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)を Claude Code プラグインとして実装した、Claude 向け外部記憶システム。

ソース文書を `raw/` に投入して `/wiki-ingest` を実行すると、Claude が永続的で相互リンクされた Markdown wiki にコンパイルする。蓄積された知識は `/wiki-query` で問い合わせ可能。`/compact` やセッション終了時に会話は自動でキャプチャされる。

## ステータス

初期 MVP (v0.1)。コアの ingest / query / 自動capture は動作する。Obsidian 深統合、グラフ可視化、lint、複数 vault ルーティングは今後実装予定。

## データフロー

```
┌─────────────────────────────────────────────────────────────┐
│ Phase A: 自動 capture（hook 経由、Claude介在なし）            │
│                                                              │
│ Claude との会話                                              │
│  ↓ /compact または /exit                                     │
│ PreCompact / SessionEnd hook 発火                            │
│  ↓ stdin JSON: {transcript_path, session_id, trigger}        │
│ capture.sh 実行                                              │
│  ↓ transcript を jq で抽出（type==text のみ）                │
│ <vault>/raw/handovers/<session-id>.md 書き出し（上書き）     │
└─────────────────────────────────────────────────────────────┘

                    ⏸ 自動 ingest はしない（v0.2 で実装予定）

┌─────────────────────────────────────────────────────────────┐
│ Phase B: 手動 ingest（ユーザーが発火、Claude がwiki構築）     │
│                                                              │
│ /wiki-ingest raw/handovers/<session-id>.md                   │
│  ↓                                                           │
│ Claude が WIKI.md スキーマを読み込み                         │
│  ↓                                                           │
│ sources/ に要約ページ生成                                    │
│ entities/ に登場人物ページ生成 or MERGE                       │
│ concepts/ に概念ページ生成 or MERGE                           │
│ index.md / overview.md / log.md 更新                         │
└─────────────────────────────────────────────────────────────┘
```

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

### 5. 会話ログを wiki に取り込む

セッションを重ねると `raw/handovers/` に `.md` が蓄積する（下記「自動 capture」セクション参照）。定期的に以下を実行：

```
/wiki-ingest raw/handovers/
```

## 自動 capture

プラグイン hook が Claude との会話を自動的に `<vault>/raw/handovers/` に書き出す。詳細：

### 発火タイミング

| イベント | hook | 説明 |
|---|---|---|
| `/compact` コマンド実行 | PreCompact | コンテキスト圧縮の**直前**に発火（圧縮で失われる情報を保存するタイミング） |
| セッション終了 | SessionEnd | `/exit`、ターミナル close、Claude Code 終了で発火 |

### 発火しないケース

- **`/clear` コマンド**: 対応 hook が存在しない（Claude Code の既知制約）。clear 前に手動で `/compact` を走らせれば capture される
- **Ctrl+C による強制中断**: hook は走らない
- **Claude Code のクラッシュ**: hook は走らない
- **`$CLAUDE_MEMORY_VAULT` 未設定**: hook は silent skip（stderr に警告のみ）
- **vault に `WIKI.md` が無い**: 同じく silent skip

### ファイル命名規則

```
<vault>/raw/handovers/<session-id>.md
```

- **session_id を主キーとする**。タイムスタンプは含めない
- 同一セッション内で複数回 hook が発火（複数 `/compact` + `/exit` など）しても、**毎回同じファイルに上書き**される
- 結果として「1 セッション = 1 ファイル」。最新の状態のみが保存される

### 保存内容

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

### 保存されない情報

- **tool_use**（ツール呼び出し）とその内容
- **tool_result**（ツール実行結果）
- **thinking** / 内部推論ブロック

これらは handover の目的（会話要約）にとってノイズなので `jq` で意図的に除外している。tool の出力を残したい場合は `raw/` に手動で別ファイルとして投入する運用を推奨。

### 要件

| 条件 | 必須 |
|---|---|
| `$CLAUDE_MEMORY_VAULT` が設定されている | Yes |
| 指定 vault に `WIKI.md` が存在する | Yes |
| `jq` が PATH にある | Yes |

いずれか満たされない場合、hook は stderr に警告を出して `exit 0` する（セッション終了はブロックしない）。

### Hook と ingest の関係

**自動 capture と自動 ingest は分離されている**。hook は raw ファイルを書くだけで、wiki の生成には触らない。理由：

- `/compact` やセッション終了は LLM 処理のタイミングに向かない（ユーザーが移動しようとしている）
- ingest 失敗が可視化されないリスクを避ける
- プライバシーの都合で「wiki 化前に raw をレビューしたい」ケースに対応

実用上は週次などで `/wiki-ingest raw/handovers/` を走らせて一括取り込みするのが現実的。v0.2 で `SessionStart` ベースの自動 ingest（opt-in）を追加予定。

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
    ├── index.md            # ページカタログ
    ├── log.md              # append-only 操作履歴
    ├── overview.md         # 生きた統合サマリ
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

## トラブルシューティング

### `/wiki-init` で `Usage: /wiki-init <vault-path>` が出る

引数を忘れている。`/wiki-init ~/vault` のようにパスを指定する。

### `/wiki-ingest` が `Vault not found` を返す

次のいずれかが必要：
- `export CLAUDE_MEMORY_VAULT=<path>` で vault 指定
- コマンドに `--vault <path>` を追加
- vault ディレクトリ配下に `cd` する（ancestor search が効く）

### `/compact` しても `raw/handovers/` にファイルが出ない

以下を順に確認：

1. `$CLAUDE_MEMORY_VAULT` が設定されているか:
   ```bash
   echo $CLAUDE_MEMORY_VAULT
   ```
2. その vault に `WIKI.md` があるか:
   ```bash
   test -f "$CLAUDE_MEMORY_VAULT/WIKI.md" && echo OK
   ```
3. `jq` がインストールされているか:
   ```bash
   which jq
   ```
4. Claude Code を起動した terminal で環境変数が見えていたか（`.zshrc` に追記した場合、既存の terminal は `source ~/.zshrc` 必要）

### プラグインを更新したのに反映されない

`plugin.json` のバージョンが上がっていないとキャッシュが無効化されない場合がある：

```
/plugin marketplace update exomemory2
/plugin install exomemory2@exomemory2
```

それでも効かない場合は手動でキャッシュ削除：

```bash
rm -rf ~/.claude/plugins/cache/exomemory2/
```

## ロードマップ

- v0.2: `SessionStart` での自動 ingest（環境変数で opt-in）
- v0.3: capture 時のプライバシーフィルタ（機密トピック除外）
- v0.4: graph-aware lint（孤立ページ、リンク切れ、矛盾検出）
- 将来: Obsidian Bases / Canvas テンプレート、Quartz 経由の HTML 公開

## ライセンス

MIT.
