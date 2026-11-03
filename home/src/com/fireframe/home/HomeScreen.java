package com.fireframe.home;

import android.animation.ObjectAnimator;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

// The whole home screen as one view. MainActivity shows it as an app; HomeService shows the same view
// as an overlay the instant Amazon's home screen opens, because Fire OS holds app launches back for
// 5 seconds after the Home button.
//
// BetterFireTV-Fassung von FireFrame (MIT, github.com/dyascj/FireFrame). Geändert:
//  - App-Kacheln in Farbe: das TV-Banner der App, sonst ihr Symbol auf einer Fläche in ihrer Farbe.
//  - Dock und ausgeblendete Apps lassen sich per adb setzen (applyExtras), die App-Liste steht in
//    Android/media/<paket>/apps.txt, damit der PC sie lesen kann.
//  - Eigene Hintergrundbilder aus Android/media/<paket>/wallpapers/ (adb kann dort schreiben).
//  - Deutsche Texte, kein Auto-Update, kein Internetzugriff.
// Kein Lambda im Code: gebaut wird mit dx, das keine Lambdas für Android umschreiben kann.
public class HomeScreen extends FrameLayout {
    // The dock when nothing is saved yet: these, in order, if installed, topped up to six with other apps.
    static final String[] DEFAULT_DOCK = {
        "com.netflix.ninja",
        "com.amazon.firebat", "com.amazon.avod.thirdpartyclient", "com.amazon.amazonvideo.livingroom",
        "org.smarttube.stable",
        "com.amazon.firetv.youtube", "com.google.android.youtube.tv",
        "com.disney.disneyplus",
        "com.apple.atve.amazon.appletv", "com.apple.atve.androidtv.appletv",
        "com.wbd.stream", "com.spotify.tv.android", "com.plexapp.android",
        "org.jellyfin.androidtv", "org.xbmc.kodi",
    };

    // Other home screens, helper apps and Fire OS internals that list themselves as apps never show up.
    static final Set<String> HIDDEN = new HashSet<>(Arrays.asList(
        HomeService.AMAZON_HOME, "com.google.android.tvlauncher", "com.google.android.apps.tv.launcherx",
        "com.google.android.leanbacklauncher",
        "com.amazon.ftv.profilepicker", "com.amazon.ftv.screensaver", "com.amazon.ssm",
        "com.amazon.vizzini.ftvcds", "com.android.providers.downloads.ui",
        "dnsfilter.android", "com.fireframe.home", "tv.dumbtv.home"));

    // Bundled wallpapers (assets/wallpapers) and the credit shown when one is picked.
    static final String[][] WALLPAPERS = {
        {"aurora", "Polarlicht über der Antarktis  ·  ISS Expedition 40, NASA"},
        {"citylights", "Stadtlichter unter Polarlicht  ·  ISS Expedition 58, NASA"},
        {"earthrise", "Erdaufgang  ·  Apollo 17, NASA"},
        {"southernlights", "Polarlicht über dem Südpazifik  ·  ISS Expedition 67, NASA"},
        {"sunrise", "Sonnenaufgang über dem Horizont  ·  ISS Expedition 40, NASA"},
    };
    static final String FILE = "file:"; // wallpaper keys for photos in the media folder

    // Design units: laid out at 1920x1080 and scaled to the real screen.
    static final int DOCK_TILE_W = 304, DRAWER_TILE_W = 262;

    final DecelerateInterpolator ease = new DecelerateInterpolator(2f);
    final List<ViewGroup> layers = new ArrayList<>();
    final Map<String, ActivityInfo> activities = new HashMap<>();
    final Map<String, Bitmap> art = new HashMap<>();      // banner or icon, per app
    final Map<String, Boolean> isBanner = new HashMap<>();
    final Map<String, Integer> artColor = new HashMap<>();

    SharedPreferences prefs;
    PackageManager pm;
    int screenW, screenH;
    float s;
    Typeface medium, semibold;
    FrameLayout root, base;
    ImageView wallView;
    GlassView glass;
    LinearLayout dockRow;
    TextView caption, clock;

    // TextClock stops ticking in an overlay window, so the time is kept here: updated on the minute.
    final Runnable tick = new Runnable() {
        @Override public void run() {
            clock.setText(android.text.format.DateFormat.format(
                    android.text.format.DateFormat.is24HourFormat(ctx) ? "H:mm" : "h:mm", new java.util.Date()));
            removeCallbacks(this);
            postDelayed(this, 60000 - System.currentTimeMillis() % 60000);
        }
    };
    Bitmap blur;
    List<String> dock = new ArrayList<>();
    boolean appsChanged;
    String shownWallpaper;
    static int dockVersion;
    static int lastDock; // the dock app last focused, in either copy
    int seenDockVersion = -1;
    static int photoVersion; // bumped when the PC sends new photos
    int seenPhotoVersion;

    // The wallpaper and its blur, shared by the app and the overlay so they're decoded once.
    static String cachedKey;
    static Bitmap cachedPhoto, cachedBlur;

