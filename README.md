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

## ステータス

初期 MVP (v0.1)。コアの ingest / query / 自動capture は動作する。Obsidian を推奨フロントエンドとし、vault template に設定プリセット（graph の色分け、推奨コアプラグインの有効化）を同梱。graph-aware lint、Bases/Canvas テンプレート、複数 vault ルーティングは今後実装予定。

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

## Obsidian（推奨フロントエンド）

exomemory2 の vault は純粋な Markdown なのでどのエディタでも閲覧・編集できるが、[Karpathy の原典](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)が想定する体験（Graph View、Backlinks、Web Clipper、Dataview）を得るには **Obsidian が最短経路**。

### インストール

- macOS: `brew install --cask obsidian`
- Linux / Windows: https://obsidian.md/download

### vault を開く

Obsidian 起動 → "Open folder as vault" → `/wiki-init` で作成した vault パスを指定。

### 同梱プリセットで何が有効になるか

`/wiki-init` で作成される vault には `.obsidian/` が同梱されており、以下が初期設定済み:

- **コアプラグイン enable**: Graph view、Backlinks、Outgoing links、Tag pane、Properties、Page preview など
- **Graph View の色分け**:
  - `wiki/sources/` → 青
  - `wiki/entities/` → 緑
  - `wiki/concepts/` → 橙

### オススメのコミュニティプラグイン

Obsidian 側で別途インストールが必要（本プラグインの管轄外）:

- **Dataview** — `type: entity` や `tags:` などの YAML frontmatter を SQL 的にクエリ
- **Obsidian Web Clipper** — ブラウザ拡張。web 記事を vault の `raw/web/` 配下に保存するよう設定すれば、後で `/wiki-ingest raw/web/` で一括取り込み可能

### 既存 vault に後から `.obsidian/` プリセットを適用する

既に `/wiki-init` 以前に作った vault でプリセットを使いたい場合:

**ケース A: `.obsidian/` がまだ無い vault**

```bash
SRC=$(ls -d ~/.claude/plugins/cache/exomemory2/exomemory2/*/template/.obsidian | sort | tail -1)
cp -R "$SRC" <your-vault>/.obsidian
```

**ケース B: 既に `.obsidian/` を持つ vault**

既存のユーザー設定を壊さないよう、必ずバックアップと差分確認を挟む:

```bash
# 1. バックアップ
cp -R <your-vault>/.obsidian <your-vault>/.obsidian.bak

# 2. 差分確認
SRC=$(ls -d ~/.claude/plugins/cache/exomemory2/exomemory2/*/template/.obsidian | sort | tail -1)
diff -r "$SRC" <your-vault>/.obsidian
```

差分を見て、以下を手動で適用:

- `graph.json`: 既存の color group を保持したいなら、template の `colorGroups` 3エントリだけを手動で既存の配列に追記
- `core-plugins.json`: 既存に無いプラグイン名だけ追加（上書きはしない）
- `app.json` / `appearance.json`: template 側は空なので既存を保持でOK

問題なければ `rm -rf <your-vault>/.obsidian.bak` でバックアップ削除。

## クイックスタート

### 1. Vault を作成

```
/wiki-init ~/vault-personal
```

指定パスに `WIKI.md`、`raw/`、`wiki/`、`.obsidian/`（推奨プリセット）を含む vault スケルトンが生成される。Obsidian が未インストールならコマンド完了時にインストール案内が出る。作成後は Obsidian で "Open folder as vault" からこのパスを開くのが推奨。

### 2. アクティブ vault を指定

環境変数で恒久設定（推奨）：

```bash
export EXOMEMORY_VAULT=~/vault-personal
```

あるいは各コマンドに `--vault <path>` を渡す、または vault 配下に `cd`（ancestor search が効く）。

> **Note:** v0.1 までは `CLAUDE_MEMORY_VAULT` という環境変数名を使っていた。後方互換のため `EXOMEMORY_VAULT` 未設定時は `CLAUDE_MEMORY_VAULT` をフォールバックで読むが、deprecation 警告が出る。**v0.3 で `CLAUDE_MEMORY_VAULT` サポートは削除予定**。`~/.zshrc` 等を `EXOMEMORY_VAULT` に書き換えること。

### 3. ソースを ingest

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

### 5. 会話ログを wiki に取り込む

