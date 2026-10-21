/*
 * 闪说原型 — 状态、动作与渲染
 * 业务规则全部来自 domain.js（与 tests/domain.test.js 共用）。
 * 状态只在内存中，刷新页面会回到初始场景。
 */
(function () {
  "use strict";

  const D = window.VoiceDomain;
  const $ = (sel) => document.querySelector(sel);

  // ---------- 计时器：重置场景时全部作废，避免旧回调写回新场景 ----------
  let scenarioVersion = 0;
  let timers = [];
  let intervals = [];

  function later(ms, fn) {
    const version = scenarioVersion;
    const id = setTimeout(() => {
      timers = timers.filter((t) => t !== id);
      if (version === scenarioVersion) fn();
    }, ms);
    timers.push(id);
    return id;
  }

  function every(ms, fn) {
    const version = scenarioVersion;
    const id = setInterval(() => {
      if (version !== scenarioVersion) {
        clearInterval(id);
        return;
      }
      fn();
    }, ms);
    intervals.push(id);
    return id;
  }

  function stopInterval(id) {
    clearInterval(id);
    intervals = intervals.filter((i) => i !== id);
  }

  function clearAllTimers() {
    timers.forEach(clearTimeout);
    intervals.forEach(clearInterval);
    timers = [];
    intervals = [];
  }

  // ---------- 场景 fixtures ----------
  const SCENARIOS = {
    "new-user": "新用户（首次打开）",
    returning: "已完成引导 · 本地模式",
    llm: "已完成引导 · 已开启智能整理",
    "copy-only": "已完成引导 · 未授权辅助功能（仅复制模式）",
  };

  const DAY = 24 * 3600 * 1000;

  function seedDictionary() {
    let dict = [];
    dict = D.addEntry(dict, { id: "t1", term: "OpenRouter", variants: ["open router"], note: "LLM 路由", hits: 3 }).dict;
    dict = D.addEntry(dict, { id: "t2", term: "Qwen3-ASR", variants: ["千问三 ASR"], note: "", hits: 1 }).dict;
    return dict;
  }

  function seedHistory(now) {
    return [
      {
        id: "h1",
        at: now - 2 * 3600 * 1000,
        app: "微信",
        raw: "好的，我晚上看一下。",
        final: "好的，我晚上看一下。",
        polished: false,
        action: "insert",
        hits: [],
      },
      {
        id: "h2",
        at: now - 5 * DAY,
        app: "备忘录",
        raw: "下周一之前把open router的账单导出来。",
        final: "下周一之前把 OpenRouter 的账单导出来。",
        polished: false,
        action: "insert",
        hits: ["OpenRouter"],
      },
    ];
  }

  function initialState(scenario) {
    const now = Date.now();
    const s = {
      scenario,
      now,
      onboardingDone: false,
      onboardingOpen: true,
      ob: {
        step: "welcome",
        visited: { welcome: true },
        done: {},
        skipped: {},
        polishPhase: "intro",
        keyDraft: "",
        keyError: null,
        keyTesting: false,
        practiceText: "",
        finishError: null,
        restartNeeded: false,
      },
      perms: { mic: "not-determined", accessibility: "not-determined", inputMonitoring: "not-determined" },
      sys: { globeKeyAction: "emoji" },
      hotkey: "fn",
      hotkeyVerified: false,
      practiceDone: false,
      model: { id: "qwen3-asr-0.6b", status: "none", progress: 0, source: "huggingface" },
      llm: { enabled: false, disclosureAccepted: false, keyLast4: null, keyValid: false, model: "recommended" },
      dict: [],
      history: [],
      historyEnabled: true,
      soundEnabled: true,
      inputDevice: "builtin",
      paused: null,
      activeTarget: "notes",
      targets: {
        notes: { value: "周会纪要\n", caret: 5 },
        wechat: {
          value: "",
          caret: 0,
          thread: [
            { me: false, text: "方案评审改到周四了吗？" },
            { me: false, text: "待会把要点发群里" },
          ],
        },
        login: { user: "arnow117", pass: "" },
      },
      clipboard: "https://example.com/报价单-v3",
      session: null,
      pill: null,
      repair: null,
      overlay: null, // {kind: 'mic-alert'|'sys-mic'|'sys-accessibility'|'sys-input'|'sys-keyboard'|'restart'|'emoji'}
      menuOpen: false,
      settingsOpen: false,
      settingsTab: "general",
      dictForm: { term: "", variants: "", note: "", error: null, warning: null },
      importText: "Codex,科德克斯,AI 编码工具\n王翀,王冲,同事\nOpenRouter",
      importResult: null,
      exportText: null,
      learning: { enabled: true, counts: {}, ignored: [] }, // REQ-003 DEC-007 静默学习
      observation: null, // 插入后正在观察的那段文字
      revokedNoticeShown: false,
      demo: {
        tab: "controls",
        utterance: "list",
        llmResult: "success",
        keyTestResult: "success",
        downloadFails: false,
        micAvailable: true,
        micSilent: false,
        indicatorAvailable: true,
        switchFocus: false,
      },
      log: [],
    };

    if (scenario !== "new-user") {
      s.onboardingDone = true;
      s.onboardingOpen = false;
      s.perms = { mic: "granted", accessibility: "granted", inputMonitoring: "granted" };
      s.sys.globeKeyAction = "none";
      s.hotkeyVerified = true;
      s.practiceDone = true;
      s.model.status = "ready";
      s.model.progress = 100;
      s.dict = seedDictionary();
      s.history = seedHistory(now);
      s.demo.utterance = "terms";
    }
    if (scenario === "llm") {
      s.llm = Object.assign(s.llm, { enabled: true, disclosureAccepted: true, keyLast4: "9f2c", keyValid: true });
      s.demo.utterance = "reasons";
    }
    if (scenario === "copy-only") {
      s.perms.accessibility = "denied";
      s.hotkey = "combo"; // REQ-001 DEC-017：没有辅助功能时只能用组合键
    }
    return s;
  }

  let state = initialState("new-user");

  // ---------- 小工具 ----------
  function esc(text) {
    return String(text == null ? "" : text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function log(message) {
    const t = new Date();
    const stamp = [t.getHours(), t.getMinutes(), t.getSeconds()].map((n) => String(n).padStart(2, "0")).join(":");
    state.log = [stamp + " " + message].concat(state.log).slice(0, 40);
  }

  // REQ-001 DEC-017：fn / 右 Option 需要辅助功能；没有时退化为组合键
  function activeHotkey() {
    return D.effectiveHotkey(state.hotkey, !copyOnly());
  }

  function hotkeyLabel(hotkey) {
    return (D.HOTKEYS[hotkey] || D.HOTKEYS.fn).label;
  }

  function demoKeyLabel() {
    const h = activeHotkey();
    return h === "fn" ? "键盘 ` 键" : h === "combo" ? "键盘 ⌃⇧ Space" : "键盘右 Option 键";
  }

  function hotkeyOptions(id) {
    const active = activeHotkey();
    return (
      '<select id="' + id + '" data-change="set-hotkey">' +
      D.availableHotkeys(!copyOnly())
        .map((h) => '<option value="' + h.id + '"' + (active === h.id ? " selected" : "") + ">按住 " + esc(h.label) + (h.id === "right-option" ? "（外接键盘推荐）" : "") + "</option>")
        .join("") +
      "</select>"
    );
  }

  function formatTime(ms) {
    const total = Math.floor(ms / 1000);
    return Math.floor(total / 60) + ":" + String(total % 60).padStart(2, "0");
  }

  function relTime(at) {
    const diff = Date.now() - at;
    if (diff < 60000) return "刚刚";
    if (diff < 3600000) return Math.floor(diff / 60000) + " 分钟前";
    if (diff < DAY) return Math.floor(diff / 3600000) + " 小时前";
    return Math.floor(diff / DAY) + " 天前";
  }

  function copyOnly() {
    return state.perms.accessibility !== "granted";
  }

  function llmActive() {
    return state.llm.enabled && state.llm.keyValid;
  }

  // ---------- 录音胶囊 ----------
  let pillTimer = null;

  function showPill(pill, autoHideMs) {
    if (pillTimer) clearTimeout(pillTimer);
    state.pill = pill;
    if (autoHideMs) {
      const version = scenarioVersion;
      pillTimer = setTimeout(() => {
        if (version !== scenarioVersion) return;
        if (state.pill === pill) {
          state.pill = null;
          render();
        }
      }, autoHideMs);
    }
  }

  // ---------- 按住说话 ----------
  let holdStartedAt = null;
  let tickId = null;
  let levelId = null;

  function hotkeyActiveNow() {
    if (state.onboardingDone) return true;
    // 引导中只在快捷键和练习步骤启用
    return state.onboardingOpen && (state.ob.step === "hotkey" || state.ob.step === "practice");
  }

  function currentTarget() {
    if (!state.onboardingDone && state.onboardingOpen && state.ob.step === "practice") return "practice";
    return state.activeTarget;
  }

  function startHold() {
    if (holdStartedAt !== null) return;
    holdStartedAt = Date.now();

    if (!hotkeyActiveNow()) {
      log("快捷键尚未启用（引导未完成）");
      holdStartedAt = null;
      render();
      return;
    }

    // 🌐 键与系统设置冲突：按下时系统会先弹出表情面板
    const conflict = D.hotkeyConflict(activeHotkey(), state.sys.globeKeyAction);
    if (conflict) {
      state.overlay = { kind: "emoji" };
      log("系统响应了 🌐 键：" + (state.sys.globeKeyAction === "emoji" ? "弹出表情与符号" : "开始系统听写"));
      holdStartedAt = null;
      later(1400, () => {
        if (state.overlay && state.overlay.kind === "emoji") state.overlay = null;
        render();
      });
      render();
      return;
    }

    if (state.session && state.session.phase !== "listening") {
      showPill({ kind: "info", icon: "warn", text: "上一段仍在处理" }, 1400);
      holdStartedAt = null;
      render();
      return;
    }

    const isHotkeyTest = !state.onboardingDone && state.ob.step === "hotkey";
    if (isHotkeyTest) {
      state.session = { phase: "listening", startedAt: Date.now(), offset: 0, test: true };
      showPill({ kind: "listening" });
      startTicking();
      render();
      return;
    }

    const check = D.checkCanStart({
      paused: !!state.paused,
      busy: false,
      secureInput: !!(D.TARGET_APPS[currentTarget()] && D.TARGET_APPS[currentTarget()].secure),
      micPermission: state.perms.mic,
      micAvailable: state.demo.micAvailable,
      modelStatus: state.model.status,
      indicatorAvailable: state.demo.indicatorAvailable,
    });
    if (!check.ok) {
      holdStartedAt = null;
      handleBlockedStart(check);
      render();
      return;
    }

    finishObservation("开始下一次听写");
    state.session = { phase: "listening", startedAt: Date.now(), offset: 0, targetAtStart: currentTarget() };
    state.repair = null;
    log("麦克风已打开" + (state.soundEnabled ? " · 提示音：开始" : ""));
    showPill({ kind: "listening" });
    startTicking();
    render();
  }

  function handleBlockedStart(check) {
    log("未开始录音：" + check.message);
    if (check.reason === "paused") {
      showPill({ kind: "paused" }, 3000);
      return;
    }
    if (check.reason === "secure-field") {
      showPill({ kind: "info", icon: "block", text: check.message }, 2600);
      return;
    }
    if (check.reason === "indicator") {
      state.repair = {
        title: "录音提示无法显示，未开始录音",
        body: "为了让你始终知道何时在录音，提示无法显示时不会录音。",
        actions: [{ label: "知道了", action: "repair-close", primary: true }],
      };
      return;
    }
    if (check.reason === "mic-permission") {
      state.repair = {
        title: "需要麦克风权限",
        body: "麦克风权限已关闭，无法录音。打开系统设置重新允许后即可使用。",
        actions: [
          { label: "打开系统设置", action: "open-sys-mic", primary: true },
          { label: "关闭", action: "repair-close" },
        ],
      };
      return;
    }
    if (check.reason === "mic-unavailable") {
      state.repair = {
        title: "没有可用的麦克风",
        body: "未检测到输入设备，或设备正被其他应用独占。",
        actions: [
          { label: "选择输入设备", action: "open-settings-general", primary: true },
          { label: "关闭", action: "repair-close" },
        ],
      };
      return;
    }
    if (check.reason === "model") {
      state.repair = {
        title: "语音模型需要修复",
        body: state.model.status === "downloading" ? "模型仍在下载（" + state.model.progress + "%），完成后即可使用。" : "本地语音模型缺失或损坏，重新下载后即可使用。",
        actions:
          state.model.status === "downloading"
            ? [{ label: "知道了", action: "repair-close", primary: true }]
            : [
                { label: "重新下载", action: "repair-model", primary: true },
                { label: "关闭", action: "repair-close" },
              ],
      };
    }
  }

  function startTicking() {
    if (tickId) stopInterval(tickId);
    if (levelId) stopInterval(levelId);
    tickId = every(200, () => {
      if (!state.session || state.session.phase !== "listening") return;
      const elapsed = Date.now() - state.session.startedAt + state.session.offset;
      if (D.shouldAutoStop(elapsed)) {
        log("达到 3 分钟上限，自动结束录音");
        finishRecording("auto");
        return;
      }
      renderPill();
    });
    levelId = every(90, animateLevels);
  }

  function stopTicking() {
    if (tickId) stopInterval(tickId);
    if (levelId) stopInterval(levelId);
    tickId = null;
    levelId = null;
  }

  function animateLevels() {
    const silent = state.demo.micSilent || state.demo.utterance === "silence";
    document.querySelectorAll(".pill .bars i").forEach((bar) => {
      const h = silent ? 3 + Math.random() * 2 : 4 + Math.random() * 16;
      bar.style.height = h + "px";
    });
  }

  function endHold() {
    if (holdStartedAt === null) return;
    holdStartedAt = null;
    if (!state.session || state.session.phase !== "listening") return;
    const held = Date.now() - state.session.startedAt + state.session.offset;
    if (D.classifyRelease(held) === "misfire") {
      stopTicking();
      state.session = null;
      log("按住少于 0.3 秒，视为误触，麦克风已释放");
      showPill({ kind: "info", icon: "warn", text: "按住 " + hotkeyLabel(activeHotkey()) + " 说话，松开结束" }, 1600);
      render();
      return;
    }
    finishRecording("release");
  }

  function cancelRecording() {
    if (!state.session || state.session.phase !== "listening") return;
    stopTicking();
    holdStartedAt = null;
    state.session = null;
    log("已取消：麦克风已释放，音频已丢弃");
    showPill({ kind: "info", icon: "warn", text: "已取消，未插入任何内容" }, 1400);
    render();
  }

  function finishRecording(reason) {
    stopTicking();
    holdStartedAt = null;
    const session = state.session;
    if (session.test) {
      state.session = null;
      state.hotkeyVerified = true;
      log("快捷键测试成功");
      showPill({ kind: "info", icon: "ok", text: "快捷键可用" }, 1500);
      render();
      return;
    }
    session.phase = "recognizing";
    session.targetAtRelease = currentTarget();
    log((reason === "auto" ? "自动结束" : "已松开") + "：麦克风已释放，开始本地识别（" + D.MODELS[state.model.id].name + "）");
    showPill({ kind: "busy", text: "识别中" });
    render();

    later(650, () => {
      const result = D.processDictation({
        utteranceId: state.demo.utterance,
        modelId: state.model.id,
        dict: state.dict,
        llmEnabled: llmActive(),
        llmResult: state.demo.llmResult,
      });
      log("音频已从内存丢弃");
      if (result.status === "empty") {
        state.session = null;
        showPill({ kind: "info", icon: "warn", text: "没有听到声音" }, 1600);
        render();
        return;
      }
      if (!llmActive()) {
        deliver(result, session);
        return;
      }
      session.phase = "polishing";
      const terms = state.dict.filter((e) => result.raw.includes(e.term) || result.dictionaryHits.includes(e.term)).length;
      log("发送到 OpenRouter：文字 " + result.raw.length + " 字、相关词条 " + terms + " 个（不含音频）" + " · 要求零数据保留");
      showPill({ kind: "busy", text: "整理中" });
      render();
      const delay = state.demo.llmResult === "timeout" ? 1800 : 850;
      later(delay, () => deliver(result, session));
    });
  }

  function insertIntoTarget(targetId, text) {
    if (targetId === "practice") {
      state.ob.practiceText = state.ob.practiceText + text;
      return;
    }
    const t = state.targets[targetId];
    const caret = Math.min(t.caret == null ? t.value.length : t.caret, t.value.length);
    t.value = t.value.slice(0, caret) + text + t.value.slice(caret);
    t.caret = caret + text.length;
    focusAfterRender = { id: "t-" + targetId, caret: t.caret };
  }

  function deliver(result, session) {
    let targetAtInsert = currentTarget();
    if (state.demo.switchFocus && session.targetAtRelease !== "practice") {
      targetAtInsert = session.targetAtRelease === "wechat" ? "notes" : "wechat";
      state.activeTarget = targetAtInsert;
      log("处理期间用户切换到了「" + D.TARGET_APPS[targetAtInsert].name + "」");
    }

    let decision;
    if (session.targetAtRelease === "practice") {
      decision = targetAtInsert === "practice" ? { action: "insert", message: "已插入" } : { action: "copy", message: "焦点已变化，已复制到剪贴板" };
    } else {
      decision = D.decideInsertion({
        targetAtRelease: session.targetAtRelease,
        targetAtInsert,
        accessibility: state.perms.accessibility === "granted" ? "granted" : "denied",
      });
    }

    if (decision.action === "insert") {
      const saved = state.clipboard;
      const observed = session.targetAtRelease !== "practice" ? snapshotForObservation(session.targetAtRelease, result.final) : null;
      insertIntoTarget(session.targetAtRelease, result.final);
      state.clipboard = saved;
      log("已插入到「" + targetName(session.targetAtRelease) + "」，剪贴板已恢复原内容");
      if (observed) startObservation(observed);
    } else if (decision.action === "copy") {
      state.clipboard = result.final;
      log("已复制到剪贴板（" + decision.message + "）");
    } else {
      log("密码框：本次内容已丢弃，未插入、未复制、未写入历史");
    }

    if (session.targetAtRelease === "practice" && decision.action === "insert") {
      state.practiceDone = true;
      state.ob.done.practice = true;
    }

    // 历史与词典命中
    if (state.historyEnabled && decision.action !== "discard") {
      state.history = [
        {
          id: "h" + Date.now(),
          at: Date.now(),
          app: targetName(session.targetAtRelease),
          raw: result.raw,
          final: result.final,
          polished: result.polished,
          fallbackReason: result.fallbackReason,
          action: decision.action,
          hits: result.dictionaryHits,
        },
      ].concat(state.history);
    }
    if (result.dictionaryHits.length && decision.action !== "discard") {
      state.dict = state.dict.map((e) => (result.dictionaryHits.includes(e.term) ? Object.assign({}, e, { hits: e.hits + 1 }) : e));
      log("词典生效：" + result.dictionaryHits.join("、") + (result.biasHits.length ? "（识别前提示：" + result.biasHits.join("、") + "）" : ""));
    }

    state.session = null;

    let pill;
    if (decision.action === "discard") {
      pill = { kind: "info", icon: "block", text: decision.message };
    } else if (result.fallbackReason) {
      pill = { kind: "info", icon: "warn", text: "智能整理不可用（" + result.fallbackReason + "），" + (decision.action === "insert" ? "已插入原文" : "已复制原文") };
    } else if (decision.action === "copy") {
      pill = { kind: "info", icon: "warn", text: decision.message.indexOf("仅复制") === 0 ? decision.message : decision.message + "，按 ⌘V 粘贴", action: copyOnly() ? { label: "开启直接插入", action: "open-sys-accessibility" } : null };
    } else {
      pill = { kind: "info", icon: "ok", text: result.polished ? "已整理并插入" : "已插入" };
    }
    showPill(pill, result.fallbackReason || decision.action !== "insert" ? 3200 : 1500);

    // 辅助功能权限被撤销：首次发生时给出修复入口（DEC-003）
    if (state.perms.accessibility === "revoked") showRevokedNotice();
    render();
  }

  // ---------- REQ-003 DEC-007：静默学习 ----------
  let observationTimer = null;

  function snapshotForObservation(targetId, text) {
    const t = state.targets[targetId];
    const caret = Math.min(t.caret == null ? t.value.length : t.caret, t.value.length);
    return { targetId, before: t.value.slice(0, caret), after: t.value.slice(caret), inserted: text };
  }

  function startObservation(obs) {
    if (!state.learning.enabled || copyOnly()) return;
    state.observation = Object.assign(obs, { at: Date.now() });
    clearTimeout(observationTimer);
    observationTimer = setTimeout(() => {
      finishObservation("已过 " + D.RULES.learnObserveMinutes + " 分钟");
      render();
    }, D.RULES.learnObserveMinutes * 60000);
    log("自动学习：开始留意刚插入的 " + obs.inserted.length + " 个字（离开输入框、开始下一次听写或 " + D.RULES.learnObserveMinutes + " 分钟后结束）");
  }

  function finishObservation(reason) {
    const obs = state.observation;
    if (!obs) return;
    state.observation = null;
    clearTimeout(observationTimer);
    if (!state.learning.enabled || copyOnly()) return;
    const current = D.locateInsertedSegment(obs, state.targets[obs.targetId].value);
    if (current === null) {
      log("自动学习（" + reason + "）：插入段前后的文字也变了，无法确定改动，本次不学习");
      return;
    }
    const r = D.learnFromEdit({ inserted: obs.inserted, edited: current, dict: state.dict, ignored: state.learning.ignored, counts: state.learning.counts });
    state.dict = r.dict;
    state.learning.counts = r.counts;
    if (r.reason) log("自动学习（" + reason + "）：" + r.reason);
    r.skipped.forEach((k) => log("自动学习：未学习「" + k.wrong + " → " + k.right + "」（" + k.reason + "）"));
    r.learned.forEach((l) => {
      if (l.action === "added-term") log("自动学习：记住「" + l.right + "」（你把「" + l.wrong + "」改成了它）");
      else if (l.action === "enabled-replace") log("自动学习：第 " + l.count + " 次看到「" + l.wrong + " → " + l.right + "」，以后自动替换");
      else log("自动学习：「" + l.wrong + " → " + l.right + "」记录 1 次，再出现 1 次后自动替换");
    });
    log("自动学习（" + reason + "）：比较结束，读到的文字已丢弃");
  }

  function showRevokedNotice() {
    if (state.revokedNoticeShown) return;
    state.revokedNoticeShown = true;
    finishObservation("辅助功能已关闭");
    state.repair = {
      title: "辅助功能权限已关闭",
      body: "已切换为仅复制模式：快捷键暂时改为 ⌃⇧ Space，结果复制到剪贴板，需要你按 ⌘V 粘贴，也不会自动学习专有词。重新允许后自动恢复。",
      actions: [
        { label: "打开系统设置", action: "open-sys-accessibility", primary: true },
        { label: "保持仅复制", action: "repair-close" },
      ],
    };
  }

  function targetName(id) {
    if (id === "practice") return "练习框";
    return D.TARGET_APPS[id] ? D.TARGET_APPS[id].name : id;
  }

  let focusAfterRender = null;

  // ---------- 模型下载 ----------
  const MODEL_MB = { "qwen3-asr-0.6b": 1010, "sensevoice-small": 245 };
  let downloadId = null;

  function startDownload() {
    if (state.model.status === "ready") return;
    state.model.status = "downloading";
    log("开始下载 " + D.MODELS[state.model.id].name + "（来源：" + sourceName(state.model.source) + "）");
    if (downloadId) stopInterval(downloadId);
    const failAt = state.demo.downloadFails && !state.model.failedOnce ? 40 : null;
    downloadId = every(260, () => {
      if (state.model.status !== "downloading") {
        stopInterval(downloadId);
        downloadId = null;
        return;
      }
      state.model.progress = Math.min(100, state.model.progress + 4);
      if (failAt && state.model.progress >= failAt) {
        state.model.status = "failed";
        state.model.failedOnce = true;
        log("模型下载中断：网络连接失败，已保留 " + state.model.progress + "%");
        stopInterval(downloadId);
        downloadId = null;
      } else if (state.model.progress >= 100) {
        state.model.status = "ready";
        state.model.downloaded = Object.assign({}, state.model.downloaded, { [state.model.id]: true });
        if (!state.onboardingDone) state.ob.done.model = true;
        log("模型已就绪：" + D.MODELS[state.model.id].name + "（文件校验通过）");
        stopInterval(downloadId);
        downloadId = null;
      }
      render();
    });
  }

  function sourceName(source) {
    return source === "modelscope" ? "ModelScope 镜像" : "Hugging Face";
  }

  // ---------- Onboarding ----------
  function obSteps() {
    return D.visibleSteps();
  }

  function obGo(stepId) {
    state.ob.step = stepId;
    state.ob.visited[stepId] = true;
    state.ob.finishError = null;
    if (stepId === "practice" && state.demo.utterance === "silence") state.demo.utterance = "list";
    focusAfterRender = stepId === "practice" ? { id: "ob-practice", caret: state.ob.practiceText.length } : null;
  }

  function obConflict() {
    return D.hotkeyConflict(activeHotkey(), state.sys.globeKeyAction);
  }

  function obCanContinue(stepId) {
    switch (stepId) {
      case "mic":
        return state.perms.mic === "granted";
      case "model":
        return state.model.status === "ready" || state.model.status === "downloading";
      case "hotkey":
        return state.hotkeyVerified && !obConflict();
      case "practice":
        return state.practiceDone;
      default:
        return true;
    }
  }

  function obNext() {
    const steps = obSteps();
    const step = state.ob.step;
    if (!obCanContinue(step)) return;
    if (step === "accessibility" && state.perms.accessibility !== "granted") state.ob.skipped.accessibility = true;
    else if (step === "polish" && !state.llm.enabled) state.ob.skipped.polish = true;
    else if (step === "model" && state.model.status !== "ready") state.ob.done.model = false;
    else state.ob.done[step] = true;
    const index = steps.findIndex((s) => s.id === step);
    if (index < steps.length - 1) obGo(steps[index + 1].id);
  }

  function obBack() {
    const steps = obSteps();
    const index = steps.findIndex((s) => s.id === state.ob.step);
    if (index > 0) obGo(steps[index - 1].id);
  }

  function obFinish() {
    const check = D.canFinishOnboarding({
      micPermission: state.perms.mic,
      modelStatus: state.model.status,
      hotkeyReady: state.hotkeyVerified && !obConflict(),
      practiceDone: state.practiceDone,
    });
    if (!check.ok) {
      state.ob.finishError = "还需要完成：" + check.missing.join("、");
      return;
    }
    state.onboardingDone = true;
    state.onboardingOpen = false;
    state.ob.done.done = true;
    log("引导完成，快捷键已在所有应用中启用");
    showPill({ kind: "info", icon: "ok", text: "闪说已就绪 · 按住 " + hotkeyLabel(activeHotkey()) + " 说话" }, 2600);
  }

  function testKey() {
    const draft = state.ob.keyDraft;
    const error = D.validateOpenRouterKey(draft);
    if (error) {
      state.ob.keyError = error;
      return;
    }
    state.ob.keyError = null;
    state.ob.keyTesting = true;
    later(900, () => {
      state.ob.keyTesting = false;
      if (state.demo.keyTestResult === "success") {
        state.llm.keyValid = true;
        state.llm.keyLast4 = draft.trim().slice(-4);
        state.llm.editingKey = false;
        state.ob.keyDraft = "";
        log("OpenRouter Key 测试通过，已保存到系统钥匙串");
      } else {
        state.ob.keyError = "OpenRouter 返回 401：Key 无效或已被撤销";
        log("OpenRouter Key 测试失败");
      }
      render();
    });
  }

  // ---------- 动作分发 ----------
  const actions = {
    // 菜单栏
    "toggle-menu": () => {
      state.menuOpen = !state.menuOpen;
    },
    "pause-hour": () => {
      state.paused = "hour";
      state.menuOpen = false;
      log("语音输入已暂停 1 小时");
    },
    "pause-manual": () => {
      state.paused = "manual";
      state.menuOpen = false;
      log("语音输入已暂停，直到手动恢复");
    },
    resume: () => {
      state.paused = null;
      state.menuOpen = false;
      state.pill = null;
      log("语音输入已恢复");
    },
    "continue-onboarding": () => {
      state.onboardingOpen = true;
      state.menuOpen = false;
    },
    "open-settings": (el) => {
      state.settingsOpen = true;
      state.settingsTab = el.dataset.tab || "general";
      state.menuOpen = false;
    },
    "settings-tab": (el) => {
      state.settingsTab = el.dataset.tab;
    },
    "close-settings": () => {
      state.settingsOpen = false;
    },
    "close-onboarding": () => {
      state.onboardingOpen = false;
      log("引导已退出，进度已保存；可从菜单栏继续");
    },

    // 修复卡片
    "repair-close": () => {
      state.repair = null;
    },
    "repair-model": () => {
      state.repair = null;
      state.settingsOpen = true;
      state.settingsTab = "model";
      startDownload();
    },
    "open-settings-general": () => {
      state.repair = null;
      state.settingsOpen = true;
      state.settingsTab = "general";
    },

    // 模拟的系统界面
    "request-mic": () => {
      state.overlay = { kind: "mic-alert" };
    },
    "mic-allow": () => {
      state.perms.mic = "granted";
      state.overlay = null;
      log("系统：已允许麦克风");
    },
    "mic-deny": () => {
      state.perms.mic = "denied";
      state.overlay = null;
      log("系统：拒绝了麦克风");
    },
    "open-sys-mic": () => {
      state.repair = null;
      state.overlay = { kind: "sys-mic" };
    },
    "open-sys-accessibility": () => {
      state.repair = null;
      state.pill = null;
      state.overlay = { kind: "sys-accessibility" };
    },
    "open-sys-input": () => {
      state.overlay = { kind: "sys-input" };
    },
    "open-sys-keyboard": () => {
      state.overlay = { kind: "sys-keyboard" };
    },
    "close-overlay": () => {
      state.overlay = null;
    },
    "sys-toggle": (el) => {
      const perm = el.dataset.perm;
      const granted = el.checked;
      if (perm === "mic") state.perms.mic = granted ? "granted" : "denied";
      if (perm === "accessibility") {
        state.perms.accessibility = granted ? "granted" : "denied";
        if (granted) state.revokedNoticeShown = false;
      }
      if (perm === "inputMonitoring") {
        state.perms.inputMonitoring = granted ? "granted" : "denied";
        if (granted) state.ob.restartNeeded = true;
      }
      log("系统设置：" + permName(perm) + (granted ? "已允许" : "已关闭"));
      if (granted && perm !== "inputMonitoring") {
        later(700, () => {
          if (state.overlay && state.overlay.kind.indexOf("sys-") === 0) state.overlay = null;
          log("已自动检测到" + permName(perm) + "授权");
          render();
        });
      }
    },
    "restart-app": () => {
      state.overlay = { kind: "restart" };
      later(1300, () => {
        state.overlay = null;
        state.ob.restartNeeded = false;
        log("已重新打开，回到「按键监听」步骤");
        render();
      });
    },

    // Onboarding
    "ob-next": obNext,
    "ob-back": obBack,
    "ob-go": (el) => {
      if (state.ob.visited[el.dataset.step]) obGo(el.dataset.step);
    },
    "ob-skip-accessibility": () => {
      state.ob.skipped.accessibility = true;
      state.hotkey = "combo";
      state.hotkeyVerified = false;
      log("跳过辅助功能：使用仅复制模式，快捷键改为 ⌃⇧ Space");
      obNext();
    },
    "ob-finish": obFinish,
    "download-model": startDownload,
    "pause-download": () => {
      state.model.status = "paused";
      log("模型下载已暂停（" + state.model.progress + "%）");
    },
    "resume-download": startDownload,
    "switch-mirror": () => {
      state.model.source = "modelscope";
      startDownload();
    },
    "set-hotkey": (el) => {
      state.hotkey = el.value;
      state.hotkeyVerified = false;
      log("快捷键改为 " + hotkeyLabel(activeHotkey()));
    },
    "use-right-option": () => {
      state.hotkey = "right-option";
      state.hotkeyVerified = false;
      log("快捷键改为 右 Option");
    },
    "sys-globe": (el) => {
      state.sys.globeKeyAction = el.value;
      log("系统设置：按下 🌐 键时 → " + globeName(el.value));
    },
    "polish-accept": () => {
      state.llm.disclosureAccepted = true;
      state.ob.polishPhase = "key";
    },
    "polish-skip": () => {
      state.ob.skipped.polish = true;
      log("暂不开启智能整理：使用本地模式");
      obNext();
    },
    "polish-test": testKey,
    "polish-enable": () => {
      state.llm.enabled = true;
      log("智能整理已开启");
      if (!state.onboardingDone && state.ob.step === "polish") {
        state.ob.done.polish = true;
        obNext();
      }
    },
    "set-llm-model": (el) => {
      state.llm.model = el.value;
    },

    // 设置
    "toggle-sound": (el) => {
      state.soundEnabled = el.checked;
    },
    "set-input-device": (el) => {
      state.inputDevice = el.value;
    },
    "select-model": (el) => {
      const id = el.value;
      if (id === state.model.id) return;
      state.model.downloaded = Object.assign({}, state.model.downloaded, state.model.status === "ready" ? { [state.model.id]: true } : {});
      state.model.id = id;
      const downloaded = state.model.downloaded && state.model.downloaded[id];
      state.model.status = downloaded ? "ready" : "none";
      state.model.progress = downloaded ? 100 : 0;
      state.model.failedOnce = false;
      log("识别模型切换为 " + D.MODELS[id].name + (downloaded ? "" : "（需要下载）"));
    },
    "set-source": (el) => {
      state.model.source = el.value;
    },
    "delete-model": () => {
      state.model.status = "none";
      state.model.progress = 0;
      state.model.failedOnce = false;
      state.model.downloaded = Object.assign({}, state.model.downloaded, { [state.model.id]: false });
      log("已删除本地模型文件：" + D.MODELS[state.model.id].name);
    },
    "llm-toggle": (el) => {
      if (!el.checked) {
        state.llm.enabled = false;
        log("智能整理已关闭：之后不再发送任何内容到云端");
        return;
      }
      if (!state.llm.disclosureAccepted) {
        state.llm.showDisclosure = true;
        return;
      }
      if (!state.llm.keyValid) {
        state.llm.toggleError = "先配置并测试 OpenRouter Key";
        return;
      }
      state.llm.enabled = true;
      state.llm.toggleError = null;
      log("智能整理已开启");
    },
    "llm-accept-disclosure": () => {
      state.llm.disclosureAccepted = true;
      state.llm.showDisclosure = false;
      if (state.llm.keyValid) {
        state.llm.enabled = true;
        log("智能整理已开启");
      } else {
        state.llm.editingKey = true;
      }
    },
    "llm-edit-key": () => {
      state.llm.editingKey = true;
      state.ob.keyError = null;
    },
    "llm-delete-key": () => {
      state.llm.keyValid = false;
      state.llm.keyLast4 = null;
      state.llm.enabled = false;
      log("OpenRouter Key 已从钥匙串删除，智能整理已关闭");
    },
    // 词典
    "dict-add": () => {
      const f = state.dictForm;
      const result = D.addEntry(state.dict, {
        term: f.term,
        variants: f.variants.split(/[,，、]/),
        note: f.note,
        source: "manual",
      });
      if (!result.ok) {
        state.dictForm.error = result.error;
        state.dictForm.warning = null;
        return;
      }
      state.dict = result.dict;
      state.dictForm = { term: "", variants: "", note: "", error: null, warning: result.warning || null, added: result.entry.term };
      log("词典新增：" + result.entry.term);
    },
    "dict-delete": (el) => {
      const r = D.forgetEntry(state.dict, state.learning.ignored, el.dataset.id);
      state.dict = r.dict;
      state.learning.ignored = r.ignored;
      if (r.entry) log("词典删除：" + r.entry.term + (r.entry.source === "auto" ? "（自动学习词，以后不再自动学回）" : ""));
    },
    "learning-toggle": (el) => {
      state.learning.enabled = el.checked;
      if (!el.checked) {
        state.observation = null;
        clearTimeout(observationTimer);
      }
      log(el.checked ? "已开启自动学习" : "已关闭自动学习：插入后不再读取输入框");
    },
    "learning-clear-ignored": () => {
      state.learning.ignored = [];
      log("已允许重新学习删除过的词");
    },
    "dict-import": () => {
      const result = D.importEntries(state.dict, D.parseImport(state.importText));
      state.dict = result.dict;
      state.importResult = "新增 " + result.added + " 条，已存在跳过 " + result.skipped + " 条，冲突 " + result.conflicts + " 条";
      log("词典导入：" + state.importResult);
    },
    "dict-export": () => {
      state.exportText = D.exportCSV(state.dict);
      log("词典已导出为 CSV（演示：未写入真实文件）");
    },

    // 历史
    "history-toggle": (el) => {
      state.historyEnabled = el.checked;
      log(el.checked ? "已开启历史记录" : "已关闭历史记录：之后不再保存");
    },
    "history-clear": () => {
      state.history = [];
      log("历史已清空");
    },
    "history-delete": (el) => {
      state.history = state.history.filter((h) => h.id !== el.dataset.id);
    },
    "history-copy": (el) => {
      const h = state.history.find((x) => x.id === el.dataset.id);
      if (h) {
        state.clipboard = h.final;
        showPill({ kind: "info", icon: "ok", text: "已复制" }, 1200);
      }
    },
    // 前台应用
    "wechat-send": () => {
      const w = state.targets.wechat;
      if (!w.value.trim()) return;
      w.thread.push({ me: true, text: w.value });
      w.value = "";
      w.caret = 0;
    },

    // 演示设置
    "demo-tab": (el) => {
      state.demo.tab = el.dataset.tab;
    },
    "demo-reset": () => resetScenario(state.scenario),
    "demo-correct": () => {
      const obs = state.observation;
      if (!obs) return;
      const t = state.targets[obs.targetId];
      const seg = D.locateInsertedSegment(obs, t.value);
      if (seg === null) return;
      let fixed = seg;
      D.UTTERANCES.forEach((u) => u.misrecognitions.forEach((m) => {
        fixed = fixed.split(m.wrong).join(m.right);
      }));
      if (fixed === seg) {
        log("演示：刚插入的文字里没有可改正的误识别");
        return;
      }
      t.value = obs.before + fixed + obs.after;
      t.caret = (obs.before + fixed).length;
      log("演示：用户在「" + targetName(obs.targetId) + "」里改正了刚插入的文字");
    },
    "demo-leave-field": () => finishObservation("离开输入框"),
    "demo-scenario": (el) => resetScenario(el.value),
    "demo-field": (el) => {
      const key = el.dataset.field;
      state.demo[key] = el.type === "checkbox" ? el.checked : el.value;
    },
    "demo-target": (el) => {
      if (state.observation && state.observation.targetId !== el.value) finishObservation("离开输入框");
      state.activeTarget = el.value;
      log("前台应用切换为「" + D.TARGET_APPS[el.value].name + "」");
    },
    "demo-perm": (el) => {
      const perm = el.dataset.perm;
      state.perms[perm] = el.value;
      if (perm === "accessibility" && el.value === "revoked") {
        state.revokedNoticeShown = false;
        showRevokedNotice();
      }
      log("模拟系统设置：" + permName(perm) + " → " + permStateName(el.value));
    },
    "demo-globe": (el) => {
      state.sys.globeKeyAction = el.value;
      log("模拟系统设置：按下 🌐 键时 → " + globeName(el.value));
    },
    "demo-fast-forward": () => {
      if (!state.session || state.session.phase !== "listening") {
        log("快进无效：当前没有在录音（按住快捷键时再点）");
        return;
      }
      const elapsed = Date.now() - state.session.startedAt + state.session.offset;
      state.session.offset += Math.max(0, D.RULES.countdownFromMs - elapsed);
      log("演示：录音时长快进到 2:45");
    },
    "demo-age-history": () => {
      state.history = state.history.map((h) => Object.assign({}, h, { at: h.at - 3 * DAY }));
      const before = state.history.length;
      state.history = D.pruneHistory(state.history, Date.now());
      log("演示：时间快进 3 天，清理超过 7 天的历史 " + (before - state.history.length) + " 条");
    },
  };

  function permName(perm) {
    return { mic: "麦克风", accessibility: "辅助功能", inputMonitoring: "输入监控" }[perm] || perm;
  }

  function permStateName(value) {
    return { granted: "已允许", denied: "未允许", revoked: "已撤销", "not-determined": "未询问" }[value] || value;
  }

  function globeName(value) {
    return { emoji: "显示表情与符号", dictation: "开始听写", none: "不执行任何操作" }[value];
  }

  function resetScenario(scenario) {
    scenarioVersion += 1;
    clearAllTimers();
    stopTicking();
    downloadId = null;
    holdStartedAt = null;
    focusAfterRender = null;
    const tab = state.demo.tab;
    state = initialState(scenario);
    state.demo.tab = tab;
    log("场景已重置：" + SCENARIOS[scenario]);
  }

  // =====================================================================
  // 渲染
  // =====================================================================
  const WAVE_ICON =
    '<svg viewBox="0 0 18 14" aria-hidden="true"><g fill="currentColor"><rect x="1" y="5" width="2" height="4" rx="1"/><rect x="5" y="2" width="2" height="10" rx="1"/><rect x="9" y="0" width="2" height="14" rx="1"/><rect x="13" y="3" width="2" height="8" rx="1"/></g></svg>';

  function computeStatus() {
    if (state.session && state.session.phase === "listening") return { title: "正在录音", sub: "松开 " + hotkeyLabel(activeHotkey()) + " 结束 · Esc 取消" };
    if (state.session) return { title: "正在处理", sub: "麦克风已关闭" };
    if (!state.onboardingDone) return { title: "设置未完成", sub: "完成引导后才能在其他应用中使用", warn: true };
    if (state.paused) return { title: "已暂停", sub: state.paused === "hour" ? "1 小时后自动恢复" : "直到你手动恢复", warn: true };
    if (state.perms.mic !== "granted") return { title: "缺少麦克风权限", sub: "按快捷键时会提示修复", warn: true };
    if (state.model.status !== "ready") return { title: "语音模型不可用", sub: "前往设置 › 语音模型", warn: true };
    if (copyOnly()) return { title: "仅复制模式", sub: "辅助功能未授权：结果复制到剪贴板", warn: true };
    return { title: "就绪", sub: "按住 " + hotkeyLabel(activeHotkey()) + " 说话" + (llmActive() ? " · 智能整理已开启" : " · 本地模式") };
  }

  function renderMenubar() {
    const recording = state.session && state.session.phase === "listening";
    const status = computeStatus();
    const frontName = state.onboardingOpen && !state.onboardingDone || state.settingsOpen
      ? "闪说"
      : { notes: "备忘录", wechat: "微信", login: "Safari", desktop: "访达" }[state.activeTarget];
    const now = new Date();
    const clock = (now.getMonth() + 1) + "月" + now.getDate() + "日 " + String(now.getHours()).padStart(2, "0") + ":" + String(now.getMinutes()).padStart(2, "0");
    $("#menubar").innerHTML =
      '<span class="apple" aria-hidden="true"></span>' +
      '<span class="front-app">' + esc(frontName) + "</span>" +
      "<span>文件</span><span>编辑</span><span>显示</span><span>窗口</span>" +
      '<span class="spacer"></span>' +
      '<button type="button" id="status-item" class="status-item' + (recording ? " recording" : "") + '" data-action="toggle-menu" aria-haspopup="menu" aria-expanded="' + state.menuOpen + '" aria-label="语音输入：' + esc(status.title) + '" style="' + (state.paused && !recording ? "opacity:.45" : "") + '">' +
      WAVE_ICON +
      (recording ? '<span class="state-text">录音中</span>' : "") +
      (!recording && status.warn && !state.paused ? '<span class="badge" aria-hidden="true"></span>' : "") +
      "</button>" +
      '<span class="clock">' + clock + "</span>";
  }

  function renderMenu() {
    const layer = $("#menu-layer");
    if (!state.menuOpen) {
      layer.innerHTML = "";
      return;
    }
    const status = computeStatus();
    const item = (label, action, extra) =>
      '<button type="button" class="menu-item' + (extra && extra.cls ? " " + extra.cls : "") + '" role="menuitem" data-action="' + action + '"' + (extra && extra.tab ? ' data-tab="' + extra.tab + '"' : "") + ">" + label + (extra && extra.right ? '<span class="muted small">' + extra.right + "</span>" : "") + "</button>";
    let html = '<div class="menu" id="menu" role="menu" aria-label="闪说菜单">';
    html += '<div class="menu-status"><strong>' + esc(status.title) + "</strong><span>" + esc(status.sub) + "</span></div>";
    if (!state.onboardingDone) html += item("继续设置…", "continue-onboarding", { cls: "menu-warning" });
    if (state.onboardingDone && copyOnly()) html += item("开启直接插入…", "open-sys-accessibility", { cls: "menu-warning" });
    if (state.paused) {
      html += item("恢复语音输入", "resume");
    } else if (state.onboardingDone) {
      html += item("暂停 1 小时", "pause-hour");
      html += item("暂停，直到我恢复", "pause-manual");
    }
    html += '<div class="menu-sep"></div>';
    html += item("历史…", "open-settings", { tab: "history" });
    html += item("词典…", "open-settings", { tab: "dictionary" });
    html += item("设置…", "open-settings", { tab: "general", right: "⌘," });
    html += item("隐私与数据…", "open-settings", { tab: "privacy" });
    html += "</div>";
    layer.innerHTML = html;
  }

  function windowChrome(title, body, extraClass, closeAction) {
    return (
      '<section class="window ' + extraClass + '" role="dialog" aria-label="' + esc(title) + '">' +
      '<div class="titlebar"><span class="lights">' +
      (closeAction ? '<button type="button" data-action="' + closeAction + '" aria-label="关闭窗口"></button>' : "<i></i>") +
      "<i></i><i></i></span><span class=\"title\">" + esc(title) + "</span></div>" +
      body +
      "</section>"
    );
  }

  function renderTarget() {
    const layer = $("#target-layer");
    const id = state.activeTarget;
    if (id === "desktop") {
      layer.innerHTML = "";
      return;
    }
    let body = "";
    let title = "";
    if (id === "notes") {
      title = "备忘录";
      body =
        '<div class="body"><textarea id="t-notes" data-target-input="notes" aria-label="备忘录正文">' +
        esc(state.targets.notes.value) +
        '</textarea><div class="target-hint">点击正文放置光标，再按住快捷键说话。</div></div>';
    } else if (id === "wechat") {
      title = "微信 · 产品讨论群";
      const thread = state.targets.wechat.thread
        .map((m) => '<div class="bubble' + (m.me ? " me" : "") + '">' + esc(m.text) + "</div>")
        .join("");
      body =
        '<div class="body"><div class="wechat-thread">' + thread + "</div>" +
        '<textarea id="t-wechat" class="wechat-input" data-target-input="wechat" aria-label="微信输入框">' + esc(state.targets.wechat.value) + "</textarea>" +
        '<div class="row" style="justify-content:flex-end"><button type="button" class="btn" data-action="wechat-send">发送</button></div></div>';
    } else if (id === "login") {
      title = "Safari — 登录";
      body =
        '<div class="body"><form class="login" onsubmit="return false">' +
        '<div><label for="t-user">账号</label><input id="t-user" value="' + esc(state.targets.login.user) + '" /></div>' +
        '<div><label for="t-pass">密码</label><input id="t-pass" type="password" autocomplete="off" /></div>' +
        '<div class="target-hint">密码框属于安全输入框：闪说在这里不可用，按住快捷键不会录音。</div>' +
        "</form></div>";
    }
    layer.innerHTML = windowChrome(title, body, "target-window", null);
  }

  function renderPill() {
    const layer = $("#pill-layer");
    const p = state.pill;
    if (!p) {
      layer.innerHTML = "";
      return;
    }
    let html = "";
    if (p.kind === "listening" && state.session) {
      const elapsed = Date.now() - state.session.startedAt + state.session.offset;
      const left = D.countdownSeconds(elapsed);
      html =
        '<div class="pill" role="status" aria-label="正在录音">' +
        '<span class="rec-dot" aria-hidden="true"></span>' +
        '<span class="bars" aria-hidden="true">' + "<i></i>".repeat(9) + "</span>" +
        "<span>" + (state.session.test ? "测试快捷键" : "正在听") + "</span>" +
        '<span class="timer">' + formatTime(elapsed) + "</span>" +
        (left !== null ? '<span class="countdown">还剩 ' + left + " 秒</span>" : "") +
        '<span class="hint">松开结束 · Esc 取消</span>' +
        "</div>";
    } else if (p.kind === "busy") {
      html = '<div class="pill" role="status"><span class="spinner" aria-hidden="true"></span><span>' + esc(p.text) + '</span><span class="hint">麦克风已关闭</span></div>';
    } else if (p.kind === "paused") {
      html = '<div class="pill" role="status"><span class="icon-warn">‖</span><span>语音输入已暂停</span><button type="button" data-action="resume">恢复</button></div>';
    } else {
      const icon = { ok: '<span class="icon-ok">✓</span>', warn: '<span class="icon-warn">!</span>', block: '<span class="icon-block">⊘</span>' }[p.icon || "ok"];
      html =
        '<div class="pill" role="status">' + icon + "<span>" + esc(p.text) + "</span>" +
        (p.action ? '<button type="button" data-action="' + p.action.action + '">' + esc(p.action.label) + "</button>" : "") +
        "</div>";
    }
    layer.innerHTML = html;
    if (p.kind === "listening") animateLevels();
  }

  function renderRepair() {
    const r = state.repair;
    $("#repair-layer").innerHTML = r
      ? '<div class="repair-card" role="alertdialog" aria-label="' + esc(r.title) + '"><h4>' + esc(r.title) + "</h4><p>" + esc(r.body) + '</p><div class="row">' +
        r.actions.map((a) => '<button type="button" class="btn' + (a.primary ? " primary" : "") + '" data-action="' + a.action + '">' + esc(a.label) + "</button>").join("") +
        "</div></div>"
      : "";
  }

  function renderFnKey() {
    const key = $("#fn-key");
    key.innerHTML = { fn: "fn 🌐", "right-option": "右 ⌥", combo: "⌃⇧ ␣" }[activeHotkey()] + "<small>按住说话</small>";
    key.classList.toggle("held", holdStartedAt !== null);
    $("#fn-key-caption").textContent = "演示：按住这个键，或按住" + demoKeyLabel() + "。Esc 取消。";
  }

  function sysPane(kind) {
    const conf = {
      "sys-mic": { crumb: "隐私与安全性 › 麦克风", desc: "允许下列应用访问麦克风。", perm: "mic", on: state.perms.mic === "granted" },
      "sys-accessibility": { crumb: "隐私与安全性 › 辅助功能", desc: "允许下列应用控制你的电脑。闪说用它把文字插入当前输入框。", perm: "accessibility", on: state.perms.accessibility === "granted" },
      "sys-input": { crumb: "隐私与安全性 › 输入监控", desc: "允许下列应用监控键盘输入。更改后需要重新打开应用才能生效。", perm: "inputMonitoring", on: state.perms.inputMonitoring === "granted" },
    }[kind];
    const body =
      '<div class="body"><div class="breadcrumb">' + conf.crumb + '</div><p class="small muted" style="margin:0">' + conf.desc + "</p>" +
      '<div class="sys-row"><div class="left"><span class="mini-icon"></span>闪说</div><label class="switch"><input type="checkbox" id="sys-switch" data-change="sys-toggle" data-perm="' + conf.perm + '"' + (conf.on ? " checked" : "") + ' aria-label="允许语音输入"><span></span></label></div>' +
      '<div class="sys-row"><div class="left"><span class="mini-icon gray"></span>Zoom</div><label class="switch"><input type="checkbox" checked disabled aria-label="Zoom"><span></span></label></div>' +
      '<div class="row" style="justify-content:flex-end"><button type="button" class="btn" data-action="close-overlay">完成</button></div></div>';
    return '<div class="scrim">' + windowChrome("系统设置（模拟）", body, "sys-settings", "close-overlay").replace('class="window sys-settings"', 'class="window sys-settings" style="position:relative"') + "</div>";
  }

  function renderOverlay() {
    const o = state.overlay;
    const layer = $("#overlay-layer");
    if (!o) {
      layer.innerHTML = "";
      return;
    }
    if (o.kind === "mic-alert") {
      layer.innerHTML =
        '<div class="scrim"><div class="alert" role="alertdialog" aria-label="麦克风授权">' +
        '<div class="app-icon">' + WAVE_ICON + "</div>" +
        "<h3>“闪说”想要访问麦克风</h3>" +
        "<p>按住快捷键时用于录音，松开立即停止。音频只在本机识别，不会上传。</p>" +
        '<div class="row"><button type="button" class="btn" data-action="mic-deny">不允许</button><button type="button" class="btn primary" id="mic-allow" data-action="mic-allow">允许</button></div>' +
        '<p class="small">（模拟的系统弹窗）</p></div></div>';
    } else if (o.kind === "sys-keyboard") {
      const body =
        '<div class="body"><div class="breadcrumb">键盘</div>' +
        '<div class="sys-row"><span>按下 🌐 键时</span><select id="sys-globe" data-change="sys-globe">' +
        ["emoji", "dictation", "none"].map((v) => '<option value="' + v + '"' + (state.sys.globeKeyAction === v ? " selected" : "") + ">" + globeName(v) + "</option>").join("") +
        "</select></div>" +
        '<div class="row" style="justify-content:flex-end"><button type="button" class="btn" data-action="close-overlay">完成</button></div></div>';
      layer.innerHTML = '<div class="scrim">' + windowChrome("系统设置（模拟）", body, "sys-settings", "close-overlay").replace('class="window sys-settings"', 'class="window sys-settings" style="position:relative"') + "</div>";
    } else if (o.kind === "restart") {
      layer.innerHTML = '<div class="scrim"><div class="alert"><div class="app-icon">' + WAVE_ICON + "</div><h3>正在重新打开“闪说”…</h3><p>输入监控权限需要重新打开应用后生效。</p></div></div>";
    } else if (o.kind === "emoji") {
      layer.innerHTML =
        '<div class="pill-layer" style="bottom:90px"><div class="alert" style="width:300px;text-align:left"><h3>表情与符号</h3><p style="font-size:22px;letter-spacing:6px">😀😂🥹👍🎉🙏</p><p>（模拟）系统响应了 🌐 键，没有开始录音。到「快捷键」步骤修复冲突。</p></div></div>';
    } else {
      layer.innerHTML = sysPane(o.kind);
    }
  }

  // ---------- Onboarding ----------
  function keyField(id) {
    const err = state.ob.keyError;
    return (
      '<div class="field"><label for="' + id + '">OpenRouter API Key</label>' +
      '<div class="row"><input id="' + id + '" type="password" style="flex:1;min-width:220px" placeholder="sk-or-v1-…" data-input="ob.keyDraft" value="' + esc(state.ob.keyDraft) + '"' + (err ? ' aria-invalid="true" aria-describedby="' + id + '-err"' : "") + " />" +
      '<button type="button" class="btn' + (state.ob.keyTesting ? " busy primary" : "") + '" data-action="polish-test"' + (state.ob.keyTesting ? " disabled" : "") + ">" + (state.ob.keyTesting ? "测试中" : "测试连接") + "</button></div>" +
      (err ? '<div class="error" id="' + id + '-err">' + esc(err) + "</div>" : '<div class="help">保存在 macOS 钥匙串，界面只显示末四位。演示：任意以 sk-or- 开头、不少于 16 位的字符串。</div>') +
      "</div>"
    );
  }

  function llmModelSelect(id) {
    const opts = [
      ["recommended", "推荐模型（plan 阶段评测后确定）"],
      ["example-fast", "示例：轻量快速模型"],
      ["example-quality", "示例：高质量模型"],
    ];
    return (
      '<select id="' + id + '" data-change="set-llm-model" aria-label="整理模型">' +
      opts.map(([v, l]) => '<option value="' + v + '"' + (state.llm.model === v ? " selected" : "") + ">" + l + "</option>").join("") +
      "</select>"
    );
  }

  function dataFlow() {
    return (
      '<div class="flow" aria-label="数据流向">' +
      '<div class="node">你的声音</div><span class="arrow">→</span><div class="node">本机识别<br><span class="small muted">音频不离开电脑</span></div><span class="arrow">→</span>' +
      '<div class="node cloud">OpenRouter<br><span class="small muted">只收到文字和相关词条</span></div>' +
      "</div>"
    );
  }

  function modelPanel() {
    const m = state.model;
    const meta = D.MODELS[m.id];
    const total = MODEL_MB[m.id];
    const got = Math.round((total * m.progress) / 100);
    let status = "";
    let buttons = "";
    if (m.status === "none") {
      buttons = '<button type="button" class="btn primary" data-action="download-model">下载 ' + esc(meta.name) + "（" + meta.size + "）</button>";
    } else if (m.status === "downloading") {
      status = '<span class="small muted">' + sourceName(m.source) + " · 已下载 " + got + " / " + total + " MB</span>";
      buttons = '<button type="button" class="btn" data-action="pause-download">暂停</button>';
    } else if (m.status === "paused") {
      status = '<span class="small muted">已暂停 · ' + got + " / " + total + " MB</span>";
      buttons = '<button type="button" class="btn primary" data-action="resume-download">继续下载</button>';
    } else if (m.status === "failed") {
      status = '<div class="callout bad">下载中断：网络连接失败。已下载的 ' + got + " MB 会保留，继续时从断点开始。</div>";
      buttons = '<button type="button" class="btn primary" data-action="resume-download">重试</button>' + (m.source !== "modelscope" ? '<button type="button" class="btn" data-action="switch-mirror">切换到 ModelScope 镜像</button>' : "");
    } else if (m.status === "ready") {
      status = '<div class="callout ok">' + esc(meta.name) + " 已就绪，在本机运行。</div>";
    }
    return (
      '<div class="stack">' +
      (m.status !== "none" && m.status !== "ready" ? '<div class="progress" role="progressbar" aria-valuenow="' + m.progress + '" aria-valuemin="0" aria-valuemax="100" aria-label="模型下载进度"><i style="width:' + m.progress + '%"></i></div>' : "") +
      status +
      (buttons ? '<div class="row">' + buttons + "</div>" : "") +
      "</div>"
    );
  }

  function obStepContent(step) {
    const p = state.perms;
    switch (step) {
      case "welcome":
        return (
          "<h2>按住说话，松开就是文字</h2>" +
          '<p class="lead">在任何应用里按住 ' + hotkeyLabel(activeHotkey()) + " 说话，松开后文字会出现在当前输入框。开始前，先说清楚三件事：</p>" +
          '<div class="promise"><span class="num">1</span><div><strong>录音时一定有提示</strong><p>屏幕底部的录音胶囊和菜单栏图标会同时亮起，松开按键立即停止录音。</p></div></div>' +
          '<div class="promise"><span class="num">2</span><div><strong>声音只在本机识别</strong><p>音频不上传、不保存到磁盘，识别完成即丢弃。</p></div></div>' +
          '<div class="promise"><span class="num">3</span><div><strong>云端整理由你决定</strong><p>智能整理默认关闭。开启后只把文字发送到你自己配置的 OpenRouter 模型。</p></div></div>' +
          '<p class="small muted">接下来需要 2～3 个系统权限和一次模型下载，大约 3 分钟。</p>'
        );
      case "mic":
        return (
          "<h2>允许使用麦克风</h2>" +
          '<p class="lead">只有在你按住快捷键时才会使用麦克风；松开按键，麦克风立即关闭。</p>' +
          (p.mic === "granted"
            ? '<div class="callout ok">已允许使用麦克风。</div>'
            : p.mic === "denied"
            ? '<div class="callout bad">麦克风权限被拒绝，没有它无法录音。macOS 不会再次弹出询问，需要在系统设置中打开。</div><div class="row"><button type="button" class="btn primary" data-action="open-sys-mic">打开系统设置</button></div>'
            : '<div class="row"><button type="button" class="btn primary" data-action="request-mic">允许使用麦克风</button></div>')
        );
      case "accessibility":
        return (
          "<h2>允许闪说在其他应用中工作</h2>" +
          '<p class="lead">macOS 把这三项能力都放在「辅助功能」权限里：在任何应用中按住 fn 说话；把文字直接放到光标处；插入后看看你有没有改动刚插入的那段文字，用来记住专有词。</p>' +
          '<p class="small muted">闪说不读取屏幕上的其他内容；为了学习而读到的文字只在内存中比较，比较完即丢弃。自动学习可以在设置 › 词典中关闭。</p>' +
          (p.accessibility === "granted"
            ? '<div class="callout ok">已允许：可以按住 fn 或右 Option 说话，结果直接插入当前输入框。</div>'
            : '<div class="row"><button type="button" class="btn primary" data-action="open-sys-accessibility">打开系统设置</button><button type="button" class="btn" data-action="ob-skip-accessibility">稍后再说</button></div>' +
              '<div class="callout">稍后再说也可以使用：快捷键改为 ⌃⇧ Space，结果复制到剪贴板，需要你按 ⌘V 粘贴（仅复制模式），也不会自动学习专有词。随时可以在菜单栏开启。</div>')
        );
      case "model":
        return (
          "<h2>下载本地语音模型</h2>" +
          '<p class="lead">识别完全在本机运行。默认模型支持中文、英文和中英混说。</p>' +
          '<div class="group">' +
          Object.values(D.MODELS)
            .map(
              (m) =>
                '<label class="item" style="cursor:pointer"><span class="label"><strong>' + esc(m.name) + (m.id === "qwen3-asr-0.6b" ? ' <span class="tag ok">推荐</span>' : "") + "</strong><span>" + esc(m.note) + " · " + m.size + '</span></span><input type="radio" name="ob-model" id="ob-model-' + m.id + '" value="' + m.id + '" data-change="select-model"' + (state.model.id === m.id ? " checked" : "") + (state.model.status === "downloading" ? " disabled" : "") + "></label>"
            )
            .join("") +
          "</div>" +
          modelPanel() +
          (state.model.status === "downloading" ? '<p class="small muted">可以先继续后面的步骤，下载会在后台进行。</p>' : "")
        );
      case "mic-test":
        return (
          "<h2>试试麦克风</h2>" +
          '<p class="lead">随便说一句话，看看下面的音量条是否跟着跳动。</p>' +
          '<div class="field"><label for="ob-device">输入设备</label><select id="ob-device" data-change="set-input-device"><option value="builtin"' + (state.inputDevice === "builtin" ? " selected" : "") + '>MacBook 内建麦克风</option><option value="airpods"' + (state.inputDevice === "airpods" ? " selected" : "") + ">AirPods Pro</option></select></div>" +
          '<div class="meter" id="ob-meter" aria-label="音量">' + "<i></i>".repeat(24) + "</div>" +
          (state.demo.micSilent ? '<div class="callout warn">没有检测到声音。检查是否选对了输入设备，或麦克风是否被静音。</div>' : '<div class="callout ok">检测到声音，麦克风工作正常。</div>')
        );
      case "hotkey": {
        const conflict = obConflict();
        return (
          "<h2>设置快捷键</h2>" +
          '<p class="lead">按住快捷键说话，松开结束。当前只支持按住式。</p>' +
          '<div class="field"><label for="ob-hotkey">快捷键</label>' + hotkeyOptions("ob-hotkey") + "</div>" +
          (copyOnly() ? '<div class="callout small">未开启辅助功能时只能使用组合键 ⌃⇧ Space。开启后可以改用 fn 或右 Option。</div>' : "") +
          (conflict
            ? '<div class="callout warn">' + esc(conflict) + '。</div><div class="row"><button type="button" class="btn primary" data-action="open-sys-keyboard">打开键盘设置</button><button type="button" class="btn" data-action="use-right-option">改用右 Option</button></div>'
            : state.hotkeyVerified
            ? '<div class="callout ok">快捷键可用。</div>'
            : '<div class="callout">现在试一下：按住屏幕左下角的键（或' + demoKeyLabel() + "）约 1 秒，然后松开。</div>")
        );
      }
      case "polish":
        if (state.llm.enabled) {
          return "<h2>智能整理</h2>" + '<div class="callout ok">智能整理已开启，Key 末四位 ' + esc(state.llm.keyLast4) + "。可随时在设置中关闭。</div>";
        }
        if (state.ob.polishPhase === "intro") {
          return (
            "<h2>智能整理（可选）</h2>" +
            '<p class="lead">把口语整理成书面文字：去掉口头禅、保留改口后的说法、补标点，把「第一、第二」整理成编号列表。</p>' +
            dataFlow() +
            '<div class="callout warn">开启后，识别出的文字会发送到你选择的 OpenRouter 模型。始终要求零数据保留路由；音频始终不会上传。不开启也能正常使用，只是保留原话。</div>'
          );
        }
        return (
          "<h2>配置 OpenRouter</h2>" +
          '<p class="lead">使用你自己的 OpenRouter 账户和额度。</p>' +
          keyField("ob-key") +
          (state.llm.keyValid ? '<div class="callout ok">连接成功，Key 末四位 ' + esc(state.llm.keyLast4) + "。</div>" : "") +
          '<div class="field"><label for="ob-llm-model">整理模型</label>' + llmModelSelect("ob-llm-model") + "</div>" +
          '<p class="small muted">始终要求零数据保留：只路由到承诺不保存请求内容的服务商。</p>'
        );
      case "practice":
        return (
          "<h2>练习一次</h2>" +
          '<p class="lead">按住快捷键，说：「第一，买牛奶，第二，取快递，第三，给老王回邮件。」然后松开。</p>' +
          (state.model.status !== "ready"
            ? '<div class="callout warn">语音模型还在准备（' + state.model.progress + "%），完成后才能练习。</div>" + modelPanel()
            : "") +
          '<textarea class="practice-box" id="ob-practice" data-input="ob.practiceText" aria-label="练习输入框" placeholder="识别结果会出现在这里">' + esc(state.ob.practiceText) + "</textarea>" +
          (state.practiceDone
            ? '<div class="callout ok">成功！' + (llmActive() ? "智能整理已把口述序号整理成列表。" : "本地模式会保留原话；开启智能整理后，口述序号会整理成编号列表。") + "</div>"
            : "")
        );
      case "done": {
        const row = (label, value, ok) => '<div class="item"><span class="label"><strong>' + label + '</strong></span><span class="tag ' + (ok ? "ok" : "warn") + '">' + value + "</span></div>";
        return (
          "<h2>准备好了</h2>" +
          '<p class="lead">在任何应用中按住 ' + hotkeyLabel(activeHotkey()) + " 说话。录音时屏幕底部会一直显示胶囊。</p>" +
          '<div class="group">' +
          row("麦克风", p.mic === "granted" ? "已允许" : "未允许", p.mic === "granted") +
          row("插入方式", p.accessibility === "granted" ? "直接插入" : "仅复制模式", p.accessibility === "granted") +
          row("语音模型", state.model.status === "ready" ? D.MODELS[state.model.id].name : "下载中 " + state.model.progress + "%", state.model.status === "ready") +
          row("快捷键", hotkeyLabel(activeHotkey()), state.hotkeyVerified && !obConflict()) +
          row("智能整理", state.llm.enabled ? "已开启" : "本地模式", true) +
          "</div>" +
          (state.ob.finishError ? '<div class="callout bad" role="alert">' + esc(state.ob.finishError) + "</div>" : "")
        );
      }
      default:
        return "";
    }
  }

  function obFooter(step) {
    const steps = obSteps();
    const index = steps.findIndex((s) => s.id === step);
    const back = index > 0 && step !== "done" ? '<button type="button" class="btn" data-action="ob-back">上一步</button>' : "<span></span>";
    let right = "";
    if (step === "welcome") right = '<button type="button" class="btn primary" data-action="ob-next">开始设置</button>';
    else if (step === "accessibility" && state.perms.accessibility !== "granted") right = "";
    else if (step === "polish" && !state.llm.enabled) {
      right =
        state.ob.polishPhase === "intro"
          ? '<button type="button" class="btn" data-action="polish-skip">暂不开启</button><button type="button" class="btn primary" data-action="polish-accept">我了解，配置 OpenRouter</button>'
          : '<button type="button" class="btn" data-action="polish-skip">暂不开启</button><button type="button" class="btn primary" data-action="polish-enable"' + (state.llm.keyValid ? "" : " disabled") + ">开启智能整理</button>";
    } else if (step === "done") right = '<button type="button" class="btn primary" data-action="ob-finish">开始使用</button>';
    else {
      const ok = obCanContinue(step);
      const label = step === "model" && state.model.status === "downloading" ? "后台下载，先继续" : "继续";
      right = '<button type="button" class="btn primary" data-action="ob-next"' + (ok ? "" : " disabled") + ">" + label + "</button>";
    }
    return '<div class="ob-footer">' + back + '<div class="row">' + right + "</div></div>";
  }

  function renderOnboarding() {
    const layer = $("#onboarding-layer");
    if (state.onboardingDone || !state.onboardingOpen) {
      layer.innerHTML = "";
      return;
    }
    const steps = obSteps();
    const list = steps
      .map((s, i) => {
        const cls = s.id === state.ob.step ? "current" : state.ob.skipped[s.id] ? "skipped" : state.ob.done[s.id] ? "done" : "";
        const mark = cls === "done" ? "✓" : cls === "skipped" ? "–" : i + 1;
        return '<li class="' + cls + '"' + (state.ob.visited[s.id] ? ' data-action="ob-go" data-step="' + s.id + '" style="cursor:pointer"' : "") + '><span class="dot">' + mark + "</span>" + s.title + (s.required ? "" : '<span class="small muted">（可选）</span>') + "</li>";
      })
      .join("");
    const body =
      '<div class="ob-body"><ol class="ob-steps" aria-label="引导步骤">' + list + '</ol><div class="ob-content" data-step="' + state.ob.step + '">' + obStepContent(state.ob.step) + "</div></div>" + obFooter(state.ob.step);
    layer.innerHTML = windowChrome("欢迎使用闪说", body, "ob-window", "close-onboarding");
  }

  // ---------- 设置 ----------
  function sw(id, action, checked, label, disabled) {
    return '<label class="switch"><input type="checkbox" id="' + id + '" data-change="' + action + '"' + (checked ? " checked" : "") + (disabled ? " disabled" : "") + ' aria-label="' + esc(label) + '"><span></span></label>';
  }

  function settingsGeneral() {
    const conflict = obConflict();
    return (
      "<h3>通用</h3>" +
      '<div class="group">' +
      '<div class="item"><span class="label"><strong>快捷键</strong><span>' + (copyOnly() ? "未开启辅助功能：只能使用组合键 ⌃⇧ Space。" : "按住说话，松开结束。当前只支持按住式。") + "</span></span>" + hotkeyOptions("set-hotkey") + "</div>" +
      (conflict ? '<div class="item"><span class="label"><strong style="color:var(--warning)">快捷键冲突</strong><span>' + esc(conflict) + '</span></span><button type="button" class="btn" data-action="open-sys-keyboard">打开键盘设置</button></div>' : "") +
      '<div class="item"><span class="label"><strong>录音提示</strong><span>录音胶囊和菜单栏录音状态始终显示，不能关闭。</span></span><span class="tag ok">始终显示</span></div>' +
      '<div class="item"><span class="label"><strong>提示音</strong><span>开始和结束录音时播放轻提示音。</span></span>' + sw("set-sound", "toggle-sound", state.soundEnabled, "提示音") + "</div>" +
      '<div class="item"><span class="label"><strong>输入设备</strong></span><select id="set-device" data-change="set-input-device"><option value="builtin"' + (state.inputDevice === "builtin" ? " selected" : "") + '>MacBook 内建麦克风</option><option value="airpods"' + (state.inputDevice === "airpods" ? " selected" : "") + ">AirPods Pro</option></select></div>" +
      "</div>" +
      "<h3>权限</h3>" +
      '<div class="group">' +
      '<div class="item"><span class="label"><strong>麦克风</strong><span>按住快捷键时录音。</span></span>' + (state.perms.mic === "granted" ? '<span class="tag ok">已允许</span>' : '<button type="button" class="btn primary" data-action="open-sys-mic">打开系统设置</button>') + "</div>" +
      '<div class="item"><span class="label"><strong>辅助功能</strong><span>' + (copyOnly() ? "未授权：快捷键只能用 ⌃⇧ Space，结果复制到剪贴板需要按 ⌘V 粘贴，不会自动学习专有词。" : "已授权：fn / 右 Option 快捷键、直接插入、从你的修改中学习专有词。") + "</span></span>" + (copyOnly() ? '<button type="button" class="btn primary" data-action="open-sys-accessibility">开启</button>' : '<span class="tag ok">已允许</span>') + "</div>" +
      "</div>"
    );
  }

  function settingsModel() {
    const tag = (id) => {
      if (id !== state.model.id) return state.model.downloaded && state.model.downloaded[id] ? '<span class="tag">已下载</span>' : '<span class="tag">未下载</span>';
      const s = state.model.status;
      if (s === "ready") return '<span class="tag ok">使用中</span>';
      if (s === "downloading") return '<span class="tag">下载中 ' + state.model.progress + "%</span>";
      if (s === "failed") return '<span class="tag bad">下载失败</span>';
      if (s === "paused") return '<span class="tag warn">已暂停</span>';
      return '<span class="tag warn">需要下载</span>';
    };
    return (
      "<h3>语音模型</h3>" +
      '<p class="small muted" style="margin:0">识别完全在本机运行，音频不会上传。</p>' +
      '<div class="group">' +
      Object.values(D.MODELS)
        .map(
          (m) =>
            '<label class="item" style="cursor:pointer"><span class="label"><strong>' + esc(m.name) + " " + tag(m.id) + "</strong><span>" + esc(m.note) + " · " + m.size + '</span></span><input type="radio" name="set-model" id="set-model-' + m.id + '" value="' + m.id + '" data-change="select-model"' + (state.model.id === m.id ? " checked" : "") + (state.model.status === "downloading" ? " disabled" : "") + "></label>"
        )
        .join("") +
      "</div>" +
      modelPanel() +
      '<div class="group">' +
      '<div class="item"><span class="label"><strong>下载来源</strong><span>Hugging Face 不可用时可切换到国内镜像。</span></span><select id="set-source" data-change="set-source"><option value="huggingface"' + (state.model.source === "huggingface" ? " selected" : "") + '>Hugging Face</option><option value="modelscope"' + (state.model.source === "modelscope" ? " selected" : "") + ">ModelScope 镜像</option></select></div>" +
      (state.model.status === "ready" ? '<div class="item"><span class="label"><strong>删除模型文件</strong><span>释放磁盘空间；删除后需要重新下载才能使用。</span></span><button type="button" class="btn danger" data-action="delete-model">删除</button></div>' : "") +
      "</div>"
    );
  }

  function settingsPolish() {
    const l = state.llm;
    let keyBlock;
    if (l.keyValid && !l.editingKey) {
      keyBlock = '<div class="item"><span class="label"><strong>OpenRouter API Key</strong><span>sk-or-…' + esc(l.keyLast4) + ' · 保存在系统钥匙串</span></span><div class="row"><button type="button" class="btn" data-action="llm-edit-key">更换</button><button type="button" class="btn danger" data-action="llm-delete-key">删除</button></div></div>';
    } else {
      keyBlock = '<div class="item" style="display:block">' + keyField("set-key") + "</div>";
    }
    return (
      "<h3>智能整理</h3>" +
      '<div class="group">' +
      '<div class="item"><span class="label"><strong>开启智能整理</strong><span>识别出的文字会发送到你配置的 OpenRouter 模型，整理成书面文本。音频不会上传。</span></span>' + sw("set-llm", "llm-toggle", l.enabled, "开启智能整理") + "</div>" +
      (l.toggleError ? '<div class="item"><div class="callout bad" style="flex:1">' + esc(l.toggleError) + "</div></div>" : "") +
      (l.showDisclosure ? '<div class="item" style="display:block"><div class="stack">' + dataFlow() + '<div class="callout warn">开启后，识别出的文字和相关词典词条会发送到 OpenRouter。始终要求零数据保留路由（只路由到承诺不保存请求内容的服务商）。</div><div class="row"><button type="button" class="btn primary" data-action="llm-accept-disclosure">我了解，继续</button></div></div></div>' : "") +
      keyBlock +
      '<div class="item"><span class="label"><strong>整理模型</strong><span>默认模型由 plan 阶段评测确定。</span></span>' + llmModelSelect("set-llm-model") + "</div>" +
      '<div class="item"><span class="label"><strong>零数据保留</strong><span>只路由到承诺不保存请求内容的服务商，不能关闭。</span></span><span class="tag ok">始终开启</span></div>' +
      "</div>" +
      '<div class="callout small">整理规则：去口头禅、保留改口后的说法、补标点和分段、口述序号转编号列表、数字规范化。不增删事实，不回答或执行你说的内容。整理失败或 5 秒内未返回时，插入本地识别的原文。</div>'
    );
  }

  function variantsCell(e) {
    const confirmed = e.variants.map(esc);
    const pending = (e.pendingVariants || []).map((v) => '<span class="muted" title="同样的改正再出现 1 次后，识别成这个写法时会自动替换">' + esc(v) + "（再改正 1 次后自动替换）</span>");
    const all = confirmed.concat(pending);
    return all.length ? all.join("、") : '<span class="muted">—</span>';
  }

  function settingsDictionary() {
    const f = state.dictForm;
    const rows = state.dict.length
      ? state.dict
          .map(
            (e) =>
              "<tr><td><strong>" + esc(e.term) + "</strong>" + (e.note ? '<div class="small muted">' + esc(e.note) + "</div>" : "") + "</td><td>" + variantsCell(e) + "</td><td>" + ({ manual: "手动", auto: '<span class="tag">自动学习</span>', import: "导入" }[e.source] || "手动") + "</td><td>" + e.hits + '</td><td><button type="button" class="btn link" data-action="dict-delete" data-id="' + e.id + '" aria-label="删除 ' + esc(e.term) + '">删除</button></td></tr>'
          )
          .join("")
      : '<tr><td colspan="5" class="empty">词典是空的。添加你常说的人名、产品名或术语；你在插入后改正过的专有词也会自动出现在这里。</td></tr>';
    const L = state.learning;
    const learningBlock =
      '<div class="group"><div class="item"><span class="label"><strong>从我的修改中自动学习</strong><span>' +
      (copyOnly()
        ? "需要辅助功能权限，仅复制模式下不可用。"
        : "插入后，如果你把刚插入文字里的专有词改对了，闪说会记住正确写法，不弹窗打扰。只比较刚插入的那一段，比较完即丢弃。") +
      "</span></span>" + sw("set-learning", "learning-toggle", L.enabled && !copyOnly(), "从我的修改中自动学习", copyOnly()) + "</div>" +
      (L.ignored.length
        ? '<div class="item"><span class="label"><strong>不再自动学习的词</strong><span>你删除过的 ' + L.ignored.length + " 个自动学习词不会被再次学回：" + L.ignored.map(esc).join("、") + '</span></span><button type="button" class="btn" data-action="learning-clear-ignored">允许重新学习</button></div>'
        : "") +
      "</div>";
    return (
      "<h3>词典</h3>" +
      '<p class="small muted" style="margin:0">' + state.dict.length + " 条 · 至少支持 " + D.RULES.dictionaryMinCapacity + " 条，只保存在本机。词典在三处生效：识别前提示（Qwen3-ASR）、识别后替换误识别写法、智能整理时交给模型。</p>" +
      learningBlock +
      '<div class="group"><div class="item" style="display:block"><div class="stack">' +
      '<div class="row" style="align-items:flex-start">' +
      '<div class="field" style="flex:1"><label for="dict-term">正确写法</label><input id="dict-term" data-input="dictForm.term" value="' + esc(f.term) + '" placeholder="如：Codex"' + (f.error ? ' aria-invalid="true"' : "") + " /></div>" +
      '<div class="field" style="flex:1.4"><label for="dict-variants">常被识别成（可选）</label><input id="dict-variants" data-input="dictForm.variants" value="' + esc(f.variants) + '" placeholder="用逗号分隔，如：科德克斯" /></div>' +
      '<div class="field" style="flex:1"><label for="dict-note">备注（可选）</label><input id="dict-note" data-input="dictForm.note" value="' + esc(f.note) + '" /></div>' +
      "</div>" +
      (f.error ? '<div class="field"><span class="error" role="alert">' + esc(f.error) + "</span></div>" : "") +
      (f.added ? '<div class="callout ok small">已添加「' + esc(f.added) + "」" + (f.warning ? "。注意：" + esc(f.warning) : "") + "</div>" : "") +
      '<div class="row"><button type="button" class="btn primary" data-action="dict-add">添加词条</button></div>' +
      "</div></div></div>" +
      '<table class="list"><thead><tr><th>正确写法</th><th>误识别写法</th><th>来源</th><th>命中</th><th></th></tr></thead><tbody>' + rows + "</tbody></table>" +
      '<div class="group"><div class="item" style="display:block"><div class="stack">' +
      '<div class="field"><label for="dict-import">导入（TXT/CSV，每行：正确写法,误识别写法1|误识别写法2,备注）</label><textarea id="dict-import" rows="3" data-input="importText">' + esc(state.importText) + "</textarea></div>" +
      '<div class="row"><button type="button" class="btn" data-action="dict-import">导入</button><button type="button" class="btn" data-action="dict-export">导出 CSV</button>' + (state.importResult ? '<span class="small muted">' + esc(state.importResult) + "</span>" : "") + "</div>" +
      (state.exportText ? '<pre class="callout small" style="margin:0;white-space:pre-wrap">' + esc(state.exportText) + "</pre>" : "") +
      "</div></div></div>"
    );
  }

  function settingsHistory() {
    const actionTag = { insert: '<span class="tag ok">已插入</span>', copy: '<span class="tag warn">已复制</span>' };
    const items = state.history.length
      ? state.history
          .map((h) => {
            return (
              '<div class="history-item"><div class="row"><strong>' + esc(h.app) + '</strong><span class="small muted">' + relTime(h.at) + "</span>" + actionTag[h.action] +
              (h.polished ? '<span class="tag">已整理</span>' : "") +
              (h.fallbackReason ? '<span class="tag warn">整理失败：' + esc(h.fallbackReason) + "</span>" : "") +
              "</div>" +
              "<pre>" + esc(h.final) + "</pre>" +
              (h.polished && h.raw !== h.final ? '<div class="raw">识别原文：' + esc(h.raw) + "</div>" : "") +
              (h.hits && h.hits.length ? '<div class="raw">词典生效：' + h.hits.map(esc).join("、") + "</div>" : "") +
              '<div class="row"><button type="button" class="btn link" data-action="history-copy" data-id="' + h.id + '">复制</button><button type="button" class="btn link" data-action="history-delete" data-id="' + h.id + '">删除</button></div>' +
              "</div>"
            );
          })
          .join("")
      : '<div class="empty">' + (state.historyEnabled ? "暂无历史。" : "历史记录已关闭。") + "</div>";
    return (
      "<h3>历史</h3>" +
      '<div class="group"><div class="item"><span class="label"><strong>保存历史</strong><span>只保存文字，不保存音频。本机保存 ' + D.RULES.historyRetentionDays + ' 天，到期自动删除。</span></span><div class="row">' + sw("set-history", "history-toggle", state.historyEnabled, "保存历史") + '<button type="button" class="btn danger" data-action="history-clear"' + (state.history.length ? "" : " disabled") + ">清空</button></div></div></div>" +
      '<div class="group">' + items + "</div>"
    );
  }

  function settingsPrivacy() {
    const rows = [
      ["录音音频", "只在内存中，识别完成即丢弃", "不保存"],
      ["识别文字历史", "本机", D.RULES.historyRetentionDays + " 天，可关闭或清空"],
      ["个人词典（含自动学习的词）", "本机", "直到你删除"],
      ["自动学习时读到的文字", "只在内存中比较刚插入的那一段", state.learning.enabled && !copyOnly() ? "比较完即丢弃" : "未开启"],
      ["OpenRouter Key", "macOS 钥匙串", "直到你删除"],
      ["发送到云端的内容", llmActive() ? "OpenRouter：文字和相关词条" : "无（智能整理未开启）", llmActive() ? "要求零数据保留" : "—"],
      ["使用统计与遥测", "不收集", "—"],
    ];
    return (
      "<h3>隐私与数据</h3>" +
      '<p class="small muted" style="margin:0">首发没有账户，也没有遥测。下表是闪说保存或发送的全部数据。</p>' +
      '<table class="list"><thead><tr><th>数据</th><th>位置</th><th>保留</th></tr></thead><tbody>' +
      rows.map((r) => "<tr><td>" + esc(r[0]) + "</td><td>" + esc(r[1]) + "</td><td>" + esc(r[2]) + "</td></tr>").join("") +
      "</tbody></table>"
    );
  }

  function renderSettings() {
    const layer = $("#settings-layer");
    if (!state.settingsOpen) {
      layer.innerHTML = "";
      return;
    }
    const tabs = [
      ["general", "通用"],
      ["model", "语音模型"],
      ["polish", "智能整理"],
      ["dictionary", "词典"],
      ["history", "历史"],
      ["privacy", "隐私与数据"],
    ];
    const content = {
      general: settingsGeneral,
      model: settingsModel,
      polish: settingsPolish,
      dictionary: settingsDictionary,
      history: settingsHistory,
      privacy: settingsPrivacy,
    }[state.settingsTab]();
    const body =
      '<div class="settings-body"><nav class="settings-nav" aria-label="设置分类">' +
      tabs.map(([id, label]) => '<button type="button" data-action="settings-tab" data-tab="' + id + '"' + (state.settingsTab === id ? ' aria-current="page"' : "") + ">" + label + "</button>").join("") +
      '</nav><div class="settings-content" data-tab="' + state.settingsTab + '">' + content + "</div></div>";
    layer.innerHTML = windowChrome("闪说 设置", body, "settings-window", "close-settings");
  }

  // ---------- 演示设置面板（不属于产品界面） ----------
  const SCENARIO_NOTES = [
    ["SCN-001", "首次引导走完", "场景「新用户」，按步骤授权、下载模型、试快捷键、练习后点「开始使用」"],
    ["SCN-002", "拒绝麦克风后恢复", "麦克风步骤点「不允许」→「打开系统设置」→ 打开开关，自动检测并返回"],
    ["SCN-003", "跳过辅助功能 → 仅复制模式", "辅助功能步骤点「稍后再说」→ 快捷键变为 ⌃⇧ Space；完成后说话，结果进剪贴板"],
    ["SCN-004", "模型下载中断与恢复", "勾选「模型下载中途断网」后下载 → 40% 中断 → 重试或切换镜像"],
    ["SCN-005", "🌐 键冲突修复", "快捷键步骤按住键会弹出表情面板 → 打开键盘设置改为「不执行任何操作」或改用右 Option"],
    ["SCN-006", "按住说话插入备忘录", "场景「已完成引导 · 本地模式」，点击备忘录正文后按住快捷键"],
    ["SCN-007", "误触、取消、静音", "快速点一下键；按住时按 Esc；选择「没有说话」后按住"],
    ["SCN-008", "处理期间切换焦点", "勾选「处理期间切换焦点」后说话 → 不插入，复制到剪贴板"],
    ["SCN-009", "密码框中不支持语音", "前台应用选「Safari · 登录页」后按住快捷键 → 不录音，提示密码框中不支持语音输入"],
    ["SCN-010", "3 分钟上限", "按住时点「录音快进到 2:45」，看倒计时后自动结束"],
    ["SCN-011", "权限撤销与模型缺失", "系统权限把麦克风改为未允许，或设置里删除模型，再按住快捷键 → 修复卡片"],
    ["SCN-012", "暂停语音输入", "菜单栏 → 暂停 1 小时 → 按住快捷键 → 胶囊提示已暂停，可直接恢复"],
    ["SCN-013", "开启智能整理", "设置 › 智能整理 → 数据流说明 → 填写并测试 Key → 开启"],
    ["SCN-014", "列表、改口与指令", "场景「已开启智能整理」，分别选择序号列表、句中列表、口头禅与改口、指令注入"],
    ["SCN-015", "整理失败回退原文", "把智能整理结果改为超时/网络/Key 无效/额度不足后说话"],
    ["SCN-016", "专有词生效", "场景「本地模式」，说「专有词」→ 识别错；词典添加 Codex 后再说 → 识别前提示修正"],
    ["SCN-017", "静默学习专有词", "场景「本地模式」，说「新专有词」→ 插入后在备忘录里把「马纳斯」「李丽」改对（或点「模拟：改正刚插入的文字」）→ 切换前台应用或再说一次 → 词典出现两条「自动学习」，没有弹窗；再说一次就写对"],
    ["SCN-020", "不该学的修改不学", "把插入的「周三」改成「周四」，或整句改写 → 事件日志显示未学习及原因；删除自动学习词后同样的改正不再学回"],
    ["SCN-018", "导入导出与冲突", "设置 › 词典 → 导入示例文本 → 查看新增/跳过/冲突计数 → 导出 CSV"],
    ["SCN-019", "历史保留 7 天", "点两次「时间快进 3 天」，超过 7 天的历史被清理"],
  ];

  function demoSelect(field, options, value) {
    return '<select id="demo-' + field + '" data-change="demo-field" data-field="' + field + '">' + options.map(([v, l]) => '<option value="' + v + '"' + (value === v ? " selected" : "") + ">" + esc(l) + "</option>").join("") + "</select>";
  }

  function demoCheck(field, label) {
    return '<label class="opt"><input type="checkbox" id="demo-' + field + '" data-change="demo-field" data-field="' + field + '"' + (state.demo[field] ? " checked" : "") + " />" + esc(label) + "</label>";
  }

  function permSelect(perm, values) {
    return '<label class="opt" style="justify-content:space-between">' + permName(perm) + '<select style="width:150px" id="demo-perm-' + perm + '" data-change="demo-perm" data-perm="' + perm + '">' + values.map((v) => '<option value="' + v + '"' + (state.perms[perm] === v ? " selected" : "") + ">" + permStateName(v) + "</option>").join("") + "</select></label>";
  }

  function renderDemo() {
    const tabs =
      '<div class="demo-tabs" role="tablist">' +
      '<button type="button" role="tab" data-action="demo-tab" data-tab="controls" aria-selected="' + (state.demo.tab === "controls") + '">演示控制</button>' +
      '<button type="button" role="tab" data-action="demo-tab" data-tab="notes" aria-selected="' + (state.demo.tab === "notes") + '">原型说明</button>' +
      "</div>";
    let body;
    if (state.demo.tab === "notes") {
      body =
        '<div class="notes">' +
        "<p>v0.3 · 覆盖 REQ-001～003 的首发体验。所有系统弹窗、权限、模型、OpenRouter 和剪贴板都是本地模拟；状态只在内存中，刷新页面会重置。</p>" +
        "<h3>验收场景</h3><ul>" +
        SCENARIO_NOTES.map((s) => "<li><strong>" + s[0] + " " + esc(s[1]) + "</strong>：" + esc(s[2]) + "</li>").join("") +
        "</ul>" +
        "<h3>不代表的东西</h3><ul>" +
        "<li>识别结果是按预设句子模拟的，不代表模型真实准确率或延迟。</li>" +
        "<li>浏览器无法捕获 fn 键，用屏幕上的按键或 <code>`</code> / 右 Option 代替。</li>" +
        "<li>自动学习判断读音是否相近时，原型只用一张覆盖演示句子的小拼音表；生产实现使用完整拼音库。</li>" +
        "<li>原型里自动学习的观察时长为真实的 2 分钟；用「模拟：离开输入框」可以立刻结束。</li>" +
        "<li>整理模型选项是示例，默认模型由 plan 阶段评测确定。</li>" +
        "</ul></div>";
    } else {
      body =
        "<fieldset><legend>场景</legend>" +
        '<select id="demo-scenario" data-change="demo-scenario" aria-label="场景">' + Object.entries(SCENARIOS).map(([k, v]) => '<option value="' + k + '"' + (state.scenario === k ? " selected" : "") + ">" + v + "</option>").join("") + "</select>" +
        '<div class="row"><button type="button" class="btn" data-action="demo-reset">重置当前场景</button></div></fieldset>' +
        "<fieldset><legend>下一次按住时你会说</legend>" + demoSelect("utterance", D.UTTERANCES.map((u) => [u.id, u.label]), state.demo.utterance) + "</fieldset>" +
        "<fieldset><legend>前台应用（模拟切换应用）</legend>" +
        Object.values(D.TARGET_APPS).map((t) => '<label class="opt"><input type="radio" name="demo-target" id="demo-target-' + t.id + '" value="' + t.id + '" data-change="demo-target"' + (state.activeTarget === t.id ? " checked" : "") + " />" + esc(t.name) + "</label>").join("") +
        "</fieldset>" +
        "<fieldset><legend>外部结果模拟</legend>" +
        '<label class="opt" style="justify-content:space-between">智能整理结果' + demoSelect("llmResult", [["success", "成功"], ["timeout", "超时（5 秒，演示缩短）"], ["network", "网络不可用"], ["invalid-key", "Key 无效"], ["credits", "额度不足"]], state.demo.llmResult).replace("<select", '<select style="width:160px"') + "</label>" +
        '<label class="opt" style="justify-content:space-between">Key 测试结果' + demoSelect("keyTestResult", [["success", "通过"], ["invalid", "无效"]], state.demo.keyTestResult).replace("<select", '<select style="width:160px"') + "</label>" +
        demoCheck("downloadFails", "模型下载中途断网（一次）") +
        demoCheck("micAvailable", "麦克风设备可用") +
        demoCheck("micSilent", "麦克风无声") +
        demoCheck("indicatorAvailable", "录音提示可以显示") +
        demoCheck("switchFocus", "处理期间切换焦点") +
        "</fieldset>" +
        "<fieldset><legend>自动学习（模拟你在输入框里改字）</legend>" +
        '<p class="small muted" style="margin:0 0 6px">' + (state.observation ? "正在留意「" + esc(targetName(state.observation.targetId)) + "」中刚插入的 " + state.observation.inserted.length + " 个字。可以直接在输入框里改，也可以用下面的按钮。" : "当前没有在留意的文字。插入一段后才会开始。") + "</p>" +
        '<div class="row"><button type="button" class="btn" data-action="demo-correct"' + (state.observation ? "" : " disabled") + '>模拟：改正刚插入的文字</button><button type="button" class="btn" data-action="demo-leave-field"' + (state.observation ? "" : " disabled") + ">模拟：离开输入框</button></div>" +
        "</fieldset>" +
        "<fieldset><legend>系统设置（模拟）</legend>" +
        permSelect("mic", ["not-determined", "granted", "denied"]) +
        permSelect("accessibility", ["not-determined", "granted", "denied", "revoked"]) +
        '<label class="opt" style="justify-content:space-between">按下 🌐 键时<select style="width:150px" id="demo-globe" data-change="demo-globe">' + ["emoji", "dictation", "none"].map((v) => '<option value="' + v + '"' + (state.sys.globeKeyAction === v ? " selected" : "") + ">" + globeName(v) + "</option>").join("") + "</select></label>" +
        "</fieldset>" +
        "<fieldset><legend>时间</legend>" +
        '<div class="row"><button type="button" class="btn" data-action="demo-fast-forward">录音快进到 2:45</button><button type="button" class="btn" data-action="demo-age-history">时间快进 3 天</button></div>' +
        "</fieldset>" +
        '<fieldset><legend>剪贴板</legend><div class="clip" id="demo-clipboard">' + esc(state.clipboard) + "</div></fieldset>" +
        '<fieldset><legend>事件日志</legend><div class="log" id="demo-log">' + state.log.map((l) => "<div>" + esc(l) + "</div>").join("") + "</div></fieldset>";
    }
    $("#demo").innerHTML = "<h2>演示设置</h2><p class=\"demo-sub\">不属于产品界面，用于切换场景和模拟外部结果。</p>" + tabs + body;
  }

  // ---------- 总渲染（保留焦点与光标） ----------
  function captureFocus() {
    const el = document.activeElement;
    if (!el || !el.id || el === document.body) return null;
    const saved = { id: el.id };
    try {
      if (typeof el.selectionStart === "number") {
        saved.start = el.selectionStart;
        saved.end = el.selectionEnd;
      }
    } catch (e) {
      /* 部分输入类型不支持选区 */
    }
    return saved;
  }

  function restoreFocus(saved) {
    const target = focusAfterRender || saved;
    focusAfterRender = null;
    if (!target) return;
    const el = document.getElementById(target.id);
    if (!el || el === document.activeElement) return;
    el.focus({ preventScroll: true });
    try {
      if (typeof target.caret === "number") el.setSelectionRange(target.caret, target.caret);
      else if (typeof target.start === "number") el.setSelectionRange(target.start, target.end);
    } catch (e) {
      /* 忽略不支持选区的控件 */
    }
  }

  function render() {
    const saved = captureFocus();
    renderMenubar();
    renderMenu();
    renderTarget();
    renderSettings();
    renderOnboarding();
    renderRepair();
    renderPill();
    renderFnKey();
    renderOverlay();
    renderDemo();
    restoreFocus(saved);
  }

  // ---------- 事件 ----------
  function setPath(path, value) {
    const parts = path.split(".");
    let obj = state;
    for (let i = 0; i < parts.length - 1; i += 1) {
      obj = obj[parts[i]];
      if (!obj) return;
    }
    obj[parts[parts.length - 1]] = value;
  }

  document.addEventListener("click", (event) => {
    const el = event.target.closest("[data-action]");
    if (state.menuOpen && !event.target.closest("#menu") && !event.target.closest("#status-item")) {
      state.menuOpen = false;
      if (!el) render();
    }
    if (!el || el.tagName === "INPUT" || el.tagName === "SELECT") return;
    const action = actions[el.dataset.action];
    if (!action) return;
    if (el.disabled) return;
    action(el);
    render();
  });

  document.addEventListener("change", (event) => {
    const el = event.target.closest("[data-change]");
    if (!el) return;
    const action = actions[el.dataset.change];
    if (action) {
      action(el);
      render();
    }
  });

  document.addEventListener("input", (event) => {
    const el = event.target;
    if (el.dataset.input) {
      setPath(el.dataset.input, el.value);
      if (el.dataset.input === "importText") state.importResult = null;
      if (el.dataset.input.indexOf("dictForm") === 0) {
        state.dictForm.error = null;
        state.dictForm.added = null;
      }
      return;
    }
    if (el.dataset.targetInput) {
      const t = state.targets[el.dataset.targetInput];
      t.value = el.value;
      t.caret = el.selectionStart;
    }
  });

  ["keyup", "click", "select"].forEach((type) => {
    document.addEventListener(type, (event) => {
      const el = event.target;
      if (el && el.dataset && el.dataset.targetInput) {
        state.targets[el.dataset.targetInput].caret = el.selectionStart;
      }
    });
  });

  function isHotkeyEvent(event) {
    const h = activeHotkey();
    if (h === "combo") return event.code === "Space" && event.ctrlKey && event.shiftKey;
    return h === "fn" ? event.code === "Backquote" : event.code === "AltRight";
  }

  // 组合键：松开其中任意一个键都算结束
  function isHotkeyRelease(event) {
    if (activeHotkey() === "combo") return ["Space", "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight"].includes(event.code);
    return isHotkeyEvent(event);
  }

  document.addEventListener("keydown", (event) => {
    if (isHotkeyEvent(event)) {
      event.preventDefault();
      if (!event.repeat) startHold();
      return;
    }
    if (event.key === "Escape") {
      if (state.session && state.session.phase === "listening") {
        event.preventDefault();
        cancelRecording();
      } else if (state.overlay) {
        state.overlay = null;
        render();
      } else if (state.menuOpen) {
        state.menuOpen = false;
        render();
      }
    }
  });

  document.addEventListener("keyup", (event) => {
    if (isHotkeyRelease(event) && (holdStartedAt !== null || isHotkeyEvent(event))) {
      event.preventDefault();
      endHold();
    }
  });

  const fnKey = $("#fn-key");
  fnKey.addEventListener("mousedown", (event) => event.preventDefault());
  fnKey.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    try {
      fnKey.setPointerCapture(event.pointerId);
    } catch (e) {
      /* 部分环境不支持指针捕获 */
    }
    startHold();
  });
  ["pointerup", "pointercancel"].forEach((type) => fnKey.addEventListener(type, endHold));
  window.addEventListener("blur", endHold);

  // 麦克风测试音量条与时钟
  setInterval(() => {
    const meter = document.getElementById("ob-meter");
    if (meter) {
      meter.querySelectorAll("i").forEach((bar, i) => {
        const wave = state.demo.micSilent ? 4 : 18 + Math.abs(Math.sin(Date.now() / 260 + i / 2)) * 60 + Math.random() * 18;
        bar.style.height = Math.min(100, wave) + "%";
      });
    }
  }, 110);
  setInterval(renderMenubar, 30000);

  // 供浏览器调试与自动化检查使用
  window.__voicePrototype = {
    getState: () => state,
    reset: (scenario) => {
      resetScenario(scenario || "new-user");
      render();
    },
  };

  log("原型已加载：" + SCENARIOS[state.scenario]);
  render();
})();
