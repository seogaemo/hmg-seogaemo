package com.seogaemo.hmg;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import com.seogaemo.hmg.module.InstalledModule;
import com.seogaemo.hmg.module.RemovedModule;
import com.seogaemo.hmg.module.Module;
import com.seogaemo.hmg.module.ModuleAction;
import com.seogaemo.hmg.module.ModuleManager;
import com.seogaemo.hmg.module.ModulePlan;
import com.seogaemo.hmg.module.ModuleRegistry;
import com.seogaemo.hmg.module.ModuleResume;
import com.seogaemo.hmg.module.ParallelReads;
import com.seogaemo.hmg.module.RestoreGate;
import com.seogaemo.hmg.module.RootClient;
import com.seogaemo.hmg.module.RootResult;
import com.seogaemo.hmg.module.Warning;
import com.seogaemo.hmg.module.WifiNetwork;
import com.seogaemo.hmg.ui.ConfirmDialog;
import com.seogaemo.hmg.ui.QrCode;
import com.seogaemo.hmg.ui.QrView;
import com.seogaemo.hmg.ui.settings.ReportsSection;
import com.seogaemo.hmg.ui.Feature;
import com.seogaemo.hmg.ui.FeatureCard;
import com.seogaemo.hmg.ui.FeaturesView;
import com.seogaemo.hmg.ui.LineIcon;
import com.seogaemo.hmg.ui.OptionsList;
import com.seogaemo.hmg.ui.PlanSummaryView;
import com.seogaemo.hmg.ui.StepProgressDialog;
import com.seogaemo.hmg.ui.Theme;
import com.seogaemo.hmg.ui.settings.SettingsPage;
import com.seogaemo.hmg.ui.settings.SettingsUi;
import com.seogaemo.hmg.core.IssueLink;
import com.seogaemo.hmg.core.update.UpdateClient;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Gen5W app: Features, Car and Settings tabs over the built-in and installed modules. */
public final class MainActivity extends Activity {
    private static final int CANVAS = Theme.CANVAS;
    private static final int SURFACE = Theme.SURFACE;
    private static final int RAISED = Theme.RAISED;
    private static final int HAIRLINE = Theme.HAIRLINE;
    private static final int WHITE = Theme.WHITE;
    private static final int MUTED = Theme.MUTED;
    private static final int BLUE = Theme.BLUE;
    private static final int ERROR = Theme.ERROR;
    private static final int WARNING = Theme.WARNING;

    private enum Tab { FEATURES, CAR, SETTINGS }

    private static final int CATEGORY_UPDATE = 0;
    private static final int CATEGORY_LANGUAGE = 1;
    private static final int CATEGORY_SUPPORT = 2;
    private static final int CATEGORY_DEVELOPER = 3;
    private static final int CATEGORY_RESET = 4;
    private static final int[] CATEGORIES = {R.string.settings_update, R.string.language, R.string.settings_support,
        R.string.settings_developer, R.string.settings_reset};
    private static final String[] CATEGORY_ICONS = {"download", "globe", "help", "code", "undo"};
    private static final int SETTLE_ATTEMPTS = 6;
    private static final long SETTLE_DELAY_MS = 2000L;

    private Typeface sans;
    private Typeface medium;
    private Tab tab = Tab.FEATURES;
    private int category = 0;
    private String detailId;
    private boolean addVisible;
    private int sidebarOffset;
    private ScrollView sidebarScroll;
    private boolean settingsVisible;
    private FeaturesView featuresView;
    private final Map<String, RootResult> statuses = new HashMap<String, RootResult>();
    private final Set<String> settling = new HashSet<String>();
    /** Modules whose first status read was not definitive (for example right after boot); re-read quietly. */
    private final Set<String> rechecking = new HashSet<String>();
    private final Map<String, Integer> sortGroups = new HashMap<String, Integer>();
    private boolean recheckRunning;
    private final Handler handler = new Handler();
    private boolean restartLater;
    private boolean sortOnLoad;
    private int loadGeneration;
    private TextView updateStatus;
    private boolean updateBusy;
    private boolean modulePlanning;
    private boolean moduleWorking;
    private RootResult mapStatus;
    private RootResult foreignStatus;
    private RootResult carCheck;
    private boolean carCheckLoading;
    private boolean mapRefreshing;
    private boolean mapBusy;
    private String mapResult;
    private TextView stockStatus;
    private boolean stockBusy;
    private boolean resumeChecking;
    private final BroadcastReceiver networkChanges = new BroadcastReceiver() {
        public void onReceive(Context context, Intent intent) { resumeUpdateWhenReady(); }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        applyLocale();
        restoreInstalledCache();
        getWindow().getDecorView().setSystemUiVisibility(5894 | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        sans = Typeface.create("sans-serif", Typeface.NORMAL);
        medium = Typeface.create("sans-serif-medium", Typeface.NORMAL);
        if (state != null) {
            tab = Tab.values()[Math.max(0, Math.min(Tab.values().length - 1, state.getInt("tab", 0)))];
            category = state.getInt("category", 0);
            sidebarOffset = state.getInt("sidebarOffset", 0);
            detailId = state.getString("detail");
            addVisible = state.getBoolean("add", false);
        }
        render();
        refreshMap(true);
        registerReceiver(networkChanges, new IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION));
        if (!getSharedPreferences("update", MODE_PRIVATE).getBoolean("resume", false) &&
                getSharedPreferences("update", MODE_PRIVATE).contains("restore")) {
            offerModuleRestore();
        }
    }

    /**
     * A restore saved by an earlier update may be stale (stock restore ran, a restart is
     * outstanding). Read state on a worker, then run it only after an explicit confirmation.
     */
    private void offerModuleRestore() {
        updateBusy = true;
        new Thread(new Runnable() { public void run() {
            RootResult stock = RootClient.stock("status");
            List<RootResult> observed = new ArrayList<RootResult>();
            for (Module module : ModuleRegistry.all()) observed.add(RootClient.run(module.id(), "status"));
            final RestoreGate.Decision decision = RestoreGate.decide(stock, observed);
            final List<RestoreGate.Step> steps = savedRestoreSteps(observed);
            runOnUiThread(new Runnable() { public void run() {
                if (isFinishing()) { updateBusy = false; return; }
                if (decision == RestoreGate.Decision.PROCEED) { confirmModuleRestore(steps); return; }
                updateBusy = false;
                if (decision == RestoreGate.Decision.PAUSED) {
                    getSharedPreferences("update", MODE_PRIVATE).edit().clear().commit();
                    getSharedPreferences("module_resume", MODE_PRIVATE).edit().clear().commit();
                    updateMessage(getString(R.string.restore_skipped_paused));
                    Toast.makeText(MainActivity.this, R.string.restore_skipped_paused, Toast.LENGTH_LONG).show();
                } else if (decision == RestoreGate.Decision.PENDING_RESTART) {
                    updateMessage(getString(R.string.restore_deferred_restart));
                    Toast.makeText(MainActivity.this, R.string.restore_deferred_restart, Toast.LENGTH_LONG).show();
                } else updateMessage(getString(R.string.update_restore_pending));
            } });
        } }, "hmg-seogaemo-restore-gate").start();
    }

    /** What the saved restore will do, from the saved desired list and the statuses just read. */
    private List<RestoreGate.Step> savedRestoreSteps(List<RootResult> observed) {
        List<String> ids = new ArrayList<String>();
        for (Module module : ModuleRegistry.all()) ids.add(module.id());
        return RestoreGate.steps(getSharedPreferences("update", MODE_PRIVATE).getString("restore", ""), ids, observed);
    }

    private String restoreConfirmMessage(List<RestoreGate.Step> steps) {
        StringBuilder message = new StringBuilder(getString(R.string.restore_confirm_message)).append("\n\n");
        if (steps.isEmpty()) message.append(getString(R.string.restore_confirm_none));
        for (RestoreGate.Step step : steps) {
            message.append("\u2022 ").append(getString(step.enable ? R.string.plan_step_enable : R.string.plan_step_disable,
                    getString(ModuleRegistry.find(step.id).nameResId()))).append('\n');
        }
        if (RestoreGate.touchesBootProcess(steps))
            message.append('\n').append(getString(R.string.restore_confirm_boot_process));
        return message.toString().trim();
    }

