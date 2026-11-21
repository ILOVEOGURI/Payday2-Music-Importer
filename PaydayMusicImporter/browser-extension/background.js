const IMPORT_ENDPOINT = "http://127.0.0.1:18921/import";
const YOUTUBE_HOME = "https://www.youtube.com/";
const pendingTabs = new Map();

function getWatchPage(rawUrl) {
  try {
    const url = new URL(rawUrl);
    const allowedHosts = new Set([
      "youtube.com",
      "www.youtube.com",
      "m.youtube.com",
      "music.youtube.com"
    ]);
    const videoId = url.searchParams.get("v");
    if (url.protocol !== "https:" || !allowedHosts.has(url.hostname) || url.pathname !== "/watch" || !videoId || !/^[A-Za-z0-9_-]{6,}$/.test(videoId)) {
      return null;
    }
    return { id: videoId, url: url.href };
  } catch (_) {
    return null;
  }
}

async function queueSelectedVideo(tabId, rawUrl) {
  const initial = getWatchPage(rawUrl);
  if (!initial || pendingTabs.get(tabId) === initial.id) {
    return;
  }
  pendingTabs.set(tabId, initial.id);

  try {
    // YouTube updates the title after its single-page route has loaded.
    let tab = null;
    let current = null;
    let title = "";
    for (let attempt = 0; attempt < 8; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      tab = await chrome.tabs.get(tabId);
      current = getWatchPage(tab.url || "");
      if (!current || current.id !== initial.id) {
        return;
      }
      title = (tab.title || "").replace(/\s+-\s+YouTube$/i, "").trim();
      if (title && title.toLowerCase() !== "youtube" && title !== current.id) {
        break;
      }
    }

    if (!title || title.toLowerCase() === "youtube" || title === current.id) {
      try {
        const results = await chrome.scripting.executeScript({
          target: { tabId },
          func: () => {
            const candidates = [
              document.querySelector("ytd-watch-metadata h1")?.innerText,
              document.querySelector("h1.ytd-watch-metadata")?.innerText,
              document.querySelector('meta[property="og:title"]')?.content,
              document.querySelector('meta[name="title"]')?.content,
              document.title
            ];
            return candidates
              .map((value) => (value || "").trim())
              .find((value) => value && value.toLowerCase() !== "youtube") || "";
          }
        });
        title = results[0]?.result || title;
      } catch (error) {
        console.warn("PAYDAY 2 Music Importer could not read the YouTube page title:", error);
      }
    }

    const response = await fetch(IMPORT_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: encodeURIComponent(JSON.stringify({ url: current.url, title: title || current.id })),
      cache: "no-store",
      credentials: "omit"
    });
    const result = await response.json();
    if (!response.ok || !result.ok) {
      throw new Error(result.error || `Importer returned HTTP ${response.status}`);
    }

    await chrome.tabs.update(tabId, { url: YOUTUBE_HOME });
  } catch (error) {
    console.error("PAYDAY 2 Music Importer could not queue this video:", error);
  } finally {
    if (pendingTabs.get(tabId) === initial.id) {
      pendingTabs.delete(tabId);
    }
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const changedUrl = changeInfo.url || tab.url;
  if (changedUrl) {
    void queueSelectedVideo(tabId, changedUrl);
  }
});

chrome.webNavigation.onHistoryStateUpdated.addListener((details) => {
  if (details.frameId === 0) {
    void queueSelectedVideo(details.tabId, details.url);
  }
}, {
  url: [
    { hostEquals: "youtube.com", pathEquals: "/watch" },
    { hostEquals: "www.youtube.com", pathEquals: "/watch" },
    { hostEquals: "m.youtube.com", pathEquals: "/watch" },
    { hostEquals: "music.youtube.com", pathEquals: "/watch" }
  ]
});
