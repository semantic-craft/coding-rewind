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
      contextMenuSavePageLink: "保存此网页链接到 Coding Rewind",
      pillAriaLabel: "暂存选中文本",
      pillReady: "暂存",
      pillSaving: "暂存中…",
      pillSaved: "已同步",
      pillQueued: "待同步",
      optionsPageTitle: "Coding Rewind 网页扩展设置",
      optionsSubtitle: "网页扩展设置",
      connectionHeading: "云端同步",
      cloudSyncIntroLine1: "不配置也能使用桌面端本地暂存和 Antigravity / Codex 对话，网页剪藏需要自托管 Memos。",
      cloudSyncIntroLine2: "配置自托管 Memos 服务后，可开启跨设备同步与 AI 自动摘要。",
      deployGuideLink: "查看部署指南 ↗",
      memosUrlLabel: "服务地址",
      memosUrlPlaceholder: "输入 Memos 服务地址",
      openConsoleBtn: "打开后台拿令牌 ↗",
      memosTokenLabel: "访问令牌",
      memosTokenPlaceholder: "请输入访问令牌",
      memosTokenSavedPlaceholder: "已保存，留空则保留现有令牌",
      tokenHelp: "用于将片段保存到你的 Memos。",
      testConnectionBtn: "测试连接",
      preferencesHeading: "保存偏好",
      uiLanguageLabel: "界面语言",
      uiLanguageAuto: "跟随浏览器",
      pillScopeLabel: "暂存胶囊",
      pillScopeOptionAll: "所有网页选中文本时显示",
      pillScopeOptionChat: "仅在 ChatGPT / Claude / Gemini 显示",
      pillScopeOptionOff: "关闭（仅使用快捷键与右键菜单）",
      pillScopeHelp: "在选区附近弹出 26px 暂存胶囊；⌃⌥⇧⌘S（Hyper+S）、Alt+Shift+S 与右键菜单在任意网页始终可用。",
      excludedDomainsLabel: "排除域名",
      excludedDomainsPlaceholder: "docs.google.com\nfigma.com\ncanva.com",
      excludedDomainsHelp: "每行一个域名，这些网站及其子域名不自动弹出划词胶囊，快捷键与右键菜单仍可使用。",
      outboxCount: "待同步片段：{count} 条",
      flushBtn: "立即同步",
      saveBtn: "保存设置",
      connInvalidUrl: "请输入有效的 Memos 服务地址",
      connHttpFailed: "连接失败 (HTTP {status})",
      connSuccessReadOnly: "连接成功，可读取片段。尚未验证保存。",
      connUnexpectedResponse: "服务返回的不是有效的 Memos 接口响应，请确认服务地址",
      connNetworkError: "网络请求失败：{error}",
      statusInvalidProtocolUrl: "请输入 https:// 开头的 Memos 服务地址（本机调试可使用 http://localhost 或 127.0.0.1）",
      statusOriginPermissionDenied: "请允许扩展访问此服务地址，才能连接 Memos",
      statusSettingsSaved: "设置已保存",
      statusSavingAndVerifying: "正在保存并验证连接…",
      statusSavedLocalOnly: "设置已保存。未填写服务地址，云端同步未启用。",
      statusSavedMissingToken: "设置已保存。缺少访问令牌，尚未验证连接。",
      statusSavedAndConnected: "设置已保存，连接成功，可读取片段。",
      statusSavedConnectionFailed: "设置已保存，但连接验证失败。{detail}",
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
      contextMenuSavePageLink: "Save page link to Coding Rewind",
      pillAriaLabel: "Stash selected text",
      pillReady: "Stash",
      pillSaving: "Saving…",
      pillSaved: "Synced",
      pillQueued: "Pending sync",
      optionsPageTitle: "Coding Rewind Web Clipper Settings",
      optionsSubtitle: "Web Clipper Settings",
      connectionHeading: "Cloud Sync",
      cloudSyncIntroLine1: "Desktop local stashing and Antigravity / Codex chats work without setup; web clipping requires Memos.",
      cloudSyncIntroLine2: "Connect a self-hosted Memos server to enable cross-device sync and automatic AI summaries.",
      deployGuideLink: "Deployment Guide ↗",
      memosUrlLabel: "Server URL",
      memosUrlPlaceholder: "Enter Memos server URL",
      openConsoleBtn: "Get Token ↗",
      memosTokenLabel: "Access Token",
      memosTokenPlaceholder: "Enter access token",
      memosTokenSavedPlaceholder: "Saved; leave blank to keep existing token",
      tokenHelp: "Used to save clips to your Memos instance.",
      testConnectionBtn: "Test Connection",
      preferencesHeading: "Preferences",
      uiLanguageLabel: "Language",
      uiLanguageAuto: "Follow Browser",
      pillScopeLabel: "Stash Pill",
      pillScopeOptionAll: "Show on all websites when selecting text",
      pillScopeOptionChat: "Only in ChatGPT, Claude, and Gemini",
      pillScopeOptionOff: "Off (shortcut and context menu only)",
      pillScopeHelp: "Shows a 26px stash pill near selections; ⌃⌥⇧⌘S (Hyper+S), Alt+Shift+S, and the context menu remain active on all pages.",
      excludedDomainsLabel: "Excluded Domains",
      excludedDomainsPlaceholder: "docs.google.com\nfigma.com\ncanva.com",
      excludedDomainsHelp: "One domain per line. Hides the automatic pill on these hosts and their subdomains while keeping shortcuts and the context menu active.",
      outboxCount: "Pending clips: {count}",
      flushBtn: "Sync Now",
      saveBtn: "Save Settings",
      connInvalidUrl: "Please enter a valid Memos server URL",
      connHttpFailed: "Connection failed (HTTP {status})",
      connSuccessReadOnly: "Connected; clips can be read. Saving has not been verified yet.",
      connUnexpectedResponse: "Server did not return a valid Memos API response; verify the server URL",
      connNetworkError: "Network request failed: {error}",
      statusInvalidProtocolUrl: "Please enter an https:// Memos server URL (http:// is allowed only for localhost / 127.0.0.1)",
      statusOriginPermissionDenied: "Please allow the extension to access this server URL to connect to Memos",
      statusSettingsSaved: "Settings saved",
      statusSavingAndVerifying: "Saving and verifying connection…",
      statusSavedLocalOnly: "Settings saved. Server URL is empty, so cloud sync is disabled.",
      statusSavedMissingToken: "Settings saved. Access token is missing, so connection was not verified.",
      statusSavedAndConnected: "Settings saved. Connected; clips can be read.",
      statusSavedConnectionFailed: "Settings saved, but connection verification failed. {detail}",
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