    private void confirmModuleRestore(List<RestoreGate.Step> steps) {
        ConfirmDialog.show(this, getString(R.string.restore_confirm_title),
                restoreConfirmMessage(steps), getString(R.string.restore_confirm_action),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                dialog.showProgress();
                new Thread(new Runnable() { public void run() {
                    if (!restoreModules()) updateMessage(getString(R.string.update_restore_pending));
                    finishUpdateWork(dialog);
                } }, "hmg-seogaemo-update-restore").start();
            }
        }, new Runnable() { public void run() {
            updateBusy = false; // The saved intent stays; it is offered again at the next start.
            updateMessage(getString(R.string.update_restore_pending));
        } });
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putInt("tab", tab.ordinal());
        state.putInt("category", category);
        state.putInt("sidebarOffset", sidebarScroll == null ? sidebarOffset : sidebarScroll.getScrollY());
        state.putString("detail", detailId);
        state.putBoolean("add", addVisible);
        super.onSaveInstanceState(state);
    }

    @Override protected void onResume() {
        super.onResume();
        if (featuresVisible() && featuresView != null) loadFeatures(false);
        resumeUpdateWhenReady();
    }

    @Override protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        unregisterReceiver(networkChanges);
        super.onDestroy();
    }

    private void resumeUpdateWhenReady() {
        if (resumeChecking || updateBusy || moduleWorking || modulePlanning || stockBusy || mapBusy || mapRefreshing ||
                !getSharedPreferences("update", MODE_PRIVATE).getBoolean("resume", false)) return;
        if (resumeExpired()) return;
        resumeChecking = true;
        new Thread(new Runnable() { public void run() {
            boolean ready = false;
            try {
                SharedPreferences resume = getSharedPreferences("update", MODE_PRIVATE);
                boolean rebooted = !resume.contains("boot") || ModuleResume.restarted(
                        resume.getString("boot", ""), ModuleResume.bootId());
                ready = rebooted && ModuleResume.ready(RootClient.run("wifi", "status"),
                        new UpdateClient(MainActivity.this).hasUsableNetwork());
            } catch (Exception ignored) { }
            final boolean canResume = ready;
            runOnUiThread(new Runnable() { public void run() {
                resumeChecking = false;
                if (!canResume || isFinishing() || isDestroyed() || updateBusy || moduleWorking || modulePlanning ||
                        stockBusy || mapBusy || mapRefreshing || !getSharedPreferences("update", MODE_PRIVATE)
                        .getBoolean("resume", false)) return;
                category = CATEGORY_UPDATE;
                detailId = null;
                addVisible = false;
                showSettings();
                checkUpdate(); // The earlier confirmation saved this resume intent.
            }});
        }}, "hmg-seogaemo-update-resume").start();
    }

    /** Stamp the resume with the monotonic clock and boot id; wall time is only a post-restart fallback. */
    private static SharedPreferences.Editor stampResume(SharedPreferences.Editor editor) {
        return editor.putLong("resume_at", System.currentTimeMillis())
                .putLong("resume_elapsed", SystemClock.elapsedRealtime())
                .putString("resume_boot", ModuleResume.bootId());
    }

    /** A saved update-resume older than a day is dropped; the module restore is offered instead. */
    private boolean resumeExpired() {
        SharedPreferences prefs = getSharedPreferences("update", MODE_PRIVATE);
        if (!prefs.contains("resume_at")) { // Saved by an older build: start the clock now.
            stampResume(prefs.edit()).commit();
            return false;
        }
        if (!ModuleResume.expired(prefs.getString("resume_boot", ""), prefs.getLong("resume_elapsed", 0L),
                prefs.getLong("resume_at", 0L), ModuleResume.bootId(), SystemClock.elapsedRealtime(),
                System.currentTimeMillis())) return false;
        prefs.edit().putBoolean("resume", false).remove("boot").remove("resume_at")
                .remove("resume_elapsed").remove("resume_boot").commit();
        updateMessage(getString(R.string.update_resume_expired));
        if (prefs.contains("restore")) offerModuleRestore();
        return true;
    }

    private SharedPreferences preferences() {
        return getSharedPreferences("ui_language", MODE_PRIVATE);
    }

    private boolean diagnosticsEnabled() {
        return getSharedPreferences("ui_developer", MODE_PRIVATE).getBoolean("diagnostics", false);
    }

    private void applyLocale() {
        String choice = preferences().getString("language", "system");
        Locale selected = "system".equals(choice) ? Resources.getSystem().getConfiguration().locale
                : new Locale(choice);
        Locale.setDefault(selected);
        Configuration config = new Configuration(getResources().getConfiguration());
        config.locale = selected;
        getResources().updateConfiguration(config, getResources().getDisplayMetrics());
    }

    private Locale locale() { return getResources().getConfiguration().locale; }

    private String particle(String name) { return Theme.objectParticle(locale(), name); }

    private int dp(float value) { return Theme.dp(this, value); }

    private GradientDrawable shape(int fill, int border, int radius) { return Theme.shape(this, fill, border, radius); }

    private StateListDrawable selectable(int fill, int border, int radius, boolean destructive) {
        return Theme.selectable(this, fill, border, radius, destructive);
    }

    private TextView text(String label, float sp, int color, Typeface face) {
        return Theme.text(this, label, sp, color, face == medium);
    }

    private LinearLayout vertical() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        return v;
    }

    private LinearLayout horizontal() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.HORIZONTAL);
        v.setGravity(Gravity.CENTER_VERTICAL);
        return v;
    }

    private LinearLayout root() {
        LinearLayout r = vertical();
        r.setBackgroundColor(CANVAS);
        setContentView(r);
        return r;
    }

    private void divider(LinearLayout parent, boolean vertical) { Theme.addHairline(this, parent, vertical); }

    private ImageView iconBox(String icon, int color, int boxDp, int iconDp) {
        ImageView view = new ImageView(this);
        view.setScaleType(ImageView.ScaleType.CENTER);
        view.setImageDrawable(new LineIcon(this, icon, color, iconDp));
        view.setBackgroundDrawable(shape(RAISED, Color.TRANSPARENT, Theme.CARD_RADIUS));
        return view;
    }

    private final class BrandMark extends View {
        private final Paint paint = new Paint();
        BrandMark() { super(MainActivity.this); paint.setColor(0xFF101016); }
        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            canvas.drawColor(Color.WHITE);
            float unit = getWidth() / 300f;
            canvas.drawRect(70 * unit, 70 * unit, 176 * unit, 176 * unit, paint);
            canvas.drawRect(124 * unit, 124 * unit, 230 * unit, 230 * unit, paint);
        }
    }

    private void header(LinearLayout root, String backTitle) {
        LinearLayout bar = horizontal();
        bar.setBackgroundColor(SURFACE);
        if (backTitle != null) {
            TextView back = text(getString(R.string.nav_back_glyph), 38, WHITE, sans);
            back.setGravity(Gravity.CENTER);
            back.setContentDescription(getString(R.string.back));
            back.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
            back.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { goBack(); } });
            bar.addView(back, new LinearLayout.LayoutParams(dp(72), dp(60)));
            TextView title = text(backTitle, 26, WHITE, medium);
            title.setSingleLine(true);
            bar.addView(title, new LinearLayout.LayoutParams(0, dp(60), 1));
        } else {
            View inset = new View(this);
            bar.addView(inset, new LinearLayout.LayoutParams(dp(22), dp(60)));
            bar.addView(new BrandMark(), new LinearLayout.LayoutParams(dp(32), dp(32)));
            View gap = new View(this);
            bar.addView(gap, new LinearLayout.LayoutParams(dp(12), dp(60)));
            TextView brand = text(getString(R.string.header_brand), 28, WHITE, medium);
            brand.setPadding(0, 0, dp(SettingsUi.LG), 0);
            bar.addView(brand, new LinearLayout.LayoutParams(-2, dp(60)));
            for (Tab target : Tab.values()) bar.addView(tabButton(target), new LinearLayout.LayoutParams(-2, dp(60)));
            View spacer = new View(this);
            bar.addView(spacer, new LinearLayout.LayoutParams(0, dp(60), 1));
        }
        TextView close = text(getString(R.string.nav_close_glyph), 35, MUTED, sans);
        close.setGravity(Gravity.CENTER);
        close.setContentDescription(getString(R.string.close));
        close.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
        close.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { close(); } });
        bar.addView(close, new LinearLayout.LayoutParams(dp(72), dp(60)));
        root.addView(bar, new LinearLayout.LayoutParams(-1, dp(60)));
        divider(root, false);
    }

    private View tabButton(final Tab target) {
        boolean selected = target == tab;
        int labelRes = target == Tab.FEATURES ? R.string.tab_features : target == Tab.CAR ? R.string.tab_car : R.string.settings;
        FrameLayout holder = new FrameLayout(this);
        holder.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
        holder.setPadding(dp(SettingsUi.LG), 0, dp(SettingsUi.LG), 0);
        TextView label = text(getString(labelRes), 23, selected ? WHITE : MUTED, medium);
        label.setGravity(Gravity.CENTER);
        holder.addView(label, new FrameLayout.LayoutParams(-2, -1, Gravity.CENTER));
        if (selected) {
            View underline = new View(this);
            underline.setBackgroundColor(BLUE);
            FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(dp(44), dp(3),
                    Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            params.bottomMargin = dp(SettingsUi.XS);
            holder.addView(underline, params);
        }
        holder.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { selectTab(target); } });
        return holder;
    }

    private void selectTab(Tab target) {
        if (target == tab && detailId == null && !addVisible) return;
        tab = target;
        detailId = null;
        addVisible = false;
        render();
        if (target == Tab.CAR) refreshMap(false);
    }

    private void render() {
        if (detailId != null) {
            Feature feature = feature(detailId);
            if (feature != null) { showDetail(feature); return; }
            detailId = null;
        }
        if (addVisible) { showAdd(); return; }
        if (tab == Tab.CAR) showCar();
        else if (tab == Tab.SETTINGS) showSettings();
        else showFeatures();
    }

    private void goBack() {
        detailId = null;
        addVisible = false;
        render();
    }

    private boolean featuresVisible() { return tab == Tab.FEATURES && detailId == null && !addVisible; }

    private List<Feature> features() {
        List<Feature> list = new ArrayList<Feature>();
        for (Module module : ModuleRegistry.all()) list.add(Feature.of(this, module));
        for (InstalledModule module : ModuleRegistry.installed()) list.add(Feature.of(module));
        return list;
    }

    private Feature feature(String id) {
        for (Feature candidate : features()) if (candidate.id.equals(id)) return candidate;
        return null;
    }

    /** Refreshes the installed list from root and caches it for the next cold start. */
    private boolean refreshInstalled(String locale) {
        if (!ModuleRegistry.refreshInstalled(locale)) return false;
        try {
            JSONObject modules = new JSONObject();
            JSONArray order = new JSONArray();
            for (InstalledModule module : ModuleRegistry.installed()) {
                order.put(module.id);
                modules.put(module.id, new JSONObject(module.info));
            }
            moduleCache().edit().putString("locale", locale).putString("order", order.toString())
                    .putString("modules", modules.toString()).apply();
        } catch (JSONException ignored) { }
        return true;
    }

    /**
     * A cold start shows the last known modules (status still loading) at once instead of an
     * empty screen while root lists and describes every package; loadFeatures() replaces them.
     */
    private void restoreInstalledCache() {
        if (!ModuleRegistry.installed().isEmpty()) return;
        SharedPreferences cache = moduleCache();
        try {
            JSONObject groups = new JSONObject(cache.getString("groups", "{}"));
            for (java.util.Iterator<?> keys = groups.keys(); keys.hasNext();) {
                String id = (String) keys.next();
                sortGroups.put(id, groups.getInt(id));
            }
            if (!describeLocale().equals(cache.getString("locale", ""))) return;
            JSONArray order = new JSONArray(cache.getString("order", "[]"));
            JSONObject modules = new JSONObject(cache.getString("modules", "{}"));
            List<InstalledModule> found = new ArrayList<InstalledModule>();
            for (int i = 0; i < order.length(); i++) {
                String id = order.getString(i);
                JSONObject values = modules.getJSONObject(id);
                Map<String, String> info = new HashMap<String, String>();
                for (java.util.Iterator<?> keys = values.keys(); keys.hasNext();) {
                    String key = (String) keys.next();
                    info.put(key, values.getString(key));
                }
                InstalledModule module = InstalledModule.parse(id, new RootResult("on", "none", "", 0, info));
                if (module == null) return;
                found.add(module);
            }
            ModuleRegistry.setInstalled(found);
        } catch (JSONException ignored) { }
    }

    private SharedPreferences moduleCache() {
        return getSharedPreferences("module_cache", MODE_PRIVATE);
    }

    private String describeLocale() {
        String language = locale().getLanguage();
        return language != null && language.matches("[a-z]{2}") ? language : "en";
    }

    private static boolean readable(RootResult result) {
        return result.exitCode == 0 && ("on".equals(result.state) || "off".equals(result.state) ||
                "pending-restart".equals(result.state));
    }

    private static boolean unreachable(RootResult result) {
        return result.exitCode != 0 && "failed".equals(result.state) && result.info.isEmpty();
    }

    private static boolean observedOn(RootResult result) {
        return "on".equals(result.state) ||
                ("pending-restart".equals(result.state) && !"off".equals(result.info.get("desired")));
    }

    private String excludedBy(String id) {
        for (String other : ModuleRegistry.excludes(id)) {
            RootResult status = statuses.get(other);
            if (status != null && status.exitCode == 0 && observedOn(status)) {
                Feature blocker = feature(other);
                return blocker == null ? other : blocker.name;
            }
        }
        return null;
    }

    private String reasonText(RootResult result) {
        if ("conflict".equals(result.state)) return getString(R.string.module_status_conflict);
        if ("incompatible".equals(result.state)) return getString(R.string.module_status_incompatible);
        if ("not-implemented".equals(result.state)) return getString(R.string.module_status_unsupported);
        if (result.detail.length() > 0) Log.w("HMG-Seogaemo", "Module status: " + result.detail);
        return getString(R.string.module_status_unknown);
    }

    private FeaturesView.Entry entry(Feature feature) {
        FeaturesView.Entry entry = new FeaturesView.Entry(feature);
        RootResult result = statuses.get(feature.id);
        if (result == null) return entry;
        if (settling.contains(feature.id) && !readable(result)) {
            entry.state = FeatureCard.State.APPLYING;
            return entry;
        }
        if (rechecking.contains(feature.id) && !readable(result)) return entry;
        entry.statusTappable = true;
        if ("pending-restart".equals(result.state)) {
            // Already applied on disk; only the head-unit restart is left, so no spinner.
            entry.state = FeatureCard.State.RESTART;
        } else if (result.exitCode == 0 && "on".equals(result.state)) {
            entry.state = FeatureCard.State.ON;
        } else if (result.exitCode == 0 && "off".equals(result.state)) {
            String blocker = excludedBy(feature.id);
            if (blocker != null) {
                entry.state = FeatureCard.State.UNAVAILABLE;
                entry.note = getString(R.string.note_in_use, blocker);
                entry.noteError = true;
            } else entry.state = FeatureCard.State.OFF;
        } else if (unreachable(result)) {
            entry.state = FeatureCard.State.UNKNOWN;
        } else {
            entry.state = FeatureCard.State.UNAVAILABLE;
            entry.note = reasonText(result);
            entry.noteError = true;
        }
        String note = result.info.get("note");
        if (entry.note == null && note != null && note.length() > 0) entry.note = note;
        return entry;
    }

    private List<FeaturesView.Entry> sortedEntries(List<Feature> features) {
        List<FeaturesView.Entry> list = new ArrayList<FeaturesView.Entry>();
        final Map<String, Integer> groups = new HashMap<String, Integer>();
        for (Feature feature : features) {
            FeaturesView.Entry entry = entry(feature);
            list.add(entry);
            // A status that is momentarily unread keeps its last sorted place instead of jumping groups.
            boolean unread = entry.state == FeatureCard.State.LOADING || entry.state == FeatureCard.State.UNKNOWN;
            Integer known = sortGroups.get(feature.id);
            if (!unread) sortGroups.put(feature.id, group(entry.state));
            groups.put(feature.id, unread && known != null ? known : group(entry.state));
        }
        moduleCache().edit().putString("groups", new JSONObject(sortGroups).toString()).apply();
        final Collator collator = Collator.getInstance(locale());
        Collections.sort(list, new Comparator<FeaturesView.Entry>() {
            public int compare(FeaturesView.Entry left, FeaturesView.Entry right) {
                int byGroup = groups.get(left.feature.id) - groups.get(right.feature.id);
                return byGroup != 0 ? byGroup : collator.compare(left.feature.name, right.feature.name);
            }
        });
        return list;
    }

    private static int group(FeatureCard.State state) {
        if (state == FeatureCard.State.ON || state == FeatureCard.State.APPLYING
                || state == FeatureCard.State.RESTART) return 0;
        if (state == FeatureCard.State.OFF || state == FeatureCard.State.LOADING) return 1;
        return 2;
    }

    private boolean restartPending() {
        for (RootResult status : statuses.values()) if ("pending-restart".equals(status.state)) return true;
        return false;
    }

    private void showFeatures() {
        tab = Tab.FEATURES;
        settingsVisible = false;
        LinearLayout r = root();
        header(r, null);
        featuresView = new FeaturesView(this, new FeaturesView.Listener() {
            public void openDetail(Feature feature) { detailId = feature.id; render(); }
            public void tapStatus(Feature feature) { tapFeatureStatus(feature); }
            public void add() { addVisible = true; render(); }
            public void restartLater() { restartLater = true; featuresView.setRestartPending(false); }
            public void restartNow() { MainActivity.this.restartNow(); }
        });
        r.addView(featuresView, new LinearLayout.LayoutParams(-1, 0, 1));
        featuresView.setEntries(sortedEntries(features()));
        featuresView.setRestartPending(!restartLater && restartPending());
        sortOnLoad = true;
        loadFeatures(true);
    }

    private void restartNow() { confirmReboot(R.string.module_restart_confirm); }

    private void tapFeatureStatus(Feature feature) {
        RootResult result = statuses.get(feature.id);
        if (result == null || settling.contains(feature.id)) return;
        if (readable(result)) { prepareModuleChange(feature, !moduleEnabled(result), false); return; }
        ConfirmDialog.showResult(this, feature.name, unreachable(result)
                ? getString(R.string.module_status_unknown) : reasonText(result), getString(R.string.close));
    }

    /** Reads the installed list and every status on a worker, then updates the cards (re-sorted only on entry). */
    private void loadFeatures(final boolean entering) {
        final int generation = ++loadGeneration;
        final String locale = describeLocale();
        new Thread(new Runnable() { public void run() {
            refreshInstalled(locale);
            final List<Feature> list = features();
            List<String> ids = new ArrayList<String>();
            for (Feature feature : list) ids.add(feature.id);
            final Map<String, RootResult> results = readStatuses(ids);
            runOnUiThread(new Runnable() { public void run() {
                statuses.putAll(results);
                for (Map.Entry<String, RootResult> status : results.entrySet()) {
                    if (!notReady(status.getValue())) continue;
                    Log.w("HMG-Seogaemo", "Status not ready for " + status.getKey() + ": " + status.getValue().state
                            + " " + status.getValue().detail);
                    rechecking.add(status.getKey());
                }
                recheck(1);
                if (generation != loadGeneration || featuresView == null || !featuresVisible()) return;
                boolean sameSet = true;
                for (Feature feature : list) if (!featuresView.shows(feature.id)) sameSet = false;
                if (entering || sortOnLoad || !sameSet) featuresView.setEntries(sortedEntries(list));
                else for (Feature feature : list) featuresView.update(entry(feature));
                sortOnLoad = false;
                featuresView.setRestartPending(!restartLater && restartPending());
            } });
        } }, "hmg-seogaemo-features").start();
    }

    private void refreshAfterOperation() {
        if (featuresVisible()) {
            if (featuresView != null) {
                for (Feature feature : features()) featuresView.update(entry(feature));
                featuresView.setRestartPending(!restartLater && restartPending());
            }
        } else if (detailId != null) render();
        else if (settingsVisible) showSettings();
        else if (tab == Tab.CAR) showCar();
    }

    /** Reads module statuses at once on the calling worker thread. */
    private static Map<String, RootResult> readStatuses(List<String> ids) {
        return ParallelReads.each(ids, new ParallelReads.Read() {
            public RootResult read(String id) { return RootClient.run(id, "status"); }
        });
    }

    /** A status that is neither readable nor a definite reason (conflict, incompatible, unsupported, unreachable). */
    private static boolean notReady(RootResult result) {
        return !readable(result) && !unreachable(result) && !"conflict".equals(result.state)
                && !"incompatible".equals(result.state) && !"not-implemented".equals(result.state);
    }

    /** Re-reads not-ready statuses every 3 s, up to SETTLE_ATTEMPTS times, while the cards show loading. */
    private void recheck(final int attempt) {
        if (rechecking.isEmpty() || (attempt == 1 && recheckRunning)) return;
        recheckRunning = true;
        handler.postDelayed(new Runnable() { public void run() {
            if (isFinishing() || rechecking.isEmpty()) { recheckRunning = false; return; }
            final List<String> ids = new ArrayList<String>(rechecking);
            new Thread(new Runnable() { public void run() {
                final Map<String, RootResult> results = readStatuses(ids);
                runOnUiThread(new Runnable() { public void run() {
                    statuses.putAll(results);
                    for (String id : ids) if (!notReady(results.get(id)) || attempt >= SETTLE_ATTEMPTS) rechecking.remove(id);
                    refreshAfterOperation();
                    if (rechecking.isEmpty()) recheckRunning = false;
                    else recheck(attempt + 1);
                } });
            } }, "hmg-seogaemo-recheck").start();
        } }, 3000);
    }

    /** Modules whose status is momentarily unreadable after an operation show 적용 중 and are re-read. */
    private void settle(final int attempt) {
        if (settling.isEmpty()) return;
        handler.postDelayed(new Runnable() { public void run() {
            if (isFinishing() || settling.isEmpty()) return;
            final List<String> ids = new ArrayList<String>(settling);
            new Thread(new Runnable() { public void run() {
                final Map<String, RootResult> results = readStatuses(ids);
                runOnUiThread(new Runnable() { public void run() {
                    statuses.putAll(results);
                    for (String id : ids) if (readable(results.get(id)) || attempt >= SETTLE_ATTEMPTS) settling.remove(id);
                    refreshAfterOperation();
                    settle(attempt + 1);
                } });
            } }, "hmg-seogaemo-settle").start();
        } }, SETTLE_DELAY_MS);
    }

    private void dispatchModuleAction(ModuleAction action) {
        if (action.type == ModuleAction.Type.ENABLE_MODULE) {
            Feature target = feature(action.target);
            if (target != null) prepareModuleChange(target, true, false);
        } else if (action.type == ModuleAction.Type.OPEN_STOCK_WIFI_SETTINGS) openWifiSettings();
    }

    private void openWifiSettings() {
        try { startActivity(new Intent("android.settings.WIFI_SETTINGS")); }
        catch (ActivityNotFoundException missing) {
            Toast.makeText(this, R.string.screen_unavailable, Toast.LENGTH_SHORT).show();
        }
    }

    private void showDetail(final Feature feature) {
        detailId = feature.id;
        settingsVisible = false;
        LinearLayout r = root();
        header(r, feature.name);
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.HORIZONTAL);
        r.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));

        final LinearLayout panelHolder = vertical();
        panelHolder.setPadding(dp(SettingsUi.LG), dp(SettingsUi.LG), dp(SettingsUi.LG), dp(SettingsUi.LG));
        body.addView(panelHolder, new LinearLayout.LayoutParams(0, -1, 2));
        divider(body, true);
        LinearLayout right = vertical();
        body.addView(right, new LinearLayout.LayoutParams(0, -1, 3));
        TextView optionsTitle = text(getString(R.string.detail_options), 17, MUTED, sans);
        optionsTitle.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.SM));
        right.addView(optionsTitle, new LinearLayout.LayoutParams(-1, -2));
        divider(right, false);
        ScrollView scroll = new ScrollView(this);
        final OptionsList options = new OptionsList(this);
        options.setPadding(dp(SettingsUi.PAGE), 0, dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        scroll.addView(options);
        right.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));

        RootResult cached = statuses.get(feature.id);
        renderDetail(feature, cached, panelHolder, options);
        final String id = feature.id;
        new Thread(new Runnable() { public void run() {
            final RootResult result = RootClient.run(id, "status");
            final SettingsPage page = new SettingsPage();
            if (feature.builtIn != null) feature.builtIn.buildSettingsPage(page);
            runOnUiThread(new Runnable() { public void run() {
                statuses.put(id, result);
                if (!id.equals(detailId)) return;
                renderDetail(feature, result, panelHolder, options);
                if (feature.builtIn != null) {
                    options.removeAllViews();
                    for (SettingsPage.Item item : page.items()) renderPageItem(options, feature, result, item);
                    finishOptions(options, feature, result, page);
                }
            } });
        } }, "hmg-seogaemo-detail").start();
    }

    private void renderDetail(final Feature feature, RootResult result, LinearLayout panelHolder, OptionsList options) {
        panelHolder.removeAllViews();
        FeaturesView.Entry entry = entry(feature);
        boolean on = entry.state == FeatureCard.State.ON;
        LinearLayout panel = vertical();
        int pad = dp(SettingsUi.LG);
        panel.setPadding(pad, pad, pad, pad);
        panel.setBackgroundDrawable(shape(SURFACE, on ? BLUE : HAIRLINE, Theme.CARD_RADIUS));
        panelHolder.addView(panel, new LinearLayout.LayoutParams(-1, -1));
        panel.addView(iconBox(feature.icon, on ? BLUE : MUTED, 72, 42), new LinearLayout.LayoutParams(dp(72), dp(72)));
        TextView name = text(feature.name, 28, WHITE, medium);
        LinearLayout.LayoutParams nameParams = new LinearLayout.LayoutParams(-1, -2);
        nameParams.topMargin = dp(SettingsUi.MD);
        panel.addView(name, nameParams);
        TextView description = text(feature.description, 18, MUTED, sans);
        description.setLineSpacing(dp(4), 1f);
        LinearLayout.LayoutParams descriptionParams = new LinearLayout.LayoutParams(-1, -2);
        descriptionParams.topMargin = dp(SettingsUi.XS);
        panel.addView(description, descriptionParams);
        if (entry.note != null) {
            TextView note = text(entry.note, 18, entry.noteError ? ERROR : WHITE, sans);
            LinearLayout.LayoutParams noteParams = new LinearLayout.LayoutParams(-1, -2);
            noteParams.topMargin = dp(SettingsUi.MD);
            panel.addView(note, noteParams);
        }
        View spacer = new View(this);
        panel.addView(spacer, new LinearLayout.LayoutParams(-1, 0, 1));
        View action;
        if (result == null || entry.state == FeatureCard.State.LOADING) {
            action = text(getString(R.string.state_loading), 20, MUTED, medium);
            ((TextView) action).setGravity(Gravity.CENTER);
        } else if (entry.state == FeatureCard.State.UNKNOWN) {
            action = text(getString(R.string.module_status_unknown), 18, MUTED, sans);
        } else if (entry.state == FeatureCard.State.UNAVAILABLE && !readable(result)) {
            action = text(reasonText(result), 18, ERROR, sans);
        } else {
            final boolean enable = !moduleEnabled(result);
            action = powerButton(getString(enable ? R.string.confirm_turn_on : R.string.confirm_turn_off), enable);
            action.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) { prepareModuleChange(feature, enable, false); }
            });
        }
        LinearLayout.LayoutParams actionParams = new LinearLayout.LayoutParams(-1, dp(Theme.ACTION_HEIGHT));
        actionParams.topMargin = dp(SettingsUi.LG);
        panel.addView(action, actionParams);
        if (feature.installed != null) {
            options.removeAllViews();
            for (String block : feature.installed.uiBlocks) renderUiBlock(options, feature, result, block);
            finishOptions(options, feature, result, null);
        } else if (result == null) {
            options.removeAllViews();
            options.addInfo(getString(R.string.state_loading));
        }
    }

    private LinearLayout powerButton(String label, boolean primary) {
        LinearLayout button = horizontal();
        button.setGravity(Gravity.CENTER);
        button.setBackgroundDrawable(selectable(primary ? BLUE : RAISED, primary ? BLUE : HAIRLINE, Theme.BUTTON_RADIUS, false));
        ImageView glyph = new ImageView(this);
        glyph.setScaleType(ImageView.ScaleType.CENTER);
        glyph.setImageDrawable(new LineIcon(this, "power", WHITE, 22));
        button.addView(glyph, new LinearLayout.LayoutParams(dp(24), dp(24)));
        TextView caption = text(label, 21, WHITE, medium);
        LinearLayout.LayoutParams captionParams = new LinearLayout.LayoutParams(-2, -2);
        captionParams.leftMargin = dp(SettingsUi.SM);
        button.addView(caption, captionParams);
        button.setClickable(true);
        return button;
    }

    private void finishOptions(OptionsList options, final Feature feature, final RootResult result,
            final SettingsPage page) {
        final StringBuilder help = new StringBuilder();
        if (page != null) for (SettingsPage.Item item : page.items()) {
            if (item.type != SettingsPage.Type.NOTE) continue;
            if (help.length() > 0) help.append("\n\n");
            help.append(getString(item.labelResId));
        }
        if (feature.installed != null) for (String block : feature.installed.uiBlocks) {
            String[] tokens = block.trim().split("\\s+");
            if (tokens.length == 0 || !"info".equals(tokens[0])) continue;
            if (help.length() > 0) help.append("\n\n");
            help.append(feature.installed.text(blockArguments(tokens).get("")));
        }
        if (help.length() > 0) options.addLink(getString(R.string.detail_help), new View.OnClickListener() {
            public void onClick(View v) {
                ConfirmDialog.showResult(MainActivity.this, getString(R.string.detail_help), help, getString(R.string.close));
            }
        });
        if (feature.removable()) options.addRemove(getString(R.string.detail_remove), new View.OnClickListener() {
            public void onClick(View v) { confirmRemove(feature); }
        });
        if (diagnosticsEnabled() && result != null) options.addLink(getString(R.string.detail_diagnostics),
                new View.OnClickListener() {
            public void onClick(View v) {
                StringBuilder raw = new StringBuilder();
                if (page != null) for (SettingsPage.Item item : page.items()) {
                    if (item.type != SettingsPage.Type.INFO) continue;
                    String value = result.info.get(item.key);
                    raw.append(getString(item.labelResId)).append(": ")
                            .append(value == null || value.length() == 0 ? "\u2014" : value).append('\n');
                }
                if (feature.installed != null) for (String block : feature.installed.uiBlocks) {
                    String[] tokens = block.trim().split("\\s+");
                    if (tokens.length == 0 || !"value".equals(tokens[0])) continue;
                    Map<String, String> arguments = blockArguments(tokens);
                    String value = arguments.get("key") == null ? null : result.info.get(arguments.get("key"));
                    if (value == null || value.length() == 0) continue;
                    raw.append(feature.installed.text(arguments.get("label"))).append(": ").append(value).append('\n');
                }
                if (raw.length() > 0) raw.append('\n');
                raw.append("state=").append(result.state).append("\nrestart=")
                        .append(result.restart).append("\nexit=").append(result.exitCode)
                        .append("\ndetail=").append(result.detail);
                for (Map.Entry<String, String> value : result.info.entrySet())
                    raw.append("\ninfo.").append(value.getKey()).append('=').append(value.getValue());
                for (Map.Entry<String, String> value : result.warnings.entrySet())
                    raw.append("\nwarn.").append(value.getKey()).append('=').append(value.getValue());
                ConfirmDialog.showResult(MainActivity.this, getString(R.string.detail_diagnostics), raw, getString(R.string.close));
            }
        });
        if (options.getChildCount() == 0) options.addEmpty();
    }

    private void renderPageItem(OptionsList rows, final Feature module, RootResult result, SettingsPage.Item item) {
        switch (item.type) {
            case STATUS_HEADER:
                break;
            case SECTION:
                rows.addSection(getString(item.labelResId));
                break;
            case INFO:
                break; // Diagnostic values belong to the developer-only diagnostics row, not to 옵션.

            case NOTE:
                break; // Guidance text is grouped behind the 도움말 row in finishOptions.
            case WARNING:
                rows.addWarning(getString(item.labelResId));
                break;
            case TOGGLE:
            case CHOICE:
                rows.addValue(getString(item.labelResId), null, false, null);
                break;
            case ACTION:
                final ModuleAction action = item.action;
                View.OnClickListener tap = new View.OnClickListener() {
                    public void onClick(View view) { dispatchModuleAction(action); }
                };
                rows.addLink(getString(item.labelResId), tap);
                break;
        }
    }

    private static Map<String, String> blockArguments(String[] tokens) {
        Map<String, String> arguments = new HashMap<String, String>();
        for (int i = 1; i < tokens.length; i++) {
            int equals = tokens[i].indexOf('=');
            if (equals > 0) arguments.put(tokens[i].substring(0, equals), tokens[i].substring(equals + 1));
            else if (tokens[i].startsWith("@")) arguments.put("", tokens[i]);
        }
        return arguments;
    }

    private Module.Setting declaredSetting(InstalledModule module, String key) {
        for (Module.Setting setting : module.settings) if (setting.key.equals(key)) return setting;
        return null;
    }

    private String settingValue(Feature feature, Module.Setting setting) {
        String cached = getSharedPreferences("module_settings", MODE_PRIVATE)
                .getString(feature.id + "." + setting.key, null);
        return cached == null ? setting.defaultValue : cached;
    }

    /** A choice value shows the module's choice_<setting>_<value> string when it has one. */
    private String settingDisplay(Feature feature, Module.Setting setting, String value) {
        if (setting.type == Module.SettingType.BOOLEAN) return getString("on".equals(value) ? R.string.on : R.string.off);
        String named = feature.installed == null ? null
                : feature.installed.strings.get("choice_" + setting.key + "_" + value);
        return named == null ? value : named;
    }

    private void renderUiBlock(OptionsList rows, final Feature feature, RootResult result, String block) {
        String[] tokens = block.trim().split("\\s+");
        if (tokens.length == 0) return;
        final String type = tokens[0];
        final Map<String, String> arguments = blockArguments(tokens);
        final InstalledModule installed = feature.installed;
        final String label = arguments.containsKey("label") ? installed.text(arguments.get("label")) : "";
        if ("status".equals(type)) return;
        // when=<key> shows the block only while the last status reports info.<key>=1 (e.g. a radio is present).
        String when = arguments.get("when");
        if (when != null && (result == null || !"1".equals(result.info.get(when)))) return;
        // info text goes behind 도움말 and value rows into the developer-only diagnostics (finishOptions),
        // so 옵션 holds only what the user can change, as for built-in modules.
        if ("info".equals(type) || "value".equals(type)) return;
        if ("warning".equals(type)) {
            rows.addWarning(installed.text(arguments.containsKey("") ? arguments.get("") : ""));
        } else if ("toggle".equals(type) || "choice".equals(type) || "number".equals(type)) {
            final Module.Setting setting = declaredSetting(installed, arguments.get("setting"));
            if (setting == null) return;
            final String current = settingValue(feature, setting);
            rows.addValue(label, settingDisplay(feature, setting, current), true, new View.OnClickListener() {
                public void onClick(View view) {
                    if (setting.type == Module.SettingType.BOOLEAN)
                        confirmSetting(feature, setting, label, "on".equals(current) ? "off" : "on");
                    else if (setting.type == Module.SettingType.CHOICE) chooseSetting(feature, setting, label, current);
                    else adjustSetting(feature, setting, label, current);
                }
            });
        } else if ("button".equals(type)) {
            final String name = arguments.get("name");
            final String confirm = arguments.containsKey("confirm") ? installed.text(arguments.get("confirm")) : label;
            // danger=1: the action deletes something; the confirm uses the destructive style.
            final boolean danger = "1".equals(arguments.get("danger"));
            boolean on = result != null && "on".equals(result.state) && RootClient.validActionName(name);
            rows.addAction(label, getString(R.string.option_run), false, on, new View.OnClickListener() {
                public void onClick(View view) { confirmAction(feature, name, label, confirm, danger); }
            });
        } else if ("enable".equals(type)) {
            final Feature target = feature(arguments.get("module"));
            if (target == null) return;
            rows.addLink(label, new View.OnClickListener() {
                public void onClick(View view) { prepareModuleChange(target, true, false); }
            });
        } else if ("open".equals(type) && "wifi_settings".equals(arguments.get("screen"))) {
            rows.addLink(getString(R.string.option_open_wifi_settings), new View.OnClickListener() {
                public void onClick(View view) { openWifiSettings(); }
            });
        } else if ("open".equals(type) && "wifi_networks".equals(arguments.get("screen"))) {
            rows.addLink(getString(R.string.wifi_networks_open), new View.OnClickListener() {
                public void onClick(View view) { showWifiNetworks(feature); }
            });
        } else if ("pick_app".equals(type)) {
            final String slot = arguments.get("slot");
            if (!"head".equals(slot) && !"swrc".equals(slot)) return;
            final Module.Setting setting = declaredSetting(installed, arguments.get("setting"));
            if (setting == null) return;
            final boolean assigned = "on".equals(settingValue(feature, setting));
            rows.addValue(label, assigned ? appLabel(UserButtonReceiver.target(this, slot))
                    : getString(R.string.user_button_stock), true, new View.OnClickListener() {
                public void onClick(View view) { pickApp(feature, setting, assigned, slot, label); }
            });
        }
    }

    private String appLabel(String pkg) {
        if (pkg.length() == 0) return "HMG-Seogaemo";
        try {
            PackageManager pm = getPackageManager();
            return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString();
        } catch (PackageManager.NameNotFoundException e) {
            return "HMG-Seogaemo";
        }
    }

    /** App the user button opens: stored in this app only; root never sees it. */
    private void pickApp(final Feature feature, final Module.Setting setting, final boolean assigned,
            final String slot, String label) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        // null = the button keeps its stock function (setting off); "" = HMG-Seogaemo.
        final List<String> packages = new ArrayList<String>();
        packages.add(null);
        packages.add("");
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        final PackageManager pm = getPackageManager();
        List<android.content.pm.ResolveInfo> found = pm.queryIntentActivities(launcher, 0);
        final Map<String, String> labels = new HashMap<String, String>();
        for (android.content.pm.ResolveInfo info : found) {
            String pkg = info.activityInfo.packageName;
            if (getPackageName().equals(pkg) || labels.containsKey(pkg)) continue;
            labels.put(pkg, info.loadLabel(pm).toString());
            packages.add(pkg);
        }
        Collections.sort(packages.subList(2, packages.size()), new Comparator<String>() {
            public int compare(String a, String b) { return labels.get(a).compareToIgnoreCase(labels.get(b)); }
        });
        final String current = assigned ? UserButtonReceiver.target(this, slot) : null;
        final String[] chosen = {current};
        final LinearLayout list = vertical();
        final List<TextView> markers = new ArrayList<TextView>();
        for (final String pkg : packages) {
            LinearLayout row = horizontal();
            row.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
            String name = pkg == null ? getString(R.string.user_button_stock)
                    : pkg.length() == 0 ? "HMG-Seogaemo" : labels.get(pkg);
            boolean selected = pkg == null ? current == null : pkg.equals(current);
            row.addView(text(name, 22, WHITE, medium), new LinearLayout.LayoutParams(0, -1, 1));
            TextView marker = text(getString(selected ? R.string.radio_selected : R.string.radio_unselected),
                    28, selected ? BLUE : MUTED, sans);
            marker.setGravity(Gravity.CENTER);
            row.addView(marker, new LinearLayout.LayoutParams(dp(60), -1));
            markers.add(marker);
            row.setOnClickListener(new View.OnClickListener() {
                public void onClick(View view) {
                    chosen[0] = pkg;
                    for (int i = 0; i < markers.size(); i++) {
                        String other = packages.get(i);
                        boolean selected = other == null ? pkg == null : other.equals(pkg);
                        markers.get(i).setText(getString(selected ? R.string.radio_selected : R.string.radio_unselected));
                        markers.get(i).setTextColor(selected ? BLUE : MUTED);
                    }
                }
            });
            list.addView(row, new LinearLayout.LayoutParams(-1, dp(Theme.ACTION_HEIGHT)));
            divider(list, false);
        }
        ConfirmDialog.showView(this, label, list, getString(R.string.apply), getString(R.string.cancel), false,
                new ConfirmDialog.Action() {
                    public void run(ConfirmDialog dialog) {
                        String pkg = chosen[0];
                        if (pkg != null) getSharedPreferences(UserButtonReceiver.PREFS, MODE_PRIVATE).edit()
                                .putString("target_" + slot, pkg).apply();
                        // Only the stock/assigned switch reaches root; the chosen app stays in the app.
                        if ((pkg != null) != assigned) applySetting(feature, setting, pkg != null ? "on" : "off", dialog);
                        else { dialog.dismiss(); showDetail(feature); }
                    }
                }, null);
    }

    private void confirmSetting(final Feature feature, final Module.Setting setting, String label, final String value) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        String display = settingDisplay(feature, setting, value);
        ConfirmDialog.show(this, getString(R.string.option_set_confirm, label, display),
                getString(R.string.option_set_note), getString(R.string.apply), getString(R.string.cancel), false,
                new ConfirmDialog.Action() { public void run(ConfirmDialog dialog) { applySetting(feature, setting, value, dialog); } },
                null);
    }

    private void chooseSetting(final Feature feature, final Module.Setting setting, String label, String current) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        final String[] chosen = {current};
        final LinearLayout list = vertical();
        final List<TextView> markers = new ArrayList<TextView>();
        for (final String value : setting.allowedValues) {
            LinearLayout row = horizontal();
            row.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
            row.addView(text(settingDisplay(feature, setting, value), 22, WHITE, medium), new LinearLayout.LayoutParams(0, -1, 1));
            TextView marker = text(getString(value.equals(current) ? R.string.radio_selected : R.string.radio_unselected),
                    28, value.equals(current) ? BLUE : MUTED, sans);
            marker.setGravity(Gravity.CENTER);
            row.addView(marker, new LinearLayout.LayoutParams(dp(60), -1));
            markers.add(marker);
            row.setOnClickListener(new View.OnClickListener() {
                public void onClick(View view) {
                    chosen[0] = value;
                    for (int i = 0; i < markers.size(); i++) {
                        boolean selected = setting.allowedValues[i].equals(value);
                        markers.get(i).setText(getString(selected ? R.string.radio_selected : R.string.radio_unselected));
                        markers.get(i).setTextColor(selected ? BLUE : MUTED);
                    }
                }
            });
            list.addView(row, new LinearLayout.LayoutParams(-1, dp(Theme.ACTION_HEIGHT)));
            divider(list, false);
        }
        ConfirmDialog.showView(this, label, list, getString(R.string.apply), getString(R.string.cancel), false,
                new ConfirmDialog.Action() {
                    public void run(ConfirmDialog dialog) { applySetting(feature, setting, chosen[0], dialog); }
                }, null);
    }

    private void adjustSetting(final Feature feature, final Module.Setting setting, String label, String current) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        final long min = Long.parseLong(setting.allowedValues[0]);
        final long max = Long.parseLong(setting.allowedValues[1]);
        final long[] value = {Long.parseLong(current)};
        LinearLayout stepper = horizontal();
        stepper.setGravity(Gravity.CENTER);
        TextView minus = Theme.button(this, "\u2212", false, false);
        final TextView number = text(current, 34, WHITE, medium);
        number.setGravity(Gravity.CENTER);
        TextView plus = Theme.button(this, "+", false, false);
        stepper.addView(minus, new LinearLayout.LayoutParams(dp(120), dp(Theme.ACTION_HEIGHT)));
        stepper.addView(number, new LinearLayout.LayoutParams(dp(220), dp(Theme.ACTION_HEIGHT)));
        stepper.addView(plus, new LinearLayout.LayoutParams(dp(120), dp(Theme.ACTION_HEIGHT)));
        minus.setOnClickListener(new View.OnClickListener() {
            public void onClick(View view) { if (value[0] > min) { value[0]--; number.setText(String.valueOf(value[0])); } }
        });
        plus.setOnClickListener(new View.OnClickListener() {
            public void onClick(View view) { if (value[0] < max) { value[0]++; number.setText(String.valueOf(value[0])); } }
        });
        ConfirmDialog.showView(this, label, stepper, getString(R.string.apply), getString(R.string.cancel), false,
                new ConfirmDialog.Action() {
                    public void run(ConfirmDialog dialog) { applySetting(feature, setting, String.valueOf(value[0]), dialog); }
                }, null);
    }

    private void applySetting(final Feature feature, final Module.Setting setting, final String value,
            final ConfirmDialog dialog) {
        moduleWorking = true;
        dialog.showProgress();
        new Thread(new Runnable() { public void run() {
            final RootResult result = RootClient.moduleSet(feature.id, setting.key, value);
            runOnUiThread(new Runnable() { public void run() {
                moduleWorking = false;
                dialog.dismiss();
                if (result.exitCode == 0) {
                    getSharedPreferences("module_settings", MODE_PRIVATE).edit()
                            .putString(feature.id + "." + setting.key, value).apply();
                    refreshAfterOperation();
                } else showFailure(getString(R.string.module_result_failed), result.detail);
            } });
        } }, "hmg-seogaemo-setting").start();
    }

    private final java.util.LinkedList<String> recentErrors = new java.util.LinkedList<String>();

    /** Failure dialog with a direct way to send a problem report; the message is kept for that report. */
    private void showFailure(String title, CharSequence detail) {
        recentErrors.addLast(new java.text.SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(new java.util.Date())
                + " " + title + ": " + detail);
        while (recentErrors.size() > 20) recentErrors.removeFirst();
        ConfirmDialog.show(this, title, detail, getString(R.string.report_export), getString(R.string.close), false,
                new ConfirmDialog.Action() { public void run(ConfirmDialog dialog) { dialog.dismiss(); confirmReport(); } },
                null);
    }

    /** Large choice cards (icon, title, note); the first is selected and choice[0] follows taps. */
    private LinearLayout choiceCards(String[] icons, int[] titles, int[] notes, final int[] choice) {
        LinearLayout cards = horizontal();
        final LinearLayout[] boxes = new LinearLayout[icons.length];
        for (int i = 0; i < boxes.length; i++) {
            final int index = i;
            LinearLayout box = vertical();
            box.setGravity(Gravity.CENTER);
            ImageView glyph = new ImageView(this);
            glyph.setImageDrawable(new LineIcon(this, icons[i], BLUE, 40));
            box.addView(glyph, new LinearLayout.LayoutParams(dp(48), dp(48)));
            TextView title = text(getString(titles[i]), 22, WHITE, medium);
            title.setGravity(Gravity.CENTER);
            title.setPadding(dp(SettingsUi.SM), 0, dp(SettingsUi.SM), 0);
            LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-2, -2);
            titleParams.topMargin = dp(SettingsUi.SM);
            box.addView(title, titleParams);
            box.addView(text(getString(notes[i]), 18, MUTED, sans), new LinearLayout.LayoutParams(-2, -2));
            box.setBackgroundDrawable(shape(SURFACE, i == 0 ? BLUE : HAIRLINE, Theme.CARD_RADIUS));
            box.setOnClickListener(new View.OnClickListener() {
                public void onClick(View view) {
                    choice[0] = index;
                    for (int j = 0; j < boxes.length; j++)
                        boxes[j].setBackgroundDrawable(shape(SURFACE, j == index ? BLUE : HAIRLINE, Theme.CARD_RADIUS));
                }
            });
            boxes[i] = box;
            LinearLayout.LayoutParams boxParams = new LinearLayout.LayoutParams(0, dp(170), 1);
            if (i < boxes.length - 1) boxParams.rightMargin = dp(SettingsUi.MD);
            cards.addView(box, boxParams);
        }
        return cards;
    }

    /**
     * Problem report: export everything to USB once, export it and open a GitHub issue from a QR code,
     * or keep recording to USB until turned off.
     */
    private void confirmReport() {
        if (stockBusy || mapBusy) return;
        final int[] choice = {0};
        LinearLayout cards = choiceCards(new String[] {"download", "phone", "record"},
                new int[] {R.string.report_now, R.string.report_issue, R.string.report_record},
                new int[] {R.string.report_now_note, R.string.report_issue_note, R.string.report_record_note}, choice);
        ConfirmDialog.showView(this, getString(R.string.report_export), cards, getString(R.string.report_start),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                if (choice[0] == 2) {
                    ReportsSection.startRecording(MainActivity.this, dialog, new Runnable() {
                        public void run() { if (tab == Tab.SETTINGS) showSettings(); }
                    });
                    return;
                }
                final boolean issue = choice[0] == 1;
                dialog.showProgress();
                writeAppState();
                new Thread(new Runnable() { public void run() {
                    final RootResult result = RootClient.exportReport(true);
                    final RootResult digest = issue ? RootClient.reportDigest() : null;
                    runOnUiThread(new Runnable() { public void run() {
                        dialog.dismiss();
                        // The issue still opens without a USB drive; the QR carries the summary and logs.
                        if (issue) showIssueQr(false, exportMessage(result), digest);
                        else ConfirmDialog.showResult(MainActivity.this, getString(R.string.report_export),
                                result.exitCode == 0 ? getString(R.string.report_done, exportMessage(result))
                                        : exportMessage(result), getString(R.string.close));
                    } });
                } }, "report-export").start();
            }
        }, null);
    }

    /**
     * Read-only QR code for a prefilled GitHub issue (problem report or new firmware map). It carries only
     * firmware ids, versions and map/module states; the exported folder is attached from the phone or a PC.
     */
    private void showIssueQr(boolean mapIssue, String exported, RootResult digest) {
        String product = systemProperty("ro.build.product");
        String onebin = systemProperty("ro.mobis.onebindir");
        String versions = "app " + installedVersion();
        StringBuilder map = new StringBuilder();
        if (mapStatus == null) map.append("unknown");
        else {
            map.append("state=").append(mapStatus.state);
            for (String key : new String[] {"source", "mapped", "verified", "failed"}) {
                String value = mapStatus.info.get(key);
                if (value != null) map.append(' ').append(key).append('=').append(value);
            }
            String failing = mapStatus.info.get("failing_ids");
            if (failing != null && failing.length() > 0) map.append("\nfailing=").append(failing);
        }
        String link;
        if (mapIssue) {
            link = IssueLink.build(IssueLink.TEMPLATE_MAP, "Map: " + product, 700, "product", product, "onebin", onebin,
                    "android", Build.VERSION.RELEASE, "versions", versions, "map-status", map.toString());
        } else {
            StringBuilder modules = new StringBuilder();
            for (String id : new java.util.TreeSet<String>(statuses.keySet())) {
                RootResult status = statuses.get(id);
                if (modules.length() > 0) modules.append('\n');
                modules.append(id).append('=').append(status.state);
                if (status.exitCode != 0 || !"on".equals(status.state) && !"off".equals(status.state))
                    modules.append(" (").append(shorten(status.detail, 60)).append(')');
            }
            // Packed log, most important first: IssueLink keeps the leading lines that fit the QR.
            StringBuilder logs = new StringBuilder("# app ").append(installedVersion()).append(" android=")
                    .append(Build.VERSION.RELEASE).append(" locale=").append(describeLocale());
            if (foreignStatus != null) logs.append(" foreign=").append(foreignStatus.info.get("count"));
            if (exported != null) logs.append("\nexport: ").append(exported);
            if (!recentErrors.isEmpty()) logs.append("\n# app errors");
            for (java.util.Iterator<String> it = recentErrors.descendingIterator(); it.hasNext(); )
                logs.append('\n').append(shorten(it.next(), 200));
            if (digest == null || digest.exitCode != 0)
                logs.append("\n# root digest unavailable: ").append(digest == null ? "-" : digest.detail);
            else for (String key : new java.util.TreeSet<String>(digest.info.keySet()))
                if (key.startsWith("log_")) logs.append('\n').append(digest.info.get(key));
            link = IssueLink.build(IssueLink.TEMPLATE_BUG, null, 990, "product", product, "onebin", onebin,
                    "versions", versions, "map-status", map.toString(), "modules", modules.toString());
            link = IssueLink.withLog(link, "app-log", logs.toString(), 990);
        }
        LinearLayout body = horizontal();
        body.setGravity(Gravity.CENTER_VERTICAL);
        final View qr = new QrView(this, QrCode.encode(link));
        body.addView(qr, new LinearLayout.LayoutParams(dp(250), dp(250)));
        String guide = getString(mapIssue ? R.string.issue_qr_map_hint : R.string.issue_qr_hint);
        TextView hint = text(exported == null ? guide : exported + "\n\n" + guide, 19, WHITE, sans);
        hint.setLineSpacing(dp(4), 1f);
        LinearLayout.LayoutParams hintParams = new LinearLayout.LayoutParams(0, -2, 1);
        hintParams.leftMargin = dp(SettingsUi.LG);
        body.addView(hint, hintParams);
        ConfirmDialog.showResultView(this, getString(mapIssue ? R.string.issue_qr_map : R.string.report_issue),
                body, getString(R.string.close));
        // The dialog body scrolls; a QR taller than the room the window leaves would be cut off and
        // unreadable, so shrink it once the real height is known.
        final LinearLayout measured = body;
        body.post(new Runnable() { public void run() {
            View viewport = (View) measured.getParent();
            int overflow = viewport == null ? 0 : measured.getHeight() - viewport.getHeight();
            if (overflow <= 0) return;
            int side = Math.max(dp(160), qr.getHeight() - overflow);
            qr.setLayoutParams(new LinearLayout.LayoutParams(side, side));
        } });
    }

    private static String shorten(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, max - 1) + "\u2026";
    }

    /** Hidden android.os.SystemProperties read; an empty string when unavailable. */
    private static String systemProperty(String key) {
        try {
            Object value = Class.forName("android.os.SystemProperties").getMethod("get", String.class).invoke(null, key);
            return value == null ? "" : value.toString();
        } catch (Exception e) {
            return "";
        }
    }

    /** The app's own view for a problem report: version, what each card showed and recent failures. */
    private void writeAppState() {
        StringBuilder state = new StringBuilder();
        state.append("app=").append(installedVersion()).append('\n');
        state.append("locale=").append(describeLocale()).append('\n');
        state.append("android=").append(Build.VERSION.RELEASE).append(" product=").append(Build.PRODUCT).append('\n');
        for (Map.Entry<String, RootResult> status : statuses.entrySet()) {
            RootResult result = status.getValue();
            state.append("status.").append(status.getKey()).append('=').append(result.state).append(" exit=")
                    .append(result.exitCode).append(" detail=").append(result.detail).append('\n');
        }
        if (mapStatus != null) state.append("map=").append(mapStatus.state).append(' ').append(mapStatus.detail).append('\n');
        for (String error : recentErrors) state.append("error ").append(error).append('\n');
        try {
            File dir = new File(getFilesDir(), "report");
            if (!dir.isDirectory() && !dir.mkdirs()) return;
            OutputStream out = new FileOutputStream(new File(dir, "app-state.txt"));
            try { out.write(state.toString().getBytes("UTF-8")); } finally { out.close(); }
        } catch (java.io.IOException error) {
            Log.w("HMG-Seogaemo", "Could not write app state for the report", error);
        }
    }

    /** USB Wi-Fi networks from the wifi module's scan; a row is picked, then the join is confirmed. */
    private void showWifiNetworks(final Feature feature) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        final LinearLayout holder = vertical();
        LinearLayout loading = horizontal();
        loading.setGravity(Gravity.CENTER);
        loading.addView(new android.widget.ProgressBar(this), new LinearLayout.LayoutParams(dp(40), dp(40)));
        holder.addView(loading, new LinearLayout.LayoutParams(-1, dp(120)));
        final WifiNetwork[] chosen = {null};
        final boolean[] closed = {false};
        final ConfirmDialog dialog = ConfirmDialog.showView(this, getString(R.string.wifi_networks_title), holder,
                getString(R.string.wifi_next), getString(R.string.cancel), false, new ConfirmDialog.Action() {
                    public void run(ConfirmDialog picked) {
                        closed[0] = true;
                        picked.dismiss();
                        confirmWifiJoin(feature, chosen[0]);
                    }
                }, new Runnable() { public void run() { closed[0] = true; } });
        if (dialog == null) return;
        dialog.setReady(false);
        new Thread(new Runnable() { public void run() {
            final RootResult result = RootClient.moduleAction(feature.id, "wifi_scan");
            runOnUiThread(new Runnable() { public void run() {
                if (closed[0] || isFinishing()) return;
                if (result.exitCode != 0) {
                    closed[0] = true;
                    dialog.dismiss();
                    showFailure(getString(R.string.module_result_failed), result.detail);
                    return;
                }
                holder.removeAllViews();
                final List<WifiNetwork> options = new ArrayList<WifiNetwork>(WifiNetwork.parse(result.info));
                options.add(null); // typed by hand: hidden networks, or a unit without wpa_cli
                final List<TextView> markers = new ArrayList<TextView>();
                for (int i = 0; i < options.size(); i++) {
                    final int index = i;
                    WifiNetwork network = options.get(i);
                    LinearLayout row = horizontal();
                    row.setBackgroundDrawable(selectable(SURFACE, Color.TRANSPARENT, 0, false));
                    row.addView(text(network == null ? getString(R.string.wifi_network_other) : network.name,
                            22, WHITE, medium), new LinearLayout.LayoutParams(0, -1, 1));
                    TextView marker = text(getString(R.string.radio_unselected), 28, MUTED, sans);
                    marker.setGravity(Gravity.CENTER);
                    row.addView(marker, new LinearLayout.LayoutParams(dp(60), -1));
                    markers.add(marker);
                    row.setOnClickListener(new View.OnClickListener() {
                        public void onClick(View view) {
                            chosen[0] = options.get(index);
                            for (int m = 0; m < markers.size(); m++) {
                                markers.get(m).setText(getString(m == index ? R.string.radio_selected : R.string.radio_unselected));
                                markers.get(m).setTextColor(m == index ? BLUE : MUTED);
                            }
                            dialog.setReady(true);
                        }
                    });
                    holder.addView(row, new LinearLayout.LayoutParams(-1, dp(Theme.ACTION_HEIGHT)));
                    divider(holder, false);
                }
            } });
        } }, "hmg-seogaemo-wifi-scan").start();
    }

    private android.widget.EditText wifiField(String hint, boolean secret) {
        android.widget.EditText field = new android.widget.EditText(this);
        field.setHint(hint);
        field.setSingleLine(true);
        field.setTextSize(22 * Theme.TEXT_SCALE);
        field.setTextColor(WHITE);
        field.setHintTextColor(MUTED);
        field.setBackgroundDrawable(shape(RAISED, HAIRLINE, Theme.BUTTON_RADIUS));
        field.setPadding(dp(SettingsUi.MD), 0, dp(SettingsUi.MD), 0);
        field.setInputType(android.text.InputType.TYPE_CLASS_TEXT | (secret
                ? android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD : 0));
        return field;
    }

    /** Name (typed network only) and passphrase; the confirm writes the join request and runs wifi_join. */
    private void confirmWifiJoin(final Feature feature, final WifiNetwork network) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        LinearLayout form = vertical();
        final android.widget.EditText name = network == null ? wifiField(getString(R.string.wifi_network_name), false) : null;
        final android.widget.EditText password = network == null || network.needsPassword()
                ? wifiField(getString(R.string.wifi_network_password), true) : null;
        for (android.widget.EditText field : new android.widget.EditText[] {name, password}) {
            if (field == null) continue;
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(Theme.ACTION_HEIGHT));
            params.bottomMargin = dp(SettingsUi.MD);
            form.addView(field, params);
        }
        if (password == null) form.addView(text(getString(R.string.wifi_network_open), 20, MUTED, sans),
                new LinearLayout.LayoutParams(-1, -2));
        final ConfirmDialog dialog = ConfirmDialog.showView(this,
                network == null ? getString(R.string.wifi_network_other) : network.name, form,
                getString(R.string.wifi_connect), getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(final ConfirmDialog confirmed) {
                moduleWorking = true;
                confirmed.showProgress();
                final byte[] ssid = network == null ? WifiNetwork.bytes(name.getText().toString()) : network.ssid;
                final String passphrase = password == null ? "" : password.getText().toString();
                new Thread(new Runnable() { public void run() {
                    File request = new File(new File(getFilesDir(), "wifi"), "usb-join");
                    RootResult result;
                    try {
                        request.getParentFile().mkdirs();
                        OutputStream out = new FileOutputStream(request);
                        try { out.write(WifiNetwork.bytes(WifiNetwork.request(ssid, passphrase))); }
                        finally { out.close(); }
                        result = RootClient.moduleAction(feature.id, "wifi_join");
                    } catch (Exception error) {
                        result = new RootResult("failed", "none", error.getClass().getSimpleName(), 1, null);
                    } finally {
                        request.delete(); // holds the derived key; root has already copied it
                    }
                    final RootResult outcome = result;
                    runOnUiThread(new Runnable() { public void run() {
                        moduleWorking = false;
                        confirmed.dismiss();
                        if (outcome.exitCode == 0) refreshAfterOperation();
                        else showFailure(getString(R.string.module_result_failed), outcome.detail);
                    } });
                } }, "hmg-seogaemo-wifi-join").start();
            }
        }, null);
        if (dialog == null) return;
        final Runnable check = new Runnable() { public void run() {
            boolean ready = (name == null || WifiNetwork.validName(name.getText().toString())) &&
                    (password == null || (network == null && password.length() == 0) ||
                            WifiNetwork.validPassphrase(password.getText().toString()));
            dialog.setReady(ready);
        } };
        android.text.TextWatcher watcher = new android.text.TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            public void onTextChanged(CharSequence s, int start, int before, int count) { }
            public void afterTextChanged(android.text.Editable s) { check.run(); }
        };
        if (name != null) name.addTextChangedListener(watcher);
        if (password != null) password.addTextChangedListener(watcher);
        check.run();
    }

    private void confirmAction(final Feature feature, final String name, final String label, String question,
            boolean destructive) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        ConfirmDialog.show(this, question, null, getString(R.string.option_run), getString(R.string.cancel), destructive,
                new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) {
                moduleWorking = true;
                dialog.dismiss();
                final StepProgressDialog progress = StepProgressDialog.show(MainActivity.this, feature.name,
                        java.util.Collections.singletonList(label));
                if (progress != null) progress.setStep(0, StepProgressDialog.RUNNING);
                new Thread(new Runnable() { public void run() {
                    final RootResult result = RootClient.moduleAction(feature.id, name);
                    runOnUiThread(new Runnable() { public void run() {
                        moduleWorking = false;
                        if (progress != null) progress.dismiss();
                        if (result.exitCode == 0) refreshAfterOperation();
                        else showFailure(getString(R.string.module_result_failed), result.detail);
                    } });
                } }, "hmg-seogaemo-action").start();
            }
        }, null);
    }

    private void confirmRemove(final Feature feature) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        ConfirmDialog.show(this, getString(R.string.detail_remove_confirm_title, feature.name, particle(feature.name)),
                getString(R.string.detail_remove_confirm), getString(R.string.detail_remove), getString(R.string.cancel), true,
                new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                moduleWorking = true;
                dialog.dismiss();
                final StepProgressDialog progress = StepProgressDialog.show(MainActivity.this,
                        getString(R.string.detail_remove), java.util.Collections.singletonList(
                                getString(R.string.detail_remove_step, feature.name)));
                if (progress != null) progress.setStep(0, StepProgressDialog.RUNNING);
                new Thread(new Runnable() { public void run() {
                    final RootResult result = RootClient.moduleRemove(feature.id);
                    refreshInstalled(describeLocale());
                    runOnUiThread(new Runnable() { public void run() {
                        moduleWorking = false;
                        if (progress != null) progress.dismiss();
                        if (result.exitCode == 0) {
                            statuses.remove(feature.id);
                            goBack();
                            ConfirmDialog.showResult(MainActivity.this, getString(R.string.detail_remove),
                                    getString(R.string.detail_removed_done, feature.name), getString(R.string.close));
                        }
                        else showFailure(getString(R.string.module_result_failed), result.detail);
                    } });
                } }, "hmg-seogaemo-remove").start();
            }
        }, null);
    }

    private void prepareModuleChange(final Feature module, final boolean enable,
            final boolean forUpdate) {
        if (modulePlanning || moduleWorking || stockBusy) return;
        modulePlanning = true;
        // The confirm appears at once with a disabled button; the plan and precheck fill it in.
        final LinearLayout holder = vertical();
        LinearLayout loading = horizontal();
        loading.setGravity(Gravity.CENTER);
        loading.addView(new android.widget.ProgressBar(this), new LinearLayout.LayoutParams(dp(40), dp(40)));
        holder.addView(loading, new LinearLayout.LayoutParams(-1, dp(120)));
        final ModulePlan[] ready = {null};
        final boolean[] closed = {false};
        final ConfirmDialog dialog = ConfirmDialog.showView(this,
                getString(enable ? R.string.confirm_turn_on_title : R.string.confirm_turn_off_title,
                        module.name, particle(module.name)), holder,
                getString(forUpdate ? R.string.update_enable_wifi : enable ? R.string.confirm_turn_on : R.string.confirm_turn_off),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
                    public void run(ConfirmDialog confirmed) {
                        if (ready[0] == null) return;
                        confirmed.dismiss();
                        runPlan(module, enable, ready[0], forUpdate);
                    }
                }, new Runnable() { public void run() { closed[0] = true; modulePlanning = false; } });
        if (dialog == null) { modulePlanning = false; return; }
        dialog.setReady(false);
        new Thread(new Runnable() {
            public void run() {
                final ModulePlan plan;
                try { plan = new ModuleManager(MainActivity.this).plan(module.id, enable); }
                catch (final IllegalStateException error) {
                    runOnUiThread(new Runnable() {
                        public void run() {
                            if (closed[0]) return;
                            modulePlanning = false;
                            dialog.dismiss();
                            showFailure(getString(R.string.module_result_failed), error.getMessage());
                        }
                    });
                    return;
                }
                final RootResult precheck = enable ? RootClient.run(module.id, "precheck") : null;
                runOnUiThread(new Runnable() {
                    public void run() {
                        if (closed[0]) return;
                        modulePlanning = false;
                        holder.removeAllViews();
                        holder.addView(planSummary(module, enable, plan, precheck, forUpdate),
                                new LinearLayout.LayoutParams(-1, -2));
                        ready[0] = plan;
                        dialog.setReady(true);
                    }
                });
            }
        }, "module-plan").start();
    }

    private String resultLine(Feature feature, boolean enable) {
        if (feature.installed != null) return feature.installed.strings.get(enable ? "on_result" : "off_result");
        if (feature.builtIn == null) return null;
        int id = getResources().getIdentifier(feature.id.replace('-', '_') + (enable ? "_on_result" : "_off_result"),
                "string", getPackageName());
        return id == 0 ? null : getString(id);
    }

    private boolean stepNeedsRestart(ModulePlan.Step step) {
        Feature target = feature(step.id);
        if (target == null) return false;
        return step.enable ? target.needsHeadUnitRestart() && !target.rebootRestore() : target.needsHeadUnitRestart();
    }

    private PlanSummaryView planSummary(Feature module, boolean enable, ModulePlan plan, RootResult precheck,
            boolean forUpdate) {
        PlanSummaryView summary = new PlanSummaryView(this);
        if (forUpdate) summary.addLine(getString(R.string.update_wifi_required), WHITE);
        boolean restart = false;
        for (ModulePlan.Step step : plan.steps) {
            Feature target = feature(step.id);
            summary.addStep(target == null ? "box" : target.icon, target == null ? step.id : target.name,
                    getString(step.enable ? R.string.confirm_turn_on : R.string.confirm_turn_off),
                    step.enable ? BLUE : WHITE);
            if (stepNeedsRestart(step)) restart = true;
        }
        if (restart) summary.addStep("restart", getString(R.string.plan_restart_name), getString(R.string.plan_restart_verb), WHITE);
        String line = resultLine(module, enable);
        if (line != null) summary.addLine(line, WHITE);
        if (!enable && module.rebootRestore())
            summary.addLine(getString(R.string.module_restore_reboot), MUTED);
        if (plan.steps.isEmpty()) summary.addLine(getString(R.string.module_no_changes), MUTED);
        if (precheck != null) {
            if (module.builtIn != null) for (Warning warning : module.builtIn.enableWarnings()) {
                if ("1".equals(precheck.warnings.get(warning.checkKey)))
                    summary.addLine(getString(warning.messageResId), WARNING);
            }
            if (module.installed != null) for (Map.Entry<String, String> warning : precheck.warnings.entrySet()) {
                if ("1".equals(warning.getValue())) summary.addLine(module.installed.text(warning.getKey()), WARNING);
            }
            if (precheck.exitCode != 0) summary.addLine(precheck.detail, ERROR);
        }
        return summary;
    }

    private void runPlan(final Feature module, final boolean enable, final ModulePlan plan, final boolean forUpdate) {
        moduleWorking = true;
        List<String> labels = new ArrayList<String>();
        boolean restart = false;
        for (ModulePlan.Step step : plan.steps) {
            Feature target = feature(step.id);
            labels.add(getString(step.enable ? R.string.plan_step_enable : R.string.plan_step_disable,
                    target == null ? step.id : target.name));
            if (stepNeedsRestart(step)) restart = true;
        }
        final int restartIndex = restart ? labels.size() : -1;
        if (restart) labels.add(getString(R.string.progress_prepare_restart));
        final StepProgressDialog progress = StepProgressDialog.show(this,
                getString(enable ? R.string.progress_turning_on : R.string.progress_turning_off, module.name), labels);
        final ModuleManager.StepListener listener = new ModuleManager.StepListener() {
            public void started(final int index, ModulePlan.Step step) {
                runOnUiThread(new Runnable() { public void run() {
                    if (progress != null) progress.setStep(index, StepProgressDialog.RUNNING);
                } });
            }
            public void finished(final int index, ModulePlan.Step step, final RootResult result) {
                runOnUiThread(new Runnable() { public void run() {
                    if (progress != null) progress.setStep(index,
                            result.exitCode == 0 ? StepProgressDialog.DONE : StepProgressDialog.FAILED);
                } });
            }
        };
        new Thread(new Runnable() {
            public void run() {
                boolean saved = true;
                if (forUpdate && !getSharedPreferences("update", MODE_PRIVATE).contains("restore")) {
                    String prior = enabledModules();
                    saved = stampResume(getSharedPreferences("update", MODE_PRIVATE).edit()
                            .putString("restore", prior).putString("boot", ModuleResume.bootId())
                            .putBoolean("resume", true)).commit();
                } else if (forUpdate) {
                    saved = stampResume(getSharedPreferences("update", MODE_PRIVATE).edit()
                            .putString("boot", ModuleResume.bootId())
                            .putBoolean("resume", true)).commit();
                }
                final RootResult outcome = !saved
                        ? new RootResult("failed", "none", getString(R.string.module_resume_failed), 1, null)
                        : enable
                        ? new ModuleManager(MainActivity.this).requestEnable(module.id,
                                forUpdate ? "update-check" : "settings", plan, listener)
                        : new ModuleManager(MainActivity.this).execute(plan, listener);
                if (forUpdate && outcome.exitCode != 0)
                    getSharedPreferences("update", MODE_PRIVATE).edit().putBoolean("resume", false).commit();
                else if (forUpdate && !"head_unit".equals(outcome.restart))
                    getSharedPreferences("update", MODE_PRIVATE).edit().remove("boot").commit();
                final Map<String, RootResult> after = new HashMap<String, RootResult>();
                for (ModulePlan.Step step : plan.steps) after.put(step.id, RootClient.run(step.id, "status"));
                if (!after.containsKey(module.id)) after.put(module.id, RootClient.run(module.id, "status"));
                runOnUiThread(new Runnable() {
                    public void run() {
                        moduleWorking = false;
                        if (progress != null) {
                            if (restartIndex >= 0) progress.setStep(restartIndex,
                                    outcome.exitCode == 0 ? StepProgressDialog.DONE : StepProgressDialog.PENDING);
                            progress.dismiss();
                        }
                        statuses.putAll(after);
                        settling.clear();
                        for (Map.Entry<String, RootResult> status : after.entrySet())
                            if (!readable(status.getValue()) && !unreachable(status.getValue())) settling.add(status.getKey());
                        if ("head_unit".equals(outcome.restart)) restartLater = false;
                        String resultText = moduleResultText(plan, outcome, forUpdate);
                        if (forUpdate) updateMessage(resultText);
                        refreshAfterOperation();
                        settle(1);
                        if (outcome.exitCode != 0 || forUpdate)
                            ConfirmDialog.showResult(MainActivity.this,
                                    getString(outcome.exitCode == 0 ? R.string.module_result_complete
                                            : R.string.module_result_failed),
                                    resultText, getString(R.string.close));
                    }
                });
            }
        }, "module-operation").start();
    }

    private String moduleResultText(ModulePlan plan, RootResult result, boolean forUpdate) {
        StringBuilder message = new StringBuilder();
        for (int i = 0; i < plan.steps.size(); i++) {
            ModulePlan.Step step = plan.steps.get(i);
            RootResult receipt = i < result.outcomes.size() ? result.outcomes.get(i).result : null;
            Feature target = feature(step.id);
            message.append("\u2022 ").append(getString(step.enable ? R.string.plan_step_enable
                    : R.string.plan_step_disable, target == null ? step.id : target.name))
                    .append(": ").append(getString(receipt == null ? R.string.stock_not_attempted
                    : receipt.exitCode != 0 ? R.string.stock_module_failed
                    : R.string.module_step_complete)).append('\n');
        }
        if (plan.steps.isEmpty()) message.append(getString(R.string.module_no_changes)).append('\n');
        if (result.exitCode != 0) message.append('\n').append(result.detail).append('\n');
        if ("head_unit".equals(result.restart))
            message.append('\n').append(getString(R.string.module_restart));
        else if ("adbd".equals(result.restart))
            message.append('\n').append(getString(R.string.module_adbd_restart));
        if (forUpdate && result.exitCode == 0)
            message.append("\n\n").append(getString(R.string.update_resume_after_restart));
        return message.toString();
    }

    private void showCar() {
        tab = Tab.CAR;
        settingsVisible = false;
        LinearLayout r = root();
        header(r, null);
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.HORIZONTAL);
        r.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout left = vertical();
        left.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        body.addView(left, new LinearLayout.LayoutParams(0, -1, 2));
        left.addView(iconBox("car", WHITE, 72, 40), new LinearLayout.LayoutParams(dp(72), dp(72)));
        TextView carName = text(carName(), 26, WHITE, medium);
        LinearLayout.LayoutParams nameParams = new LinearLayout.LayoutParams(-1, -2);
        nameParams.topMargin = dp(SettingsUi.MD);
        left.addView(carName, nameParams);
        String product = mapInfo("product");
        if ("\u2014".equals(product)) product = Build.PRODUCT;
        infoBlock(left, R.string.car_firmware, product);
        infoBlock(left, R.string.car_region, region(product));
        boolean rootReachable = (mapStatus != null && !unreachable(mapStatus)) || anyReachableStatus();
        infoBlock(left, R.string.car_nemesis, getString(rootReachable ? R.string.car_nemesis_connected : R.string.state_unknown));

        divider(body, true);
        LinearLayout right = vertical();
        right.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        body.addView(right, new LinearLayout.LayoutParams(0, -1, 3));
        right.addView(text(getString(R.string.car_compatibility), 17, MUTED, sans), new LinearLayout.LayoutParams(-1, -2));
        List<Feature> features = features();
        int available = 0;
        boolean known = false;
        for (Feature feature : features) {
            RootResult status = statuses.get(feature.id);
            if (status == null) continue;
            if (!unreachable(status)) known = true;
            if (readable(status)) available++;
        }
        LinearLayout split = horizontal();
        LinearLayout summary = vertical();
        split.addView(summary, new LinearLayout.LayoutParams(0, -2, 1));
        LinearLayout count = horizontal();
        count.setGravity(Gravity.BOTTOM);
        count.addView(text(known ? String.valueOf(available) : "\u2014", 60, WHITE, medium), new LinearLayout.LayoutParams(-2, -2));
        TextView total = text(getString(R.string.car_features_available, features.size()), 20, MUTED, sans);
        LinearLayout.LayoutParams totalParams = new LinearLayout.LayoutParams(-2, -2);
        totalParams.leftMargin = dp(SettingsUi.SM);
        totalParams.bottomMargin = dp(10);
        count.addView(total, totalParams);
        LinearLayout.LayoutParams countParams = new LinearLayout.LayoutParams(-1, -2);
        countParams.topMargin = dp(SettingsUi.SM);
        summary.addView(count, countParams);
        LinearLayout bar = horizontal();
        bar.setBackgroundDrawable(shape(HAIRLINE, Color.TRANSPARENT, 3));
        View fill = new View(this);
        fill.setBackgroundDrawable(shape(BLUE, Color.TRANSPARENT, 3));
        int filled = known && !features.isEmpty() ? available : 0;
        bar.addView(fill, new LinearLayout.LayoutParams(0, -1, filled));
        bar.addView(new View(this), new LinearLayout.LayoutParams(0, -1, Math.max(0, features.size() - filled)));
        LinearLayout.LayoutParams barParams = new LinearLayout.LayoutParams(-1, dp(6));
        barParams.topMargin = dp(SettingsUi.MD);
        summary.addView(bar, barParams);
        int status = R.string.mapping_loading;
        if (mapStatus != null) {
            if ("on".equals(mapStatus.state)) status = R.string.mapping_ready;
            else if ("off".equals(mapStatus.state)) status = R.string.mapping_verification_needed;
            else if ("incompatible".equals(mapStatus.state)) status = R.string.mapping_needed;
            else status = R.string.mapping_unavailable;
        }
        String verified = mapInfo("verified");
        String checkLine = getString(mapBusy ? R.string.mapping_progress : status);
        if (!"\u2014".equals(verified)) checkLine = getString(R.string.car_last_check, verified) + " \u00B7 " + checkLine;
        TextView check = text(checkLine, 18, MUTED, sans);
        LinearLayout.LayoutParams checkParams = new LinearLayout.LayoutParams(-1, -2);
        checkParams.topMargin = dp(SettingsUi.MD);
        summary.addView(check, checkParams);
        if (mapResult != null) {
            TextView resultView = text(mapResult, 18, WHITE, sans);
            LinearLayout.LayoutParams resultParams = new LinearLayout.LayoutParams(-1, -2);
            resultParams.topMargin = dp(SettingsUi.SM);
            summary.addView(resultView, resultParams);
        }
        final List<String[]> foreignItems = foreignItems();
        if (!foreignItems.isEmpty()) {
            TextView foreignLine = text(getString(R.string.foreign_found, foreignItems.size()), 18, Theme.WARNING, sans);
            LinearLayout.LayoutParams foreignParams = new LinearLayout.LayoutParams(-1, -2);
            foreignParams.topMargin = dp(SettingsUi.MD);
            summary.addView(foreignLine, foreignParams);
        }
        addCarChecks(split);
        right.addView(split, new LinearLayout.LayoutParams(-1, -2));
        View spacer = new View(this);
        right.addView(spacer, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout actions = horizontal();
        actions.setGravity(Gravity.RIGHT);
        if (!foreignItems.isEmpty()) {
            TextView clean = Theme.button(this, getString(R.string.foreign_clean), false, false);
            clean.setEnabled(!mapBusy && !stockBusy);
            clean.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { confirmForeignClean(foreignItems); } });
            LinearLayout.LayoutParams cleanParams = new LinearLayout.LayoutParams(dp(180), dp(Theme.ACTION_HEIGHT));
            cleanParams.rightMargin = dp(SettingsUi.MD);
            actions.addView(clean, cleanParams);
        }
        // A map this car generated (not the bundled one) is what developers need in a GitHub issue.
        if (mapStatus != null && "on".equals(mapStatus.state) && !"bundled".equals(mapStatus.info.get("source"))) {
            TextView export = Theme.button(this, getString(R.string.car_export), false, false);
            export.setEnabled(!mapBusy);
            export.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { confirmMapExport(); } });
            LinearLayout.LayoutParams exportParams = new LinearLayout.LayoutParams(dp(220), dp(Theme.ACTION_HEIGHT));
            exportParams.rightMargin = dp(SettingsUi.MD);
            actions.addView(export, exportParams);
        }
        boolean needsMap = mapStatus != null && !"on".equals(mapStatus.state) && !unreachable(mapStatus);
        TextView recheck = Theme.button(this, getString(R.string.car_recheck), needsMap, false);
        recheck.setEnabled(!mapBusy);
        recheck.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { confirmMapRun(); } });
        actions.addView(recheck, new LinearLayout.LayoutParams(dp(220), dp(Theme.ACTION_HEIGHT)));
        right.addView(actions, new LinearLayout.LayoutParams(-1, -2));
        if (statuses.isEmpty() || foreignStatus == null) loadStatusesForCar();
        if (carCheck == null) loadCarCheck();
    }

    /** Read-only car check (preflight) for the Car tab; slow, so it runs once and after a recheck or cleanup. */
    private void loadCarCheck() {
        if (carCheckLoading) return;
        carCheckLoading = true;
        new Thread(new Runnable() { public void run() {
            final RootResult result = RootClient.preflight();
            runOnUiThread(new Runnable() { public void run() {
                carCheck = result;
                carCheckLoading = false;
                if (tab == Tab.CAR && detailId == null && !addVisible) showCar();
            } });
        } }, "hmg-seogaemo-car-check").start();
    }

    private static int checkRank(String level) {
        return "block".equals(level) ? 3 : "warn".equals(level) ? 2 : "unknown".equals(level) ? 1 : 0;
    }

    /** One icon row per constraint; library and module checks fold into one row each; problems first. */
    private void addCarChecks(LinearLayout split) {
        if (carCheck != null && (carCheck.exitCode != 0 || carCheck.info.isEmpty())) return;
        LinearLayout column = vertical();
        LinearLayout.LayoutParams columnParams = new LinearLayout.LayoutParams(0, -2, 1);
        columnParams.leftMargin = dp(SettingsUi.LG);
        split.addView(column, columnParams);
        if (carCheck == null) {
            column.addView(text(getString(R.string.car_check_loading), 18, MUTED, sans), new LinearLayout.LayoutParams(-1, dp(44)));
            return;
        }
        Map<String, String> checks = new java.util.TreeMap<String, String>();
        for (Map.Entry<String, String> entry : carCheck.info.entrySet())
            if (entry.getKey().startsWith("check_")) checks.put(entry.getKey(), entry.getValue());
        Map<String, String> levels = new java.util.LinkedHashMap<String, String>();
        for (String line : checks.values()) {
            String[] part = line.split("\\|", 4);
            if (part.length < 4) continue;
            String label = part[0].startsWith("lib_") ? getString(R.string.car_check_libs)
                    : part[0].startsWith("module_") ? getString(R.string.car_check_modules)
                    : ReportsSection.title(this, part[0]) + radioDetail(part);
            String known = levels.get(label);
            if (known == null || checkRank(part[1]) > checkRank(known)) levels.put(label, part[1]);
        }
        List<String> order = new ArrayList<String>();
        for (int rank = 3; rank >= 0; rank--)
            for (Map.Entry<String, String> entry : levels.entrySet())
                if (checkRank(entry.getValue()) == rank) order.add(entry.getKey());
        int shown = 0;
        for (String label : order) {
            String level = levels.get(label);
            if (shown >= 5 && checkRank(level) == 0) {
                addCheckRow(column, "check", BLUE, getString(R.string.car_check_more, order.size() - shown));
                break;
            }
            int rank = checkRank(level);
            addCheckRow(column, rank == 3 ? "cross" : rank == 2 ? "alert" : rank == 1 ? "help" : "check",
                    rank == 3 ? Theme.ERROR : rank == 2 ? Theme.WARNING : rank == 1 ? MUTED : BLUE, label);
            shown++;
        }
    }

    /** Built-in Wi-Fi present or not; the USB adapter's model, or none / not supported. */
    private String radioDetail(String[] check) {
        if ("wifi_builtin".equals(check[0]))
            return ": " + getString("ok".equals(check[1]) ? R.string.car_check_present : R.string.car_check_absent);
        if (!"wifi_usb".equals(check[0])) return "";
        if ("ok".equals(check[1])) {
            int end = check[3].indexOf(" (");
            return ": " + (end > 0 ? check[3].substring(0, end) : check[3]);
        }
        return ": " + getString(check[3].startsWith("USB device") ? R.string.car_check_unsupported : R.string.car_check_absent);
    }

    private void addCheckRow(LinearLayout column, String icon, int color, String label) {
        LinearLayout row = horizontal();
        row.setGravity(Gravity.CENTER_VERTICAL);
        ImageView glyph = new ImageView(this);
        glyph.setImageDrawable(new LineIcon(this, icon, color, 20));
        row.addView(glyph, new LinearLayout.LayoutParams(dp(28), dp(28)));
        TextView name = text(label, 19, WHITE, sans);
        name.setPadding(dp(SettingsUi.SM), 0, 0, 0);
        row.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
        column.addView(row, new LinearLayout.LayoutParams(-1, dp(42)));
        divider(column, false);
    }

    /** {item-id, class} pairs from the last `foreign status`, in root order. */
    private List<String[]> foreignItems() {
        List<String[]> items = new ArrayList<String[]>();
        if (foreignStatus == null || foreignStatus.exitCode != 0) return items;
        for (int i = 1; ; i++) {
            String value = foreignStatus.info.get("item_" + i);
            if (value == null) break;
            String[] parts = value.split(",", 2);
            if (parts.length == 2) items.add(parts);
        }
        return items;
    }

    private String foreignName(String id) {
        int res = getResources().getIdentifier("foreign_item_" + id.replace('-', '_'), "string", getPackageName());
        return res == 0 ? id : getString(res);
    }

    /** Lists every finding; cleans only the removable and deletable ones, in order, after one confirm. */
    private void confirmForeignClean(List<String[]> items) {
        if (moduleWorking || modulePlanning || stockBusy || mapBusy) return;
        final List<String[]> cleanable = new ArrayList<String[]>();
        StringBuilder body = new StringBuilder();
        for (String[] item : items) {
            boolean report = "report".equals(item[1]);
            if (!report) cleanable.add(item);
            body.append("\u2022 ").append(foreignName(item[0])).append(" \u2014 ").append(getString(
                    "remove".equals(item[1]) ? R.string.foreign_class_remove
                            : "delete".equals(item[1]) ? R.string.foreign_class_delete : R.string.foreign_class_report))
                    .append('\n');
        }
        body.append('\n').append(getString(cleanable.isEmpty() ? R.string.foreign_nothing : R.string.foreign_clean_note));
        if (cleanable.isEmpty()) {
            ConfirmDialog.showResult(this, getString(R.string.foreign_clean), body, getString(R.string.close));
            return;
        }
        ConfirmDialog.show(this, getString(R.string.foreign_clean_title), body, getString(R.string.foreign_clean),
                getString(R.string.cancel), true, new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) {
                dialog.dismiss();
                runForeignClean(cleanable);
            }
        }, null);
    }

    private void runForeignClean(final List<String[]> items) {
        moduleWorking = true;
        List<String> labels = new ArrayList<String>();
        for (String[] item : items) labels.add(foreignName(item[0]));
        final StepProgressDialog progress = StepProgressDialog.show(this, getString(R.string.foreign_clean_title), labels);
        new Thread(new Runnable() { public void run() {
            boolean restart = false;
            RootResult failed = null;
            String failedName = null;
            for (int i = 0; i < items.size() && failed == null; i++) {
                final int index = i;
                runOnUiThread(new Runnable() { public void run() {
                    if (progress != null) progress.setStep(index, StepProgressDialog.RUNNING);
                } });
                final RootResult result = RootClient.foreignClean(items.get(i)[0]);
                final boolean ok = result.exitCode == 0;
                if (ok && "pending-restart".equals(result.state)) restart = true;
                if (!ok) { failed = result; failedName = foreignName(items.get(i)[0]); }
                runOnUiThread(new Runnable() { public void run() {
                    if (progress != null) progress.setStep(index, ok ? StepProgressDialog.DONE : StepProgressDialog.FAILED);
                } });
            }
            final RootResult foreign = RootClient.foreignStatus();
            final boolean needRestart = restart;
            final RootResult failure = failed;
            final String failureName = failedName;
            runOnUiThread(new Runnable() { public void run() {
                moduleWorking = false;
                foreignStatus = foreign;
                carCheck = null;
                if (progress != null) progress.dismiss();
                if (tab == Tab.CAR && detailId == null && !addVisible) showCar();
                if (failure != null) showFailure(getString(R.string.foreign_clean_failed, failureName), failure.detail);
                else if (needRestart) restartNow();
                else ConfirmDialog.showResult(MainActivity.this, getString(R.string.foreign_clean_title),
                        getString(R.string.foreign_clean_done), getString(R.string.close));
            } });
        } }, "hmg-seogaemo-foreign").start();
    }

    private boolean anyReachableStatus() {
        for (RootResult status : statuses.values()) if (!unreachable(status)) return true;
        return false;
    }

    private void loadStatusesForCar() {
        final int generation = ++loadGeneration;
        new Thread(new Runnable() { public void run() {
            final List<Feature> list = features();
            final Map<String, RootResult> results = new HashMap<String, RootResult>();
            for (Feature feature : list) results.put(feature.id, RootClient.run(feature.id, "status"));
            final RootResult foreign = RootClient.foreignStatus();
            runOnUiThread(new Runnable() { public void run() {
                statuses.putAll(results);
                foreignStatus = foreign;
                if (generation == loadGeneration && tab == Tab.CAR && detailId == null && !addVisible) showCar();
            } });
        } }, "hmg-seogaemo-car").start();
    }

    private String carName() {
        String manufacturer = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.trim();
        String model = Build.MODEL == null ? "" : Build.MODEL.trim();
        if (manufacturer.length() > 0 && !"unknown".equalsIgnoreCase(manufacturer) &&
                !model.toLowerCase(Locale.US).startsWith(manufacturer.toLowerCase(Locale.US)))
            return (manufacturer + " " + model).trim();
        return model.length() > 0 ? model : getString(R.string.tab_car);
    }

    private static String region(String product) {
        String[] parts = product == null ? new String[0] : product.split("\\.");
        return parts.length > 1 && parts[1].matches("[A-Z]{2,4}") ? parts[1] : "\u2014";
    }

    private void infoBlock(LinearLayout parent, int labelRes, String value) {
        TextView label = text(getString(labelRes), 16, MUTED, sans);
        LinearLayout.LayoutParams labelParams = new LinearLayout.LayoutParams(-1, -2);
        labelParams.topMargin = dp(SettingsUi.LG);
        parent.addView(label, labelParams);
        TextView content = text(value, 20, WHITE, sans);
        LinearLayout.LayoutParams contentParams = new LinearLayout.LayoutParams(-1, -2);
        contentParams.topMargin = dp(4);
        parent.addView(content, contentParams);
    }

    private void showAdd() {
        addVisible = true;
        settingsVisible = false;
        LinearLayout r = root();
        header(r, getString(R.string.add_title));
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.HORIZONTAL);
        r.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));
        ScrollView listScroll = new ScrollView(this);
        final LinearLayout list = vertical();
        list.setBackgroundColor(SURFACE);
        listScroll.addView(list);
        listScroll.setBackgroundColor(SURFACE);
        body.addView(listScroll, new LinearLayout.LayoutParams(0, -1, 2));
        divider(body, true);
        final LinearLayout detail = vertical();
        detail.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        body.addView(detail, new LinearLayout.LayoutParams(0, -1, 3));
        TextView loading = text(getString(R.string.add_scanning), 20, MUTED, sans);
        loading.setPadding(dp(SettingsUi.LG), dp(SettingsUi.LG), dp(SettingsUi.LG), 0);
        list.addView(loading, new LinearLayout.LayoutParams(-1, -2));
        new Thread(new Runnable() { public void run() {
            getFilesDir();
            RootClient.moduleUsbImport();
            final List<AddItem> packages = new ArrayList<AddItem>();
            for (RemovedModule removed : RemovedModule.parse(RootClient.moduleListRemoved(describeLocale())))
                packages.add(new AddItem(removed));
            for (File file : findPackages()) packages.add(new AddItem(file, packageInfo(file)));
            runOnUiThread(new Runnable() { public void run() {
                if (!addVisible) return;
                list.removeAllViews();
                if (packages.isEmpty()) {
                    TextView empty = text(getString(R.string.add_empty), 20, MUTED, sans);
                    empty.setLineSpacing(dp(4), 1f);
                    empty.setPadding(dp(SettingsUi.LG), dp(SettingsUi.LG), dp(SettingsUi.LG), 0);
                    list.addView(empty, new LinearLayout.LayoutParams(-1, -2));
                    detail.removeAllViews();
                    return;
                }
                for (AddItem item : packages) addPackageRow(list, detail, item, packages, item == packages.get(0));
                showPackage(detail, packages.get(0));
            } });
        } }, "hmg-seogaemo-add-scan").start();
    }

    /** One row of the Add screen: a USB package file, or a bundled module the owner removed. */
    private static final class AddItem {
        final File file;
        final String bundledId;
        final Map<String, String> info;
        AddItem(File file, Map<String, String> info) { this.file = file; this.bundledId = null; this.info = info; }
        AddItem(RemovedModule removed) {
            this.file = null;
            this.bundledId = removed.id;
            Map<String, String> values = new HashMap<String, String>();
            values.put("name", removed.name);
            values.put("icon", removed.icon);
            if (removed.summary.length() > 0) values.put("summary", removed.summary);
            if (removed.version.length() > 0) values.put("version", removed.version);
            this.info = values;
        }
    }

    private List<File> findPackages() {
        List<File> found = new ArrayList<File>();
        File[] files = new File(getFilesDir(), "hsm-usb").listFiles();
        if (files != null) for (File file : files) {
            if (file.isFile() && file.getName().toLowerCase(Locale.US).endsWith(".hsm") && file.length() > 0) found.add(file);
        }
        Collections.sort(found, new Comparator<File>() {
            public int compare(File left, File right) { return left.getName().compareTo(right.getName()); }
        });
        return found;
    }

    private static String fileStem(File file) {
        String name = file.getName();
        return name.toLowerCase(Locale.US).endsWith(".hsm") ? name.substring(0, name.length() - 4) : name;
    }

    private static final Set<String> PACKAGE_ICONS = new HashSet<String>(java.util.Arrays.asList("box", "wifi",
            "phone", "terminal", "car", "gear", "display", "speaker", "camera", "map", "power", "key", "skip",
            "button", "link", "bolt"));
    private final Map<String, Map<String, String>> packageInfos = new HashMap<String, Map<String, String>>();

    /** Reads name, summary, icon and version from a .hsm file for the preview; the root installer validates it. */
    private Map<String, String> packageInfo(File file) {
        String key = file.getPath() + ":" + file.length() + ":" + file.lastModified();
        synchronized (packageInfos) {
            Map<String, String> cached = packageInfos.get(key);
            if (cached != null) return cached;
        }
        Map<String, String> info = new HashMap<String, String>();
        java.util.zip.ZipFile zip = null;
        try {
            zip = new java.util.zip.ZipFile(file);
            Map<String, String> props = zipProperties(zip, "module.properties");
            Map<String, String> strings = zipProperties(zip, "strings/en.txt");
            strings.putAll(zipProperties(zip, "strings/" + describeLocale() + ".txt"));
            if (props.get("version") != null) info.put("version", props.get("version"));
            if (PACKAGE_ICONS.contains(props.get("icon"))) info.put("icon", props.get("icon"));
            String name = strings.get("name");
            info.put("name", name != null && name.length() > 0 ? name
                    : props.get("id") != null ? props.get("id") : fileStem(file));
            if (strings.get("summary") != null) info.put("summary", strings.get("summary"));
        } catch (Exception unreadable) {
            info.put("name", fileStem(file));
        } finally {
            if (zip != null) try { zip.close(); } catch (java.io.IOException ignored) { }
        }
        if (!info.containsKey("icon")) info.put("icon", "box");
        synchronized (packageInfos) { packageInfos.put(key, info); }
        return info;
    }

    private static Map<String, String> zipProperties(java.util.zip.ZipFile zip, String path) throws java.io.IOException {
        Map<String, String> values = new HashMap<String, String>();
        java.util.zip.ZipEntry entry = zip.getEntry(path);
        if (entry == null) return values;
        InputStream in = zip.getInputStream(entry);
        try {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int n;
            while ((n = in.read(buffer)) != -1 && bytes.size() < 65536) bytes.write(buffer, 0, n);
            for (String line : new String(bytes.toByteArray(), "UTF-8").split("\n")) {
                int eq = line.indexOf('=');
                if (eq > 0 && !line.startsWith("#")) values.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
            }
        } finally { in.close(); }
        return values;
    }

    private String packageName(File file) { return packageInfo(file).get("name"); }


    private void addPackageRow(final LinearLayout list, final LinearLayout detail, final AddItem item,
            final List<AddItem> all, boolean selected) {
        LinearLayout row = horizontal();
        row.setPadding(dp(SettingsUi.LG), 0, dp(SettingsUi.MD), 0);
        row.setBackgroundDrawable(selectable(selected ? Theme.SELECTED : SURFACE, Color.TRANSPARENT, 0, false));
        View marker = new View(this);
        marker.setBackgroundColor(selected ? BLUE : Color.TRANSPARENT);
        row.addView(marker, new LinearLayout.LayoutParams(dp(4), dp(56)));
        ImageView glyph = iconBox(item.info.get("icon"), selected ? BLUE : MUTED, 44, 26);
        LinearLayout.LayoutParams glyphParams = new LinearLayout.LayoutParams(dp(44), dp(44));
        glyphParams.leftMargin = dp(SettingsUi.MD);
        row.addView(glyph, glyphParams);
        LinearLayout copy = vertical();
        copy.setGravity(Gravity.CENTER_VERTICAL);
        copy.setPadding(dp(SettingsUi.MD), 0, 0, 0);
        SettingsUi.titleBlock(this, copy, text(item.info.get("name"), 21, selected ? WHITE : Theme.DIM, medium),
                text((item.bundledId != null ? getString(R.string.add_removed_source) : "USB")
                        + (item.info.get("version") != null ? " \u00B7 " + item.info.get("version") : ""), 16, MUTED, sans));
        row.addView(copy, new LinearLayout.LayoutParams(0, -1, 1));
        row.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                list.removeAllViews();
                for (AddItem other : all) addPackageRow(list, detail, other, all, other == item);
                showPackage(detail, item);
            }
        });
        list.addView(row, new LinearLayout.LayoutParams(-1, dp(76)));
        divider(list, false);
    }

    private void showPackage(LinearLayout detail, final AddItem item) {
        detail.removeAllViews();
        LinearLayout head = horizontal();
        Map<String, String> info = item.info;
        head.addView(iconBox(info.get("icon"), WHITE, 72, 40), new LinearLayout.LayoutParams(dp(72), dp(72)));
        LinearLayout copy = vertical();
        copy.setPadding(dp(SettingsUi.LG), 0, 0, 0);
        String summary = info.get("summary");
        SettingsUi.titleBlock(this, copy, text(info.get("name"), 26, WHITE, medium),
                text(summary != null && summary.length() > 0 ? summary : getString(R.string.add_hint), 18, MUTED, sans));
        head.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));
        detail.addView(head, new LinearLayout.LayoutParams(-1, -2));
        OptionsList rows = new OptionsList(this);
        if (info.get("version") != null) rows.addReadOnly(getString(R.string.add_version), info.get("version"));
        if (item.file != null) rows.addReadOnly(getString(R.string.add_file), item.file.getName());
        LinearLayout.LayoutParams rowsParams = new LinearLayout.LayoutParams(-1, -2);
        rowsParams.topMargin = dp(SettingsUi.LG);
        detail.addView(rows, rowsParams);
        View spacer = new View(this);
        detail.addView(spacer, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout actions = horizontal();
        actions.setGravity(Gravity.RIGHT);
        TextView install = Theme.button(this, getString(R.string.add_install), true, false);
        install.setOnClickListener(new View.OnClickListener() { public void onClick(View v) {
            if (item.bundledId != null) confirmBundledAdd(item.bundledId, item.info.get("name"));
            else confirmPackageInstall(item.file);
        } });
        actions.addView(install, new LinearLayout.LayoutParams(dp(220), dp(Theme.ACTION_HEIGHT)));
        detail.addView(actions, new LinearLayout.LayoutParams(-1, -2));
    }

    private void confirmPackageInstall(final File file) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        String name = packageName(file);
        ConfirmDialog.show(this, getString(R.string.add_install_confirm_title, name, particle(name)),
                getString(R.string.add_install_confirm), getString(R.string.add_install), getString(R.string.cancel), false,
                new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                moduleWorking = true;
                dialog.dismiss();
                final StepProgressDialog progress = StepProgressDialog.show(MainActivity.this,
                        getString(R.string.add_install), java.util.Collections.singletonList(
                                getString(R.string.add_install_step, packageName(file))));
                if (progress != null) progress.setStep(0, StepProgressDialog.RUNNING);
                new Thread(new Runnable() { public void run() {
                    RootResult outcome;
                    File staged = null;
                    try {
                        staged = stagePackage(file);
                        outcome = RootClient.moduleInstall(staged.getName().substring(0, 64));
                    } catch (Exception error) {
                        outcome = new RootResult("failed", "none", getString(R.string.add_failed), 1, null);
                    }
                    if (staged != null && !staged.getParentFile().equals(file.getParentFile())) staged.delete();
                    refreshInstalled(describeLocale());
                    final RootResult result = outcome;
                    runOnUiThread(new Runnable() { public void run() {
                        moduleWorking = false;
                        if (progress != null) progress.dismiss();
                        if (result.exitCode == 0) {
                            goBack();
                            ConfirmDialog.showResult(MainActivity.this, getString(R.string.add_install),
                                    getString(R.string.add_installed_done), getString(R.string.close));
                        } else showFailure(getString(R.string.add_failed), result.detail);
                    } });
                } }, "hmg-seogaemo-install").start();
            }
        }, null);
    }

    /** Adds a removed bundled module back; like an install it changes nothing until the owner turns it on. */
    private void confirmBundledAdd(final String moduleId, final String name) {
        if (moduleWorking || modulePlanning || stockBusy) return;
        ConfirmDialog.show(this, getString(R.string.add_install_confirm_title, name, particle(name)),
                getString(R.string.add_removed_confirm), getString(R.string.add_install), getString(R.string.cancel), false,
                new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                moduleWorking = true;
                dialog.dismiss();
                final StepProgressDialog progress = StepProgressDialog.show(MainActivity.this,
                        getString(R.string.add_install), java.util.Collections.singletonList(
                                getString(R.string.add_install_step, name)));
                if (progress != null) progress.setStep(0, StepProgressDialog.RUNNING);
                new Thread(new Runnable() { public void run() {
                    final RootResult result = RootClient.moduleAddBundled(moduleId);
                    refreshInstalled(describeLocale());
                    runOnUiThread(new Runnable() { public void run() {
                        moduleWorking = false;
                        if (progress != null) progress.dismiss();
                        if (result.exitCode == 0) {
                            goBack();
                            ConfirmDialog.showResult(MainActivity.this, getString(R.string.add_install),
                                    getString(R.string.add_installed_done), getString(R.string.close));
                        } else showFailure(getString(R.string.add_failed), result.detail);
                    } });
                } }, "hmg-seogaemo-add-removed").start();
            }
        }, null);
    }

    /** Copies the package into the root-readable staging directory under its SHA-256 name. */
    private File stagePackage(File source) throws Exception {
        File staging = new File(getFilesDir(), "hsm");
        if (!staging.isDirectory() && !staging.mkdirs()) throw new java.io.IOException("staging");
        File temp = new File(staging, "incoming-" + System.currentTimeMillis() + ".tmp");
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        InputStream in = new FileInputStream(source);
        try {
            OutputStream out = new FileOutputStream(temp);
            try {
                byte[] buffer = new byte[65536];
                int n;
                while ((n = in.read(buffer)) != -1) { digest.update(buffer, 0, n); out.write(buffer, 0, n); }
            } finally { out.close(); }
        } finally { in.close(); }
        StringBuilder hex = new StringBuilder();
        for (byte b : digest.digest()) hex.append(String.format(Locale.US, "%02x", b & 0xFF));
        File staged = new File(staging, hex + ".hsm");
        if (staged.exists() && !staged.delete()) throw new java.io.IOException("stale staging file");
        if (!temp.renameTo(staged)) throw new java.io.IOException("could not stage package");
        return staged;
    }

    private void showSettings() {
        if (sidebarScroll != null) sidebarOffset = sidebarScroll.getScrollY();
        tab = Tab.SETTINGS;
        settingsVisible = true;
        LinearLayout r = root();
        header(r, null);
        LinearLayout body = horizontal();
        r.addView(body, new LinearLayout.LayoutParams(-1, 0, 1));
        ScrollView sideScroll = new ScrollView(this);
        sidebarScroll = sideScroll;
        LinearLayout side = vertical();
        side.setBackgroundColor(SURFACE);
        sideScroll.addView(side);
        sideScroll.setBackgroundColor(SURFACE);
        body.addView(sideScroll, new LinearLayout.LayoutParams(0, -1, 1));
        for (int i = 0; i < CATEGORIES.length; i++) addCategory(side, i);
        sideScroll.post(new Runnable() {
            public void run() { if (sidebarScroll != null) sidebarScroll.scrollTo(0, sidebarOffset); }
        });
        divider(body, true);
        LinearLayout content = vertical();
        body.addView(content, new LinearLayout.LayoutParams(0, -1, 2));
        TextView paneTitle = text(getString(CATEGORIES[category]), 26, WHITE, medium);
        paneTitle.setPadding(dp(SettingsUi.PAGE), 0, 0, 0);
        content.addView(paneTitle, new LinearLayout.LayoutParams(-1, dp(52)));
        divider(content, false);
        ScrollView scroll = new ScrollView(this);
        LinearLayout pane = vertical();
        scroll.addView(pane);
        content.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if (category == CATEGORY_UPDATE) showUpdate(pane);
        else if (category == CATEGORY_LANGUAGE) showLanguage(pane);
        else if (category == CATEGORY_SUPPORT) showSupport(pane);
        else if (category == CATEGORY_DEVELOPER) showDeveloper(pane);
        else showStock(pane);
    }

    private void showLanguage(LinearLayout content) {
        View gap = new View(this);
        content.addView(gap, new LinearLayout.LayoutParams(-1, dp(SettingsUi.SM)));
        addLanguageOption(content, R.string.language_system, "system");
        addLanguageOption(content, R.string.language_english, "en");
        addLanguageOption(content, R.string.language_korean, "ko");
        TextView hint = text(getString(R.string.language_scope), 18, MUTED, sans);
        hint.setPadding(dp(SettingsUi.PAGE), 0, 0, 0);
        content.addView(hint, new LinearLayout.LayoutParams(-1, dp(48)));
    }

    private void showSupport(LinearLayout content) {
        TextView explanation = text(getString(R.string.report_hint), 19, MUTED, sans);
        explanation.setLineSpacing(dp(4), 1f);
        explanation.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        content.addView(explanation, new LinearLayout.LayoutParams(-1, -2));
        TextView export = action(getString(R.string.report_export), true);
        content.addView(export, SettingsUi.contentAction(this));
        export.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { confirmReport(); }
        });
        ReportsSection.addRecordingRow(this, content, new Runnable() {
            public void run() { if (tab == Tab.SETTINGS) showSettings(); }
        });
        TextView about = text(getString(R.string.support_about, getString(R.string.app_name), installedVersion(),
                getString(R.string.value_gen5w)), 18, MUTED, sans);
        about.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.LG), dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        content.addView(about, new LinearLayout.LayoutParams(-1, -2));
    }

    private void showDeveloper(LinearLayout content) {
        OptionsList rows = new OptionsList(this);
        rows.setPadding(dp(SettingsUi.PAGE), 0, dp(SettingsUi.PAGE), 0);
        final boolean enabled = diagnosticsEnabled();
        rows.addValue(getString(R.string.developer_diagnostics), getString(enabled ? R.string.on : R.string.off), true,
                new View.OnClickListener() {
            public void onClick(View v) {
                ConfirmDialog.show(MainActivity.this, getString(R.string.developer_diagnostics),
                        getString(enabled ? R.string.developer_diagnostics_off : R.string.developer_diagnostics_on),
                        getString(R.string.apply), getString(R.string.cancel), false, new ConfirmDialog.Action() {
                    public void run(ConfirmDialog dialog) {
                        getSharedPreferences("ui_developer", MODE_PRIVATE).edit().putBoolean("diagnostics", !enabled).apply();
                        dialog.dismiss();
                        showSettings();
                    }
                }, null);
            }
        });
        rows.addLink(getString(R.string.mapping_export), new View.OnClickListener() {
            public void onClick(View v) { confirmMapExport(); }
        });
        rows.addLink(getString(R.string.open_nemesis), new View.OnClickListener() {
            public void onClick(View v) { openNemesis(); }
        });
        rows.addInfo(getString(R.string.mapping_issue_hint));
        content.addView(rows, new LinearLayout.LayoutParams(-1, -2));
    }

    private String mapInfo(String key) {
        String value = mapStatus == null ? null : mapStatus.info.get(key);
        return value == null || value.length() == 0 ? "\u2014" : value;
    }

    private boolean mapOffered;

    private void refreshMap(final boolean verifyKnown) {
        if (mapRefreshing) return;
        mapRefreshing = true;
        new Thread(new Runnable() { public void run() {
            RootResult status = RootClient.map("status");
            String failure = null;
            if (verifyKnown && status.exitCode == 0 && "off".equals(status.state) &&
                    !"none".equals(status.info.get("source"))) {
                RootResult verification = RootClient.map("verify");
                if (verification.exitCode != 0) failure = verification.detail;
                status = RootClient.map("status");
            }
            final RootResult observed = status;
            final String observedFailure = failure;
            runOnUiThread(new Runnable() { public void run() {
                mapStatus = observed;
                if (observedFailure != null) mapResult = observedFailure;
                mapRefreshing = false;
                // Unknown firmware: offer the mapping on its own, once per app start, behind the usual confirmation.
                if (!mapOffered && observed.exitCode == 0 && "off".equals(observed.state)
                        && "none".equals(observed.info.get("source")) && !mapBusy && !stockBusy && !isFinishing()) {
                    mapOffered = true;
                    confirmMapRun();
                }
                if (tab == Tab.CAR && detailId == null && !addVisible) showCar();
                resumeUpdateWhenReady();
            } });
        } }, "car-map-status").start();
    }

    private void confirmMapRun() {
        if (mapBusy || stockBusy) return;
        ConfirmDialog.show(this, getString(R.string.mapping_run), getString(R.string.mapping_run_confirm),
                getString(R.string.mapping_run), getString(R.string.cancel), false,
                new ConfirmDialog.Action() { public void run(ConfirmDialog dialog) { mapOperation("run", dialog); } }, null);
    }

    /** Map export: as a GitHub issue (default; the folder is saved, then a QR code opens the issue) or to USB only. */
    private void confirmMapExport() {
        if (mapBusy || stockBusy) return;
        final int[] choice = {0};
        LinearLayout cards = choiceCards(new String[] {"phone", "download"},
                new int[] {R.string.mapping_export_issue, R.string.mapping_export_usb},
                new int[] {R.string.mapping_export_issue_note, R.string.mapping_export_usb_note}, choice);
        ConfirmDialog.showView(this, getString(R.string.mapping_export), cards, getString(R.string.report_start),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) { mapOperation(choice[0] == 0 ? "issue" : "export", dialog); }
        }, null);
    }

    /** A USB export is reported done only after root flushed and verified the stick. */
    private String exportMessage(RootResult result) {
        return result.exitCode == 0 && "usb".equals(result.info.get("export_safe"))
                ? getString(R.string.export_usb_done, result.detail) : result.detail;
    }

    private void mapOperation(final String verb, final ConfirmDialog dialog) {
        mapBusy = true;
        dialog.showProgress();
        if (tab == Tab.CAR && detailId == null && !addVisible) showCar();
        new Thread(new Runnable() { public void run() {
            final RootResult outcome = RootClient.map("issue".equals(verb) ? "export" : verb);
            final RootResult observed = RootClient.map("status");
            runOnUiThread(new Runnable() { public void run() {
                mapBusy = false;
                mapStatus = observed;
                if ("run".equals(verb)) { carCheck = null; loadCarCheck(); }
                mapResult = outcome.exitCode == 0 && "run".equals(verb)
                        ? getString(R.string.mapping_run_done)
                        : "run".equals(verb) ? outcome.detail : exportMessage(outcome);
                dialog.dismiss();
                if (tab == Tab.CAR && detailId == null && !addVisible) showCar();
                if (outcome.exitCode == 0 && "run".equals(verb)) {
                    // A new map goes to the developers as a GitHub issue with the exported maps folder.
                    ConfirmDialog.show(MainActivity.this, getString(R.string.mapping_run), mapResult,
                            getString(R.string.car_export), getString(R.string.close), false,
                            new ConfirmDialog.Action() { public void run(ConfirmDialog done) {
                                done.dismiss();
                                confirmMapExport();
                            } }, null);
                } else if (outcome.exitCode == 0 && "issue".equals(verb)) {
                    showIssueQr(true, mapResult, null);
                } else ConfirmDialog.showResult(MainActivity.this, getString("run".equals(verb)
                        ? R.string.mapping_run : R.string.mapping_export), mapResult, getString(R.string.close));
                resumeUpdateWhenReady();
            } });
        } }, "car-map-" + verb).start();
    }

    private void addLanguageOption(LinearLayout content, final int labelRes, final String choice) {
        boolean selected = choice.equals(preferences().getString("language", "system"));
        LinearLayout row = horizontal();
        SettingsUi.contentRow(this, row);
        row.setBackgroundDrawable(selectable(selected ? Theme.SELECTED : CANVAS,
                Color.TRANSPARENT, 0, false));
        TextView title = text(getString(labelRes), 24, WHITE, medium);
        row.addView(title, new LinearLayout.LayoutParams(0, -1, 1));
        TextView radio = text(getString(selected ? R.string.radio_selected : R.string.radio_unselected), 28, selected ? BLUE : MUTED, sans);
        radio.setGravity(Gravity.CENTER);
        row.addView(radio, new LinearLayout.LayoutParams(dp(60), -1));
        row.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                if (choice.equals(preferences().getString("language", "system"))) return;
                ConfirmDialog.show(MainActivity.this, getString(R.string.language_confirm_title),
                        getString(R.string.language_confirm_message, getString(labelRes)),
                        getString(R.string.apply), getString(R.string.cancel), false,
                        new ConfirmDialog.Action() {
                    public void run(ConfirmDialog dialog) {
                        preferences().edit().putString("language", choice).apply();
                        dialog.dismiss();
                        recreate();
                    }
                }, null);
            }
        });
        content.addView(row, new LinearLayout.LayoutParams(-1, dp(62)));
        divider(content, false);
    }

    private void showUpdate(LinearLayout content) {
        addRow(content, R.string.update_current, R.string.update_current_hint, installedVersion());
        updateStatus = text(getString(getSharedPreferences("update", MODE_PRIVATE).contains("restore") ? R.string.update_restore_pending : R.string.update_idle), 18, MUTED, sans);
        updateStatus.setPadding(dp(SettingsUi.PAGE), 0, dp(SettingsUi.PAGE), 0);
        content.addView(updateStatus, new LinearLayout.LayoutParams(-1, dp(48)));
        TextView check = action(getString(R.string.update_check), true);
        check.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { confirmCheckUpdate(); } });
        LinearLayout.LayoutParams cp = SettingsUi.contentAction(this);
        content.addView(check, cp);
        TextView rollback = action(getString(R.string.update_rollback), false);
        rollback.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { confirmRollback(); } });
        LinearLayout.LayoutParams rp = SettingsUi.contentAction(this);
        rp.topMargin = dp(SettingsUi.SM);
        content.addView(rollback, rp);
    }

    private void resetRow(LinearLayout parent, int titleRes, int subRes, int buttonRes, View.OnClickListener tap) {
        LinearLayout row = horizontal();
        SettingsUi.contentRow(this, row);
        LinearLayout copy = vertical();
        copy.setGravity(Gravity.CENTER_VERTICAL);
        SettingsUi.titleBlock(this, copy, text(getString(titleRes), 23, WHITE, medium), text(getString(subRes), 17, MUTED, sans));
        row.addView(copy, new LinearLayout.LayoutParams(0, -2, 1));
        TextView button = Theme.button(this, getString(buttonRes), false, true);
        button.setOnClickListener(tap);
        LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(dp(150), dp(Theme.ACTION_HEIGHT));
        buttonParams.leftMargin = dp(SettingsUi.MD);
        row.addView(button, buttonParams);
        parent.addView(row, new LinearLayout.LayoutParams(-1, dp(96)));
        divider(parent, false);
    }

    private void showStock(LinearLayout content) {
        resetRow(content, R.string.reset_restore_title, R.string.reset_restore_sub, R.string.reset_restore_button,
                new View.OnClickListener() { public void onClick(View view) { confirmStock(false); } });
        resetRow(content, R.string.stock_uninstall, R.string.reset_uninstall_sub, R.string.reset_uninstall_button,
                new View.OnClickListener() { public void onClick(View view) { confirmStock(true); } });
        resetRow(content, R.string.device_reboot, R.string.reset_restart_sub, R.string.reset_restart_button,
                new View.OnClickListener() { public void onClick(View view) { confirmReboot(R.string.device_reboot_confirm); } });
        stockStatus = text(getString(R.string.stock_hint), 18, MUTED, sans);
        stockStatus.setLineSpacing(dp(4), 1f);
        stockStatus.setPadding(dp(SettingsUi.PAGE), dp(SettingsUi.MD),
                dp(SettingsUi.PAGE), dp(SettingsUi.LG));
        content.addView(stockStatus, new LinearLayout.LayoutParams(-1, -2));
        final TextView target = stockStatus;
        new Thread(new Runnable() { public void run() {
            final RootResult result = RootClient.stock("status");
            runOnUiThread(new Runnable() { public void run() {
                if (!stockBusy && stockStatus == target && !result.info.isEmpty())
                    target.setText(stockResultText(result));
            }});
        }}, "hmg-seogaemo-stock-status").start();
    }

    private void openNemesis() {
        Intent launch = getPackageManager().getLaunchIntentForPackage("com.nemesis.manager");
        // NEMESIS Manager declares MAIN without LAUNCHER, so name its activity directly.
        if (launch == null) launch = new Intent(Intent.ACTION_MAIN).setClassName(
                "com.nemesis.manager", "com.nemesis.manager.MainActivity");
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                startActivity(launch);
                return;
            } catch (ActivityNotFoundException ignored) {
                // Fall through to the same neutral message as an unresolved package.
            } catch (SecurityException ignored) {
                // Fall through to the same neutral message as an unresolved package.
            }
        }
        Toast.makeText(this, R.string.nemesis_unavailable, Toast.LENGTH_SHORT).show();
    }

    private void confirmReboot(int messageRes) {
        if (stockBusy || updateBusy || moduleWorking || modulePlanning || mapBusy) return;
        ConfirmDialog.show(this, getString(R.string.device_reboot),
                getString(messageRes), getString(R.string.device_reboot),
                getString(R.string.cancel), true, new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                stockBusy = true;
                dialog.showProgress();
                new Thread(new Runnable() { public void run() {
                    final RootResult result = RootClient.rebootDevice();
                    runOnUiThread(new Runnable() { public void run() {
                        stockBusy = false;
                        dialog.dismiss();
                        if (result.exitCode != 0) ConfirmDialog.showResult(MainActivity.this,
                                getString(R.string.device_reboot), getString(R.string.device_reboot_failed),
                                getString(R.string.close));
                    }});
                }}, "hmg-seogaemo-device-reboot").start();
            }
        }, null);
    }

    private void confirmStock(final boolean uninstall) {
        if (stockBusy || updateBusy || moduleWorking || modulePlanning || mapBusy) return;
        final int title = uninstall ? R.string.stock_uninstall : R.string.stock_restore;
        ConfirmDialog.show(this, getString(title),
                getString(uninstall ? R.string.stock_uninstall_confirm : R.string.stock_restore_confirm),
                getString(title), getString(R.string.cancel), uninstall, new ConfirmDialog.Action() {
            public void run(final ConfirmDialog dialog) {
                stockBusy = true;
                // The confirmed stock action supersedes any saved OTA resume.
                // Commit before the root call in case removing the APK closes us.
                if (!getSharedPreferences("update", MODE_PRIVATE).edit().clear().commit() ||
                        !getSharedPreferences("module_resume", MODE_PRIVATE).edit().clear().commit()) {
                    stockBusy = false;
                    dialog.dismiss();
                    stockStatus.setText(getString(R.string.stock_failed));
                    return;
                }
                dialog.showProgress();
                stockStatus.setText(getString(R.string.stock_working));
                new Thread(new Runnable() { public void run() {
                    final RootResult result = uninstall ? RootClient.uninstallPackage() : RootClient.stock("restore");
                    runOnUiThread(new Runnable() { public void run() {
                        stockBusy = false;
                        dialog.dismiss();
                        stockStatus.setText(stockResultText(result));
                        statuses.clear();
                    }});
                }}, "hmg-seogaemo-stock-operation").start();
            }
        }, null);
    }

    private String stockResultText(RootResult result) {
        boolean queued = "queued".equals(result.info.get("uninstall"));
        StringBuilder message = new StringBuilder(getString(result.exitCode != 0 ||
                "failed".equals(result.info.get("uninstall"))
                ? R.string.stock_failed : queued ? R.string.stock_queued : R.string.stock_complete));
        for (Feature feature : features()) {
            String value = result.info.get("module_" + feature.id.replace('-', '_'));
            if (value == null) continue;
            int label = "reverted".equals(value) ? R.string.stock_reverted
                    : "conflict".equals(value) ? R.string.stock_conflict
                    : "failed".equals(value) ? R.string.stock_module_failed : R.string.stock_not_attempted;
            message.append("\n\u2022 ").append(feature.name).append(": ").append(getString(label));
        }
        if ("head_unit".equals(result.restart))
            message.append("\n\n").append(getString(R.string.stock_restart));
        if ("failed".equals(result.info.get("uninstall")))
            message.append("\n\n").append(getString(R.string.stock_uninstall_failed));
        if (result.exitCode != 0 && result.detail.length() > 0)
            message.append("\n\n").append(result.detail);
        return message.toString();
    }

    private void updateMessage(final String value) {
        runOnUiThread(new Runnable() { public void run() { if (updateStatus != null) updateStatus.setText(value); } });
    }

    private void confirmCheckUpdate() {
        if (updateBusy || stockBusy) return;
        ConfirmDialog.show(this, getString(R.string.update_check),
                getString(R.string.update_check_confirm), getString(R.string.update_check),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) { checkUpdate(dialog); }
        }, null);
    }

    private void checkUpdate() { checkUpdate(null); }

    private void checkUpdate(final ConfirmDialog dialog) {
        if (updateBusy || stockBusy) { if (dialog != null) dialog.dismiss(); return; }
        try {
            final UpdateClient client = new UpdateClient(this);
            if (!client.hasUsableNetwork()) {
                if (dialog != null) dialog.dismiss();
                Feature wifi = feature("wifi");
                if (wifi != null) prepareModuleChange(wifi, true, true);
                return;
            }
            updateBusy = true;
            if (dialog != null) dialog.showProgress();
            new Thread(new Runnable() { public void run() {
                try {
                    final String version = client.download(installedVersion(), new UpdateClient.Progress() {
                        public void changed(int phase) { updateMessage(getString(phase)); }
                    });
                    getSharedPreferences("update", MODE_PRIVATE).edit().putBoolean("resume", false).apply();
                    runOnUiThread(new Runnable() { public void run() {
                        updateBusy = false;
                        if (dialog != null) dialog.dismiss();
                        confirmInstall(version);
                    } });
                } catch (UpdateClient.NoUpdateException e) {
                    boolean restored = restoreModules();
                    updateMessage(getString(R.string.update_no_update) + (restored ? "" : " \u00B7 " + getString(R.string.update_restore_pending)));
                    finishUpdateWork(dialog);
                } catch (Exception e) {
                    boolean restored = restoreModules();
                    updateMessage(e.getMessage() + (restored ? "" : " \u00B7 " + getString(R.string.update_restore_pending)));
                    finishUpdateWork(dialog);
                }
            }}, "hmg-seogaemo-update-check").start();
        } catch (Exception e) { if (dialog != null) dialog.dismiss(); updateMessage(e.getMessage()); }
    }

    private void finishUpdateWork(final ConfirmDialog dialog) {
        runOnUiThread(new Runnable() { public void run() {
            updateBusy = false;
            if (dialog != null) dialog.dismiss();
        } });
    }

    private void confirmInstall(final String version) {
        ConfirmDialog.show(this, getString(R.string.update_install),
                getString(R.string.update_available, version), getString(R.string.update_install),
                getString(R.string.cancel), false, new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) { rootUpdate(true, dialog); }
        }, new Runnable() {
            public void run() {
                updateBusy = true;
                new Thread(new Runnable() {
                    public void run() {
                        if (!restoreModules()) updateMessage(getString(R.string.update_restore_pending));
                        finishUpdateWork(null);
                    }
                }, "hmg-seogaemo-update-restore").start();
            }
        });
    }

    private void confirmRollback() {
        if (updateBusy || stockBusy) return;
        ConfirmDialog.show(this, getString(R.string.update_rollback),
                getString(R.string.update_rollback_confirm), getString(R.string.update_rollback),
                getString(R.string.cancel), true, new ConfirmDialog.Action() {
            public void run(ConfirmDialog dialog) { rootUpdate(false, dialog); }
        }, null);
    }

    private void rootUpdate(final boolean install, final ConfirmDialog dialog) {
        updateBusy = true;
        dialog.showProgress();
        new Thread(new Runnable() { public void run() {
            try {
                if (!install) {
                    RootResult projection = RootClient.run("wireless-carplay-and-aa", "status");
                    if (!"absent".equals(projection.info.get("restore_material"))) {
                        updateMessage(getString(R.string.update_rollback_projection_blocked));
                        return;
                    }
                }
                if (install) { updateMessage(getString(R.string.update_staging)); UpdateClient.root("stage"); }
                updateMessage(getString(install ? R.string.update_applying : R.string.update_rolling_back));
                UpdateClient.root(install ? "apply" : "rollback");
                updateMessage(getString(restoreModules() ? R.string.update_complete : R.string.update_restore_pending));
            } catch (Exception e) {
                boolean restored = restoreModules();
                updateMessage(e.getMessage() + (restored ? "" : " \u00B7 " + getString(R.string.update_restore_pending)));
            } finally { finishUpdateWork(dialog); }
        }}, "hmg-seogaemo-update-root").start();
    }

    private static boolean moduleEnabled(RootResult result) {
        return result.desiredEnabled();
    }

    private String enabledModules() {
        StringBuilder enabled = new StringBuilder();
        for (Module module : ModuleRegistry.all()) {
            RootResult result = RootClient.run(module.id(), "status");
            if (moduleEnabled(result)) enabled.append(module.id()).append(',');
        }
        return enabled.toString();
    }

    private boolean restoreModules() {
        SharedPreferences pending = getSharedPreferences("update", MODE_PRIVATE);
        if (!pending.contains("restore")) return true;
        if (!pending.edit().putBoolean("resume", false).commit()) return false;
        if (pending.contains("restore_boot")) {
            if (!ModuleResume.restarted(pending.getString("restore_boot", ""), ModuleResume.bootId()))
                return false;
            if (!pending.edit().remove("restore_boot").commit()) return false;
        }
        String desired = pending.getString("restore", "");
        ModuleManager manager = new ModuleManager();
        boolean success = true;
        try {
        for (Module module : ModuleRegistry.all()) {
            boolean wanted = ("," + desired).contains("," + module.id() + ",");
            RootResult observed = RootClient.run(module.id(), "status");
            boolean active = moduleEnabled(observed) || "on".equals(observed.state);
            if (active && !wanted && !restoreModule(manager, module.id(), false, pending)) success = false;
        }
        for (Module module : ModuleRegistry.all()) {
            boolean wanted = ("," + desired).contains("," + module.id() + ",");
            RootResult observed = RootClient.run(module.id(), "status");
            boolean active = moduleEnabled(observed);
            if (wanted && (!active || "off".equals(observed.state)) &&
                    !restoreModule(manager, module.id(), true, pending)) success = false;
        }
        } catch (IllegalStateException error) { return false; }
        for (Module module : ModuleRegistry.all()) {
            boolean wanted = ("," + desired).contains("," + module.id() + ",");
            RootResult observed = RootClient.run(module.id(), "status");
            if (observed.exitCode != 0 || "pending-restart".equals(observed.state) ||
                    "head_unit".equals(observed.restart) ||
                    (wanted ? !moduleEnabled(observed) || !"on".equals(observed.state)
                            : moduleEnabled(observed) || !("off".equals(observed.state) ||
                                    "not-implemented".equals(observed.state)))) success = false;
        }
        if (success) {
            success = pending.edit().clear().commit();
            if (success) getSharedPreferences("module_resume", MODE_PRIVATE).edit().clear().commit();
        }
        return success;
    }

    private boolean restoreModule(ModuleManager manager, String id, boolean enable, SharedPreferences pending) {
        RootResult result = manager.execute(manager.plan(id, enable));
        if ("head_unit".equals(result.restart)) {
            pending.edit().putString("restore_boot", ModuleResume.bootId()).commit();
            return false;
        }
        return result.exitCode == 0;
    }

    private void addCategory(LinearLayout parent, final int index) {
        boolean selected = index == category;
        LinearLayout row = horizontal();
        row.setPadding(dp(SettingsUi.LG), 0, dp(SettingsUi.MD), 0);
        row.setBackgroundDrawable(selectable(selected ? Theme.SELECTED : SURFACE, Color.TRANSPARENT, 0, false));
        View marker = new View(this);
        marker.setBackgroundColor(selected ? BLUE : Color.TRANSPARENT);
        row.addView(marker, new LinearLayout.LayoutParams(dp(4), dp(56)));
        ImageView glyph = new ImageView(this);
        glyph.setScaleType(ImageView.ScaleType.CENTER);
        glyph.setImageDrawable(new LineIcon(this, CATEGORY_ICONS[index], selected ? WHITE : MUTED, 24));
        LinearLayout.LayoutParams glyphParams = new LinearLayout.LayoutParams(dp(28), dp(28));
        glyphParams.leftMargin = dp(SettingsUi.MD);
        row.addView(glyph, glyphParams);
        TextView name = text(getString(CATEGORIES[index]), 22, selected ? WHITE : Theme.DIM, medium);
        name.setPadding(dp(SettingsUi.MD), 0, 0, 0);
        row.addView(name, new LinearLayout.LayoutParams(0, -1, 1));
        row.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { category = index; showSettings(); }
        });
        parent.addView(row, new LinearLayout.LayoutParams(-1, dp(70)));
        divider(parent, false);
    }

    private String installedVersion() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "?";
        }
    }

    private void addRow(LinearLayout parent, int label, int sub, String value) {
        LinearLayout row = horizontal();
        SettingsUi.contentRow(this, row);
        row.setBackgroundDrawable(selectable(CANVAS, Color.TRANSPARENT, 0, false));
        LinearLayout copy = vertical();
        copy.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = text(getString(label), 24, WHITE, medium);
        TextView detail = text(getString(sub), 18, MUTED, sans);
        SettingsUi.titleBlock(this, copy, title, detail);
        row.addView(copy, new LinearLayout.LayoutParams(0, -1, 1));
        TextView trailing = text(value, 20, WHITE, sans);
        trailing.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams valueParams = new LinearLayout.LayoutParams(dp(240), -1);
        valueParams.leftMargin = dp(SettingsUi.MD);
        row.addView(trailing, valueParams);
        parent.addView(row, new LinearLayout.LayoutParams(-1, dp(75)));
        divider(parent, false);
    }

    private TextView action(String label, boolean primary) {
        return Theme.button(this, label, primary, false);
    }

    /** HMG's finishActivity() may reject a missing GET_TASKS grant. */
    private void close() {
        try { finish(); }
        catch (SecurityException denied) {
            try { moveTaskToBack(true); }
            catch (Throwable ignored) { }
        }
    }

    @Override public void onBackPressed() {
        if (detailId != null || addVisible) goBack();
        else if (tab != Tab.FEATURES) selectTab(Tab.FEATURES);
        else close();
    }
}
