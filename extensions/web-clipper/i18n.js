// SPDX-License-Identifier: MIT

(() => {
  if (globalThis.CodingRewindI18n) return;

  const SUPPORTED_UI_LANGUAGES = Object.freeze(["auto", "zh-CN", "en"]);

  const MESSAGES = Object.freeze({
    "zh-CN": Object.freeze({
      toastSaved: "片段已保存到 Memos",
      toastQueued: "片段已保存到本机，稍后将自动重试同步",
      toastUnconfigured: "片段已保存到本机，请检查 Memos 服务地址和访问令牌",
      toastSaveUnconfirmedError: "保存失败，未能确认片段已保存到 Memos 或本机",
      toastSaveRetryError: "保存失败，请重试",
      untitledSession: "未命名对话",
      contextMenuSaveSelection: "保存所选文本到 Coding Rewind",
      pillAriaLabel: "暂存选中文本",
      pillReady: "暂存",
      pillSaving: "暂存中…",
      pillSaved: "已同步",
      pillQueued: "待同步",
      optionsPageTitle: "Coding Rewind 网页扩展设置",
      optionsSubtitle: "网页扩展设置",
      connectionHeading: "Memos 连接",
      memosUrlLabel: "服务地址",
      memosUrlPlaceholder: "输入 Memos 服务地址",
      memosTokenLabel: "访问令牌",
      memosTokenPlaceholder: "输入 Memos 访问令牌",
      tokenHelp: "用于将片段保存到你的 Memos。",
      testConnectionBtn: "测试连接",
      preferencesHeading: "保存偏好",
      uiLanguageLabel: "界面语言",
      uiLanguageAuto: "跟随浏览器",
      showPillLabel: "选中文本时显示暂存胶囊",
      selectionHelp: "在 ChatGPT、Claude、Gemini 中，也可使用右键菜单、⌃⌥⇧⌘S（Hyper+S）或 Alt+Shift+S 暂存。",
      outboxCount: "待同步片段：{count} 条",
      flushBtn: "立即同步",
      saveBtn: "保存设置",
      connInvalidUrl: "请输入有效的 Memos 服务地址",
      connHttpFailed: "连接失败 (HTTP {status})",
      connSuccessReadOnly: "连接成功，可读取片段。尚未验证保存。",
      connNetworkError: "网络请求失败：{error}",
      statusInvalidProtocolUrl: "请输入以 http:// 或 https:// 开头的有效 Memos 服务地址",
      statusOriginPermissionDenied: "请允许扩展访问此服务地址，才能连接 Memos",
      statusSettingsSaved: "设置已保存",
      statusTestingConnection: "正在测试连接…",
      statusSyncingClips: "正在同步片段…",
      statusSyncSummary: "已同步 {flushed} 条片段，待同步 {remaining} 条",
      statusSyncFailed: "同步失败，请检查网络、服务地址和访问令牌"
    }),
    en: Object.freeze({
      toastSaved: "Clip saved to Memos",
      toastQueued: "Clip saved locally; will retry sync automatically",
      toastUnconfigured: "Clip saved locally; check Memos URL and access token",
      toastSaveUnconfirmedError: "Save failed; could not confirm clip was saved to Memos or locally",
      toastSaveRetryError: "Save failed, please try again",
      untitledSession: "Untitled Session",
      contextMenuSaveSelection: "Save selection to Coding Rewind",
      pillAriaLabel: "Stash selected text",
      pillReady: "Stash",
      pillSaving: "Saving…",
      pillSaved: "Synced",
      pillQueued: "Pending sync",
      optionsPageTitle: "Coding Rewind Web Clipper Settings",
      optionsSubtitle: "Web Clipper Settings",
      connectionHeading: "Memos Connection",
      memosUrlLabel: "Server URL",
      memosUrlPlaceholder: "Enter Memos server URL",
      memosTokenLabel: "Access Token",
      memosTokenPlaceholder: "Enter Memos access token",
      tokenHelp: "Used to save clips to your Memos instance.",
      testConnectionBtn: "Test Connection",
      preferencesHeading: "Preferences",
      uiLanguageLabel: "Language",
      uiLanguageAuto: "Follow Browser",
      showPillLabel: "Show stash pill when selecting text",
      selectionHelp: "In ChatGPT, Claude, and Gemini, you can also stash via the context menu, ⌃⌥⇧⌘S (Hyper+S), or Alt+Shift+S.",
      outboxCount: "Pending clips: {count}",
      flushBtn: "Sync Now",
      saveBtn: "Save Settings",
      connInvalidUrl: "Please enter a valid Memos server URL",
      connHttpFailed: "Connection failed (HTTP {status})",
      connSuccessReadOnly: "Connected; clips can be read. Saving has not been verified yet.",
      connNetworkError: "Network request failed: {error}",
      statusInvalidProtocolUrl: "Please enter a valid Memos server URL starting with http:// or https://",
      statusOriginPermissionDenied: "Please allow the extension to access this server URL to connect to Memos",
      statusSettingsSaved: "Settings saved",
      statusTestingConnection: "Testing connection…",
      statusSyncingClips: "Syncing clips…",
      statusSyncSummary: "Synced {flushed} clips; {remaining} pending",
      statusSyncFailed: "Sync failed; check your network, server URL, and access token"
    })
  });

  function detectBrowserLanguage() {
    const chromeLang = globalThis.chrome?.i18n?.getUILanguage?.();
    if (typeof chromeLang === "string" && chromeLang.trim().length > 0) {
      return chromeLang.trim();
    }
    const navLang = globalThis.navigator?.language;
    if (typeof navLang === "string" && navLang.trim().length > 0) {
      return navLang.trim();
    }
    return undefined;
  }

  function resolveLocale(preferredLanguage = "auto", browserLanguage = detectBrowserLanguage()) {
    const pref = typeof preferredLanguage === "string" ? preferredLanguage.trim().toLowerCase() : "auto";
    if (pref === "zh-cn" || pref === "zh-hans" || pref === "zh") {
      return "zh-CN";
    }
    if (pref === "en" || pref.startsWith("en-")) {
      return "en";
    }
    const effectiveBrowserLanguage =
      browserLanguage === undefined || browserLanguage === null
        ? detectBrowserLanguage()
        : browserLanguage;
    if (typeof effectiveBrowserLanguage === "string" && effectiveBrowserLanguage.trim().length > 0) {
      return /^zh(?:$|[-_])/i.test(effectiveBrowserLanguage.trim()) ? "zh-CN" : "en";
    }
    return "zh-CN";
  }

  function t(locale, key, params = undefined) {
    const resolved = locale === "en" || locale === "zh-CN" ? locale : resolveLocale(locale);
    const catalog = MESSAGES[resolved] || MESSAGES["zh-CN"];
    const template = Object.prototype.hasOwnProperty.call(catalog, key)
      ? catalog[key]
      : MESSAGES["zh-CN"][key] ?? String(key);
    if (!params || typeof params !== "object") {
      return template;
    }
    return template.replace(/\{(\w+)\}/g, (match, token) =>
      Object.prototype.hasOwnProperty.call(params, token) && params[token] !== undefined
        ? String(params[token])
        : match
    );
  }

  function createTranslator(options = {}) {
    const preferredLanguage = typeof options === "string" ? options : options?.preferredLanguage;
    const browserLanguage = typeof options === "string" ? undefined : options?.browserLanguage;
    const locale = resolveLocale(preferredLanguage, browserLanguage);
    const translate = (key, params) => t(locale, key, params);
    translate.locale = locale;
    translate.t = translate;
    return Object.freeze(translate);
  }

  globalThis.CodingRewindI18n = Object.freeze({
    SUPPORTED_UI_LANGUAGES,
    MESSAGES,
    detectBrowserLanguage,
    resolveLocale,
    t,
    createTranslator
  });
})();