セッションを重ねると `raw/handovers/` に `.md` が蓄積する（下記「自動 capture」セクション参照）。引数なしの `/wiki-ingest` で一緒に取り込まれる：

```
/wiki-ingest
```

handover だけを対象にしたい場合は従来通り `/wiki-ingest raw/handovers/`。

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
- **`$EXOMEMORY_VAULT` 未設定**: hook は silent skip（stderr に警告のみ）
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
| `$EXOMEMORY_VAULT`（または旧 `$CLAUDE_MEMORY_VAULT`）が設定されている | Yes |
| 指定 vault に `WIKI.md` が存在する | Yes |
| `jq` が PATH にある | Yes |

いずれか満たされない場合、hook は stderr に警告を出して `exit 0` する（セッション終了はブロックしない）。

### Hook と ingest の関係

**自動 capture と自動 ingest は分離されている**。hook は raw ファイルを書くだけで、wiki の生成には触らない。理由：

- `/compact` やセッション終了は LLM 処理のタイミングに向かない（ユーザーが移動しようとしている）
- ingest 失敗が可視化されないリスクを避ける
- プライバシーの都合で「wiki 化前に raw をレビューしたい」ケースに対応

実用上は週次などで `/wiki-ingest`（引数なし）を走らせて一括取り込みするのが現実的。v0.2 で `SessionStart` ベースの自動 ingest（opt-in）を追加予定。

## コマンド一覧

| コマンド | 用途 |
|---|---|
| `/wiki-init <vault-path>` | 新規 vault のスケルトン作成 |
| `/wiki-ingest [<file-or-dir>] [--vault <path>]` | raw ソースを wiki ページへコンパイル（引数省略で `raw/` 全体をスキャン） |
| `/wiki-query <question> [--vault <path>] [--save]` | wiki から合成回答を生成 |

## Vault 構造

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

## 設計方針

- **Claude Code 専用** — コマンドとフックは Claude Code ネイティブで構成。Python 等の外部ツール不要。
- **File over app** — wiki の実体は Markdown ファイルのみ。特定アプリへのロックインなし。Obsidian を推奨フロントエンドとするが、データは純 Markdown なので VS Code や他の Markdown ビューワでも動く。
- **Compounds over time** — entity / concept ページは新規ソース取り込み時に **上書きせず MERGE** する。情報が累積して濃くなる。
- **Local by default** — クラウド接続・アカウント不要。vault はあなたの手元にある。

## トラブルシューティング

### `/wiki-init` で `Usage: /wiki-init <vault-path>` が出る

引数を忘れている。`/wiki-init ~/vault` のようにパスを指定する。

### `/wiki-ingest` が `Vault not found` を返す

次のいずれかが必要：
- `export EXOMEMORY_VAULT=<path>` で vault 指定（旧 `CLAUDE_MEMORY_VAULT` も後方互換でフォールバック、deprecation 警告つき）
- コマンドに `--vault <path>` を追加
- vault ディレクトリ配下に `cd` する（ancestor search が効く）

### `/compact` しても `raw/handovers/` にファイルが出ない

以下を順に確認：

1. `$EXOMEMORY_VAULT`（または旧 `$CLAUDE_MEMORY_VAULT`）が設定されているか:
   ```bash
   echo "${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
   ```
2. その vault に `WIKI.md` があるか:
   ```bash
   VAULT="${EXOMEMORY_VAULT:-${CLAUDE_MEMORY_VAULT:-}}"
   test -f "$VAULT/WIKI.md" && echo OK
   ```
3. `jq` がインストールされているか:
   ```bash
   which jq
   ```
4. Claude Code を起動した terminal で環境変数が見えていたか（`.zshrc` に追記した場合、既存の terminal は `source ~/.zshrc` 必要）

### Obsidian で vault を開いたが graph の色分けが効かない

以下を確認：

- vault 直下に `.obsidian/graph.json` が存在するか（`/wiki-init` で作成した新規 vault なら自動で入る）
- Obsidian の Graph View を開いた状態で、左上の "Groups" メニューに3エントリ（sources / entities / concepts）が見えるか
- 見えない場合、Obsidian を一度再起動してから再度 Graph View を開く（設定ファイル読み込みは起動時に走る）

既存 vault の場合は Obsidian セクションの「既存 vault に後から `.obsidian/` プリセットを適用する」を参照。

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
