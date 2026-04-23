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
    <p>Claude との会話から、Claude 自身が自動で wiki を育てる外部記憶</p>
</h3>

[Andrej Karpathy の LLM Wiki パターン](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)を Claude Code プラグインとして実装した、Claude 向け外部記憶システム。

**主眼は自動化**。セッションを終えるたびに会話が vault の `raw/` に保存され、閾値を超えると Claude がバックグラウンドで相互リンクされた Markdown wiki にコンパイルしていく。ユーザーは何もしなくても、会話を重ねるほど知識グラフが育つ。

v0.3 からは会話だけでなく **Claude が `WebFetch` で読んだページも自動的に wiki に流れ込む**（`/wiki-clip` で明示クリップも可、認証付きページは `browser-use` 経由で Chrome のログインセッションを流用）。これで「Claude と一緒に読んだもの」が全部蓄積される。

v0.4 では蓄積された wiki を **Obsidian Dataview で横断クエリ**できるよう、source page に `source_type` / `word_count` / `reading_time_min` / `domain` などの frontmatter を自動付与し、`wiki/dashboards/` に「直近 source」「domain 別 web クリップ」「人気 entity」など 8 種のダッシュボードを同梱する（`/wiki-migrate` で既存 vault も一発で現行スキーマに揃う）。

