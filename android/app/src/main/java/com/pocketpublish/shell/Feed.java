package com.pocketpublish.shell;

import android.util.JsonReader;
import android.util.JsonToken;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.StringReader;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONArray;
import org.json.JSONObject;

final class Feed {
    private static final int MAX_BYTES = 128 * 1024;

    private Feed() {}

    static String fetch(String address) {
        HttpsURLConnection connection = null;
        try {
            URI uri = URI.create(address);
            if (!"https".equals(uri.getScheme()) || uri.getHost() == null
                || uri.getRawUserInfo() != null || uri.getRawFragment() != null) {
                return null;
            }
            connection = (HttpsURLConnection) uri.toURL().openConnection();
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8000);
            connection.setReadTimeout(8000);
            connection.setRequestProperty("Accept", "application/json");
            connection.setUseCaches(false);
            if (connection.getResponseCode() != 200 || connection.getContentLength() > MAX_BYTES) {
                return null;
            }
            try (InputStream stream = connection.getInputStream()) {
                return validate(read(stream));
            }
        } catch (Exception ignored) {
            return null;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    static String read(InputStream stream) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (bytes.size() + count > MAX_BYTES) {
                throw new IOException("Response exceeds limit");
            }
            bytes.write(buffer, 0, count);
        }
        return StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
    }

    private static String validate(String source) throws Exception {
        try (JsonReader reader = new JsonReader(new StringReader(source))) {
            JSONObject feed = new JSONObject();
            reader.beginObject();
            while (reader.hasNext()) {
                String name = reader.nextName();
                if (feed.has(name)) {
                    return null;
                }
                switch (name) {
                    case "title": feed.put(name, string(reader)); break;
                    case "items": feed.put(name, items(reader)); break;
                    default: return null;
                }
            }
            reader.endObject();
            return feed.length() == 2 && reader.peek() == JsonToken.END_DOCUMENT ? feed.toString() : null;
        }
    }

    private static JSONArray items(JsonReader reader) throws Exception {
        JSONArray items = new JSONArray();
        reader.beginArray();
        while (reader.hasNext()) {
            if (items.length() >= 100) {
                throw new IOException("Too many entries");
            }
            JSONObject item = new JSONObject();
            reader.beginObject();
            while (reader.hasNext()) {
                String name = reader.nextName();
                if (item.has(name) || (!"title".equals(name) && !"body".equals(name))) {
                    throw new IOException("Invalid entry");
                }
                item.put(name, string(reader));
            }
            reader.endObject();
            if (item.length() != 2) {
                throw new IOException("Invalid entry");
            }
            items.put(item);
        }
        reader.endArray();
        return items;
    }

    private static String string(JsonReader reader) throws IOException {
        if (reader.peek() != JsonToken.STRING) {
            throw new IOException("Expected a string");
        }
        return reader.nextString();
    }
}
