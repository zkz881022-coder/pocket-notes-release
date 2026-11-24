package com.pocketpublish.shell;

import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

public final class MainActivity extends Activity {
    private static final String HOST = "pocket.invalid";
    private static final String START_URL = "https://" + HOST + "/index.html";
    private static final int REFRESH_DELAY = 5 * 60 * 1000;
    private static final String POLICY =
        "default-src 'self'; script-src 'self' 'unsafe-inline'; "
        + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        + "font-src 'self' data:; connect-src 'self'; frame-src 'none'; "
        + "object-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'self'";
    private static final Map<String, String> ASSET_HEADERS;
    static {
        Map<String, String> headers = new HashMap<>();
        headers.put("Content-Security-Policy", POLICY);
        headers.put("X-Content-Type-Options", "nosniff");
        ASSET_HEADERS = Collections.unmodifiableMap(headers);
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Runnable refreshTick = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, REFRESH_DELAY);
        }
    };
    private WebView webView;
    private String feedUrl;
    private String latest;
    private boolean pageReady;
    private boolean loadingFeed;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        try (InputStream config = getAssets().open("mobile.json")) {
            feedUrl = new JSONObject(Feed.read(config)).getString("feedUrl");
        } catch (Exception ignored) {
            // The packaged page remains usable if feed configuration is unavailable.
        }
        latest = getPreferences(MODE_PRIVATE).getString("latestFeed", null);
        webView = new WebView(this);
        webView.getSettings().setJavaScriptEnabled(true);
        webView.getSettings().setDomStorageEnabled(true);
        webView.getSettings().setAllowFileAccess(false);
        webView.getSettings().setAllowContentAccess(false);
        webView.getSettings().setSupportMultipleWindows(false);
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return !request.isForMainFrame() || assetPath(request.getUrl()) == null;
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                String path = assetPath(request.getUrl());
                if (!"GET".equals(request.getMethod()) || path == null) {
                    return unavailable(403, "Forbidden");
                }
                try {
                    String mime = mimeType(path);
                    String encoding = mime.startsWith("text/") ? "UTF-8" : null;
                    return new WebResourceResponse(
                        mime, encoding, 200, "OK", ASSET_HEADERS,
                        getAssets().open("web/" + path)
                    );
                } catch (IOException error) {
                    return unavailable(404, "Not Found");
                }
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                pageReady = false;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                pageReady = assetPath(Uri.parse(url)) != null && url.equals(view.getUrl());
                showFeed();
            }
        });
        setContentView(webView);
        webView.loadUrl(START_URL);
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.removeCallbacks(refreshTick);
        refreshTick.run();
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(refreshTick);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        handler.removeCallbacksAndMessages(null);
        webView.destroy();
        super.onDestroy();
    }

    private void refresh() {
        if (feedUrl == null || loadingFeed) {
            return;
        }
        loadingFeed = true;
        executor.execute(() -> {
            String response = Feed.fetch(feedUrl);
            handler.post(() -> {
                loadingFeed = false;
                if (!isDestroyed() && response != null && !response.equals(latest)) {
                    latest = response;
                    getPreferences(MODE_PRIVATE).edit().putString("latestFeed", latest).apply();
                    showFeed();
                }
            });
        });
    }

    private void showFeed() {
        if (pageReady && latest != null) {
            String argument = JSONObject.quote(latest)
                .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029");
            webView.evaluateJavascript(
                "window.dispatchEvent(new CustomEvent('pocket-feed',{detail:JSON.parse(" + argument + ")}));",
                null
            );
        }
    }

    private static String assetPath(Uri uri) {
        if (!"https".equals(uri.getScheme()) || !HOST.equals(uri.getEncodedAuthority())) {
            return null;
        }
        String path = uri.getPath();
        if (path == null || path.isEmpty() || path.equals("/")) {
            return "index.html";
        }
        String[] parts = path.substring(1).split("/", -1);
        for (String part : parts) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")
                || part.indexOf('\\') >= 0 || part.indexOf(0) >= 0) {
                return null;
            }
        }
        return path.substring(1);
    }

    private static String mimeType(String path) {
        int dot = path.lastIndexOf('.');
        String suffix = dot < 0 ? "" : path.substring(dot + 1).toLowerCase(java.util.Locale.ROOT);
        switch (suffix) {
            case "html": return "text/html";
            case "css": return "text/css";
            case "js":
            case "mjs": return "application/javascript";
            case "json": return "application/json";
            case "wasm": return "application/wasm";
            case "svg": return "image/svg+xml";
            default:
                String mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(suffix);
                return mime == null ? "application/octet-stream" : mime;
        }
    }

    private static WebResourceResponse unavailable(int status, String reason) {
        return new WebResourceResponse(
            "text/plain", "UTF-8", status, reason, Collections.emptyMap(),
            new ByteArrayInputStream(reason.getBytes(StandardCharsets.UTF_8))
        );
    }
}