    final BroadcastReceiver timeChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) { tick.run(); }
    };

    final BroadcastReceiver packagesChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            appsChanged = true;
            art.clear();
            isBanner.clear();
            artColor.clear();
            if (hasWindowFocus() && layers.isEmpty()) buildDock();
        }
    };

    final Context ctx;

    HomeScreen(Context c) {
        super(c);
        ctx = c;
        prefs = ctx.getSharedPreferences("fireframe", Context.MODE_PRIVATE);
        pm = ctx.getPackageManager();
        DisplayMetrics dm = new DisplayMetrics();
        ((WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(dm);
        screenW = Math.max(dm.widthPixels, dm.heightPixels);
        screenH = Math.min(dm.widthPixels, dm.heightPixels);
        s = screenW / 1920f;
        medium = Typeface.createFromAsset(ctx.getAssets(), "fonts/Inter-Medium.ttf");
        semibold = Typeface.createFromAsset(ctx.getAssets(), "fonts/Inter-SemiBold.ttf");

        root = this;
        root.setBackgroundColor(0xFF000000);
        wallView = new ImageView(ctx);
        wallView.setScaleType(ImageView.ScaleType.CENTER_CROP);
        root.addView(wallView, new FrameLayout.LayoutParams(-1, -1));
        View scrim = new View(ctx);
        scrim.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[] {0x66000000, 0}));
        root.addView(scrim, new FrameLayout.LayoutParams(-1, px(300)));

        base = new FrameLayout(ctx);
        root.addView(base, new FrameLayout.LayoutParams(-1, -1));

        clock = new TextView(ctx);
        style(clock, 66, medium);
        clock.setShadowLayer(px(16), 0, px(2), 0x40000000);
        base.addView(clock, at(140, 60, -2, -2));

        // Top right: wallpaper, all apps, settings.
        View first = addIcon("image", 1920 - 140 - 76 * 3 - 24 * 2, new View.OnClickListener() {
            @Override public void onClick(View v) { nextWallpaper(); }
        });
        addIcon("grid_view", 1920 - 140 - 76 * 2 - 24, new View.OnClickListener() {
            @Override public void onClick(View v) { openDrawer(v); }
        });
        View last = addIcon("settings", 1920 - 140 - 76, new View.OnClickListener() {
            @Override public void onClick(View v) { openSettingsMenu(v); }
        });
        // Left and Right stay in this row instead of dropping down to the dock.
        first.setNextFocusLeftId(first.getId());
        last.setNextFocusRightId(last.getId());

        caption = new TextView(ctx);
        style(caption, 22, medium);
        caption.setAlpha(0);
        caption.setShadowLayer(px(10), 0, px(1), 0x80000000);
        FrameLayout.LayoutParams clp = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.RIGHT);
        clp.topMargin = px(158);
        clp.rightMargin = px(140);
        base.addView(caption, clp);

        // The dock: a frosted glass bar, its apps scrolling sideways inside it.
        glass = new GlassView(ctx, 46, 0x2E000000);
        HorizontalScrollView scroller = new HorizontalScrollView(ctx);
        scroller.setHorizontalScrollBarEnabled(false);
        scroller.setOverScrollMode(View.OVER_SCROLL_NEVER);
        scroller.setPadding(px(22), px(20), px(22), px(14));
        scroller.setClipToPadding(false);
        dockRow = new LinearLayout(ctx);
        dockRow.setClipChildren(false); // focused tiles grow a little past the row
        scroller.setClipChildren(false);
        glass.setClipChildren(false);
        scroller.addView(dockRow, new FrameLayout.LayoutParams(-2, -1));
        glass.addView(scroller, new FrameLayout.LayoutParams(-1, -1));
        base.addView(glass, at(100, 652, 1720, 262));

        showWallpaper(wallpaperKey());
        buildDock();
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addDataScheme("package");
        ctx.registerReceiver(packagesChanged, f);
        IntentFilter time = new IntentFilter(Intent.ACTION_TIME_CHANGED); // the TV syncs its clock after boot
        time.addAction(Intent.ACTION_TIMEZONE_CHANGED);
        ctx.registerReceiver(timeChanged, time);
        tick.run();
    }

    @Override
    protected void onDetachedFromWindow() {
        ctx.unregisterReceiver(packagesChanged);
        ctx.unregisterReceiver(timeChanged);
        removeCallbacks(tick);
        super.onDetachedFromWindow();
    }

    // Settings sent from the PC (tool/betterfiretv.sh) with `am start ... --es/--ez`:
    //   dock      "pkg,pkg,..."  the dock, in order
    //   hide      "pkg,pkg,..."  apps left out of the dock and the app drawer ("" = none)
    //   wallpaper "file:name.jpg" or a bundled name
    //   builtins  true|false     show the bundled NASA photos next to your own
    //   reload    true           the photos in the media folder changed
    //   export    true           write the app list to the media folder now
    void applyExtras(Intent intent) {
        if (intent == null) return;
        SharedPreferences.Editor e = prefs.edit();
        boolean apps = false, photos = false;
        if (intent.hasExtra("dock")) { e.putString("dock", clean(intent.getStringExtra("dock"))); apps = true; }
        if (intent.hasExtra("hide")) { e.putString("hidden", clean(intent.getStringExtra("hide"))); apps = true; }
        if (intent.hasExtra("builtins")) { e.putBoolean("builtins", intent.getBooleanExtra("builtins", true)); photos = true; }
        if (intent.getBooleanExtra("reload", false)) photos = true;
        String w = intent.getStringExtra("wallpaper");
        if (w != null) { e.putString("wallpaper", w); photos = true; }
        e.commit();
        if (apps) { dockVersion++; appsChanged = true; }
        if (photos) { cachedKey = null; photoVersion++; }
        if (intent.getBooleanExtra("export", false) && !apps) exportApps(installed(true));
    }

    static String clean(String csv) {
        if (csv == null) return "";
        StringBuilder b = new StringBuilder();
        for (String p : csv.split(",")) {
            p = p.trim();
            if (p.isEmpty()) continue;
            if (b.length() > 0) b.append(',');
            b.append(p);
        }
        return b.toString();
    }

    // Called whenever this screen comes to the front: catch up on changes made by the other copy
    // (the app or the overlay), by the PC, or by installs and uninstalls. reset: Home was pressed,
    // so close any menus and go back to the dock.
    void onShown(boolean reset) {
        if (reset) while (!layers.isEmpty()) closeLayer();
        if (!wallpaperKey().equals(shownWallpaper) || seenPhotoVersion != photoVersion) showWallpaper(wallpaperKey());
        if ((appsChanged || seenDockVersion != dockVersion) && layers.isEmpty()) buildDock();
        if (!layers.isEmpty() || dockRow.getChildCount() == 0) return;
        View f = findFocus();
        // Both copies keep focus on the same dock app, so swapping one for the other can't be seen.
        if (reset || f == null || f.getParent() == dockRow) dockRow.getChildAt(Math.min(lastDock, dockRow.getChildCount() - 1)).requestFocus();
    }

    String wallpaperKey() {
        List<String> c = choices();
        String w = prefs.getString("wallpaper", c.get(0));
        return c.contains(w) ? w : c.get(0);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        if (e.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            if (e.getAction() == KeyEvent.ACTION_UP && !layers.isEmpty()) closeLayer();
            return true; // home screen: nothing behind it
        }
        return super.dispatchKeyEvent(e);
    }

    // ---- Apps ----

    Set<String> hiddenByUser() {
        Set<String> out = new HashSet<>();
        for (String p : prefs.getString("hidden", "").split(",")) if (!p.trim().isEmpty()) out.add(p.trim());
        return out;
    }

    // Every app that can be opened, by name. withHidden: also the ones the user hid.
    Map<String, String> installed(boolean withHidden) {
        final Map<String, String> labels = new HashMap<>();
        Set<String> hidden = withHidden ? new HashSet<String>() : hiddenByUser();
        for (String cat : new String[] {Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER}) {
            for (ResolveInfo r : pm.queryIntentActivities(new Intent(Intent.ACTION_MAIN).addCategory(cat), 0)) {
                String p = r.activityInfo.packageName;
                if (p.equals(ctx.getPackageName()) || HIDDEN.contains(p) || hidden.contains(p) || labels.containsKey(p)) continue;
                labels.put(p, r.activityInfo.applicationInfo.loadLabel(pm).toString());
                if (!activities.containsKey(p)) activities.put(p, r.activityInfo);
            }
        }
        List<String> names = new ArrayList<>(labels.keySet());
        Collections.sort(names, new Comparator<String>() {
            @Override public int compare(String a, String b) { return labels.get(a).compareToIgnoreCase(labels.get(b)); }
        });
        Map<String, String> sorted = new LinkedHashMap<>();
        for (String p : names) sorted.put(p, labels.get(p));
        return sorted;
    }

    Map<String, String> installed() { return installed(false); }

    List<String> dockApps(Map<String, String> apps) {
        List<String> out = new ArrayList<>();
        String saved = prefs.getString("dock", null);
        if (saved != null) {
            for (String p : saved.split(",")) if (apps.containsKey(p) && !out.contains(p)) out.add(p);
            return out;
        }
        for (String p : DEFAULT_DOCK) if (apps.containsKey(p) && !out.contains(p)) out.add(p);
        for (String p : apps.keySet()) {
            if (out.size() >= 6) break;
            if (!out.contains(p) && !isSystem(p)) out.add(p);
        }
        return out;
    }

    boolean isSystem(String p) {
        try {
            return (pm.getApplicationInfo(p, 0).flags & ApplicationInfo.FLAG_SYSTEM) != 0;
        } catch (PackageManager.NameNotFoundException e) {
            return true;
        }
    }

    void saveDock() {
        prefs.edit().putString("dock", TextUtils.join(",", dock)).commit();
        dockVersion++;
    }

    void buildDock() {
        appsChanged = false;
        seenDockVersion = dockVersion;
        Map<String, String> apps = installed();
        View focused = findFocus();
        int keep = focused != null && focused.getParent() == dockRow ? dockRow.indexOfChild(focused) : 0;
        dock = dockApps(apps);
        dockRow.removeAllViews();
        for (String p : dock) dockRow.addView(tile(p, apps.get(p), DOCK_TILE_W, true), dockParams());
        if (dock.isEmpty()) {
            View add = textTile("Apps hinzufügen", DOCK_TILE_W, 200);
            add.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { openDrawer(v); }
            });
            dockRow.addView(add, dockParams());
        }
        if (layers.isEmpty()) dockRow.getChildAt(Math.min(keep, dockRow.getChildCount() - 1)).requestFocus();
        exportApps(installed(true));
    }

    LinearLayout.LayoutParams dockParams() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(px(DOCK_TILE_W), -1);
        lp.leftMargin = px(12);
        lp.rightMargin = px(12);
        return lp;
    }

    // The app list for the PC: package, name, place in the dock (or -), hidden (1/0). Written off the
    // UI thread into Android/media/<package>/apps.txt, which adb can read.
    void exportApps(Map<String, String> all) {
        final File dir = mediaDir();
        if (dir == null) return;
        Set<String> hidden = hiddenByUser();
        final StringBuilder b = new StringBuilder();
        for (Map.Entry<String, String> a : all.entrySet()) {
            int i = dock.indexOf(a.getKey());
            b.append(a.getKey()).append('\t').append(a.getValue().replace('\t', ' ').replace('\n', ' '))
             .append('\t').append(i >= 0 ? String.valueOf(i + 1) : "-")
             .append('\t').append(hidden.contains(a.getKey()) ? "1" : "0").append('\n');
        }
        new Thread(new Runnable() {
            @Override public void run() {
                File tmp = new File(dir, "apps.txt.tmp");
                try (OutputStream out = new FileOutputStream(tmp)) {
                    out.write(b.toString().getBytes("UTF-8"));
                } catch (Exception e) {
                    return;
                }
                tmp.renameTo(new File(dir, "apps.txt"));
            }
        }).start();
    }

    void launch(final String p, String label) {
        // On the overlay, in the 5 seconds after Home, only Amazon's launcher can open apps right away.
        if (ctx instanceof HomeService) {
            ((HomeService) ctx).launchThroughAmazon(label, new Runnable() {
                @Override public void run() { startApp(p); }
            }, 0);
        } else startApp(p);
    }

    void startApp(String p) {
        Intent i = pm.getLeanbackLaunchIntentForPackage(p);
        if (i == null) i = pm.getLaunchIntentForPackage(p);
        try {
            ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception e) {
            showCaption("Die App lässt sich nicht öffnen");
        }
    }

    // ---- App art, in colour ----

    // The app's TV banner (16:9, made for exactly this), or failing that its icon.
    Bitmap artFor(String p) {
        if (art.containsKey(p)) return art.get(p);
        Bitmap out = null;
        boolean banner = false;
        try {
            Drawable d = null;
            ActivityInfo ai = activities.get(p);
            if (ai != null) d = ai.loadBanner(pm);
            if (d == null) d = pm.getApplicationBanner(p);
            if (d != null) {
                out = toBitmap(d, px(320), px(180));
                banner = true;
            } else {
                d = ai != null ? ai.loadIcon(pm) : pm.getApplicationIcon(p);
                out = toBitmap(d, px(160), px(160));
            }
        } catch (Exception ignored) { }
        art.put(p, out);
        isBanner.put(p, banner);
        artColor.put(p, out == null ? 0xFF3A3A40 : backdrop(out));
        return out;
    }

    static Bitmap toBitmap(Drawable d, int w, int h) {
        int iw = d.getIntrinsicWidth(), ih = d.getIntrinsicHeight();
        if (iw > 0 && ih > 0) { // keep the drawable's own shape
            float k = Math.min((float) w / iw, (float) h / ih);
            w = Math.max(1, Math.round(iw * k));
            h = Math.max(1, Math.round(ih * k));
        }
        Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(b);
        d.setBounds(0, 0, w, h);
        d.draw(c);
        return b;
    }

    // A deep version of the art's average colour, as the tile behind an icon.
    static int backdrop(Bitmap b) {
        Bitmap small = Bitmap.createScaledBitmap(b, 16, 16, true);
        long r = 0, g = 0, bl = 0, n = 0;
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
            int c = small.getPixel(x, y);
            if (Color.alpha(c) < 128) continue;
            r += Color.red(c); g += Color.green(c); bl += Color.blue(c); n++;
        }
        if (n == 0) return 0xFF3A3A40;
        float[] hsv = new float[3];
        Color.RGBToHSV((int) (r / n), (int) (g / n), (int) (bl / n), hsv);
        hsv[1] = Math.min(1f, hsv[1] * 1.2f);
        hsv[2] = Math.max(0.22f, Math.min(hsv[2] * 0.62f, 0.55f));
        return Color.HSVToColor(hsv);
    }

    // ---- Tiles ----

    // An app tile: the art in colour with rounded corners, the name below. Focus lifts it, adds a
    // white rim and a shadow, and brightens the name.
    View tile(final String p, final String label, int w, final boolean inDock) {
        final FrameLayout t = new FrameLayout(ctx);
        t.setFocusable(true);
        t.setFocusableInTouchMode(true); // TVs have no touch; this just lets focus land after adb or a reboot
        t.setClickable(true);
        t.setClipChildren(false);
        int cardH = Math.round(w * 9f / 16f);

        final FrameLayout card = new FrameLayout(ctx);
        rounded(card, 22);
        Bitmap a = artFor(p);
        boolean banner = Boolean.TRUE.equals(isBanner.get(p));
        Integer bg = artColor.get(p);
        card.setBackgroundColor(bg == null ? 0xFF3A3A40 : bg);
        ImageView img = new ImageView(ctx);
        if (a != null) img.setImageBitmap(a);
        if (banner) {
            img.setScaleType(ImageView.ScaleType.CENTER_CROP);
            card.addView(img, new FrameLayout.LayoutParams(-1, -1));
        } else {
            img.setScaleType(ImageView.ScaleType.FIT_CENTER);
            int icon = Math.round(cardH * 0.56f);
            card.addView(img, new FrameLayout.LayoutParams(px(icon), px(icon), Gravity.CENTER));
        }
        final View rim = new View(ctx);
        GradientDrawable rd = new GradientDrawable();
        rd.setColor(0);
        rd.setCornerRadius(px(22));
        rd.setStroke(Math.max(2, px(4)), 0xFFFFFFFF);
        rim.setBackground(rd);
        rim.setAlpha(0);
        card.addView(rim, new FrameLayout.LayoutParams(-1, -1));
        t.addView(card, new FrameLayout.LayoutParams(px(w), px(cardH), Gravity.TOP | Gravity.CENTER_HORIZONTAL));

        final TextView name = new TextView(ctx);
        style(name, 24, medium);
        name.setSingleLine();
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setText(label);
        name.setGravity(Gravity.CENTER);
        name.setAlpha(0.72f);
        name.setShadowLayer(px(8), 0, px(1), 0x80000000);
        FrameLayout.LayoutParams nlp = new FrameLayout.LayoutParams(px(w), -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        nlp.topMargin = px(cardH + 14);
        t.addView(name, nlp);

        t.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override public void onFocusChange(View v, boolean has) {
                if (has && t.getParent() == dockRow) lastDock = dockRow.indexOfChild(t);
                ObjectAnimator.ofFloat(rim, "alpha", rim.getAlpha(), has ? 1f : 0f).setDuration(140).start();
                name.animate().alpha(has ? 1f : 0.72f).setDuration(140).start();
                card.animate().translationZ(has ? px(22) : 0).setDuration(180).start();
                t.setTranslationZ(has ? px(6) : 0); // the focused tile draws over its neighbours
                t.animate().scaleX(has ? 1.08f : 1).scaleY(has ? 1.08f : 1).setDuration(180).setInterpolator(ease).start();
            }
        });
        t.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { launch(p, label); }
        });
        t.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) { appMenu(v, p, inDock); return true; }
        });
        t.setOnKeyListener(new View.OnKeyListener() {
            @Override public boolean onKey(View v, int k, KeyEvent e) {
                if (k != KeyEvent.KEYCODE_MENU) return false;
                if (e.getAction() == KeyEvent.ACTION_UP) appMenu(v, p, inDock);
                return true;
            }
        });
        return t;
    }

    View textTile(String text, int w, int h) {
        FrameLayout t = focusTile(32, 1.04f);
        TextView label = new TextView(ctx);
        style(label, 30, medium);
        label.setText(text);
        label.setGravity(Gravity.CENTER);
        t.addView(label, new FrameLayout.LayoutParams(-1, px(Math.round(w * 9f / 16f))));
        return t;
    }

    // A focusable tile: a soft glass pill fades in behind it and it lifts slightly when focused.
    FrameLayout focusTile(int radius, final float lift) {
        final FrameLayout t = new FrameLayout(ctx);
        t.setFocusable(true);
        t.setFocusableInTouchMode(true);
        t.setClickable(true);
        // The pill is the tile's background, so it never changes the tile's size.
        final GradientDrawable pill = new GradientDrawable();
        pill.setColor(0x33FFFFFF);
        pill.setCornerRadius(px(radius));
        pill.setAlpha(0);
        t.setBackground(pill);
        t.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override public void onFocusChange(View v, boolean has) {
                if (has && t.getParent() == dockRow) lastDock = dockRow.indexOfChild(t);
                ObjectAnimator.ofInt(pill, "alpha", pill.getAlpha(), has ? 255 : 0).setDuration(140).start();
                t.animate().scaleX(has ? lift : 1).scaleY(has ? lift : 1).setDuration(180).setInterpolator(ease).start();
            }
        });
        return t;
    }

    View addIcon(String asset, int x, View.OnClickListener click) {
        FrameLayout b = focusTile(38, 1.1f);
        b.setId(View.generateViewId());
        ImageView img = new ImageView(ctx);
        img.setImageBitmap(bitmap("ui/" + asset + ".png"));
        b.addView(img, new FrameLayout.LayoutParams(px(40), px(40), Gravity.CENTER));
        b.setOnClickListener(click);
        base.addView(b, at(x, 56, 76, 76));
        return b;
    }

    // ---- Menus and the app drawer ----

    interface Pick { void pick(int i); }

    void appMenu(View anchor, final String p, boolean inDock) {
        final int i = dock.indexOf(p);
        if (inDock) {
            menu(anchor, new String[] {"Nach links", "Nach rechts", "Aus dem Dock nehmen"}, new Pick() {
                @Override public void pick(int which) {
                    if (which == 2) dock.remove(i);
                    else {
                        int j = which == 0 ? i - 1 : i + 1;
                        if (j < 0 || j >= dock.size()) return;
                        Collections.swap(dock, i, j);
                    }
                    saveDock();
                    buildDock();
                    int at = which == 2 ? Math.min(i, dock.size() - 1) : (which == 0 ? i - 1 : i + 1);
                    if (at >= 0 && at < dockRow.getChildCount()) dockRow.getChildAt(at).requestFocus();
                }
            });
        } else {
            menu(anchor, new String[] {i >= 0 ? "Aus dem Dock nehmen" : "Ins Dock legen", "Ausblenden", "App-Info"}, new Pick() {
                @Override public void pick(int which) {
                    if (which == 2) {
                        start(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + p)));
                        return;
                    }
                    if (which == 1) {
                        Set<String> h = hiddenByUser();
                        h.add(p);
                        dock.remove(p);
                        prefs.edit().putString("hidden", TextUtils.join(",", h)).commit();
                        saveDock();
                        buildDock();
                        showCaption("Ausgeblendet. Zurückholen: Einstellungen oben rechts");
                        return;
                    }
                    if (i >= 0) dock.remove(p); else dock.add(p);
                    saveDock();
                    buildDock();
                    showCaption(i >= 0 ? "Aus dem Dock genommen" : "Ins Dock gelegt");
                }
            });
        }
    }

    void openSettingsMenu(View anchor) {
        boolean amazon = isInstalled(HomeService.AMAZON_HOME);
        final List<String> items = new ArrayList<>(amazon ? Arrays.asList("Fire-TV-Einstellungen", "Amazon-Startseite")
                : Arrays.asList("Einstellungen"));
        final boolean anyHidden = !hiddenByUser().isEmpty();
        if (anyHidden) items.add("Ausgeblendete Apps wieder zeigen");
        menu(anchor, items.toArray(new String[0]), new Pick() {
            @Override public void pick(int which) {
                if (which == 0) {
                    HomeService.pause(true);
                    // Amazon's own settings screen. Settings.ACTION_SETTINGS goes through Amazon's home screen on Fire OS 7 and 8.
                    if (!start(new Intent(Intent.ACTION_MAIN).addCategory("android.intent.category.LEANBACK_SETTINGS")
                            .setPackage(HomeService.AMAZON_HOME))) start(new Intent(Settings.ACTION_SETTINGS));
                } else if (anyHidden && which == items.size() - 1) {
                    prefs.edit().putString("hidden", "").commit();
                    dockVersion++;
                    buildDock();
                    showCaption("Alle Apps werden wieder gezeigt");
                } else {
                    HomeService.pause(false);
                    Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                            .setPackage(HomeService.AMAZON_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    if (!start(home)) showCaption("Amazons Startseite ist nicht verfügbar");
                    else if (ctx instanceof Activity) ((Activity) ctx).finish();
                }
            }
        });
    }

    boolean start(Intent i) {
        try {
            ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    boolean isInstalled(String p) {
        try { pm.getPackageInfo(p, 0); return true; } catch (PackageManager.NameNotFoundException e) { return false; }
    }

    // A small glass menu by the anchor. Back closes it.
    void menu(View anchor, String[] items, final Pick pick) {
        FrameLayout layer = new FrameLayout(ctx);
        LinearLayout box = new LinearLayout(ctx);
        box.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xF0202024);
        bg.setCornerRadius(px(30));
        box.setBackground(bg);
        box.setPadding(px(10), px(10), px(10), px(10));
        View first = null;
        for (int i = 0; i < items.length; i++) {
            final int which = i;
            FrameLayout row = focusTile(22, 1f);
            TextView t = new TextView(ctx);
            style(t, 28, medium);
            t.setText(items[i]);
            t.setPadding(px(28), px(18), px(48), px(18));
            row.addView(t, new FrameLayout.LayoutParams(-2, -2));
            row.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { closeLayer(); pick.pick(which); }
            });
            box.addView(row, new LinearLayout.LayoutParams(-1, -2));
            if (first == null) first = row;
        }
        box.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
        int[] loc = new int[2];
        anchor.getLocationInWindow(loc);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-2, -2);
        lp.leftMargin = Math.max(px(40), Math.min(loc[0], screenW - box.getMeasuredWidth() - px(40)));
        int below = loc[1] + anchor.getHeight() + px(16);
        lp.topMargin = below + box.getMeasuredHeight() < screenH - px(40) ? below : loc[1] - box.getMeasuredHeight() - px(16);
        layer.addView(box, lp);
        openLayer(layer, anchor, first);
    }

    void openDrawer(View anchor) {
        FrameLayout layer = new FrameLayout(ctx);
        layer.addView(new GlassView(ctx, 0, 0xA6000000), new FrameLayout.LayoutParams(-1, -1));
        TextView title = new TextView(ctx);
        style(title, 48, semibold);
        title.setText("Apps");
        layer.addView(title, at(140, 64, -2, -2));
        TextView hint = new TextView(ctx);
        style(hint, 24, medium);
        hint.setAlpha(0.6f);
        hint.setText("OK lange drücken oder Menü-Taste: ins Dock legen, ausblenden");
        layer.addView(hint, at(140, 136, -2, -2));

        ScrollView sv = new ScrollView(ctx);
        sv.setVerticalScrollBarEnabled(false);
        sv.setOverScrollMode(View.OVER_SCROLL_NEVER);
        sv.setClipToPadding(false);
        sv.setPadding(px(118), px(24), px(118), px(80));
        GridLayout grid = new GridLayout(ctx);
        grid.setClipChildren(false);
        grid.setColumnCount(6);
        Map<String, String> apps = installed();
        int tileH = Math.round(DRAWER_TILE_W * 9f / 16f) + 52;
        View first = null;
        for (Map.Entry<String, String> a : apps.entrySet()) {
            View t = tile(a.getKey(), a.getValue(), DRAWER_TILE_W, false);
            GridLayout.LayoutParams lp = new GridLayout.LayoutParams();
            lp.width = px(DRAWER_TILE_W);
            lp.height = px(tileH);
            lp.setMargins(px(8), px(10), px(8), px(10));
            grid.addView(t, lp);
            if (first == null) first = t;
        }
        sv.addView(grid);
        FrameLayout.LayoutParams slp = new FrameLayout.LayoutParams(-1, -1);
        slp.topMargin = px(190);
        layer.addView(sv, slp);
        openLayer(layer, anchor, first);
    }

    // Layers stack over the home screen; only the top one can take focus.
    void openLayer(ViewGroup layer, View returnFocus, View focus) {
        layer.setTag(returnFocus);
        layer.setClickable(true);
        top().setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        layers.add(layer);
        root.addView(layer, new FrameLayout.LayoutParams(-1, -1));
        layer.setAlpha(0);
        layer.animate().alpha(1).setDuration(140).start();
        if (focus != null) focus.requestFocus();
    }

    void closeLayer() {
        ViewGroup layer = layers.remove(layers.size() - 1);
        root.removeView(layer);
        top().setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
        View back = (View) layer.getTag();
        if (back != null && back.isAttachedToWindow()) back.requestFocus();
        else if (layers.isEmpty() && dockRow.getChildCount() > 0) dockRow.getChildAt(0).requestFocus();
        if (layers.isEmpty() && appsChanged) buildDock();
        if (layers.isEmpty() && ctx instanceof HomeService) HomeService.menusClosed();
    }

    ViewGroup top() {
        return layers.isEmpty() ? base : layers.get(layers.size() - 1);
    }

    // ---- Wallpaper ----

    File mediaDir() {
        try {
            File[] d = ctx.getExternalMediaDirs();
            if (d != null && d.length > 0 && d[0] != null) {
                if (!d[0].exists()) d[0].mkdirs();
                return d[0];
            }
        } catch (Exception ignored) { }
        return null;
    }

    File wallDir() {
        File m = mediaDir();
        return m == null ? null : new File(m, "wallpapers");
    }

    // Your photos first (Android/media/<package>/wallpapers, by name), then the bundled ones.
    List<String> choices() {
        List<String> c = new ArrayList<>();
        File d = wallDir();
        String[] names = d == null ? null : d.list();
        if (names != null) {
            Arrays.sort(names);
            for (String n : names) {
                String l = n.toLowerCase();
                if (l.endsWith(".jpg") || l.endsWith(".jpeg") || l.endsWith(".png") || l.endsWith(".webp")) c.add(FILE + n);
            }
        }
        if (c.isEmpty() || prefs.getBoolean("builtins", true)) for (String[] w : WALLPAPERS) c.add(w[0]);
        return c;
    }

    void nextWallpaper() {
        List<String> c = choices();
        String next = c.get((c.indexOf(prefs.getString("wallpaper", c.get(0))) + 1) % c.size());
        prefs.edit().putString("wallpaper", next).commit();
        showWallpaper(next);
        String credit = next.startsWith(FILE) ? "Eigenes Bild  ·  " + next.substring(FILE.length()) : "";
        for (String[] w : WALLPAPERS) if (w[0].equals(next)) credit = w[1];
        showCaption(credit);
    }

    // Decoding a photo takes a moment on a Fire TV Stick, so it happens off the UI thread.
    void showWallpaper(final String key) {
        shownWallpaper = key;
        seenPhotoVersion = photoVersion;
        if (key.equals(cachedKey) && cachedPhoto != null) {
            wallView.setImageBitmap(cachedPhoto);
            blur = cachedBlur;
            invalidateGlass(root);
            return;
        }
        new Thread(new Runnable() {
            @Override public void run() {
                Bitmap b = decode(key);
                if (b == null) b = decode(WALLPAPERS[0][0]);
                final Bitmap photo = b, soft = b == null ? null : blurred(b);
                post(new Runnable() {
                    @Override public void run() {
                        cachedKey = key;
                        cachedPhoto = photo;
                        cachedBlur = soft;
                        wallView.setImageBitmap(photo);
                        blur = soft;
                        root.invalidate();
                        invalidateGlass(root);
                    }
                });
            }
        }).start();
    }

    void invalidateGlass(View v) {
        if (v instanceof GlassView) v.invalidate();
        if (v instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) v).getChildCount(); i++) invalidateGlass(((ViewGroup) v).getChildAt(i));
    }

    Bitmap decode(String key) {
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            try (InputStream in = open(key)) { BitmapFactory.decodeStream(in, null, o); }
            if (o.outWidth <= 0 || o.outHeight <= 0) return null;
            o.inSampleSize = 1;
            while (o.outWidth / (o.inSampleSize * 2) >= screenW && o.outHeight / (o.inSampleSize * 2) >= screenH) o.inSampleSize *= 2;
            o.inJustDecodeBounds = false;
            try (InputStream in = open(key)) { return BitmapFactory.decodeStream(in, null, o); }
        } catch (Throwable e) {
            return null;
        }
    }

    InputStream open(String key) throws Exception {
        if (key.startsWith(FILE)) return new FileInputStream(new File(wallDir(), key.substring(FILE.length())));
        return ctx.getAssets().open("wallpapers/" + key + ".jpg");
    }

    // The frosted glass: the photo shrunk to 96 pixels wide and box-blurred. Drawn stretched, it reads as blur.
    static Bitmap blurred(Bitmap b) {
        int w = 96, h = Math.max(1, Math.round(96f * b.getHeight() / b.getWidth()));
        Bitmap mid = Bitmap.createScaledBitmap(b, w * 4, h * 4, true);
        Bitmap small = Bitmap.createScaledBitmap(mid, w, h, true);
        int[] a = new int[w * h], t = new int[w * h];
        small.getPixels(a, 0, w, 0, 0, w, h);
        for (int i = 0; i < 3; i++) {
            boxPass(a, t, h, w, w, 1, 3);
            boxPass(t, a, w, h, 1, w, 3);
        }
        return Bitmap.createBitmap(a, w, h, Bitmap.Config.ARGB_8888);
    }

    static void boxPass(int[] src, int[] dst, int lines, int len, int lineStep, int step, int r) {
        for (int l = 0; l < lines; l++) {
            int start = l * lineStep;
            for (int i = 0; i < len; i++) {
                int red = 0, green = 0, blue = 0, n = 0;
                for (int k = Math.max(0, i - r); k <= Math.min(len - 1, i + r); k++, n++) {
                    int c = src[start + k * step];
                    red += (c >> 16) & 255;
                    green += (c >> 8) & 255;
                    blue += c & 255;
                }
                dst[start + i * step] = 0xFF000000 | (red / n) << 16 | (green / n) << 8 | blue / n;
            }
        }
    }

    // Draws the blurred photo exactly behind itself, so it looks like frosted glass over the wallpaper.
    class GlassView extends FrameLayout {
        final float radius;
        final Paint photo = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        final Paint tint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint edge = new Paint(Paint.ANTI_ALIAS_FLAG);
        final RectF rect = new RectF();
        final Matrix m = new Matrix();
        final int[] loc = new int[2];
        Bitmap shaderFor;

        GlassView(Context c, int radius, int tintColor) {
            super(c);
            this.radius = px(radius);
            tint.setColor(tintColor);
            edge.setStyle(Paint.Style.STROKE);
            edge.setStrokeWidth(Math.max(1, px(1.5f)));
            edge.setColor(radius > 0 ? 0x1FFFFFFF : 0);
            setWillNotDraw(false);
        }

        @Override
        protected void onDraw(Canvas c) {
            rect.set(0, 0, getWidth(), getHeight());
            if (blur != null) {
                if (shaderFor != blur) {
                    photo.setShader(new BitmapShader(blur, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP));
                    shaderFor = blur;
                }
                // Same centre-crop as the wallpaper, shifted to this view's place on screen.
                float k = Math.max((float) screenW / blur.getWidth(), (float) screenH / blur.getHeight());
                getLocationInWindow(loc);
                m.setScale(k, k);
                m.postTranslate((screenW - blur.getWidth() * k) / 2 - loc[0], (screenH - blur.getHeight() * k) / 2 - loc[1]);
                photo.getShader().setLocalMatrix(m);
                c.drawRoundRect(rect, radius, radius, photo);
            }
            c.drawRoundRect(rect, radius, radius, tint);
            if (radius > 0) {
                float e = edge.getStrokeWidth() / 2;
                rect.inset(e, e);
                c.drawRoundRect(rect, radius - e, radius - e, edge);
            }
        }
    }

    // ---- Helpers ----

    void showCaption(String text) {
        caption.setText(text);
        caption.animate().cancel();
        caption.animate().alpha(1).setDuration(160).withEndAction(new Runnable() {
            @Override public void run() { caption.animate().alpha(0).setStartDelay(2600).setDuration(400).start(); }
        }).start();
    }

    Bitmap bitmap(String asset) {
        try (InputStream in = ctx.getAssets().open(asset)) {
            return BitmapFactory.decodeStream(in);
        } catch (Exception e) {
            return null;
        }
    }

    void rounded(View v, final int radius) {
        v.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View view, Outline o) {
                o.setRoundRect(0, 0, view.getWidth(), view.getHeight(), px(radius));
            }
        });
        v.setClipToOutline(true);
    }

    void style(TextView t, float size, Typeface face) {
        t.setTextSize(TypedValue.COMPLEX_UNIT_PX, px(size));
        t.setTypeface(face);
        t.setTextColor(0xFFFFFFFF);
        t.setIncludeFontPadding(false);
    }

    FrameLayout.LayoutParams at(int x, int y, int w, int h) {
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w < 0 ? w : px(w), h < 0 ? h : px(h));
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.leftMargin = px(x);
        lp.topMargin = px(y);
        return lp;
    }

    int px(float v) {
        return Math.round(v * s);
    }
}
