#!/usr/bin/env python3
"""Summarise ShanshuoProbe's probe-log.jsonl into the T002 conclusion tables (Markdown on stdout).

  python3 spikes/platform/summarize_probe.py .work/t002/probe-log.jsonl > spikes/platform/RESULTS-raw.md
"""
import json
import statistics
import sys
from collections import Counter, defaultdict

APPS = {
    "com.apple.Notes": "备忘录", "com.apple.TextEdit": "TextEdit", "com.apple.Safari": "Safari",
    "com.google.Chrome": "Chrome", "com.tencent.xinWeChat": "微信", "com.electron.lark": "飞书",
    "com.bytedance.lark": "飞书", "com.larksuite.larkApp": "飞书", "com.tinyspeck.slackmacgap": "Slack",
    "com.microsoft.VSCode": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor", "notion.id": "Notion",
    "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2",
}


def name(bundle):
    return APPS.get(bundle, bundle)


def main(path):
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    by = defaultdict(list)
    for r in rows:
        by[r["kind"]].append(r)
    out = []
    w = out.append

    w("## 1. 构建与权限\n")
    w("| build | 启动次数 | 启动时辅助功能 | 启动时麦克风 | 剪贴板访问策略 |")
    w("|---|---|---|---|---|")
    builds = defaultdict(list)
    for r in by["launch"]:
        builds[r["build"]].append(r)
    for b, ls in builds.items():
        w(f"| {b} | {len(ls)} | {', '.join(str(x['ax_trusted']) for x in ls)} | {', '.join(x['mic'] for x in ls)} | "
          f"{', '.join(sorted({x['pb_access'] for x in ls}))} |")
    w("")
    for r in by["ax_trust_changed"]:
        w(f"- {r['t']} 辅助功能变为 {r['now']}（build {r['build']}）")
    for r in by["tap_after_grant_without_restart"]:
        w(f"- {r['t']} 授权后不重启安装 tap：ok={r['ok']} enabled={r['enabled']}")
    for r in by["tap_install"]:
        w(f"- {r['t']} tap_install ok={r['ok']}")
    for r in by["tap_disabled"] + by["tap_reenabled_by_health_check"]:
        w(f"- {r['t']} {r['kind']} {r.get('reason', '')}")
    for r in by["deeplink_opened"]:
        w(f"- {r['t']} 打开深链接 {r['which']} ok={r['ok']}")
    for r in by["mic_request_result"]:
        w(f"- {r['t']} 麦克风请求结果 granted={r['granted']}")
    w("")

    w("## 2. 按键事件\n")
    keys = Counter((r["key"], r.get("down")) for r in by["key"])
    w("| 按键 | 按下 | 松开 | 其中安全输入开启时 |")
    w("|---|---|---|---|")
    for k in ("fn", "right_option", "esc", "ctrl_shift_space_seen_by_tap"):
        sec = sum(1 for r in by["key"] if r["key"] == k and r.get("secure_input"))
        w(f"| {k} | {keys[(k, True)]} | {keys[(k, False)]} | {sec} |")
    sw = sum(1 for r in by["key"] if r["key"] == "esc" and r.get("swallowed"))
    w(f"\nEsc 被拦截 {sw} 次；取消事件：{Counter(r['by'] for r in by['cancelled'])}")
    cc = Counter((r["down"], r["ax_trusted"]) for r in by["carbon_combo"])
    w(f"\nCarbon ⌃⇧Space：未授权时 按下 {cc[(True, False)]} / 松开 {cc[(False, False)]}；授权后 按下 {cc[(True, True)]} / 松开 {cc[(False, True)]}；"
      f"Carbon Esc {len(by['carbon_esc'])} 次；注册结果 {[(r.get('combo_status'), r.get('handler_status')) for r in by['carbon_register']][:1]}")
    w(f"\n密码框/安全输入时拒绝开始：{len(by['hold_blocked_secure'])} 次；插入时识别为密码框：{sum(1 for r in by['insert_attempt'] if r.get('result') == 'blocked_secure_field')} 次\n")

    w("## 3. 录音胶囊\n")
    caps = by["capsule_shown"]
    if caps:
        ms = [r["ms_since_key"] for r in caps if r["ms_since_key"] >= 0]
        w(f"显示 {len(caps)} 次；从按键到显示 P50 {statistics.median(ms):.0f} ms，最大 {max(ms)} ms；"
          f"定位方式 {Counter(r['by'] for r in caps)}；屏幕编号 {Counter(r['screen'] for r in caps)}（共 {max(r['screens'] for r in caps)} 块）")
        w("\n| 前台应用 | 次数 | visible | on_active_space |")
        w("|---|---|---|---|")
        for b, n in Counter(r["front"] for r in caps).items():
            rs = [r for r in caps if r["front"] == b]
            w(f"| {name(b)} | {n} | {Counter(r['visible'] for r in rs)} | {Counter(r['on_active_space'] for r in rs)} |")
    w("")

    w("## 4. 插入（按应用 × 方式）\n")
    verdicts = {}
    for r in by["manual_verdict"]:
        verdicts[r["attempt"]] = r["verdict"]
    w("| 应用 | 方式 | 次数 | AX 读回包含 | 人工判定 | 角色 | 可写选中文字 | 值可读 | 可按范围读 | 光标附近可读字数 | 备注 |")
    w("|---|---|---|---|---|---|---|---|---|---|---|")
    groups = defaultdict(list)
    for r in by["insert_attempt"]:
        groups[(r["front"], r.get("method_used", r.get("result", "?")))].append(r)
    for (b, m), rs in sorted(groups.items(), key=lambda x: (name(x[0][0]), x[0][1])):
        ver = Counter(r.get("verified", "—") for r in rs)
        man = Counter(verdicts.get(r["attempt"], "未判定") for r in rs)
        last = rs[-1]
        note = []
        if last.get("focused") is False:
            note.append("无焦点元素")
        if last.get("focused_initially_nil"):
            note.append(f"开启 AXManualAccessibility rc={last.get('set_manual_ax')}")
        if "ax_set_error" in last:
            note.append(f"AX 写入 rc={last['ax_set_error']}")
        if "clipboard_items_read" in last:
            note.append(f"读剪贴板 {last['clipboard_items_read']} 项 {last['clipboard_read_ms']} ms")
        w(f"| {name(b)} | {m} | {len(rs)} | {dict(ver)} | {dict(man)} | {last.get('role', '—')}/{last.get('subrole', '')} | "
          f"{last.get('selected_text_settable', '—')} | {last.get('value_readable', '—')} | {last.get('string_for_range', '—')} | "
          f"{last.get('context_len_before', '—')}→{last.get('context_len_after', '—')} | {'；'.join(note)} |")
    w("")

    w("## 5. 剪贴板\n")
    reads = by["paste_data_requested"]
    if reads:
        early = sum(1 for r in reads if r["before_cmd_v"])
        after = [r["ms_after_cmd_v"] for r in reads if r["ms_after_cmd_v"] >= 0]
        w(f"延迟数据被读取 {len(reads)} 次，其中在 ⌘V 之前被读取 {early} 次（说明有其他进程先读）；"
          f"⌘V 后被读取的耗时 P50 {statistics.median(after) if after else '—'} ms，最大 {max(after) if after else '—'} ms")
    w(f"\n恢复方式：{Counter(r['how'] for r in by['clipboard_restored'])}；1 秒兜底：{len(by['clipboard_restore_fallback'])} 次")
    for r in by["clipboard_read_test"]:
        w(f"- {r['t']} 读取测试：{r['items']} 项，{r['ms']} ms，策略 {r['pb_access']}，前台 {name(r['front'])}")
    for r in by["clipboard_write_test"]:
        w(f"- {r['t']} 写入测试：markers={r['markers']}")
    w("")
    w(f"日志共 {len(rows)} 行，{rows[0]['t'] if rows else ''} ～ {rows[-1]['t'] if rows else ''}；T002 完成标记：{len(by['t002_done'])}")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/Users/arnow117/hansen_agent_team/workspace/20261021-voice-dictation/.work/t002/probe-log.jsonl")