v0.5 では `wiki/index.md` の冒頭に **GitHub 草風の年間アクティビティヒートマップ**が入るようになった（[Contribution Graph](https://github.com/vran-dev/obsidian-contribution-graph) プラグインが必要）。vault を開いた瞬間に「いつ / どれだけ情報を溜めたか」が一目でわかる。DataviewJS は不要なので JS Queries は OFF のまま運用可能。同時に `/wiki-migrate-dataview` は `/wiki-migrate` にリネーム（**破壊的変更**）。

手動の `/wiki-ingest` / `/wiki-query` コマンドも提供するが、これは補助的な位置づけ — 外部ソース（論文など）を `raw/` に投入して明示的に取り込んだり、蓄積された wiki に直接問い合わせたい時のためのもの。

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Obsidian (recommended frontend)](#obsidian-recommended-frontend)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Web clipping (v0.3+)](#web-clipping-v03)
- [Dataview dashboards (v0.4+)](#dataview-dashboards-v04)
- [Auto-capture](#auto-capture)
- [Auto-ingest (v0.2+)](#auto-ingest-v02)
- [Vault layout](#vault-layout)
- [Design notes](#design-notes)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [License](#license)

## Requirements

| 項目 | 用途 | 必須？ |
|---|---|---|
| `jq` | capture hook が transcript JSON の抽出に使用 | 必須 |
| `python3` | `/wiki-init` のパス展開で使用（macOS / 主要 Linux には標準同梱） | 必須 |
| [Obsidian](https://obsidian.md) | **強く推奨**。技術的には optional（vault は純 Markdown なのでどのエディタでも開ける）だが、Karpathy の原典 gist が想定する UX（Graph View / Backlinks / Web Clipper / Dataview）は Obsidian でしか成立しない。入れずに使うのは「LLM wiki パターンの半分を捨てる」ことに近い | 推奨 |
| `readable` ([readability-cli](https://www.npmjs.com/package/readability-cli), `npm i -g readability-cli`) | `/wiki-clip` と auto-clip が web ページ本文抽出に使用 | v0.3 機能に必須 |
| [`pandoc`](https://pandoc.org) | `/wiki-clip` が HTML→Markdown 変換に使用 | v0.3 機能に必須 |
| [`browser-use`](https://github.com/browser-use/browser-use) | 認証壁 URL（Notion / Confluence 等）の取得と現タブクリップに使用 | v0.3 機能で auth ページを扱うなら必須 |

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

- **Dataview** — **v0.4 以降は事実上必須**。`wiki/dashboards/` の 8 種のビューは Dataview が enable されていないとただのコードブロックに見える。詳細は [Dataview dashboards](#dataview-dashboards-v04) 参照
- **Obsidian Web Clipper** — ブラウザ拡張。web 記事を vault の `raw/web/` 配下に保存するよう設定すれば、後で `/wiki-ingest raw/web/` で一括取り込み可能（v0.3 以降は exomemory2 側の `/wiki-clip` がほぼ同等の機能を提供するので、こちらは補助手段）

## Quick start

### 1. Create a vault

```
/wiki-init
```

デフォルトで `~/vault` に `WIKI.md`、`raw/`、`wiki/`、`.obsidian/`（推奨プリセット）を含む vault スケルトンが生成される。別パスを使いたい場合は `/wiki-init ~/vault-personal` のように引数で指定する。

### 2. Set `EXOMEMORY_VAULT`

auto-capture hook は環境変数しか見ないので、これを設定しないと会話の自動保存が動かない。`~/.zshrc` 等に追記:

```bash
export EXOMEMORY_VAULT=~/vault
```

### 3. Open the vault in Obsidian

Obsidian 起動 → "Open folder as vault" → `~/vault`（上で作ったパス）。同梱プリセットで Graph View の色分け（sources 青 / entities 緑 / concepts 橙）や推奨コアプラグインが自動で有効になる。Obsidian 未導入の場合の入れ方・プリセットの詳細は上の [Obsidian](#obsidian-recommended-frontend) セクション参照。

### 以降は Claude を普段通り使うだけ

`/compact` やセッション終了のたびに会話が `raw/handovers/` に保存され、一定量溜まるとバックグラウンドで Claude が wiki に取り込む。Obsidian の Graph View を開いておくと知識が育つ様子が見える。

### wiki から何か思い出したいとき

蓄積された wiki に直接問い合わせるには `/wiki-query` を使う:

```
/wiki-query "先週の auto-ingest のバグ調査で何が分かったっけ？"
```

Claude が関連ページを `[[wikilink]]` 引用付きで合成して答える。外部ソース（論文・Web クリップ）の手動取り込みは [Commands](#commands) 参照。

## Commands

| コマンド | 用途 |
|---|---|
| `/wiki-init [<vault-path>]` | 新規 vault のスケルトン作成（省略時は `~/vault`） |
| `/wiki-ingest [<file-or-dir>] [--vault <path>]` | raw ソースを wiki ページへコンパイル（引数省略で `raw/` 全体をスキャン） |
| `/wiki-query <question> [--vault <path>] [--save]` | wiki から合成回答を生成 |
| `/wiki-clip [<url>] [--browser] [--batch <queue>]` (v0.3+) | web ページを `raw/web/` にクリップ、画像は `raw/assets/` に content-address 保存。URL 省略で現タブを取得 |
| `/wiki-gc [--dry-run] [--purge-older-than <days>]` (v0.3+) | `raw/assets/` から孤立画像を `.trash/` に論理削除、90日超経過で物理削除 |
| `/wiki-migrate [--dry-run] [--skip-schema-update] [--force]` (v0.5+) | 旧バージョンで作った vault を現行スキーマへ retrofit（v0.4 の frontmatter 派生フィールド + dashboards + v0.5 の index heatmap）。v0.4 時代は `/wiki-migrate-dataview` だった |

## Web clipping (v0.3+)

入力帯域を handover（Claude 会話ログ）だけから **Claude が読んだ web ページ** まで拡張する機構。3 つの経路で `raw/web/` にクリップが流れ込む。

### 経路

| 経路 | トリガ | ユースケース |
|---|---|---|
| **auto-webfetch** | Claude が `WebFetch` したページ | 会話で「この記事読んで」と指示したら自動で記憶化。`PostToolUse[WebFetch]` hook がキューに URL を積み、SessionEnd で一括クリップ |
| **manual clip** | `/wiki-clip <url>` | 明示的にクリップしたい URL を渡す。公開 URL は `curl + readable` で、auth 壁ドメイン（notion.so 等）は自動で `browser-use` 経由 |
| **current tab** | `/wiki-clip`（引数なし） | ブラウザで今読んでるタブをそのまま取得。要 Chrome CDP（`open -a "Google Chrome" --args --remote-debugging-port=9222`） |

### パイプライン

```
HTML 取得（curl or browser-use）
  ↓
readable 本文抽出（Readability.js）
  ↓
pandoc HTML→Markdown 変換
  ↓
画像ダウンロード（curl → 失敗時 browser-use page-context fetch で auth 壁越え）
  ↓
画像は sha256 で content-address、raw/assets/ に保存
  ↓
Markdown の画像参照を ../assets/<hash>.<ext> に書き換え
  ↓
raw/web/<slug>.md に保存（frontmatter は初回生成後不変）
```

### Auth-walled ドメイン

以下は自動で browser-use 経路に切り替わる（Chrome プロファイルのログインセッションを流用）:

```
notion.so, notion.site, atlassian.net, atlassian.com,
slack.com, linear.app, docs.google.com, drive.google.com
```

`--browser` フラグで任意の URL を強制的に browser-use 経由にすることも可能。

### セッション紐付け（handover ブリッジ）

auto-webfetch で取得したクリップは、そのセッションの handover の末尾に自動で "Clips Captured" セクションとして追記される:

```markdown
## Clips Captured in This Session

- [[web--gist-github-com--karpathy--442a6b...]] — https://gist.github.com/karpathy/442a6bf...
```

次回 `/wiki-ingest` で handover が処理されるとき、この wikilink から **handover → web clip の Connection が wiki/sources/handovers--xxx.md に自動で張られる**。「どのセッションでこの記事を読んだか」が wiki グラフ上で辿れるようになる。

### 画像プール管理（`/wiki-gc`）

画像は content-addressed（`<sha256>.<ext>`）なので、同じ画像が複数記事で使われても 1 ファイルで済む。クリップを削除してもプール内の画像は残るので、定期的に `/wiki-gc` で孤立画像を掃除する：

```
/wiki-gc --dry-run                    # 件数とサンプルだけ報告
/wiki-gc                              # 孤立を raw/assets/.trash/<today>/ に論理削除
/wiki-gc --purge-older-than 90        # .trash/ の 90 日超経過分を物理削除（default）
```

論理削除なので 90 日以内ならいつでも復旧可能。

### Configuration

`<vault>/.exomemory-config` に以下キー（v0.3 で追加、INT のみ、既存と同じ strict parser）:

```
# Auto-capture of WebFetch URLs (1 = enabled, 0 = disabled)
AUTO_CLIP=1

# Cap per-session auto-capture queue to prevent runaway (e.g., Claude
# fetching 200 URLs in one session)
AUTO_CLIP_MAX_PER_SESSION=20
```

## Dataview dashboards (v0.4+)

すべての source page に **Dataview-queryable な frontmatter** を付与し、`wiki/dashboards/` に 8 種の事前構築ビューを同梱する。Obsidian で Dataview plugin を enable するとそのまま動く。

### 追加される frontmatter

source page 共通:

| field | 意味 |
|-------|------|
| `source_type` | `handover` / `web-clip` / `manual`（`source_id` prefix から派生） |
| `word_count` | raw body の単語数 |
| `reading_time_min` | `ceil(word_count / 200)` |

handover のみ: `session_id`（Claude セッションの UUID）
web-clip のみ: `source_url` / `domain` / `captured_at` / `captured_by`（raw frontmatter から forward）

entity / concept page は **変更なし**。Dataview の native field（`length(file.inlinks)`, `file.ctime`, `file.mtime`）で十分なため。

### 同梱 dashboards（`wiki/dashboards/`）

| ファイル | 用途 |
|---------|------|
| `recent.md` | 直近 30 日に更新された source |
| `by-source-type.md` | `source_type` ごとの件数 |
| `by-domain.md` | web クリップを domain でグルーピング |
| `handovers-timeline.md` | handover 一覧（新しい順、turn 量の proxy 付き） |
| `popular-entities.md` | entity を inbound リンク数で降順 |
| `orphan-concepts.md` | inbound リンク ≤ 1 の concept（整理候補） |
| `long-reads.md` | `reading_time_min >= 10` の濃い source |
| `README.md` | dashboards の使い方と frontmatter 一覧 |

### 既存 vault の upgrade

旧バージョンで作成した vault は `/wiki-migrate` で現行スキーマに揃える：

```
/wiki-migrate --dry-run     # 変更予定を確認（write なし）
/wiki-migrate               # 実際に retrofit
```

（v0.4 時代の `/wiki-migrate-dataview` は v0.5 で `/wiki-migrate` にリネームされた。破壊的変更）

実行内容:

1. `wiki/sources/*.md` 全ページの frontmatter に derived field を追加（body は無変更、未知キーは保持）
2. `WIKI.md` が v0.4 marker を持たなければ template の v0.4 版で上書き（`WIKI.md.bak` を保全）
3. `wiki/dashboards/` が未存在なら template からコピー

**Idempotent**: 再実行しても diff ゼロ（derived field は純関数）。バグ修正を含む新版で再走らせれば全ページが自動で正しい値に揃う。

WIKI.md を手書きカスタムしている場合は `--skip-schema-update` でページ側だけ migrate できる。

### Dataview plugin の導入

Obsidian → Settings → Community plugins → Browse → "Dataview" → Install + Enable。DataviewJS は不要（本プラグインの dashboards は全て DQL のみ）。

### Contribution Graph plugin の導入（v0.5+、Activity heatmap 用）

`wiki/index.md` 冒頭の Activity heatmap を描画するには [Contribution Graph](https://github.com/vran-dev/obsidian-contribution-graph) プラグインが必要。Dataview と同じ手順で install：

Obsidian → Settings → Community plugins → Browse → "Contribution Graph" → Install + Enable。

DataviewJS は不要（プラグイン独自の `contributionGraph` コードブロックを使うので JS Queries は OFF のままで OK）。未インストールのまま index.md を開いても壊れず、コードブロックがソース表示されるだけ。

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

- **handover + auto-clipped web**: `raw/handovers/*.md` が dirty 判定の起点、v0.3 からは `PostToolUse[WebFetch]` でキューに積まれた URL が SessionEnd 時に batch clip され、そのまま ingest の対象に入る
- `raw/papers/` 等の手動投入ソースは従来通り `/wiki-ingest raw/papers/` を叩く運用（auto-ingest の dirty 判定には含まれないので勝手には走らない）
- batch clip と ingest は **独立した gate** で制御される（clip はキューがあれば常時、ingest は dirty ≥ 閾値 && interval 経過で）

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

## Vault layout

```
<vault>/
├── WIKI.md                 # スキーマとワークフロー（Claude が参照する正本）
├── .obsidian/              # Obsidian 推奨プリセット（graph 色分け、core plugin 有効化）
├── raw/                    # イミュータブルなソース文書（ユーザーがここに投入）
│   ├── handovers/          # 自動キャプチャされた会話ログ
│   ├── web/                # web クリップ（v0.3+、/wiki-clip と auto-webfetch が投入）
│   └── assets/             # 画像プール（v0.3+、content-addressed <sha256>.<ext>）
└── wiki/                   # LLM が保守する知識レイヤー
    ├── index.md            # ページカタログ
    ├── log.md              # append-only 操作履歴
    ├── overview.md         # 生きた統合サマリ
    ├── sources/            # raw ソース1つに対し1ページ
    ├── entities/           # 人物、組織、プロジェクト、製品
    ├── concepts/           # 概念、フレームワーク、手法、理論
    └── dashboards/         # Obsidian Dataview で動く横断ビュー（v0.4+）
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

- [x] v0.2: auto-ingest 機構（dirty 判定 + gate + background spawn）
- [x] v0.3: 入力層の拡張 — `/wiki-clip` + `PostToolUse[WebFetch]` 自動クリップ + browser-use による認証壁対応 + `/wiki-gc` 孤立画像 GC
- [x] v0.4: Dataview 対応 — source page に `source_type` / `word_count` / `domain` 等の frontmatter を自動付与、`wiki/dashboards/` に 8 種のビュー同梱、`/wiki-migrate` で既存 vault を retrofit
- [x] v0.5: `index.md` に GitHub 草風のアクティビティヒートマップ同梱（Contribution Graph プラグイン連携、DataviewJS 不要）+ `/wiki-migrate-dataview` を `/wiki-migrate` に汎用化リネーム
- [ ] v0.6: capture 時のプライバシーフィルタ（機密トピック除外）、source page 間 MERGE（例: 同じ web clip が複数セッションから参照されたとき、どの handover が触ったかを web clip 側にも記録する bidirectional graph）
- [ ] 将来: graph-aware lint（孤立ページ、リンク切れ、矛盾検出）、Obsidian Bases / Canvas テンプレート、Quartz 経由の HTML 公開

## License

MIT.
